import XCTest
@testable import OpenSuperWhisper

/// The queue's rules that cannot be driven from a test.
///
/// `TranscriptionQueue` is a singleton wired to `TranscriptionService.shared`
/// and to the user's real recordings database, so the loop itself is asserted as
/// a pure function in `TranscriptionQueueStepTests` and the wiring that has to
/// hold around it is asserted here, in the source - the same way
/// `AskVoiceShortcutTests` asserts the recorder's ownership rules.
final class TranscriptionQueueBehaviourTests: XCTestCase {

    private var queue: String {
        get throws { try Self.source(of: "OpenSuperWhisper/TranscriptionQueue.swift") }
    }

    /// Every way a pass can end has to leave the row out of the three statuses
    /// `getNextPendingRecording` treats as pending, or the loop is handed it
    /// again and transcribes it a second time.
    func testEveryCancelledExitWritesTheRowOutOfTheQueue() throws {
        let source = try queue
        XCTAssertTrue(
            source.contains("private func processRecording(_ recording: Recording) async -> Bool"),
            "a pass has to report whether it settled the row")

        let settle = try Self.body(of: "private func settleCancelled(_ id: UUID) async -> Bool {", in: source)
        XCTAssertTrue(settle.contains("status: .failed"),
                      "a cancelled row leaves the pending statuses")
        XCTAssertTrue(settle.contains("Self.cancelledMessage"))

        // Three points in one pass can notice a cancellation, and all three have
        // to leave the same state behind.
        let body = try Self.body(of: "private func processRecording(_ recording: Recording) async -> Bool {", in: source)
        XCTAssertGreaterThanOrEqual(
            body.components(separatedBy: "settleCancelled(recording.id)").count - 1, 2,
            "the cancellation checks inside the transcription have to settle the row too")
        XCTAssertTrue(
            body.contains("Self.cancelledMessage"),
            "and so does the one before the transcription starts")
    }

    /// A queue that never stops being busy is not a stuck row: `isProcessing`
    /// gates `IndicatorViewModel.isTranscriptionBusy`, which refuses to start a
    /// dictation at all.
    func testTheBusyFlagComesDownHoweverTheLoopEnds() throws {
        let body = try Self.body(of: "func startProcessingQueue() {", in: try queue)
        XCTAssertTrue(body.contains("defer {"),
                      "the busy flag must come down on every exit, including a cancelled task")
        let deferred = try XCTUnwrap(body.range(of: "defer {")).upperBound
        let tail = String(body[deferred...])
        XCTAssertTrue(tail.contains("self.isProcessing = false"))
        XCTAssertTrue(tail.contains("self.cancelledRecordingIds.removeAll()"),
                      "the cancelled-id set only ever grew")
    }

    /// The loop asks `TranscriptionQueueStep` rather than deciding for itself.
    func testTheLoopUsesTheDecisionType() throws {
        let body = try Self.body(of: "private func processQueue() async {", in: try queue)
        XCTAssertTrue(body.contains("TranscriptionQueueStep.next("))
        XCTAssertFalse(
            body.contains("while let recording = recordingStore.getNextPendingRecording()"),
            "the loop that could not tell a settled row from an unsettled one")
    }

    /// Progress ticks stay out of the database.
    ///
    /// Whisper reports about a hundred of them per recording, and persisting
    /// each one meant that many SQLite transactions inside one transcription.
    /// The comment on `updateRecordingProgressTransient` says so; this is what
    /// keeps it true.
    func testAProgressTickWritesNothingToTheDatabase() throws {
        let store = try Self.source(of: "OpenSuperWhisper/Models/Recording.swift")
        let tick = try Self.body(
            of: "func updateRecordingProgressTransient(_ id: UUID, progress: Float, status: RecordingStatus) {",
            in: store)
        XCTAssertFalse(tick.contains("dbQueue"), "a progress tick must not reach the database")

        let local = try Self.body(
            of: "private func applyLocalProgressUpdate(", in: store)
        XCTAssertFalse(local.contains("dbQueue"), "nor may what it delegates to")
    }

    private static func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "no function \(signature) to read")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
