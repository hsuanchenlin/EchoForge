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
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
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
