import XCTest
@testable import OpenSuperWhisper

/// Onboarding's one obligation: the row it shows as selected is the row whose
/// engine is stored.
///
/// It was broken for the automatic selection only - a user who tapped a row got
/// their engine persisted, and a user whose model was already downloaded (a
/// reinstall, or a cache shared with another build) got a green checkmark, an
/// enabled Continue button and no `selectedEngine` at all. The screen then set
/// `hasCompletedOnboarding` and every dictation afterwards failed to load an
/// engine and was discarded without a word.
///
/// The download state is injected, so these pin the rule rather than whichever
/// caches happen to be on the machine running the tests, and the preferences go
/// to a throwaway suite - see `IsolatedPreferencesTestCase`.
@MainActor
final class OnboardingEngineSelectionTests: IsolatedPreferencesTestCase {

    /// Reports exactly one row as downloaded: the one matching `engine`, or the
    /// first Whisper row when `whisperFilename` is given.
    private func reader(engine: EngineKind? = nil,
                        parakeetVersion: String? = nil,
                        whisperFilename: String? = nil) -> OnboardingViewModel.DownloadStateReader {
        { type in
            switch type {
            case .engine(let kind):
                return kind == engine
            case .parakeet(let version):
                return version == parakeetVersion
            case .whisper(let url, _):
                return url.lastPathComponent == whisperFilename
            }
        }
    }

    private func makeViewModel(_ isDownloaded: @escaping OnboardingViewModel.DownloadStateReader)
        -> OnboardingViewModel {
        OnboardingViewModel(isDownloaded: isDownloaded)
    }

    // MARK: - The bug

    /// The captain's own machine: SenseVoice already in the shared cache, so the
    /// row is auto-selected on the first screen. The engine behind it has to be
    /// the stored one.
    func testAutoSelectedDownloadedRow_persistsItsEngine() {
        let viewModel = makeViewModel(reader(engine: .sensevoice))

        XCTAssertNotNil(viewModel.selectedModelId, "a downloaded row is shown as selected")
        XCTAssertTrue(viewModel.canContinue, "and Continue is enabled on the strength of it")
        XCTAssertEqual(
            AppPreferences.shared.selectedEngine, .sensevoice,
            "so the engine it names must be the one stored"
        )
    }

    func testAutoSelectedWhisperRow_persistsTheEngineAndTheModelPath() {
        let viewModel = makeViewModel(reader(whisperFilename: "ggml-large-v3-turbo.bin"))

        XCTAssertTrue(viewModel.canContinue)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
        XCTAssertEqual(
            AppPreferences.shared.selectedWhisperModelPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            "ggml-large-v3-turbo.bin",
            "Whisper is the one engine that also needs the file, so both halves are stored"
        )
    }

    func testAutoSelectedParakeetRow_persistsTheEngineAndTheModelVersion() {
        let viewModel = makeViewModel(reader(parakeetVersion: "v2"))

        XCTAssertTrue(viewModel.canContinue)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .fluidaudio)
        XCTAssertEqual(AppPreferences.shared.fluidAudioModelVersion, "v2")
    }

    /// Whatever onboarding leaves behind, the engine that comes out of it has to
    /// be one the app can actually load - which is the question
    /// `EngineConfiguration` answers everywhere else.
    func testAutoSelectedRow_leavesAConfigurationTheAppCanLoad() {
        _ = makeViewModel(reader(engine: .sensevoice))

        XCTAssertTrue(
            EngineConfiguration.isConfigured(
                engine: AppPreferences.shared.selectedEngine,
                whisperModelPath: AppPreferences.shared.selectedWhisperModelPath,
                availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
            )
        )
    }

    // MARK: - Nothing downloaded

    func testNothingDownloaded_selectsNothingAndBlocksContinue() {
        let viewModel = makeViewModel { _ in false }

        XCTAssertNil(viewModel.selectedModelId)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertFalse(
            viewModel.commitSelectedModel(),
            "onboarding must not be finishable while nothing can transcribe"
        )
        XCTAssertNil(
            storedPreference("selectedEngine"),
            "and it must not invent an engine to get past itself"
        )
    }

    // MARK: - Explicit selection is unchanged

    func testExplicitSelection_persistsTheEngineAsItAlwaysHas() throws {
        let viewModel = makeViewModel { _ in true }

        let paraformerRow = try XCTUnwrap(
            viewModel.unifiedModels.first { model in
                if case .engine(.paraformer) = model.type { return true }
                return false
            }
        )
        viewModel.selectModel(paraformerRow)

        XCTAssertEqual(viewModel.selectedModelId, paraformerRow.id)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
        XCTAssertEqual(
            AppPreferences.shared.whisperLanguage, "zh",
            "Paraformer is Mandarin-only, so selecting it moves the language with it"
        )
    }

    /// Selecting a row after the automatic one wins, and takes the stored engine
    /// with it.
    func testSelectionAfterAutoSelection_replacesTheStoredEngine() throws {
        let viewModel = makeViewModel { _ in true }
        let autoSelected = viewModel.selectedModelId

        let whisperRow = try XCTUnwrap(
            viewModel.unifiedModels.first { model in
                if case .whisper = model.type { return true }
                return false
            }
        )
        viewModel.selectModel(whisperRow)

        XCTAssertNotEqual(viewModel.selectedModelId, autoSelected)
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .whisper)
        XCTAssertNotNil(AppPreferences.shared.selectedWhisperModelPath)
    }

    // MARK: - Continue

    func testCommitSelectedModel_persistsTheSelectionItLetsThrough() {
        let viewModel = makeViewModel(reader(engine: .paraformer))

        XCTAssertTrue(viewModel.commitSelectedModel())
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .paraformer)
    }

    /// The guard at the moment that decides whether the user ever sees this
    /// screen again: a row whose model has gone missing since it was selected
    /// does not finish onboarding.
    func testCommitSelectedModel_rejectsARowThatIsNoLongerDownloaded() {
        var downloaded = true
        let viewModel = makeViewModel { type in
            if case .engine(.sensevoice) = type { return downloaded }
            return false
        }
        XCTAssertTrue(viewModel.canContinue)

        downloaded = false

        XCTAssertFalse(viewModel.commitSelectedModel())
    }
}
