import FluidAudio
import XCTest
@testable import OpenSuperWhisper

final class ModelLoadCoordinatorTests: XCTestCase {
    func testLateJoinerReceivesLatestAndFutureProgressFromSingleOperation() async throws {
        let coordinator = ModelLoadCoordinator<String>()
        let operationStarted = XCTestExpectation(description: "operation started")
        let releaseOperation = XCTestExpectation(description: "release operation")
        let joinedOperation = XCTestExpectation(description: "joined operation")
        let progress = ProgressRecorder()
        let operationCount = Counter()

        let first = Task {
            try await coordinator.run {
                await operationCount.increment()
                operationStarted.fulfill()
                await coordinator.reportProgress(
                    .init(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4))
                )
                await self.fulfillment(of: [releaseOperation], timeout: 1)
                await coordinator.reportProgress(
                    .init(fractionCompleted: 0.75, phase: .downloading(completedFiles: 3, totalFiles: 4))
                )
                return "loaded"
            }
        }

        await fulfillment(of: [operationStarted], timeout: 1)
        let second = Task {
            try await coordinator.run(progressHandler: { update in
                progress.append(update.fractionCompleted)
                joinedOperation.fulfill()
            }) {
                await operationCount.increment()
                return "duplicate"
            }
        }

        await fulfillment(of: [joinedOperation], timeout: 1)
        releaseOperation.fulfill()

        let firstValue = try await first.value
        let secondValue = try await second.value
        let finalOperationCount = await operationCount.value
        XCTAssertEqual(firstValue, "loaded")
        XCTAssertEqual(secondValue, "loaded")
        XCTAssertEqual(finalOperationCount, 1)
        XCTAssertEqual(progress.values, [0.25, 0.75])
    }

    func testCancellingOnlyWaiterCancelsUnderlyingOperation() async {
        let coordinator = ModelLoadCoordinator<String>()
        let operationStarted = XCTestExpectation(description: "operation started")
        let operationCancelled = XCTestExpectation(description: "operation cancelled")

        let waiter = Task {
            try await coordinator.run {
                operationStarted.fulfill()
                do {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    operationCancelled.fulfill()
                    throw error
                }
            }
        }

        await fulfillment(of: [operationStarted], timeout: 1)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Cancelled waiter unexpectedly completed")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [operationCancelled], timeout: 1)
    }

    func testCancellingOneWaiterKeepsLoadAliveForAnotherWaiter() async throws {
        let coordinator = ModelLoadCoordinator<String>()
        let operationStarted = XCTestExpectation(description: "operation started")
        let releaseOperation = XCTestExpectation(description: "release operation")
        let joinedOperation = XCTestExpectation(description: "joined operation")
        let operationWasCancelled = Flag()

        let dictationWaiter = Task {
            try await coordinator.run {
                operationStarted.fulfill()
                await coordinator.reportProgress(
                    .init(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4))
                )
                await self.fulfillment(of: [releaseOperation], timeout: 1)
                await operationWasCancelled.set(Task.isCancelled)
                try Task.checkCancellation()
                return "loaded"
            }
        }

        await fulfillment(of: [operationStarted], timeout: 1)
        let settingsWaiter = Task {
            try await coordinator.run(progressHandler: { _ in joinedOperation.fulfill() }) {
                "duplicate"
            }
        }
        await fulfillment(of: [joinedOperation], timeout: 1)

        settingsWaiter.cancel()
        await Task.yield()
        releaseOperation.fulfill()

        let dictationValue = try await dictationWaiter.value
        let underlyingWasCancelled = await operationWasCancelled.value
        XCTAssertEqual(dictationValue, "loaded")
        XCTAssertFalse(underlyingWasCancelled)
        do {
            _ = try await settingsWaiter.value
            XCTFail("Cancelled waiter unexpectedly completed")
        } catch is CancellationError {
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Flag {
    private(set) var value = false
    func set(_ value: Bool) { self.value = value }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}
