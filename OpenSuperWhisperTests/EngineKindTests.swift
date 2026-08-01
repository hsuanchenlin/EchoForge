import XCTest
@testable import OpenSuperWhisper

/// The raw values are the on-disk preference format. These tests exist to make
/// a rename fail loudly here rather than silently reset every user's engine.
final class EngineKindRawValueTests: XCTestCase {

    func testRawValues_matchThePersistedStrings() {
        XCTAssertEqual(EngineKind.whisper.rawValue, "whisper")
        XCTAssertEqual(EngineKind.fluidaudio.rawValue, "fluidaudio")
        XCTAssertEqual(EngineKind.paraformer.rawValue, "paraformer")
        XCTAssertEqual(EngineKind.sensevoice.rawValue, "sensevoice")
    }

    func testEveryCase_roundTripsThroughItsRawValue() {
        for kind in EngineKind.allCases {
            XCTAssertEqual(EngineKind(rawValue: kind.rawValue), kind)
            XCTAssertEqual(EngineKind(stored: kind.rawValue), kind)
        }
    }

    func testFallback_isWhisper() {
        XCTAssertEqual(EngineKind.fallback, .whisper)
    }

    /// The captain's decision, pinned: Chinese dictation defaults to the engine
    /// that punctuates, and the Mandarin-accuracy engine stays reachable beside
    /// it. Both surfaces that will pick an engine - Settings and onboarding -
    /// read these rather than deciding again.
    func testChineseDictation_defaultsToSenseVoiceWithParaformerAsTheAlternative() {
        XCTAssertEqual(EngineKind.defaultChineseDictation, .sensevoice)
        XCTAssertEqual(EngineKind.chineseAccuracyAlternative, .paraformer)
        XCTAssertNotEqual(
            EngineKind.defaultChineseDictation, EngineKind.fallback,
            "the Chinese default must not silently become the app-wide default"
        )
    }

    /// The default Chinese engine has to be one that can actually be asked for
    /// Chinese - the pairing of an engine with its language scope is what a
    /// future engine addition is most likely to get wrong.
    func testChineseEngines_bothSupportChinese() {
        for kind in [EngineKind.defaultChineseDictation, .chineseAccuracyAlternative] {
            XCTAssertTrue(
                LanguageUtil.supportedLanguages(engine: kind, fluidAudioModelVersion: "v3").contains("zh"),
                "\(kind.rawValue) is offered for Chinese but does not support it"
            )
            XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: kind), "zh")
        }
    }

    func testStoredInit_unknownValue_fallsBackToWhisper() {
        // A user who tries a newer build and then downgrades must land on
        // Whisper, not on a missing engine.
        for unknown in ["qwen3", "Whisper", "", "SenseVoice"] {
            XCTAssertEqual(EngineKind(stored: unknown), .whisper, "\(unknown) must fall back to Whisper")
        }
    }

    /// Settings persists exactly these strings. Renaming one silently resets the
    /// engine choice of every user who had picked it.
    func testStoredInit_chineseEngines_areRecognised() {
        XCTAssertEqual(EngineKind(stored: "paraformer"), .paraformer)
        XCTAssertEqual(EngineKind(stored: "sensevoice"), .sensevoice)
    }

    func testStoredInit_missingValue_fallsBackToWhisper() {
        XCTAssertEqual(EngineKind(stored: nil), .whisper)
    }

    /// The whisper.cpp decode controls are Whisper's alone, and Settings hides
    /// them for everything else. A new engine that answered `true` here would
    /// show a user four sliders its transcription never reads.
    func testOnlyWhisperUsesTheWhisperDecodingSettings() {
        XCTAssertTrue(EngineKind.whisper.usesWhisperDecodingSettings)
        for kind in EngineKind.allCases where kind != .whisper {
            XCTAssertFalse(
                kind.usesWhisperDecodingSettings,
                "\(kind.rawValue) does not read whisper_full_params; Settings must not offer them"
            )
        }
    }
}

final class EngineKindFactoryTests: XCTestCase {

    func testMakeEngine_whisper_buildsTheWhisperEngine() async {
        let engine = await EngineKind.whisper.makeEngine()
        XCTAssertEqual(engine.engineName, "Whisper")
        XCTAssertTrue(engine is WhisperEngine)
        XCTAssertFalse(engine.isModelLoaded, "A freshly built engine must not claim a loaded model")
    }

    func testMakeEngine_fluidaudio_buildsTheFluidAudioEngine() async {
        let engine = await EngineKind.fluidaudio.makeEngine()
        XCTAssertEqual(engine.engineName, "FluidAudio")
        XCTAssertTrue(engine is FluidAudioEngine)
        XCTAssertFalse(engine.isModelLoaded, "A freshly built engine must not claim a loaded model")
    }

    func testMakeEngine_everyCase_producesADistinctEngine() async {
        var names: Set<String> = []
        for kind in EngineKind.allCases {
            names.insert(await kind.makeEngine().engineName)
        }
        XCTAssertEqual(names.count, EngineKind.allCases.count)
    }

    func testMakeEngine_paraformer_buildsTheParaformerEngine() async {
        let engine = await EngineKind.paraformer.makeEngine()
        XCTAssertEqual(engine.engineName, "Paraformer")
        XCTAssertTrue(engine is ParaformerEngine)
        XCTAssertFalse(engine.isModelLoaded, "A freshly built engine must not claim a loaded model")
    }

    func testMakeEngine_sensevoice_buildsTheSenseVoiceEngine() async {
        let engine = await EngineKind.sensevoice.makeEngine()
        XCTAssertEqual(engine.engineName, "SenseVoice")
        XCTAssertTrue(engine is SenseVoiceEngine)
        XCTAssertFalse(engine.isModelLoaded, "A freshly built engine must not claim a loaded model")
    }

    /// The FunASR model licence requires the model name to be retained rather
    /// than rebranded, and the engine name is the first place that shows.
    func testMakeEngine_chineseEngines_keepTheirModelNames() async {
        let names = await [EngineKind.sensevoice.makeEngine().engineName,
                           EngineKind.paraformer.makeEngine().engineName]
        XCTAssertTrue(names[0].contains("SenseVoice"))
        XCTAssertTrue(names[1].contains("Paraformer"))
    }

    /// The pre-refactor `if selectedEngine == "fluidaudio" { … } else { Whisper }`
    /// chain sent unknown tags to Whisper. Going through the stored-value
    /// initialiser has to keep doing that.
    func testUnknownStoredValue_stillSelectsWhisper() async {
        let engine = await EngineKind(stored: "qwen3").makeEngine()
        XCTAssertEqual(engine.engineName, "Whisper")
    }
}

final class SelectedEnginePreferenceTests: XCTestCase {

    private let key = "selectedEngine"
    private var originalValue: Any?

    override func setUp() {
        super.setUp()
        originalValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let originalValue {
            UserDefaults.standard.set(originalValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testSelectedEngine_defaultsToWhisper() {
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
    }

    func testSelectedEngine_persistsAsAPlainString() {
        AppPreferences.shared.selectedEngine = .fluidaudio

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "fluidaudio",
                       "The stored format must stay the bare tag older builds wrote")
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .fluidaudio)
    }

    func testSelectedEngine_readsStringsWrittenByEarlierBuilds() {
        UserDefaults.standard.set("fluidaudio", forKey: key)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .fluidaudio)

        UserDefaults.standard.set("whisper", forKey: key)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
    }

    func testSelectedEngine_unknownStoredValue_readsAsWhisper() {
        UserDefaults.standard.set("qwen3", forKey: key)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
    }

    /// The hand-edited default is the only way into either Chinese engine in
    /// this build - neither has a picker entry yet.
    func testSelectedEngine_chineseEngineStoredByHand_isHonoured() {
        for kind in [EngineKind.paraformer, .sensevoice] {
            UserDefaults.standard.set(kind.rawValue, forKey: key)
            XCTAssertEqual(AppPreferences.shared.selectedEngine, kind)
        }
    }

    /// Being the Chinese default is not being the app default: a fresh install
    /// with no stored preference still gets Whisper.
    func testSelectedEngine_noChineseEngineIsTheAppDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertNotEqual(AppPreferences.shared.selectedEngine, .paraformer)
        XCTAssertNotEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
    }

    func testSelectedEngine_nonStringStoredValue_readsAsWhisper() {
        UserDefaults.standard.set(42, forKey: key)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
    }

    /// Selecting an engine must not disturb the language the user picked, and
    /// the language scope each engine reports must be the one it had before the
    /// enum landed.
    func testLanguageScope_isUnchangedPerEngine() {
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: .whisper, fluidAudioModelVersion: "v3"),
                       LanguageUtil.availableLanguages)
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: .fluidaudio, fluidAudioModelVersion: "v2"),
                       LanguageUtil.parakeetV2Languages)
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: .fluidaudio, fluidAudioModelVersion: "v3"),
                       LanguageUtil.parakeetV3Languages)
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: .paraformer, fluidAudioModelVersion: "v3"),
                       ["zh"])
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: .sensevoice, fluidAudioModelVersion: "v3"),
                       ["auto", "zh", "yue", "en", "ja", "ko"])
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .whisper), "auto")
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .fluidaudio), "en")
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .paraformer), "zh")
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .sensevoice), "zh")
    }
}

/// Stands in for a real engine so the wiring can be exercised without a model.
private final class StubTranscriptionEngine: TranscriptionEngine {
    var isModelLoaded = true
    var engineName: String { "Stub" }
    var onProgressUpdate: ((Float) -> Void)?

    func initialize() async throws {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "" }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}

@MainActor
final class TranscriptionProgressForwardingTests: XCTestCase {

    private let engineKey = "selectedEngine"
    private let modelPathKey = "selectedWhisperModelPath"
    private var originalEngine: Any?
    private var originalModelPath: Any?

    override func setUp() {
        super.setUp()
        // `TranscriptionService.init` loads whatever engine the host machine has
        // selected. Pin it to Whisper with no model so the load fails fast
        // instead of downloading Parakeet weights from the network.
        originalEngine = UserDefaults.standard.object(forKey: engineKey)
        originalModelPath = UserDefaults.standard.object(forKey: modelPathKey)
        UserDefaults.standard.set("whisper", forKey: engineKey)
        UserDefaults.standard.removeObject(forKey: modelPathKey)
    }

    override func tearDown() {
        restore(originalEngine, forKey: engineKey)
        restore(originalModelPath, forKey: modelPathKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func waitForProgress(_ service: TranscriptionService, toReach expected: Float) async -> Float {
        for _ in 0..<200 where service.progress != expected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return service.progress
    }

    /// Any conformer, not just the two concrete classes the old downcast ladder
    /// knew about, reaches the published progress.
    func testProgressReachesTheServiceThroughTheProtocol() async {
        let service = TranscriptionService()
        let engine = StubTranscriptionEngine()

        service.observeProgress(of: engine)
        XCTAssertNotNil(engine.onProgressUpdate, "Observing must install a callback on the engine")

        engine.onProgressUpdate?(0.42)
        let observed = await waitForProgress(service, toReach: 0.42)
        XCTAssertEqual(observed, 0.42, accuracy: 0.0001)
    }

    func testProgressForwardsSuccessiveUpdates() async {
        let service = TranscriptionService()
        let engine = StubTranscriptionEngine()
        service.observeProgress(of: engine)

        for step in [Float(0.1), 0.5, 1.0] {
            engine.onProgressUpdate?(step)
            let observed = await waitForProgress(service, toReach: step)
            XCTAssertEqual(observed, step, accuracy: 0.0001)
        }
    }

    func testCancellationResetsForwardedProgress() async {
        let service = TranscriptionService()
        let engine = StubTranscriptionEngine()
        service.observeProgress(of: engine)

        engine.onProgressUpdate?(0.3)
        _ = await waitForProgress(service, toReach: 0.3)

        service.cancelTranscription()
        XCTAssertEqual(service.progress, 0.0)
    }

    func testEveryEngine_exposesProgressThroughTheProtocol() async {
        for kind in EngineKind.allCases {
            let engine = await kind.makeEngine()
            var received: Float?
            engine.onProgressUpdate = { received = $0 }
            engine.onProgressUpdate?(0.7)
            XCTAssertEqual(received, 0.7, "\(kind.rawValue) must report progress through the protocol")
        }
    }
}
