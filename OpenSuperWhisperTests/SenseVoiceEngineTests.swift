import XCTest
@testable import OpenSuperWhisper

/// Regression coverage for the SenseVoice engine's chunk-handling loop and for
/// the two decode inputs that fail silently if they are wrong.
///
/// The fake model here is not a stub returning a canned string - it *reproduces
/// the limits that make this engine non-trivial*. It throws outside the
/// 3,200...480,000 sample range CoreML accepts, and it renders its output the way
/// the real model does under the options it was configured with: punctuated
/// Mandarin at `textNorm 14`, bare characters at `15`. So a test asserting the
/// transcript is punctuated is asserting the engine asked for the right decode
/// flag, and a test asserting the whole script came back is asserting the engine
/// never handed the model more audio than it accepts.
///
/// The identifiers (C1, C2, C5-C8, F1, F3, F6) are the runtime report's. No model
/// weights are downloaded: the seams are `AudioChunkProviding` and
/// `SenseVoiceTranscriberFactory`, and the real `AudioChunker` runs underneath.
final class SenseVoiceEngineTests: XCTestCase {

    private let sampleRate = 16_000

    /// One character per this many samples in the fake's rendered script - a
    /// plausible dense-Mandarin rate, and the grid `script(covering:)` shares so
    /// a dropped chunk shows up as a gap.
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

    /// What a perfect transcription of `range` would be, with the punctuation
    /// `textNorm 14` produces stripped back out - the comparison every
    /// completeness assertion needs.
    private func script(covering range: Range<Int>) -> String {
        let first = (range.lowerBound + Self.samplesPerCharacter - 1) / Self.samplesPerCharacter
        let last = (range.upperBound + Self.samplesPerCharacter - 1) / Self.samplesPerCharacter
        return String((first..<last).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) })
    }

    private func makeEngine(
        samples: [Float],
        segments: [WhisperVadSegment],
        script: FakeSenseVoiceScript = .mandarin
    ) -> (SenseVoiceEngine, StubSenseVoiceChunkProvider, FakeSenseVoiceFactory) {
        let provider = StubSenseVoiceChunkProvider(samples: samples, segments: segments)
        let factory = FakeSenseVoiceFactory(
            samplesPerCharacter: Self.samplesPerCharacter,
            script: script
        )
        let engine = SenseVoiceEngine(chunkSource: provider, loadFactory: { factory })
        return (engine, provider, factory)
    }

    private func transcribe(
        _ engine: SenseVoiceEngine,
        language: String = "zh"
    ) async throws -> String {
        try await engine.initialize()
        var settings = Settings()
        settings.selectedLanguage = language
        return try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
    }

    /// The transcript with the model's punctuation removed, for comparing
    /// against `script(covering:)`.
    private func characters(of text: String) -> String {
        text.filter { !"，。".contains($0) }
    }

    // MARK: - C6 / C7: the decode flags that fail silently

    /// The single highest-value assertion in this file. `SenseVoiceConfig`'s
    /// default is `15` and `SenseVoiceManager.load()` hardcodes it, so the
    /// natural-looking implementation ships an engine with no punctuation and no
    /// ITN - the exact opposite of why this engine is the Chinese default, with
    /// nothing failing to make it visible.
    func testC6_theEngineAsksForPunctuationAndItn() async throws {
        let (engine, _, factory) = makeEngine(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
        )

        _ = try await transcribe(engine)

        XCTAssertEqual(
            factory.requestedOptions.map(\.textNorm), [14],
            "textNorm 15 is FluidAudio's default and means no punctuation and no ITN"
        )
    }

    func testC7_theTranscriptIsPunctuated() async throws {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 44.78), segments: [segment(0, 44.78)]
        )

        let text = try await transcribe(engine)

        XCTAssertTrue(text.contains("。"), "punctuation is what this engine is chosen for: \(text)")
    }

    /// A recording is one model configuration, not one per chunk: the options
    /// are encoder inputs and rebuilding them per chunk would let a language
    /// change mid-transcript.
    func testTheModelIsConfiguredOncePerRecording() async throws {
        let (engine, _, factory) = makeEngine(
            samples: positionEncodedSamples(seconds: 87.6), segments: [segment(0, 87.6)]
        )

        _ = try await transcribe(engine)

        XCTAssertEqual(factory.requestedOptions.count, 1)
        XCTAssertGreaterThan(factory.transcriber.receivedRanges.count, 1, "87.6 s cannot be one call")
    }

    // MARK: - C8: the language embedding the app owns

    func testC8_eachSupportedLanguageIsSentAsItsEmbedIndex() async throws {
        let expected: [String: Int32] = ["auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12]

        for (code, index) in expected {
            let (engine, _, factory) = makeEngine(
                samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
            )

            _ = try await transcribe(engine, language: code)

            XCTAssertEqual(
                factory.requestedOptions.first?.language.embedIndex, index,
                "\(code) must reach the encoder as embedding \(index)"
            )
        }
    }

    /// FluidAudio validates nothing here: an out-of-range index neither throws
    /// nor clamps, it silently mis-conditions the model. A language the model
    /// has no embedding for has to become auto-detect.
    func testC8_anUnsupportedLanguageBecomesAutoDetect() async throws {
        for code in ["de", "he", "", "zh-Hant"] {
            let (engine, _, factory) = makeEngine(
                samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
            )

            _ = try await transcribe(engine, language: code)

            XCTAssertEqual(
                factory.requestedOptions.first?.language, .auto,
                "\(code) has no embedding, so the model must be left to detect the language"
            )
        }
    }

    func testC8_supportedLanguagesAreTheSixWithEmbeddings() async {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
        )
        XCTAssertEqual(engine.getSupportedLanguages(), ["auto", "zh", "yue", "en", "ja", "ko"])
    }

    // MARK: - F3 / C1: long audio is split, never truncated

    /// 44.78 s is past the 30 s ceiling, where a single call throws outright.
    func testF3_longAudioIsTranscribedWhole() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let (engine, _, factory) = makeEngine(samples: audio, segments: [segment(0, 44.78)])

        let text = try await transcribe(engine)

        XCTAssertEqual(
            characters(of: text), script(covering: 0..<audio.count),
            "a missing run of characters is audio the engine dropped"
        )
        XCTAssertGreaterThan(factory.transcriber.receivedRanges.count, 1, "44.78 s cannot be one call")
    }

    /// The closing sentence is the part a truncating engine loses, and the part
    /// a user notices.
    func testF3_theTailOfTheRecordingSurvives() async throws {
        let audio = positionEncodedSamples(seconds: 175)
        let (engine, _, factory) = makeEngine(samples: audio, segments: [segment(0, 175)])

        let text = try await transcribe(engine)

        let tail = try XCTUnwrap(script(covering: 0..<audio.count).last)
        XCTAssertEqual(characters(of: text).last, tail)
        XCTAssertEqual(factory.transcriber.receivedRanges.last?.upperBound, audio.count)
    }

    /// Speech separated by 36 s of digital silence: both marker sentences must
    /// come back, and the silence must never reach the model, which answers it
    /// with hallucinated text.
    func testF3_speechAroundLongSilenceIsKeptAndTheSilenceIsNot() async throws {
        let audio = positionEncodedSamples(seconds: 40.64)
        let segments = [segment(0, 0.9), segment(39.2, 40.6)]
        let (engine, _, factory) = makeEngine(samples: audio, segments: segments)

        let text = try await transcribe(engine)

        XCTAssertEqual(factory.transcriber.receivedRanges.count, 2, "the 36 s of silence must not become a call")
        XCTAssertFalse(text.isEmpty)
        for segment in segments {
            let range = Int(segment.startCs) * sampleRate / 100..<Int(segment.endCs) * sampleRate / 100
            XCTAssertTrue(
                factory.transcriber.receivedRanges.contains {
                    $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound
                },
                "speech at \(range) was never sent to the model"
            )
        }
    }

    // MARK: - F1 / C1 / C2: the accepted input range

    func testF1_everyCallIsInsideTheRangeCoreMLAccepts() async throws {
        for duration in [1.0, 27.9, 29.9, 30.1, 44.78, 90.0, 175.0] {
            let audio = positionEncodedSamples(seconds: duration)
            let (engine, _, factory) = makeEngine(samples: audio, segments: [segment(0, duration)])

            _ = try await transcribe(engine)

            XCTAssertFalse(factory.transcriber.receivedRanges.isEmpty, "\(duration)s produced no calls")
            for range in factory.transcriber.receivedRanges {
                XCTAssertGreaterThanOrEqual(range.count, 3_200, "\(duration)s: under the floor, CoreML throws")
                XCTAssertLessThanOrEqual(range.count, 480_000, "\(duration)s: over the ceiling, CoreML throws")
            }
        }
    }

    /// The engine must ask for the shared preset rather than inventing limits of
    /// its own - that preset is where the measured constraints are documented,
    /// and it is deliberately not Paraformer's.
    func testTheSharedSenseVoiceBudgetIsWhatIsRequested() async throws {
        let (engine, provider, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
        )

        _ = try await transcribe(engine)

        XCTAssertEqual(provider.requestedBudgets, [.senseVoiceSmall])
        XCTAssertNotEqual(
            AudioChunkBudget.senseVoiceSmall, .paraformerZh,
            "SenseVoice has no token clamp, so it must not inherit Paraformer's shorter chunks"
        )
    }

    // MARK: - F6 / C5: the silence gate

    func testF6_silenceIsAnEmptyTranscriptAndNeverReachesTheModel() async throws {
        let (engine, _, factory) = makeEngine(samples: positionEncodedSamples(seconds: 5), segments: [])

        let text = try await transcribe(engine)

        XCTAssertEqual(text, "", "silence transcribes as 我. if it reaches the model")
        XCTAssertTrue(factory.transcriber.receivedRanges.isEmpty)
    }

    func testF6_silenceStillCompletesTheProgressBar() async throws {
        let (engine, _, _) = makeEngine(samples: positionEncodedSamples(seconds: 5), segments: [])
        var reported: [Float] = []
        engine.onProgressUpdate = { reported.append($0) }

        _ = try await transcribe(engine)

        XCTAssertEqual(reported.last, 1.0, "an empty transcript must not leave the bar hanging")
    }

    // MARK: - Progress

    /// At ~8x real time a 175 s recording is most of a minute of decoding, so a
    /// bar that only moves at the ends reads as a hang.
    func testProgressIsReportedPerChunkAndReachesOne() async throws {
        let (engine, _, factory) = makeEngine(
            samples: positionEncodedSamples(seconds: 175), segments: [segment(0, 175)]
        )
        var reported: [Float] = []
        engine.onProgressUpdate = { reported.append($0) }

        _ = try await transcribe(engine)

        XCTAssertGreaterThanOrEqual(reported.count, factory.transcriber.receivedRanges.count)
        XCTAssertEqual(reported.first, 0.02)
        XCTAssertEqual(reported.last, 1.0)
        for pair in zip(reported, reported.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1, "progress must never go backwards")
        }
    }

    // MARK: - Joining chunks

    /// Chinese and Japanese do not separate words, and the model punctuates, so
    /// a seam that inserts a space is visible damage.
    func testMandarinChunksAreJoinedWithoutInventedSpaces() async throws {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 90), segments: [segment(0, 90)]
        )

        let text = try await transcribe(engine)

        XCTAssertFalse(text.contains(" "), "a space between two Han characters is text the user did not say")
        XCTAssertFalse(text.contains("\n"))
    }

    /// English is the mirror image: gluing `gold.` to `The` is equally visible,
    /// and this engine transcribes English too.
    func testLatinScriptChunksAreJoinedWithASpace() async throws {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 90),
            segments: [segment(0, 90)],
            script: .english
        )

        let text = try await transcribe(engine, language: "en")

        XCTAssertFalse(text.contains(".The"), "two chunks were glued into one word: \(text)")
        XCTAssertTrue(text.contains(". The"))
    }

    func testEmptyChunkResultsAreDroppedRatherThanPaddingTheTranscript() async throws {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 44.78),
            segments: [segment(0, 44.78)],
            script: .empty
        )

        let text = try await transcribe(engine)

        XCTAssertEqual(text, "", "a model that recognised nothing must not produce whitespace")
    }

    // MARK: - Lifecycle

    func testTranscribingBeforeInitializeThrows() async {
        let (engine, _, factory) = makeEngine(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
        )

        do {
            _ = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("Transcribing without a loaded model must throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .contextInitializationFailed)
        }
        XCTAssertTrue(factory.transcriber.receivedRanges.isEmpty)
    }

    func testIsModelLoadedOnlyAfterInitialize() async throws {
        let (engine, _, _) = makeEngine(
            samples: positionEncodedSamples(seconds: 10), segments: [segment(0, 10)]
        )

        XCTAssertFalse(engine.isModelLoaded)
        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded)
    }

    func testCancellationStopsBeforeTheNextChunk() async throws {
        let (engine, _, factory) = makeEngine(
            samples: positionEncodedSamples(seconds: 175), segments: [segment(0, 175)]
        )
        factory.transcriber.onCall = { [weak engine] count in
            if count == 2 { engine?.cancelTranscription() }
        }

        try await engine.initialize()
        do {
            _ = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: Settings())
            XCTFail("A cancelled transcription must not return a partial transcript as if it were complete")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(factory.transcriber.receivedRanges.count, 2, "the remaining chunks must not be decoded")
    }

    /// A cancelled recording must not poison the next one.
    func testANewTranscriptionClearsAPreviousCancellation() async throws {
        let audio = positionEncodedSamples(seconds: 44.78)
        let (engine, _, _) = makeEngine(samples: audio, segments: [segment(0, 44.78)])

        try await engine.initialize()
        engine.cancelTranscription()

        var settings = Settings()
        settings.selectedLanguage = "zh"
        let text = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
        XCTAssertEqual(characters(of: text), script(covering: 0..<audio.count))
    }
}

/// F7. The download the user pays for lands in a folder whose name is not the
/// Hugging Face slug - `Repo.folderName` strips `-coreml` - so anything that
/// shows or clears the cache has to ask FluidAudio rather than rebuild the path.
/// Cheap, and it catches the rename on a FluidAudio bump.
final class SenseVoiceModelCacheTests: XCTestCase {

    func testF7_theCacheFolderIsTheOneFluidAudioActuallyWritesTo() {
        let directory = SenseVoiceEngine.modelCacheDirectory

        XCTAssertEqual(directory.lastPathComponent, "sensevoice-small")
        XCTAssertNotEqual(directory.lastPathComponent, "sensevoice-small-coreml")
        XCTAssertTrue(
            directory.path.contains("Application Support/FluidAudio/Models"),
            "the models live in FluidAudio's shared cache, not in the app's container: \(directory.path)"
        )
    }
}

/// Hands the engine chunks from the *real* `AudioChunker`, without decoding a
/// file or loading the VAD - so what these tests exercise is the production
/// chunking, not a re-implementation of it.
private final class StubSenseVoiceChunkProvider: AudioChunkProviding {
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

/// What the fake model writes, so the joining rule can be exercised in both of
/// the writing systems this engine has to serve.
private enum FakeSenseVoiceScript {
    /// Han characters, with `，` inside a chunk and `。` at its end - what
    /// `textNorm 14` produces.
    case mandarin
    /// Space-separated words ending in `.`, starting with a capital.
    case english
    /// Recognised nothing.
    case empty
}

/// Records what the engine asked the model to be, and hands back one transcriber
/// so a test can inspect the calls it received.
private final class FakeSenseVoiceFactory: SenseVoiceTranscriberFactory {
    let transcriber: RangeRecordingSenseVoiceTranscriber
    private(set) var requestedOptions: [SenseVoiceModelOptions] = []

    init(samplesPerCharacter: Int, script: FakeSenseVoiceScript) {
        transcriber = RangeRecordingSenseVoiceTranscriber(
            samplesPerCharacter: samplesPerCharacter, script: script
        )
    }

    func makeTranscriber(_ options: SenseVoiceModelOptions) -> SenseVoiceTranscribing {
        requestedOptions.append(options)
        transcriber.textNorm = options.textNorm
        return transcriber
    }
}

/// A stand-in for `SenseVoiceManager` that reproduces the constraints that make
/// this engine non-trivial: it throws outside the accepted sample range, and it
/// punctuates only when it was configured to.
///
/// It reads its own offset out of the position-encoded samples it is given, so
/// it can report exactly which part of the recording it was asked to transcribe.
private final class RangeRecordingSenseVoiceTranscriber: SenseVoiceTranscribing {
    private static let acceptedSamples = 3_200...480_000

    /// FluidAudio's `withitn` embed index. The fake punctuates for this value
    /// and for nothing else, exactly as the model does.
    private static let withItn: Int32 = 14

    private let samplesPerCharacter: Int
    private let script: FakeSenseVoiceScript

    /// FluidAudio's own default, so a code path that forgets to configure the
    /// model is unpunctuated here exactly as it would be in production.
    var textNorm: Int32 = 15
    private(set) var receivedRanges: [Range<Int>] = []
    var onCall: ((Int) -> Void)?

    init(samplesPerCharacter: Int, script: FakeSenseVoiceScript) {
        self.samplesPerCharacter = samplesPerCharacter
        self.script = script
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

        switch script {
        case .empty:
            return ""
        case .mandarin:
            return mandarin(covering: range)
        case .english:
            return english(covering: range)
        }
    }

    /// One distinct Han character per grid point, so a dropped chunk is visible
    /// as a gap rather than as a shorter run of the same character.
    private func mandarin(covering range: Range<Int>) -> String {
        let first = (range.lowerBound + samplesPerCharacter - 1) / samplesPerCharacter
        let last = (range.upperBound + samplesPerCharacter - 1) / samplesPerCharacter
        let characters = (first..<last).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) }
        guard punctuates else { return String(characters) }

        // A comma partway through and a full stop at the end, which is the shape
        // of real `textNorm 14` output.
        let middle = characters.count / 2
        var punctuated = characters
        if middle > 0 { punctuated.insert("，", at: middle) }
        punctuated.append("。")
        return String(punctuated)
    }

    private func english(covering range: Range<Int>) -> String {
        let first = (range.lowerBound + samplesPerCharacter - 1) / samplesPerCharacter
        let last = (range.upperBound + samplesPerCharacter - 1) / samplesPerCharacter
        let words = (first..<last).map { "The\($0)" }
        return words.joined(separator: " ") + (punctuates ? "." : "")
    }

    private var punctuates: Bool { textNorm == Self.withItn }
}
