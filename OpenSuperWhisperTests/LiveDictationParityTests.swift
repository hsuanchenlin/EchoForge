import XCTest

@testable import OpenSuperWhisper

/// The claim `LiveDictationSessionTests` cannot make: that a recording fed
/// through the session half a second at a time, cut by the real VAD and
/// decoded by the real `WhisperEngine`, comes out as the words the whole-file
/// decode of the same audio produces.
///
/// Runs against the tracked `jfk.wav` and `ggml-tiny.en.bin` in the repository
/// root, the same pair `WhisperStateIsolationTests` uses, and skips when either
/// is absent. The one multilingual case reads `ggml-large-v3-turbo.bin` from
/// the app's own model directory and the Mandarin fixture
/// `SenseVoiceEngineIntegrationTests` documents, and skips without them.
/// Nothing here downloads anything.
@MainActor
final class LiveDictationParityTests: IsolatedPreferencesTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Half a second of audio per push, the cadence the session polls at.
    private static let frameSamples = LiveCutBudget.sampleRate / 2

    private var engine: WhisperEngine!
    private var samples: [Float]!
    private var directory: URL!

    /// Loads the model and the clip, or skips. Called from each test rather
    /// than from an async `setUp`, which XCTest runs *before* the synchronous
    /// one that redirects the preferences - and the model path written here
    /// must land in the throwaway suite, not the developer's own settings.
    private func prepare() async throws {
        let modelURL = Self.repoRoot.appendingPathComponent("ggml-tiny.en.bin")
        let audioURL = Self.repoRoot.appendingPathComponent("jfk.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path)
                && FileManager.default.fileExists(atPath: audioURL.path),
            "tiny model / jfk sample not present in repo root"
        )
        try await prepare(model: modelURL, audio: audioURL)
    }

    private func prepare(model modelURL: URL, audio audioURL: URL) async throws {
        AppPreferences.shared.selectedWhisperModelPath = modelURL.path
        AppPreferences.shared.whisperLanguage = "en"

        engine = WhisperEngine()
        try await engine.initialize()
        let loaded = try await PCMAudioLoader.loadSamples(from: audioURL)
        samples = try XCTUnwrap(loaded)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-parity-\(UUID().uuidString)")
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        super.tearDown()
    }

    private func settings(language: String = "en") -> Settings {
        var settings = Settings()
        settings.selectedLanguage = language
        settings.initialPrompt = ""
        settings.showTimestamps = false
        return settings
    }

    private func makeSession(
        _ tap: FakeLiveAudioTap, decoder: WhisperEngineDecoder, language: String = "en"
    ) -> LiveDictationSession {
        LiveDictationSession(
            recordingSession: RecordingSessionClaim().claim()!,
            engine: .whisper,
            budget: .whisper,
            settings: settings(language: language),
            tap: tap,
            decoder: decoder,
            segmenter: SpeechSegmenter(),
            stopTail: 0,
            pollInterval: nil,
            utteranceDirectory: directory)
    }

    /// Pushes `audio` half a second at a time, polling after each push, the
    /// way the recorder's tap and the session's timer interleave in production.
    private func speak(_ audio: [Float], into tap: FakeLiveAudioTap, session: LiveDictationSession) async {
        var offset = 0
        while offset < audio.count {
            let end = min(offset + Self.frameSamples, audio.count)
            tap.push(Array(audio[offset..<end]))
            await session.poll()
            offset = end
        }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// One clip, fed live, decodes to the words the whole file decodes to.
    func testTheLiveTranscriptMatchesTheWholeFileDecode() async throws {
        try await prepare()
        let whole = try await engine.transcribeAudio(
            url: Self.repoRoot.appendingPathComponent("jfk.wav"), settings: settings())
        XCTAssertTrue(whole.lowercased().contains("your country"), "unexpected whole-file decode: \(whole)")

        let tap = FakeLiveAudioTap()
        let decoder = WhisperEngineDecoder(engine: engine)
        let session = makeSession(tap, decoder: decoder)
        await session.start()
        XCTAssertEqual(session.state, .running)

        await speak(samples, into: tap, session: session)
        let outcome = await session.finish(session.recordingSession)

        guard case .committed(let live) = outcome else {
            return XCTFail("the live path did not stand for the recording: \(outcome)")
        }
        XCTAssertTrue(live.lowercased().contains("your country"), "unexpected live transcript: \(live)")
        XCTAssertEqual(
            normalized(live), normalized(whole),
            "live: \(live)\nwhole: \(whole)")
        XCTAssertGreaterThanOrEqual(decoder.decodeCount, 1)
    }

    /// The clip three times with a pause between each: an utterance is
    /// committed while the "recording" is still going, the rest follows, and
    /// the joined transcript carries all three clips without a word lost at
    /// the cut.
    ///
    /// Three rather than two because of the Whisper budget's 8 s minimum: the
    /// VAD finds under 8 s of speech in the eleven-second clip, so the first
    /// pause is too early to cut at. Where exactly the cut then lands is the
    /// policy's business - the first qualifying pause after the minimum is
    /// inside the second clip, after "my fellow Americans" - so what is held
    /// here is that a cut happened at a pause and that nothing went missing,
    /// not the boundary itself.
    func testAPauseCommitsAnUtteranceWhileRecording() async throws {
        try await prepare()
        let pause = [Float](repeating: 0, count: Int(1.5 * Double(LiveCutBudget.sampleRate)))
        // "your country" is said twice per clip.
        func mentions(in text: String) -> Int {
            text.lowercased().components(separatedBy: "your country").count - 1
        }

        let tap = FakeLiveAudioTap()
        let decoder = WhisperEngineDecoder(engine: engine)
        let session = makeSession(tap, decoder: decoder)
        await session.start()

        await speak(samples + pause, into: tap, session: session)
        XCTAssertEqual(decoder.decodeCount, 0, "under the minimum, the first pause is not a cut")
        XCTAssertNil(session.transcript)

        await speak(samples + pause, into: tap, session: session)
        XCTAssertGreaterThanOrEqual(decoder.decodeCount, 1, "a pause past the minimum ends an utterance while recording")
        let firstLine = try XCTUnwrap(session.transcript?.text)
        XCTAssertGreaterThanOrEqual(
            mentions(in: firstLine), 2, "the first clip is on the line while recording: \(firstLine)")

        await speak(samples, into: tap, session: session)
        let outcome = await session.finish(session.recordingSession)

        guard case .committed(let live) = outcome else {
            return XCTFail("the live path did not stand for the recording: \(outcome)")
        }
        XCTAssertGreaterThan(
            decoder.decodeCount, 1, "what was left after the last cut is decoded at finish")
        XCTAssertEqual(mentions(in: live), 6, "all three clips are in the joined transcript: \(live)")
        XCTAssertEqual(session.transcript?.text, live, "the line ends as the transcript")
        XCTAssertEqual(session.transcript?.segmentCount, decoder.decodeCount)
    }

    // MARK: - Language

    /// The same three clips on `auto`: the first utterance is decoded on
    /// `auto` and reports its language - English with certainty on an
    /// English-only model, which has nothing to detect - and every decode
    /// after it is asked for English outright. The settings the session hands
    /// back for the finish still say `auto`.
    func testTheFirstUtterancePinsTheLanguageForTheRestOfTheSession() async throws {
        try await prepare()
        let pause = [Float](repeating: 0, count: Int(1.5 * Double(LiveCutBudget.sampleRate)))

        let tap = FakeLiveAudioTap()
        let decoder = WhisperEngineDecoder(engine: engine)
        let session = makeSession(tap, decoder: decoder, language: "auto")
        await session.start()

        await speak(samples + pause, into: tap, session: session)
        await speak(samples + pause, into: tap, session: session)
        XCTAssertGreaterThanOrEqual(decoder.decodeCount, 1)
        XCTAssertEqual(decoder.languages.first, "auto", "the first utterance is detected")
        XCTAssertEqual(decoder.reported.first??.code, "en")
        XCTAssertEqual(decoder.reported.first??.probability, 1, "an English-only model is certain by construction")
        XCTAssertEqual(session.pinnedLanguage, "en")

        await speak(samples, into: tap, session: session)
        let outcome = await session.finish(session.recordingSession)

        guard case .committed(let live) = outcome else {
            return XCTFail("the live path did not stand for the recording: \(outcome)")
        }
        XCTAssertEqual(
            decoder.languages, ["auto"] + Array(repeating: "en", count: decoder.decodeCount - 1),
            "every decode after the first runs in the pinned language, the tail included")
        XCTAssertEqual(
            live.lowercased().components(separatedBy: "your country").count - 1, 6,
            "all three clips are in the joined transcript: \(live)")
        XCTAssertEqual(session.settings.selectedLanguage, "auto", "the finish settings are never pinned")
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "en", "no preference is written")
    }

    /// A language the user chose is asked for on every decode, and nothing is
    /// pinned over it.
    func testAnExplicitLanguageIsAskedForOnEveryDecode() async throws {
        try await prepare()
        let pause = [Float](repeating: 0, count: Int(1.5 * Double(LiveCutBudget.sampleRate)))

        let tap = FakeLiveAudioTap()
        let decoder = WhisperEngineDecoder(engine: engine)
        let session = makeSession(tap, decoder: decoder, language: "en")
        await session.start()

        await speak(samples + pause, into: tap, session: session)
        await speak(samples + pause, into: tap, session: session)
        await speak(samples, into: tap, session: session)
        _ = await session.finish(session.recordingSession)

        XCTAssertGreaterThanOrEqual(decoder.decodeCount, 2)
        XCTAssertEqual(decoder.languages, Array(repeating: "en", count: decoder.decodeCount))
        XCTAssertEqual(decoder.reported.compactMap { $0?.probability }, [], "a given language is reported without a probability")
        XCTAssertNil(session.pinnedLanguage)
    }

    /// The pin on a multilingual model, with a real detection: 36 s of
    /// Mandarin on `auto` through `ggml-large-v3-turbo`. The first utterance -
    /// forced by the 28 s cap, since `say` leaves no pause the budget accepts -
    /// is detected as Mandarin with the probability whisper.cpp's own detector
    /// puts on it, the tail is decoded in Mandarin without another detection,
    /// and the joined text is the script the fixture was synthesised from.
    ///
    /// The script rather than the whole-file decode, because on this fixture
    /// the whole-file decode is not a reference: whisper.cpp's second 30 s
    /// window starts where its first window's last segment ended, and here
    /// that skips the 14-character sentence before the marker
    /// (`最后一句话是一个特别的标记句`) - measured, deterministic, and whisper.cpp's
    /// own. The live path's utterances each sit inside one window and keep it.
    ///
    /// Opt-in: skips without the turbo model in the app's model directory or
    /// the SenseVoice fixture. Measured on the pinned whisper.cpp
    /// (`docs/live-dictation.md`): p = 0.998 on this clip.
    func testAMultilingualModelDetectsAndPinsMandarin() async throws {
        let modelURL = AppDataLocation.whisperModelsDirectory()
            .appendingPathComponent("ggml-large-v3-turbo.bin")
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sensevoice")
        let audioURL = fixtures.appendingPathComponent("sensevoice-long.wav")
        let scriptURL = fixtures.appendingPathComponent("sensevoice-script.txt")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path)
                && FileManager.default.fileExists(atPath: audioURL.path)
                && FileManager.default.fileExists(atPath: scriptURL.path),
            "needs ggml-large-v3-turbo.bin in \(modelURL.deletingLastPathComponent().path) and the SenseVoice fixture")
        try await prepare(model: modelURL, audio: audioURL)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let marker = "说明整段音频都被完整地识别了"

        let tap = FakeLiveAudioTap()
        let decoder = WhisperEngineDecoder(engine: engine)
        let session = makeSession(tap, decoder: decoder, language: "auto")
        await session.start()
        await speak(samples, into: tap, session: session)
        XCTAssertGreaterThanOrEqual(decoder.decodeCount, 1, "the cap forces a cut inside 36 s")
        XCTAssertEqual(session.pinnedLanguage, "zh")
        let first = try XCTUnwrap(decoder.reported.first ?? nil)
        XCTAssertEqual(first.code, "zh")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.probability), LiveLanguagePin.minimumConfidence)

        let outcome = await session.finish(session.recordingSession)
        guard case .committed(let live) = outcome else {
            return XCTFail("the live path did not stand for the recording: \(outcome)")
        }
        XCTAssertEqual(
            decoder.languages, ["auto"] + Array(repeating: "zh", count: decoder.decodeCount - 1),
            "the tail is decoded in the pinned language without another detection")
        XCTAssertTrue(live.contains(marker), "the closing sentence was lost at the cut or in the tail: \(live)")
        let rate = TranscriptDistance.characterErrorRate(reference: script, hypothesis: live)
        XCTAssertLessThanOrEqual(rate, 0.03, "the live transcript differs from the script by \(rate * 100)% of characters: \(live)")
        XCTAssertEqual(session.settings.selectedLanguage, "auto")
    }
}

/// `LiveUtteranceDecoding` over one real engine, outside `TranscriptionService`:
/// the frame is not what this test is about, the decode is.
@MainActor
private final class WhisperEngineDecoder: LiveUtteranceDecoding {
    private let engine: WhisperEngine
    private(set) var decodeCount = 0
    /// The language each decode was asked for, in order.
    private(set) var languages: [String] = []
    /// The language each decode reported, in order.
    private(set) var reported: [DecodedLanguage?] = []

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    var activeEngine: EngineKind? { .whisper }
    var engineLoadGeneration: Int { 0 }

    func decodeRaw(url: URL, settings: Settings) async throws -> RawDecode {
        decodeCount += 1
        languages.append(settings.selectedLanguage)
        let decoded = try await engine.transcribeAudioReportingLanguage(url: url, settings: settings)
        reported.append(decoded.language)
        return decoded
    }
}
