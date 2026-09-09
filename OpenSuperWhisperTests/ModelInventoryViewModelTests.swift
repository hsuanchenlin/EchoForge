import XCTest

@testable import OpenSuperWhisper

private final class MeasurementGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let firstStarted = DispatchSemaphore(value: 0)
    private var invocations = 0

    var count: Int {
        lock.withLock { invocations }
    }

    func measure(
        availability: EngineAvailability,
        preparations: [ModelPreparation]
    ) -> ([ModelInventoryEntry], Int64) {
        let invocation = lock.withLock {
            invocations += 1
            return invocations
        }
        if invocation == 1 {
            firstStarted.signal()
            releaseFirst.wait()
        }
        return ([], 0)
    }

    func waitUntilFirstStarts() async {
        await Task.detached { self.firstStarted.wait() }.value
    }

    func release() {
        releaseFirst.signal()
    }
}

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

    func testConfirmedRemovalReservesWeightsAgainstNewUse() {
        let service = TranscriptionService()

        XCTAssertEqual(service.reserveEngineForRemoval(.paraformer), .reserved)
        XCTAssertTrue(service.isEngineReservedForRemoval(.paraformer))
        XCTAssertEqual(service.reserveEngineForRemoval(.paraformer), .alreadyReserved)

        service.releaseEngineRemovalReservation(.paraformer)
        XCTAssertFalse(service.isEngineReservedForRemoval(.paraformer))
    }

    func testConfirmingRemovalIsRefusedWhileAnEngineLoadIsStarting() {
        let service = TranscriptionService()

        XCTAssertTrue(EngineWeightUseCoordinator.shared.beginUse(of: .paraformer))
        XCTAssertEqual(service.reserveEngineForRemoval(.paraformer), .engineInUse)
        EngineWeightUseCoordinator.shared.endUse(of: .paraformer)
    }

    func testOpeningRemovalDialogDoesNotReserveWeightsBeforeConfirmation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenSuperWhisper/Engines/ModelInventoryView.swift"),
            encoding: .utf8)
        let requestStart = try XCTUnwrap(source.range(of: "func requestRemoval"))
        let confirmStart = try XCTUnwrap(source.range(of: "func confirmRemoval"))
        let requestBody = source[requestStart.lowerBound..<confirmStart.lowerBound]

        XCTAssertFalse(requestBody.contains("reserveEngineForRemoval"))
        XCTAssertTrue(source[confirmStart.lowerBound...].contains("reserveEngineForRemoval"))
    }

    func testRefreshRequestedDuringMeasurementRunsAfterItFinishes() async {
        let gate = MeasurementGate()
        let viewModel = ModelInventoryViewModel(
            service: TranscriptionService(),
            measure: gate.measure)

        viewModel.refresh()
        await gate.waitUntilFirstStarts()
        viewModel.refresh()
        gate.release()

        for _ in 0..<200 where viewModel.isMeasuring || gate.count < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(gate.count, 2)
        XCTAssertFalse(viewModel.isMeasuring)
    }

    func testEngineUsePathsConsultRemovalReservation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenSuperWhisper/TranscriptionService.swift"),
            encoding: .utf8)

        for signature in [
            "private func startPreparingDesiredEngineIfNeeded(allowModelDownload: Bool)",
            "private func engineForTranscription() async throws",
        ] {
            let start = try XCTUnwrap(source.range(of: signature))
            let rest = source[start.upperBound...]
            let nextFunction = rest.range(of: "\n    private func ")
            let body = String(rest[..<(nextFunction?.lowerBound ?? rest.endIndex)])
            XCTAssertTrue(body.contains("isEngineReservedForRemoval"))
        }
    }
}
