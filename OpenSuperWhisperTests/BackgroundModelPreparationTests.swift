import XCTest

@testable import OpenSuperWhisper

/// The promise the whole feature rests on: nothing that happens while a model is
/// being prepared may change what the user chose.
///
/// There are three ways it could, and one test each: the interim engine that
/// stands in for the download, the launch-time recovery that repairs stale
/// configurations, and the record of which engine last loaded.
@MainActor
final class DesiredEnginePreferenceSafetyTests: IsolatedPreferencesTestCase {

    /// Selecting an engine whose weights are not there yet leaves the selection
    /// exactly as made, however long the download takes and whatever is
    /// transcribing meanwhile.
    func testRunningOnAnInterimEngine_neverRewritesTheSelection() {
        AppPreferences.shared.selectedEngine = .paraformer
        AppPreferences.shared.whisperLanguage = "zh"
        AppPreferences.shared.lastReadyEngine = .sensevoice

        TranscriptionService.shared.refreshSelection(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        )

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
        XCTAssertEqual(TranscriptionService.shared.selection.desired, .paraformer)
        XCTAssertEqual(TranscriptionService.shared.selection.active, .sensevoice)
        XCTAssertEqual(TranscriptionService.shared.selection.interimReason, .previousModel)
    }

    /// Dictation stays available throughout, which is what stops the whole thing
    /// from being an error state with better wording.
    func testAnInterimEngineMeansDictationIsStillAvailable() {
        AppPreferences.shared.selectedEngine = .paraformer
        AppPreferences.shared.whisperLanguage = "zh"
        AppPreferences.shared.lastReadyEngine = .sensevoice

        TranscriptionService.shared.refreshSelection(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        )

        XCTAssertTrue(TranscriptionService.shared.isEngineConfigured)
    }

    /// With nothing at all on the Mac the app says so rather than accepting
    /// dictation it will throw away - and still leaves the selection alone.
    func testNothingReady_reportsUnavailableWithoutRewritingTheSelection() {
        AppPreferences.shared.selectedEngine = .paraformer

        TranscriptionService.shared.refreshSelection(
            availability: EngineAvailability(usableEngines: [], whisperModelPaths: [])
        )

        XCTAssertFalse(TranscriptionService.shared.isEngineConfigured)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
    }

    /// `lastReadyEngine` is written only by a successful load, so it must not
    /// already exist for an engine that has never loaded.
    func testTheLastReadyEngineIsNotWrittenByMerelySelectingOne() {
        AppPreferences.shared.selectedEngine = .paraformer

        TranscriptionService.shared.refreshSelection(
            availability: EngineAvailability(usableEngines: [], whisperModelPaths: [])
        )

        XCTAssertNil(storedPreference("lastReadyEngine"))
    }
}

/// Launch-time recovery, which is the one thing in the app that *may* rewrite the
/// selection - and the boundary that keeps it from rewriting a download in
/// progress.
final class LaunchRecoveryAndPendingPreparationTests: IsolatedPreferencesTestCase {

    /// Quitting during a 240 MB download and relaunching must not undo the
    /// choice that started it. Without the pending marker, recovery sees an
    /// engine that cannot load and repairs it onto something else - silently
    /// discarding what the user asked for.
    func testAnInterruptedDownloadIsResumedRatherThanRecoveredAway() {
        AppPreferences.shared.selectedEngine = .paraformer
        AppPreferences.shared.whisperLanguage = "zh"
        AppPreferences.shared.pendingEnginePreparation = .paraformer

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .preparing(.paraformer))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "zh")
    }

    /// The marker only protects the engine it names. A stale marker left behind
    /// for a different engine must not stop recovery repairing a genuinely
    /// broken configuration.
    func testAPendingMarkerForAnotherEngineDoesNotBlockRecovery() {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.whisperLanguage = "zh"
        AppPreferences.shared.pendingEnginePreparation = .paraformer

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .recovered(engine: .sensevoice, whisperModelPath: nil, language: "zh"))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
    }

    /// A genuinely stale configuration is still repaired, exactly as before: a
    /// Whisper model deleted from disk is not something the app can fetch back on
    /// its own, so it is not "pending".
    func testADeletedWhisperModelIsStillRecoveredFrom() {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.selectedWhisperModelPath = "/models/deleted.bin"
        AppPreferences.shared.whisperLanguage = "en"

        let outcome = EngineConfiguration.recoverIfNeeded(
            availability: EngineAvailability(usableEngines: [.fluidaudio], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .recovered(engine: .fluidaudio, whisperModelPath: nil, language: "en"))
    }

    /// The pending marker is stored as a plain string, so a value written by a
    /// build that had an engine this one does not must read back as nothing
    /// rather than as the fallback engine - which would wrongly protect it.
    func testAnUnknownPendingEngineReadsBackAsNothing() {
        PreferenceStore.defaults.set("an-engine-from-the-future", forKey: "pendingEnginePreparation")

        XCTAssertNil(AppPreferences.shared.pendingEnginePreparation)
    }

    func testTheLastReadyEngineAlsoReadsBackAsNothingWhenUnknown() {
        PreferenceStore.defaults.set("an-engine-from-the-future", forKey: "lastReadyEngine")

        XCTAssertNil(AppPreferences.shared.lastReadyEngine)
    }
}
