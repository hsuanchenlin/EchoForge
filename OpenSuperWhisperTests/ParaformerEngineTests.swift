import XCTest
@testable import OpenSuperWhisper

/// Regression coverage for the Paraformer engine's chunk-handling loop.
///
/// The failure this whole engine is shaped around is silent: FluidAudio's
/// Paraformer decoder clamps to 128 output tokens with no log and no error, and
/// its preprocessor throws outside 3,200...480,000 samples. Measured on the
/// pinned 0.15.4, a 28.1 s clip came back as 127 characters of a 200-character
/// script at 35.8 % CER, and 0.53 % once chunked.
///
/// So the fake model here is not a stub that returns a canned string - it
/// *reproduces both limits*. It refuses audio outside the accepted range and it
/// clamps its own output at 128 characters, which means a test asserting the
/// full script came back is asserting that the engine never handed it too much
/// audio. Feeding the whole recording in one call fails these tests the same way
/// it fails in production.
///
/// The identifiers (C1-C5, F1-F3, F6) are the runtime report's. No model weights
/// are downloaded: the seams are `AudioChunkProviding` and
/// `ParaformerTranscribing`, and the real `AudioChunker` runs underneath.
final class ParaformerEngineTests: XCTestCase {

    private let sampleRate = 16_000

    /// The planning speech rate `AudioChunkBudget.paraformerZh` is derived from:
    /// 128 tokens at 9 tokens/s is what makes a ~14.2 s chunk the safe size.
    private static let samplesPerCharacter = 16_000 / 9

    // MARK: - Fixtures

    /// Samples that carry their own offset, so the fake model can tell which
    /// part of the recording it was handed.
    private func positionEncodedSamples(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map(Float.init)
    }

    private func segment(_ start: Double, _ end: Double) -> WhisperVadSegment {
        WhisperVadSegment(startCs: Int64(start * 100), endCs: Int64(end * 100))
    }

    /// What a perfect transcription of `range` would be, at the planning rate.
    /// One distinct character per grid point, so a dropped chunk is visible as a
    /// gap rather than as a shorter run of the same character.
    private func script(covering range: Range<Int>) -> String {
        let first = (range.lowerBound + Self.samplesPerCharacter - 1) / Self.samplesPerCharacter
        let last = (range.upperBound + Self.samplesPerCharacter - 1) / Self.samplesPerCharacter
        return String(
            (first..<last).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) }
        )
    }

    private func makeEngine(
        samples: [Float],
        segments: [WhisperVadSegment]
    ) -> (ParaformerEngine, StubChunkProvider, ClampedFakeTranscriber) {
        let provider = StubChunkProvider(samples: samples, segments: segments)
        let model = ClampedFakeTranscriber(samplesPerCharacter: Self.samplesPerCharacter)
        let engine = ParaformerEngine(chunkSource: provider, loadTranscriber: { model })
        return (engine, provider, model)
    }

    private func transcribe(_ engine: ParaformerEngine) async throws -> String {
        try await engine.initialize()
        return try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
    }

    // MARK: - F3: long audio is split, never truncated

    /// 44.78 s - the fixture that threw in one shot and lost three quarters of
    /// its characters when the throw was worked around by truncating.
    func testF3_longAudioIsTranscribedWhole() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, 44.78)])

        let text = try await transcribe(engine)

        XCTAssertEqual(
            text, script(covering: 0..<audio.count),
            "the transcript must be the whole script - a missing run of characters is audio the engine dropped"
        )
        XCTAssertGreaterThan(
            text.count, 127,
            "127 characters is what a single clamped call produces; anything at or below it is the bug"
        )
        XCTAssertGreaterThan(model.receivedRanges.count, 1, "44.78 s cannot be one call")
    }

    /// The closing sentence is the part a truncating engine loses, and the part
    /// a user notices.
    func testF3_theTailOfTheRecordingSurvives() async throws {
        let audio = positionEncodedSamples(seconds: 87.6)
        let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, 87.6)])

        let text = try await transcribe(engine)

        let tail = try XCTUnwrap(script(covering: 0..<audio.count).last)
        XCTAssertEqual(text.last, tail, "the last character of the script is the closing marker sentence")
        XCTAssertEqual(model.receivedRanges.last?.upperBound, audio.count)
    }

    /// Speech separated by 36 s of digital silence: both marker sentences must
    /// come back, and the silence must never reach the model, which answers it
    /// with hallucinated text.
    func testF3_speechAroundLongSilenceIsKeptAndTheSilenceIsNot() async throws {
        let audio = positionEncodedSamples(seconds: 40.64)
        let segments = [segment(0, 0.9), segment(39.2, 40.6)]
        let (engine, _, model) = makeEngine(samples: audio, segments: segments)

        let text = try await transcribe(engine)

        XCTAssertEqual(model.receivedRanges.count, 2, "the 36 s of silence must not become a call")
        XCTAssertFalse(text.isEmpty)
        for segment in segments {
            let range = Int(segment.startCs) * sampleRate / 100..<Int(segment.endCs) * sampleRate / 100
            XCTAssertTrue(
                model.receivedRanges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound },
                "speech at \(range) was never sent to the model"
            )
        }
    }

    // MARK: - F2 / C3: the silent 128-token clamp

    /// 28.14 s is inside the 30 s ceiling, so nothing throws - the engine has to
    /// chunk it anyway or the decoder quietly keeps 127 characters of it.
    func testF2_denseSpeechInsideTheCeilingIsStillChunked() async throws {
        let audio = positionEncodedSamples(seconds: 28.14)
        let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, 28.14)])

        let text = try await transcribe(engine)

        XCTAssertGreaterThan(model.receivedRanges.count, 1, "a 28.1 s clip in one call returns 127 characters")
        XCTAssertGreaterThan(text.count, 150, "the runtime report's F2 threshold: one-shot yields 127")
        XCTAssertEqual(text, script(covering: 0..<audio.count))
    }

    func testC3_noCallEverExceedsTheTokenBudget() async throws {
        let audio = positionEncodedSamples(seconds: 175)
        let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, 175)])

        _ = try await transcribe(engine)

        for range in model.receivedRanges {
            XCTAssertLessThanOrEqual(
                range.count, AudioChunkBudget.paraformerZh.preferredSamples,
                "a call longer than the token-derived budget is a call whose tail is silently dropped"
            )
        }
    }

    /// The engine must ask for the shared preset rather than inventing limits of
    /// its own - that preset is where the measured constraints are documented.
    func testC3_theSharedParaformerBudgetIsWhatIsRequested() async throws {
        let audio = positionEncodedSamples(seconds: 10)
        let (engine, provider, _) = makeEngine(samples: audio, segments: [segment(0, 10)])

        _ = try await transcribe(engine)

        XCTAssertEqual(provider.requestedBudgets, [.paraformerZh])
    }

    // MARK: - F1: the accepted input range

    func testF1_everyCallIsInsideTheRangeCoreMLAccepts() async throws {
        for duration in [1.0, 13.9, 29.9, 30.1, 44.78, 90.0, 175.0] {
            let audio = positionEncodedSamples(seconds: duration)
            let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, duration)])

            _ = try await transcribe(engine)

            XCTAssertFalse(model.receivedRanges.isEmpty, "\(duration)s produced no calls")
            for range in model.receivedRanges {
                XCTAssertGreaterThanOrEqual(range.count, 3_200, "\(duration)s: under the floor, CoreML throws")
                XCTAssertLessThanOrEqual(range.count, 480_000, "\(duration)s: over the ceiling, CoreML throws")
            }
        }
    }

    // MARK: - F6 / C5: the silence gate

    func testF6_silenceIsAnEmptyTranscriptAndNeverReachesTheModel() async throws {
        let audio = positionEncodedSamples(seconds: 5)
        let (engine, _, model) = makeEngine(samples: audio, segments: [])

        let text = try await transcribe(engine)

        XCTAssertEqual(text, "", "silence transcribes as 嗯嗯嗯… if it reaches the model")
        XCTAssertTrue(model.receivedRanges.isEmpty)
    }

    func testF6_silenceStillCompletesTheProgressBar() async throws {
        let (engine, _, _) = makeEngine(samples: positionEncodedSamples(seconds: 5), segments: [])
        var reported: [Float] = []
        engine.onProgressUpdate = { reported.append($0) }

        _ = try await transcribe(engine)

        XCTAssertEqual(reported.last, 1.0, "an empty transcript must not leave the bar hanging")
    }

    // MARK: - Progress

    func testProgressIsReportedPerChunkAndReachesOne() async throws {
        let audio = positionEncodedSamples(seconds: 87.6)
        let (engine, _, model) = makeEngine(samples: audio, segments: [segment(0, 87.6)])
        var reported: [Float] = []
        engine.onProgressUpdate = { reported.append($0) }

        _ = try await transcribe(engine)

        XCTAssertGreaterThanOrEqual(
            reported.count, model.receivedRanges.count,
            "a 6-chunk recording that reports twice looks stalled for most of a minute"
        )
        XCTAssertEqual(reported.first, 0.02)
        XCTAssertEqual(reported.last, 1.0)
        for pair in zip(reported, reported.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1, "progress must never go backwards")
        }
    }

    // MARK: - Output shape

    /// Paraformer's vocab8404 carries no punctuation and Mandarin has no word
    /// spaces, so anything inserted between chunks is text the user did not say.
    func testChunksAreJoinedWithoutInventedSeparators() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let (engine, _, _) = makeEngine(samples: audio, segments: [segment(0, 44.78)])

        let text = try await transcribe(engine)

        XCTAssertFalse(text.contains(" "))
        XCTAssertFalse(text.contains("\n"))
        for punctuation in ["，", "。", ",", ".", "、"] {
            XCTAssertFalse(text.contains(punctuation), "the engine must not invent \(punctuation)")
        }
    }

    func testEmptyChunkResultsAreDroppedRatherThanPaddingTheTranscript() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let provider = StubChunkProvider(samples: audio, segments: [segment(0, 44.78)])
        let model = ClampedFakeTranscriber(samplesPerCharacter: Self.samplesPerCharacter, returnsEmpty: true)
        let engine = ParaformerEngine(chunkSource: provider, loadTranscriber: { model })

        let text = try await transcribe(engine)

        XCTAssertEqual(text, "", "a model that recognised nothing must not produce whitespace")
    }

    // MARK: - Lifecycle

    func testTranscribingBeforeInitializeThrows() async {
        let (engine, _, model) = makeEngine(samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)])

        do {
            _ = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("Transcribing without a loaded model must throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .contextInitializationFailed)
        }
        XCTAssertTrue(model.receivedRanges.isEmpty)
    }

    func testIsModelLoadedOnlyAfterInitialize() async throws {
        let (engine, _, _) = makeEngine(samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)])

        XCTAssertFalse(engine.isModelLoaded)
        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded)
    }

    func testCancellationStopsBeforeTheNextChunk() async throws {
        let audio = positionEncodedSamples(seconds: 175)
        let provider = StubChunkProvider(samples: audio, segments: [segment(0, 175)])
        let model = ClampedFakeTranscriber(samplesPerCharacter: Self.samplesPerCharacter)
        let engine = ParaformerEngine(chunkSource: provider, loadTranscriber: { model })
        model.onCall = { [weak engine] count in
            if count == 2 { engine?.cancelTranscription() }
        }

        try await engine.initialize()
        do {
            _ = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("A cancelled transcription must not return a partial transcript as if it were complete")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(model.receivedRanges.count, 2, "the remaining chunks must not be decoded")
    }

    /// A cancelled recording must not poison the next one.
    func testANewTranscriptionClearsAPreviousCancellation() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let (engine, _, _) = makeEngine(samples: audio, segments: [segment(0, 44.78)])

        try await engine.initialize()
        engine.cancelTranscription()

        let text = try await engine.transcribeAudio(
            url: URL(fileURLWithPath: "/dev/null"), settings: Settings()
        )
        XCTAssertEqual(text, script(covering: 0..<audio.count))
    }

    // MARK: - Language

    func testSupportedLanguagesAreMandarinOnly() async {
        let (engine, _, _) = makeEngine(samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)])
        XCTAssertEqual(engine.getSupportedLanguages(), ["zh"])
    }

    // MARK: - Non-Mandarin input

    /// The language lock is a picker setting, and a picker cannot stop somebody
    /// speaking English. What the model returns then is not a poor transcript,
    /// it is the tokeniser's own sub-word units, and it used to be pasted into
    /// whatever the user was typing in.
    ///
    /// `ParaformerLanguageGuard` owns the classification and is tested on its
    /// own; what is asserted here is that the engine consults it, and that a
    /// refused transcript is a thrown error rather than a returned string.
    func testFragmentedOutputFailsTheDictationInsteadOfReturningIt() async throws {
        let engine = engineReturning("how@@ ever the mee@@ ting is on tues@@ day")

        try await engine.initialize()
        do {
            let text = try await engine.transcribeAudio(
                url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("tokeniser fragments were returned as a transcript: \(text)")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, ParaformerLanguageGuard.failure)
        }
    }

    /// The same case with nothing for the marker rule to find - the model also
    /// returns whole Latin words, and the day upstream starts detokenising it
    /// will return them every time. The engine must fail identically.
    func testUnmarkedNonMandarinOutputAlsoFailsTheDictation() async throws {
        let engine = engineReturning("the meeting is on tuesday afternoon")

        try await engine.initialize()
        do {
            let text = try await engine.transcribeAudio(
                url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("an English transcript was returned by a Mandarin-only engine: \(text)")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, ParaformerLanguageGuard.failure)
        }
    }

    /// The failure has to be the one that keeps the user's audio. A dictation
    /// refused for its language is not a decode that produced nothing: the
    /// recording is good and transcribes on another engine.
    func testARefusedDictationIsReportedAsOneWorthKeepingTheAudioFor() async throws {
        let engine = engineReturning("please send me the report before friday")

        try await engine.initialize()
        do {
            _ = try await engine.transcribeAudio(
                url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("the dictation was not refused")
        } catch {
            XCTAssertEqual(
                DictationFailureOutcome.forError(error),
                .keep(
                    reason: ParaformerLanguageGuard.message,
                    indicatorState: .wrongLanguage(ParaformerLanguageGuard.shortMessage)))
        }
    }

    /// Fragments spliced across chunks are still fragments. The guard reads the
    /// joined transcript, so a marker in any chunk refuses the recording rather
    /// than only the chunk it fell in.
    func testFragmentsInOneChunkOfManyStillRefuseTheRecording() async throws {
        let provider = StubChunkProvider(
            samples: positionEncodedSamples(seconds: 44.78), segments: [segment(0, 44.78)])
        let model = ScriptedFakeTranscriber(
            responses: ["今天的會議紀錄", "已經整理好了", "sched@@ ule", "請大家過目"])
        let engine = ParaformerEngine(chunkSource: provider, loadTranscriber: { model })

        try await engine.initialize()
        do {
            let text = try await engine.transcribeAudio(
                url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("a transcript carrying tokeniser fragments was returned: \(text)")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, ParaformerLanguageGuard.failure)
        }
    }

    /// The guard must be invisible to the engine's actual job. Every other test
    /// in this file transcribes Han characters and would fail if it were not, but
    /// this says so directly.
    func testMandarinIsUnaffectedByTheGuard() async throws {
        let engine = engineReturning("今天天氣很好我們去公園散步吧")

        try await engine.initialize()
        let text = try await engine.transcribeAudio(
            url: URL(fileURLWithPath: "/dev/null"), settings: Settings())

        XCTAssertEqual(text, "今天天氣很好我們去公園散步吧")
    }

    /// A short recording is not evidence of a language, and refusing one would
    /// refuse a legitimate two-word Mandarin dictation that mentions a product
    /// name.
    func testAShortMixedTranscriptIsNotRefused() async throws {
        let engine = engineReturning("好的OK")

        try await engine.initialize()
        let text = try await engine.transcribeAudio(
            url: URL(fileURLWithPath: "/dev/null"), settings: Settings())

        XCTAssertEqual(text, "好的OK")
    }

    /// One 10 s recording, one chunk, one canned answer - so a test about what
    /// the engine does with the model's output is not also a test about chunking.
    private func engineReturning(_ response: String) -> ParaformerEngine {
        let provider = StubChunkProvider(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)])
        return ParaformerEngine(
            chunkSource: provider, loadTranscriber: { ScriptedFakeTranscriber(responses: [response]) })
    }
}

/// Returns what it was told to, chunk by chunk, with the last answer repeated
/// once it runs out. Unlike `ClampedFakeTranscriber` it models nothing about the
/// decoder - these tests are about the string the engine is handed, not about
/// how much audio produced it.
private final class ScriptedFakeTranscriber: ParaformerTranscribing {
    private let responses: [String]
    private var callCount = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func transcribe(audio: [Float]) async throws -> String {
        defer { callCount += 1 }
        return responses[min(callCount, responses.count - 1)]
    }
}

/// Hands the engine chunks from the *real* `AudioChunker`, without decoding a
/// file or loading the VAD - so what these tests exercise is the production
/// chunking, not a re-implementation of it.
private final class StubChunkProvider: AudioChunkProviding {
    private let samples: [Float]
    private let segments: [WhisperVadSegment]
    private(set) var requestedBudgets: [AudioChunkBudget] = []

    init(samples: [Float], segments: [WhisperVadSegment]) {
        self.samples = samples
        self.segments = segments
    }

    func chunks(for url: URL, budget: AudioChunkBudget) async throws -> [AudioChunk] {
        requestedBudgets.append(budget)
        guard !segments.isEmpty else { return [] }
        return AudioChunker.chunks(from: samples, segments: segments, budget: budget)
    }
}

/// A stand-in for `ParaformerManager` that reproduces the two limits that make
/// this engine non-trivial: it throws outside the accepted sample range, and it
/// clamps its output at 128 characters.
///
/// It reads its own offset out of the position-encoded samples it is given, so
/// it can report exactly which part of the recording it was asked to transcribe.
private final class ClampedFakeTranscriber: ParaformerTranscribing {
    private static let tokenLimit = 128
    private static let acceptedSamples = 3_200...480_000

    private let samplesPerCharacter: Int
    private let returnsEmpty: Bool

    private(set) var receivedRanges: [Range<Int>] = []
    var onCall: ((Int) -> Void)?

    init(samplesPerCharacter: Int, returnsEmpty: Bool = false) {
        self.samplesPerCharacter = samplesPerCharacter
        self.returnsEmpty = returnsEmpty
    }

    func transcribe(audio: [Float]) async throws -> String {
        guard Self.acceptedSamples.contains(audio.count) else {
            throw NSError(
                domain: "com.apple.CoreML", code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Size (\(audio.count)) of dimension (1) is not in allowed range (3200..480000)"
                ]
            )
        }

        let start = Int(audio.first ?? 0)
        let range = start..<(start + audio.count)
        receivedRanges.append(range)
        onCall?(receivedRanges.count)

        if returnsEmpty { return "" }

        let first = (range.lowerBound + samplesPerCharacter - 1) / samplesPerCharacter
        let last = (range.upperBound + samplesPerCharacter - 1) / samplesPerCharacter
        let characters = (first..<last).prefix(Self.tokenLimit)
        return String(characters.compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) })
    }
}
