import XCTest
@testable import OpenSuperWhisper

/// The queue loop's rule for what to do with the row the store hands it.
///
/// The case that made this a type rather than a `while let` is
/// `testACancelledItemIsNotHandedBackToTheEngine`: `getNextPendingRecording`
/// counts `.converting` as pending, so a pass that ended without writing the row
/// out of that status got the same row back on the next turn and transcribed the
/// recording the user had just cancelled.
final class TranscriptionQueueStepTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testAnEmptyQueueFinishes() {
        XCTAssertEqual(TranscriptionQueueStep.next(nil, after: nil), .finished)
        XCTAssertEqual(
            TranscriptionQueueStep.next(nil, after: .init(id: a, settled: true)),
            .finished
        )
    }

    func testTheFirstPendingRecordingIsProcessed() {
        XCTAssertEqual(TranscriptionQueueStep.next(a, after: nil), .process(a))
    }

    func testTheNextRecordingIsProcessedAfterOneThatSettled() {
        XCTAssertEqual(
            TranscriptionQueueStep.next(b, after: .init(id: a, settled: true)),
            .process(b)
        )
    }

    /// The failure-then-success case: an item that failed settles, and the item
    /// behind it runs normally.
    func testAFailedItemDoesNotBlockTheNextOne() {
        var previous: TranscriptionQueueStep.Previous?
        // `a` failed - a failure still writes the row out of the queue.
        previous = .init(id: a, settled: true)
        XCTAssertEqual(TranscriptionQueueStep.next(b, after: previous), .process(b))
    }

    /// The bug this exists for: a pass that left the row pending must not be
    /// handed the same row to run again.
    func testACancelledItemIsNotHandedBackToTheEngine() {
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: false)),
            .abandon(a)
        )
    }

    /// Abandoning writes the row out of the queue. If it comes back anyway the
    /// database is not accepting the write, and the loop must end rather than
    /// spin: `isProcessing` gates every later dictation.
    func testARowThatSurvivesBeingAbandonedEndsTheLoop() {
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: false, abandoned: true)),
            .finished
        )
    }

    /// The swallowed write, which is the case the whole `settled` flag is for: a
    /// pass that ran to the end and could not persist what it did reports itself
    /// unsettled, so the row it left in the pending statuses is written out
    /// rather than transcribed a second time. `TranscriptionQueue` used to
    /// answer `true` here regardless - the store printed the error and returned
    /// nothing - so the loop read the row coming back as a regenerate.
    func testAPassWhosePersistenceFailedIsAbandonedRatherThanRepeated() {
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: false)),
            .abandon(a)
        )

        // And when the abandoning write is swallowed too, the loop ends rather
        // than turning again on a database that is not accepting writes.
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: false, abandoned: true)),
            .finished
        )

        // An abandoning write that *did* land settles the row, so the user
        // pressing regenerate on it is new work like any other.
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: true, abandoned: true)),
            .process(a)
        )
    }

    /// The false positive an identity-only rule would have: the user presses
    /// regenerate on the recording that just finished, while the loop is still
    /// draining. That pass settled the row, so this is a new piece of work.
    func testRegeneratingTheRecordingThatJustFinishedIsProcessed() {
        XCTAssertEqual(
            TranscriptionQueueStep.next(a, after: .init(id: a, settled: true)),
            .process(a)
        )
    }

    /// Draining a queue of three, the middle one of which is cancelled, ends -
    /// and no recording is handed to the engine twice.
    func testDrainingAQueueTerminatesAndNoItemRunsTwice() {
        let c = UUID()
        // What the store would return each turn, given what the loop wrote.
        var pending = [a, b, c]
        var processed: [UUID] = []
        var abandoned: [UUID] = []
        var previous: TranscriptionQueueStep.Previous?

        for _ in 0..<20 {
            switch TranscriptionQueueStep.next(pending.first, after: previous) {
            case .finished:
                XCTAssertEqual(processed, [a, b, c], "Every item is attempted, in order")
                XCTAssertEqual(Set(processed).count, processed.count, "and none of them twice")
                XCTAssertEqual(abandoned, [b], "The cancelled one is written out, not re-run")
                return
            case .process(let id):
                processed.append(id)
                // `b` is the cancelled one: its pass leaves it pending.
                if id == b {
                    previous = .init(id: id, settled: false)
                } else {
                    pending.removeFirst()
                    previous = .init(id: id, settled: true)
                }
            case .abandon(let id):
                abandoned.append(id)
                pending.removeFirst()
                previous = .init(id: id, settled: false, abandoned: true)
            }
        }
        XCTFail("The loop did not terminate")
    }
}
