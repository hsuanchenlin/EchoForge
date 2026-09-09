import XCTest

@testable import OpenSuperWhisper

/// The wiring between a Settings-driven engine download and the inventory's
/// removal decision.
///
/// `TranscriptionService.modelPreparation` tracks only the desired engine's
/// background preparation, so a download started from the inventory's own
/// Download button is invisible to it. What stops a removal deleting the cache
/// that download is writing into is `settingsPreparation`, and these assert
/// the wiring rather than the decision - `ModelInventoryTests` has the
/// decision.
@MainActor
final class ModelInventoryViewModelTests: XCTestCase {

    private func entry(for engine: EngineKind) -> ModelInventoryEntry {
        ModelInventoryEntry(
            engine: engine, readiness: .incomplete, installedBytes: 120_000_000,
            expectedMegabytes: 653, cacheDirectories: [URL(fileURLWithPath: "/tmp/models")])
    }

    func testRemovalIsRefusedWhileSettingsDownloadsThatEngine() {
        let viewModel = ModelInventoryViewModel(service: TranscriptionService())
        viewModel.settingsPreparation = ModelPreparation(
            engine: .paraformer, stage: .downloading(fraction: 0.3))

        viewModel.requestRemoval(of: entry(for: .paraformer))

        XCTAssertNil(viewModel.pendingRemoval)
        XCTAssertEqual(viewModel.failure, ModelRemoval.Refusal.engineIsBeingPrepared.message)
    }

    /// A download of a *different* engine is not a reason to refuse: only the
    /// cache being written into is at risk.
    func testRemovalOfAnEngineSettingsIsNotDownloadingIsStillAskedAbout() {
        let viewModel = ModelInventoryViewModel(service: TranscriptionService())
        viewModel.settingsPreparation = ModelPreparation(
            engine: .sensevoice, stage: .downloading(fraction: 0.3))

        viewModel.requestRemoval(of: entry(for: .paraformer))

        XCTAssertNil(viewModel.failure)
        XCTAssertEqual(viewModel.pendingRemoval?.engine, .paraformer)
    }
}
