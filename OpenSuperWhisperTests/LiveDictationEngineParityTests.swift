import XCTest

@testable import OpenSuperWhisper

/// `LiveDictationParityTests` for the other engines: a recording fed through a
/// live session half a second at a time, cut by the real VAD under the
/// engine's own `LiveCutBudget`, decoded by the real weights, comes out as the
/// words the whole-file decode of the same audio produces - the marker
/// sentence at the end survives, nothing at a cut is lost or doubled, and the
/// engine's own refusals still fire.
///
/// Opt-in twice over, and skipped by default. It reads the fixtures the engine
/// integration tests document (`SenseVoiceEngineIntegrationTests`,
/// `ParaformerEngineIntegrationTests`; this file adds Parakeet's below), and it
/// skips rather than downloads when the weights are not in the FluidAudio
/// cache - a live-dictation parity run is not the moment to fetch 650 MB.
///
/// ```sh
/// mkdir -p OpenSuperWhisperTests/Fixtures/parakeet && cd $_
/// cat > parakeet-script.txt <<'EOF'
/// Speech recognition has improved a great deal over the past ten years. [[slnc 900]] A model has to cope with accents,
/// with background noise, and with people who change their mind half way through a sentence. [[slnc 900]] Latency matters
/// as well: many applications expect an answer within a few hundred milliseconds of the speaker falling silent. [[slnc 900]]
/// The last sentence is a marker: if you can read this sentence, the whole recording was transcribed.
/// EOF
/// say -v Samantha -f parakeet-script.txt -o parakeet-long.wav --file-format=WAVE --data-format=LEI16@16000   # ~26 s
/// ```
///
/// Prefixed because the test bundle flattens every fixture directory into one
/// Resources folder, and Paraformer already has a `long.wav`. The `[[slnc 900]]`
/// marks are the point of this fixture: `say` leaves 0.17-0.26 s between
/// sentences (measured with the bundled VAD on the Mandarin fixtures), which no
/// engine's pause reaches - a person leaves more - so the Mandarin fixtures
/// exercise only the cap-forced cut and this one exercises the pause cut.
///
/// The bound on the difference is a character error rate over the letters and
/// digits alone, because the whole-file path and the live path do not cut in
/// the same places: `AudioChunker` places its seams at the VAD silences that
/// fit its chunk, the live policy at the pauses that end an utterance, and a
/// seam costs the FluidAudio models about half a point of CER each
/// (`AudioChunkBudget+FluidAudio.swift`). What must not happen is a word lost
/// or doubled at a cut, which is what the marker and the bound together catch.
@MainActor
final class LiveDictationEngineParityTests: IsolatedPreferencesTestCase {

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// Half a second of audio per push, the cadence the session polls at.
    private static let frameSamples = LiveCutBudget.sampleRate / 2

    /// Letters and digits that may differ between the live and the whole-file
    /// transcript, as a share of the whole-file one. One seam costs the
    /// FluidAudio engines about 0.5 pp; a lost or doubled word costs more.
    private static let maximumCharacterErrorRate = 0.03

    private var directory: URL!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-engine-parity-\(UUID().uuidString)")
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        super.tearDown()
    }

    // MARK: - Opt-in

    private func fixture(_ relativePath: String) throws -> URL {
        let url = Self.fixturesDirectory.appendingPathComponent(relativePath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Generate \(url.path) to run the live-dictation engine parity tests - see this file's comment"
        )
        return url
    }

    private func skipUnlessDownloaded(_ isDownloaded: Bool, _ engine: String) throws {
        try XCTSkipUnless(isDownloaded, "\(engine) weights are not downloaded; this test never downloads them")
    }

    private func settings(language: String) -> Settings {
        var settings = Settings()
        settings.selectedLanguage = language
        settings.initialPrompt = ""
        settings.showTimestamps = false
        return settings
    }

    // MARK: - The live path

    private struct LiveRun {
        let outcome: LiveDictationOutcome
        let decodeCount: Int
        /// Decodes made before the key went up.
        let decodesWhileRecording: Int
        let line: PartialTranscript?
    }

    /// Feeds `audio` through a session on `engine` half a second at a time,
    /// polling after each push, and finishes it.
    private func dictateLive(
        _ audio: [Float], engine: TranscriptionEngine, kind: EngineKind, language: String
    ) async -> LiveRun {
        let tap = FakeLiveAudioTap()
        let decoder = EngineDecoder(engine: engine, kind: kind)
        let session = LiveDictationSession(
            recordingSession: RecordingSessionClaim().claim()!,
            engine: kind,
            budget: LiveCutBudget.preset(for: kind)!,
            settings: settings(language: language),
            tap: tap,
            decoder: decoder,
            segmenter: SpeechSegmenter(),
            stopTail: 0,
            pollInterval: nil,
            utteranceDirectory: directory)
        await session.start()
        XCTAssertEqual(session.state, .running)

        var offset = 0
        while offset < audio.count {
            let end = min(offset + Self.frameSamples, audio.count)
            tap.push(Array(audio[offset..<end]))
            await session.poll()
            offset = end
        }
        let decodesWhileRecording = decoder.decodeCount
        let outcome = await session.finish(session.recordingSession)
        return LiveRun(
            outcome: outcome,
            decodeCount: decoder.decodeCount,
            decodesWhileRecording: decodesWhileRecording,
            line: session.transcript)
    }

    private func samples(of url: URL) async throws -> [Float] {
        let loaded = try await PCMAudioLoader.loadSamples(from: url)
        return try XCTUnwrap(loaded)
    }

    private func committed(_ run: LiveRun, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .committed(let raw) = run.outcome else {
            XCTFail("the live path did not stand for the recording: \(run.outcome)", file: file, line: line)
            return nil
        }
        return raw
    }

    // MARK: - Comparison

    private func assertParity(
        live: String, reference: String, engine: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let rate = TranscriptDistance.characterErrorRate(reference: reference, hypothesis: live)
        XCTAssertLessThanOrEqual(
            rate, Self.maximumCharacterErrorRate,
            "\(engine): the live transcript differs from the reference by \(rate * 100)% of characters\nlive:      \(live)\nreference: \(reference)",
            file: file, line: line)
    }

    // MARK: - SenseVoice

    private let mandarinMarker = "说明整段音频都被完整地识别了"

    /// 36 s of Mandarin under the SenseVoice budget: the 28 s cap forces at
    /// least one cut while recording, the closing marker survives the tail,
    /// and the joined text is the whole-file text.
    func testSenseVoiceMandarinLiveMatchesTheWholeFile() async throws {
        let url = try fixture("sensevoice/sensevoice-long.wav")
        try skipUnlessDownloaded(SenseVoiceEngine.isModelDownloaded, "SenseVoice")
        let engine = SenseVoiceEngine()
        try await engine.initialize()

        let whole = try await engine.transcribeAudio(url: url, settings: settings(language: "zh"))
        XCTAssertTrue(whole.contains(mandarinMarker), "unexpected whole-file decode: \(whole)")

        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .sensevoice, language: "zh")
        guard let live = committed(run) else { return }

        XCTAssertGreaterThanOrEqual(run.decodesWhileRecording, 1, "an utterance is committed while recording")
        XCTAssertTrue(live.contains(mandarinMarker), "the closing sentence was lost at a cut or in the tail: \(live)")
        assertParity(live: live, reference: whole, engine: "SenseVoice")
        XCTAssertEqual(run.line?.text, live, "the line ends as the transcript")
    }

    /// The utterance this app is named for, through the live path on the one
    /// engine that transcribes both languages together: the English words and
    /// the Mandarin both come back, as they do from the whole file.
    func testSenseVoiceMixedEnglishAndMandarinLiveMatchesTheWholeFile() async throws {
        let url = try fixture("sensevoice/sensevoice-mixed.wav")
        try skipUnlessDownloaded(SenseVoiceEngine.isModelDownloaded, "SenseVoice")
        let engine = SenseVoiceEngine()
        try await engine.initialize()

        let whole = try await engine.transcribeAudio(url: url, settings: settings(language: "auto"))
        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .sensevoice, language: "auto")
        guard let live = committed(run) else { return }

        let english = ["feature", "login", "branch", "tag", "James", "nginx", "log", "PR"]
        XCTAssertGreaterThanOrEqual(
            english.filter { live.localizedCaseInsensitiveContains($0) }.count, 3,
            "the English half did not survive the live path: \(live)")
        XCTAssertTrue(ChineseScriptVariant.isHanDominant(live), "the Mandarin half did not survive the live path: \(live)")
        assertParity(live: live, reference: whole, engine: "SenseVoice (mixed)")
    }

    // MARK: - Paraformer

    /// 36 s of Mandarin under the Paraformer budget, whose ~14 s cap is the
    /// decoder's silent 128-token clamp: the cuts keep every utterance under
    /// it, so the tail is not truncated and nothing degenerates into
    /// repetition.
    func testParaformerLongMandarinLiveMatchesTheWholeFile() async throws {
        let url = try fixture("paraformer/long.wav")
        try skipUnlessDownloaded(ParaformerEngine.isModelDownloaded, "Paraformer")
        let engine = ParaformerEngine()
        try await engine.initialize()

        let whole = try await engine.transcribeAudio(url: url, settings: settings(language: "zh"))
        XCTAssertTrue(whole.contains(mandarinMarker), "unexpected whole-file decode: \(whole)")

        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .paraformer, language: "zh")
        guard let live = committed(run) else { return }

        XCTAssertGreaterThanOrEqual(run.decodesWhileRecording, 1, "an utterance is committed while recording")
        XCTAssertTrue(live.contains(mandarinMarker), "the closing sentence was lost, the sign of the token clamp: \(live)")
        assertNoRepeatedTail(live)
        assertParity(live: live, reference: whole, engine: "Paraformer")
    }

    /// The dense fixture - the same 151 characters in 22.6 s - is where the
    /// clamp bound first, and the VAD hears it as one unbroken segment. The
    /// policy never cuts inside speech, so nothing is committed while
    /// recording and the whole 22.6 s is the tail: it is the engine's own
    /// chunker, splitting the utterance as it splits a file, that keeps it
    /// under the clamp, and the marker comes out of it.
    func testParaformerUnbrokenDenseMandarinIsChunkedByTheEngineNotCutByThePolicy() async throws {
        let url = try fixture("paraformer/dense.wav")
        try skipUnlessDownloaded(ParaformerEngine.isModelDownloaded, "Paraformer")
        let engine = ParaformerEngine()
        try await engine.initialize()

        let whole = try await engine.transcribeAudio(url: url, settings: settings(language: "zh"))
        XCTAssertTrue(whole.contains(mandarinMarker), "unexpected whole-file decode: \(whole)")
        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .paraformer, language: "zh")
        guard let live = committed(run) else { return }

        XCTAssertEqual(run.decodesWhileRecording, 0, "unbroken speech is never cut, whatever the cap says")
        XCTAssertEqual(run.decodeCount, 1, "the tail is one utterance, chunked inside the engine")
        XCTAssertTrue(live.contains(mandarinMarker), "the closing sentence was lost, the sign of the token clamp: \(live)")
        assertNoRepeatedTail(live)
        assertParity(live: live, reference: whole, engine: "Paraformer (dense)")
    }

    /// English on Paraformer is refused, not mis-transcribed, on the live path
    /// exactly as on the whole file: the utterance's own guard throws, the
    /// session falls back, and the whole-file decode refuses in turn - so the
    /// dictation fails with its recording kept, as it did before live existed.
    func testParaformerRefusesEnglishOnTheLivePath() async throws {
        let url = try fixture("sensevoice/hf_en.wav")
        try skipUnlessDownloaded(ParaformerEngine.isModelDownloaded, "Paraformer")
        let engine = ParaformerEngine()
        try await engine.initialize()

        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .paraformer, language: "zh")
        guard case .fallback(.decodeFailed) = run.outcome else {
            return XCTFail("English was not refused on the live path: \(run.outcome)")
        }
        XCTAssertNil(run.line, "the line is cleared before the whole-file decode")

        do {
            let text = try await engine.transcribeAudio(url: url, settings: settings(language: "zh"))
            XCTFail("the whole-file decode accepted English: \(text)")
        } catch TranscriptionError.unsupportedSpokenLanguage {
            // The fallback refuses too: the recording is kept, nothing pasted.
        }
    }

    /// Longest common prefix of the tail with an earlier repetition of itself,
    /// the shape the clamped Paraformer decoder degenerates into. The same
    /// check `ParaformerEngineIntegrationTests` makes.
    private func assertNoRepeatedTail(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let characters = Array(text)
        guard characters.count >= 12 else { return }
        let tail = String(characters.suffix(6))
        XCTAssertFalse(
            String(characters.dropLast(6)).hasSuffix(tail),
            "the transcript ends in a repeated 6-character run, which is what an overrun decoder emits",
            file: file, line: line)
    }

    // MARK: - Parakeet

    /// The Parakeet fixture's script, letters and digits: what the live path is
    /// held to, because the whole-file decode is not a reference here. On the
    /// pinned FluidAudio the whole-file path windows anything over 15 s and
    /// merges the windows by token deduplication, and on this 26 s fixture that
    /// merge drops "expect an answer within a few hundred milliseconds of the
    /// speaker falling silent" - deterministically, across three runs, while
    /// every clip of 20 s or less kept it (`docs/upstream-issues.md`). The live
    /// path's utterances are single sentences, each inside one window, so it
    /// keeps the clause; holding it to the lossy whole-file text would fail the
    /// path that is right.
    private static let parakeetScript = """
        Speech recognition has improved a great deal over the past ten years. A model has to cope with accents, \
        with background noise, and with people who change their mind half way through a sentence. Latency matters \
        as well: many applications expect an answer within a few hundred milliseconds of the speaker falling silent. \
        The last sentence is a marker: if you can read this sentence, the whole recording was transcribed.
        """

    /// ~26 s of English with 0.9 s pauses between sentences under the Parakeet
    /// budget: the 3 s floor and 0.6 s pause make a sentence an utterance, so
    /// sentences are committed while recording, every utterance stays inside
    /// one FluidAudio window, and the live transcript is the script - the
    /// marker and the clause the whole-file merge loses included.
    func testParakeetEnglishLiveMatchesTheScript() async throws {
        let url = try fixture("parakeet/parakeet-long.wav")
        try skipUnlessDownloaded(
            EngineAvailability.isFluidAudioDownloaded(version: AppPreferences.shared.fluidAudioModelVersion),
            "Parakeet")
        let engine = FluidAudioEngine()
        try await engine.initialize()

        let run = await dictateLive(try await samples(of: url), engine: engine, kind: .fluidaudio, language: "en")
        guard let live = committed(run) else { return }

        XCTAssertGreaterThanOrEqual(run.decodesWhileRecording, 2, "sentences are committed at their pauses while recording")
        for phrase in ["the whole recording was transcribed", "milliseconds of the speaker falling silent"] {
            XCTAssertTrue(live.lowercased().contains(phrase), "\"\(phrase)\" was lost on the live path: \(live)")
        }
        // "ten years" comes back as "10 years": inverse text normalisation is
        // the engine's, and three characters of the script's ~330.
        assertParity(live: live, reference: Self.parakeetScript, engine: "Parakeet")
    }
}

/// `LiveUtteranceDecoding` over one real engine, outside `TranscriptionService`:
/// the frame is not what these tests are about, the decode is.
@MainActor
private final class EngineDecoder: LiveUtteranceDecoding {
    private let engine: TranscriptionEngine
    let activeEngine: EngineKind?
    private(set) var decodeCount = 0

    init(engine: TranscriptionEngine, kind: EngineKind) {
        self.engine = engine
        self.activeEngine = kind
    }

    var engineLoadGeneration: Int { 0 }

    func decodeRaw(url: URL, settings: Settings) async throws -> RawDecode {
        decodeCount += 1
        if let reporting = engine as? DecodeLanguageReporting {
            return try await reporting.transcribeAudioReportingLanguage(url: url, settings: settings)
        }
        return RawDecode(text: try await engine.transcribeAudio(url: url, settings: settings))
    }
}
