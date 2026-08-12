import XCTest
@testable import OpenSuperWhisper

/// The rules that decide whether this app can transcribe at all.
///
/// Every case here is a state a shipped EchoForge install has been in: onboarding
/// finished without persisting the engine it showed as selected, a model cache
/// deleted from the folder Settings offers to open, an engine chosen in a build
/// that had one this build does not. Each of them used to end as a recording that
/// decoded into nothing, printed one console line and deleted the user's audio.
final class EngineConfigurationTests: XCTestCase {

    private func availability(_ engines: Set<EngineKind>, whisperModels: [String] = []) -> EngineAvailability {
        EngineAvailability(usableEngines: engines, whisperModelPaths: whisperModels)
    }

    // MARK: - Nothing is configured

    func testResolve_completedOnboardingWithNoEngineAndNothingDownloaded_isUnavailable() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: EngineKind.fallback,
            whisperModelPath: nil,
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: availability([])
        )

        XCTAssertEqual(outcome, .unavailable)
    }

    func testResolve_whisperSelectedWithNoModelFile_isNotConsideredConfigured() {
        XCTAssertFalse(
            EngineConfiguration.isConfigured(
                engine: .whisper,
                whisperModelPath: nil,
                availability: availability([])
            )
        )
    }

    /// The stored path pointing at a file the user has since deleted is not a
    /// configured engine, however plausible the preference looks.
    func testResolve_whisperModelPathNoLongerOnDisk_isNotConsideredConfigured() {
        let present = availability([.whisper], whisperModels: ["/models/ggml-large-v3-turbo.bin"])

        XCTAssertFalse(
            EngineConfiguration.isConfigured(
                engine: .whisper,
                whisperModelPath: "/models/deleted.bin",
                availability: present
            )
        )
        XCTAssertTrue(
            EngineConfiguration.isConfigured(
                engine: .whisper,
                whisperModelPath: "/models/ggml-large-v3-turbo.bin",
                availability: present
            )
        )
    }

    // MARK: - Recovery

    /// The state this fix was written for: onboarding completed against an
    /// already-downloaded SenseVoice, but nothing was ever persisted, so the app
    /// woke up on its `.whisper` default with no Whisper model at all.
    func testResolve_chineseUserWithSenseVoiceDownloaded_recoversOntoSenseVoice() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: EngineKind.fallback,
            whisperModelPath: nil,
            language: "zh",
            fluidAudioModelVersion: "v3",
            availability: availability([.sensevoice, .paraformer])
        )

        XCTAssertEqual(outcome, .recovered(engine: .sensevoice, whisperModelPath: nil, language: "zh"))
    }

    /// `EngineKind.defaultChineseDictation` is where the app states which Chinese
    /// engine it recommends, and recovery has to honour it rather than take
    /// whichever one is listed first.
    func testResolve_chineseUserWithBothChineseEngines_prefersTheRecommendedOne() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .fluidaudio,
            whisperModelPath: nil,
            language: "zh",
            fluidAudioModelVersion: "v3",
            availability: availability([.paraformer, .sensevoice])
        )

        XCTAssertEqual(
            outcome,
            .recovered(engine: EngineKind.defaultChineseDictation, whisperModelPath: nil, language: "zh")
        )
    }

    func testResolve_chineseUserWithOnlyParaformerDownloaded_recoversOntoParaformer() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .sensevoice,
            whisperModelPath: nil,
            language: "zh",
            fluidAudioModelVersion: "v3",
            availability: availability([.paraformer])
        )

        XCTAssertEqual(outcome, .recovered(engine: .paraformer, whisperModelPath: nil, language: "zh"))
    }

    /// Whisper is `EngineKind.fallback` and the only engine that does every
    /// language, so it leads for everyone who is not dictating Chinese - and
    /// recovering onto it also has to choose the file, which is the half of a
    /// Whisper configuration a bare engine name leaves out.
    func testResolve_englishUserWithWhisperModels_recoversOntoWhisperAndPicksAFile() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .whisper,
            whisperModelPath: nil,
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: availability(
                [.whisper, .sensevoice],
                whisperModels: ["/models/ggml-large-v3-turbo.bin", "/models/ggml-tiny.en.bin"]
            )
        )

        XCTAssertEqual(
            outcome,
            .recovered(
                engine: .whisper,
                whisperModelPath: "/models/ggml-large-v3-turbo.bin",
                language: "en"
            )
        )
    }

    /// The rule onboarding and Settings already apply: an engine is never left
    /// paired with a language it only mis-transcribes. Paraformer is Mandarin-only
    /// and does not refuse German, it garbles it.
    func testResolve_onlyEngineLeftCannotDoTheLanguage_movesTheLanguageToo() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .whisper,
            whisperModelPath: nil,
            language: "de",
            fluidAudioModelVersion: "v3",
            availability: availability([.paraformer])
        )

        XCTAssertEqual(outcome, .recovered(engine: .paraformer, whisperModelPath: nil, language: "zh"))
    }

    /// A downloaded engine that can do the user's language beats one that cannot,
    /// whatever the order says.
    func testResolve_prefersADownloadedEngineThatSupportsTheLanguage() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .whisper,
            whisperModelPath: nil,
            language: "ja",
            fluidAudioModelVersion: "v3",
            availability: availability([.fluidaudio, .sensevoice])
        )

        XCTAssertEqual(outcome, .recovered(engine: .sensevoice, whisperModelPath: nil, language: "ja"))
    }

    // MARK: - A working configuration is left alone

    func testResolve_configuredEngine_isLeftUntouched() {
        for engine in [EngineKind.sensevoice, .paraformer, .fluidaudio] {
            XCTAssertEqual(
                EngineConfiguration.resolve(
                    selectedEngine: engine,
                    whisperModelPath: nil,
                    language: LanguageUtil.fallbackLanguage(engine: engine),
                    fluidAudioModelVersion: "v3",
                    availability: availability([engine])
                ),
                .usable(engine),
                "\(engine) is downloaded, so nothing may be changed behind the user's back"
            )
        }
    }

    /// A Whisper user with a model file keeps both the engine and the file, even
    /// with newer engines sitting downloaded beside it.
    func testResolve_configuredWhisper_isNotMigratedOntoAnotherEngine() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .whisper,
            whisperModelPath: "/models/ggml-large-v3-turbo.bin",
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: availability(
                [.whisper, .sensevoice, .paraformer, .fluidaudio],
                whisperModels: ["/models/ggml-large-v3-turbo.bin"]
            )
        )

        XCTAssertEqual(outcome, .usable(.whisper))
    }

    /// A Chinese user whose SenseVoice is downloaded is not dragged onto Whisper
    /// just because Whisper leads the general order.
    func testResolve_configuredChineseEngine_survivesWhisperBeingAvailable() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .sensevoice,
            whisperModelPath: "/models/ggml-tiny.en.bin",
            language: "zh",
            fluidAudioModelVersion: "v3",
            availability: availability([.whisper, .sensevoice], whisperModels: ["/models/ggml-tiny.en.bin"])
        )

        XCTAssertEqual(outcome, .usable(.sensevoice))
    }

    // MARK: - The chosen cloud engine

    /// A cloud selection whose configuration is incomplete is a choice made in
    /// the Cloud pane, not a stale configuration: recovery must keep it and let
    /// the refusal surface on each dictation, naming the field to fix.
    func testResolve_misconfiguredCloudSelection_isKeptRatherThanRecovered() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .cloud,
            whisperModelPath: nil,
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: EngineAvailability(
                usableEngines: [.whisper],
                whisperModelPaths: ["/models/turbo.bin"],
                cloudTranscriptionRefusal: .noAPIKey
            )
        )

        XCTAssertEqual(outcome, .cloudMisconfigured(.noAPIKey))
    }

    /// The offline-only build is the one case where a stored cloud selection is
    /// recovered: `EngineKind.cloud` can never become the active engine there,
    /// and the preference can only be a leftover from another build.
    func testResolve_cloudSelectionInAnOfflineOnlyBuild_isRecoveredOntoALocalEngine() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .cloud,
            whisperModelPath: nil,
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: EngineAvailability(
                usableEngines: [.whisper],
                whisperModelPaths: ["/models/turbo.bin"],
                cloudTranscriptionRefusal: .notInThisBuild
            )
        )

        XCTAssertEqual(
            outcome,
            .recovered(engine: .whisper, whisperModelPath: "/models/turbo.bin", language: "en")
        )
    }

    // MARK: - Ordering

    /// Adding an engine without placing it in the recovery order would make it
    /// invisible to recovery, which is the quiet half of this bug all over again.
    ///
    /// Every engine that runs on this Mac, that is. Recovery repairs a broken
    /// configuration silently, at launch, without asking - so recovering onto an
    /// engine that uploads the user's audio (`EngineKind.usesCloudProvider`)
    /// would make that the one change this app makes behind someone's back.
    func testRecoveryOrder_coversEveryLocalEngineAndNoCloudOne() {
        let local = EngineKind.allCases.filter { !$0.usesCloudProvider }

        for language in ["en", "zh"] {
            XCTAssertEqual(
                Set(EngineConfiguration.recoveryOrder(for: language)),
                Set(local),
                "every local engine must be reachable by recovery for a \(language) user"
            )
            XCTAssertEqual(
                EngineConfiguration.recoveryOrder(for: language).count,
                local.count,
                "no engine may appear twice in the recovery order"
            )
        }
    }

    func testRecoveryOrder_leadsWithWhisperUnlessTheUserDictatesChinese() {
        XCTAssertEqual(EngineConfiguration.recoveryOrder(for: "en").first, EngineKind.fallback)
        XCTAssertEqual(
            EngineConfiguration.recoveryOrder(for: "zh").first,
            EngineKind.defaultChineseDictation
        )
    }

    // MARK: - The user-visible failure

    func testEngineNotConfiguredError_carriesAnActionableMessage() {
        let message = TranscriptionError.engineNotConfigured.errorDescription

        XCTAssertEqual(message, EngineConfiguration.unavailableMessage)
        XCTAssertTrue(
            message?.contains("Settings") == true,
            "the message has to name where the user fixes it, not just that it is broken"
        )
    }

    /// The queue renders `localizedDescription` on a failed recording. Before
    /// this, a missing engine reached the user as
    /// "OpenSuperWhisper.TranscriptionError error 0".
    func testEngineNotConfiguredError_localizedDescriptionIsNotTheRawEnumCase() {
        let description = TranscriptionError.engineNotConfigured.localizedDescription

        XCTAssertEqual(description, EngineConfiguration.unavailableMessage)
        XCTAssertFalse(description.contains("TranscriptionError"))
    }

    /// The one failure worth keeping the user's audio for; everything else is
    /// still discarded exactly as before.
    func testIsNotConfigured_identifiesOnlyTheMissingEngineFailure() {
        XCTAssertTrue(EngineConfiguration.isNotConfigured(TranscriptionError.engineNotConfigured))

        for other: TranscriptionError in [.contextInitializationFailed, .audioConversionFailed, .processingFailed] {
            XCTAssertFalse(EngineConfiguration.isNotConfigured(other))
        }
        XCTAssertFalse(EngineConfiguration.isNotConfigured(CancellationError()))
    }

    /// The audio belongs to the user: a failure they can fix must not take it
    /// with it, and it has to reach both dictation entry points the same way.
    func testDictationFailure_missingEngine_keepsTheAudioAndReportsIt() {
        XCTAssertEqual(
            DictationFailureOutcome.forError(TranscriptionError.engineNotConfigured),
            .keep(reason: EngineConfiguration.unavailableMessage, indicatorState: .noEngine)
        )
    }

    /// Every other failure still discards, exactly as before this change.
    func testDictationFailure_everyOtherError_stillDiscards() {
        for error: Error in [
            TranscriptionError.contextInitializationFailed,
            TranscriptionError.audioConversionFailed,
            TranscriptionError.processingFailed,
            CancellationError(),
        ] {
            XCTAssertEqual(DictationFailureOutcome.forError(error), .discard)
        }
    }

    func testIndicatorMessage_isShortEnoughForTheDictationCard() {
        XCTAssertLessThanOrEqual(
            EngineConfiguration.unavailableShortMessage.count,
            "No microphone".count + 3,
            "the indicator card is 200 pt wide; a longer line truncates"
        )
    }
}

/// The write-back half of recovery, which is what actually repairs an install.
///
/// `AppPreferences` writes real preferences, so these run against a throwaway
/// defaults suite - see `IsolatedPreferencesTestCase`.
final class EngineConfigurationRecoveryWriteTests: IsolatedPreferencesTestCase {

    func testRecoverIfNeeded_writesTheRecoveredEngineAndLanguage() {
        AppPreferences.shared.whisperLanguage = "zh"

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .recovered(engine: .sensevoice, whisperModelPath: nil, language: "zh"))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "zh")
    }

    func testRecoverIfNeeded_writesTheWhisperModelPathItChose() {
        AppPreferences.shared.whisperLanguage = "en"

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(
                usableEngines: [.whisper],
                whisperModelPaths: ["/models/ggml-large-v3-turbo.bin"]
            )
        )

        XCTAssertEqual(
            outcome,
            .recovered(engine: .whisper, whisperModelPath: "/models/ggml-large-v3-turbo.bin", language: "en")
        )
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, "/models/ggml-large-v3-turbo.bin")
    }

    /// Nothing downloaded means nothing to write: the app must not claim an
    /// engine it does not have, it must say so.
    func testRecoverIfNeeded_withNothingDownloaded_changesNothing() {
        AppPreferences.shared.whisperLanguage = "en"

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(usableEngines: [], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertNil(storedPreference("selectedEngine"))
        XCTAssertNil(AppPreferences.shared.selectedWhisperModelPath)
    }

    /// The launch-recovery half of the same rule the pure tests pin: a cloud
    /// selection missing only its key - the user quit before pasting it, or
    /// denied the post-update keychain prompt - comes out of a launch exactly
    /// as it went in.
    func testRecoverIfNeeded_misconfiguredCloudSelection_leavesTheChoiceStored() {
        AppPreferences.shared.selectedEngine = .cloud

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(
                usableEngines: [.sensevoice],
                whisperModelPaths: [],
                cloudTranscriptionRefusal: .noAPIKey
            )
        )

        XCTAssertEqual(outcome, .cloudMisconfigured(.noAPIKey))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .cloud)
    }

    /// A user who already has a working engine must come out of a launch with
    /// exactly the engine they chose.
    func testRecoverIfNeeded_withAWorkingConfiguration_leavesPreferencesAlone() {
        AppPreferences.shared.selectedEngine = .paraformer
        AppPreferences.shared.whisperLanguage = "zh"

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(
                usableEngines: [.paraformer, .sensevoice, .whisper],
                whisperModelPaths: ["/models/ggml-tiny.en.bin"]
            )
        )

        XCTAssertEqual(outcome, .usable(.paraformer))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "zh")
        XCTAssertNil(AppPreferences.shared.selectedWhisperModelPath)
    }
}

/// `TranscriptionService.reloadEngine` and `.transcribeAudio` are the two ways a
/// stored engine gets checked outside of launch - a Settings tap and an actual
/// dictation attempt. Neither may rewrite the stored selection: recovery that
/// does that (`EngineConfiguration.recoverIfNeeded`) only runs once, at launch.
@MainActor
final class TranscriptionServiceEngineSelectionTests: IsolatedPreferencesTestCase {

    override func tearDown() {
        MainActor.assumeIsolated { TranscriptionService.shared.availabilityOverride = nil }
        super.tearDown()
    }

    /// The concrete failing sequence this closes: a user with a working Whisper
    /// setup taps an engine (e.g. Paraformer) whose weights are not downloaded
    /// yet. Even though Whisper was available to "recover" onto, the reload this
    /// tap triggers must leave the explicit choice stored exactly as made.
    func testReloadEngineWithoutDownload_afterExplicitSwitch_leavesTheChosenEngineStored() {
        AppPreferences.shared.selectedEngine = .paraformer
        let onlyWhisperIsDownloaded = EngineAvailability(
            usableEngines: [.whisper],
            whisperModelPaths: ["/models/ggml-large-v3-turbo.bin"]
        )

        TranscriptionService.shared.reloadEngine(allowModelDownload: false, availability: onlyWhisperIsDownloaded)

        XCTAssertEqual(
            AppPreferences.shared.selectedEngine,
            .paraformer,
            "loading a just-chosen, not-yet-downloaded engine must not revert to a previously working one"
        )
    }

    /// Dictating with nothing on the Mac at all still fails with the actionable
    /// error and still leaves the selection exactly as the user made it.
    ///
    /// The window this used to cover - dictating between picking an engine and
    /// its download finishing - is no longer a failure at all: `EngineSelector`
    /// keeps a previous or starter model running through it, which is what
    /// `EngineSelectionTests` covers. What remains here is the case where there
    /// is genuinely nothing to stand in.
    func testTranscribeAudio_withNothingAvailable_failsVisiblyWithoutRewritingTheSelection() async {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.selectedWhisperModelPath = "/definitely/does-not-exist.bin"
        TranscriptionService.shared.availabilityOverride = EngineAvailability(
            usableEngines: [],
            whisperModelPaths: []
        )

        do {
            _ = try await TranscriptionService.shared.transcribeAudio(
                url: URL(fileURLWithPath: "/tmp/echoforge-tests-does-not-exist.wav"),
                settings: Settings()
            )
            XCTFail("expected engineNotConfigured to be thrown")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .engineNotConfigured)
        }

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, "/definitely/does-not-exist.bin")
    }

    /// The superseding behaviour, stated where the old one was: a not-yet-ready
    /// selection is a state the app dictates through, not an error - and the
    /// preference still comes out untouched.
    func testTranscribeAudio_withAStandInAvailable_doesNotReportNothingConfigured() {
        AppPreferences.shared.selectedEngine = .paraformer
        AppPreferences.shared.whisperLanguage = "zh"
        AppPreferences.shared.lastReadyEngine = .sensevoice
        TranscriptionService.shared.availabilityOverride = EngineAvailability(
            usableEngines: [.sensevoice],
            whisperModelPaths: []
        )

        TranscriptionService.shared.reloadEngine(allowModelDownload: false)

        XCTAssertTrue(TranscriptionService.shared.isEngineConfigured)
        XCTAssertEqual(TranscriptionService.shared.selection.active, .sensevoice)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
    }
}
