import XCTest
@testable import OpenSuperWhisper

/// A recording start that fails after the caller has been handed its session.
///
/// `startRecording` claims the microphone synchronously and returns at once,
/// then pays CoreAudio's 20-35 ms on the work queue - so both ways a start can
/// fail happen after the caller has been told it owns a recording. The claim was
/// given back there and nothing else was: the dictation card blinked
/// "Recording..." over a microphone that never opened, the press that ended it
/// got `nil` from `stopRecording`, and the session closed without a word. The
/// Ask panel had the same hole and reported it as "No speech detected".
final class FailedRecordingStartTests: XCTestCase {

    /// Two sessions from one claim, which is the only way to get two distinct
    /// ones: the counter belongs to the claim, and a fresh claim starts again at
    /// the same id.
    private func twoSessions() throws -> (RecordingSession, RecordingSession) {
        let claim = RecordingSessionClaim()
        let first = try XCTUnwrap(claim.claim())
        claim.release(first)
        let second = try XCTUnwrap(claim.claim())
        XCTAssertNotEqual(first, second)
        return (first, second)
    }

    /// The subscription rule, which is the whole of it: `failedStart` is
    /// `@Published` and five keys share one recorder, so a surface may act only
    /// on a failure naming the session it is actually holding.
    func testAFailureEndsOnlyTheSessionItNames() throws {
        let (mine, someoneElses) = try twoSessions()
        let failure = FailedRecordingStart(session: mine, reason: .noAudioInput)

        XCTAssertTrue(failure.ends(mine))
        XCTAssertFalse(failure.ends(someoneElses),
                       "the Ask panel's failure must not end a dictation")
    }

    /// The replay case: a subscriber holding nothing is replayed whatever
    /// failure was last published, and must ignore it.
    func testAFailureEndsNothingWhenNoSessionIsHeld() throws {
        let failure = FailedRecordingStart(session: try twoSessions().0, reason: .recorderFailed)
        XCTAssertFalse(failure.ends(nil))
    }

    /// Two reasons because they are two different sentences, and the short forms
    /// are what the 200 pt card and the capsule pill actually hold.
    func testEachReasonHasWordsForEverySurface() {
        for reason in [FailedRecordingStart.Reason.noAudioInput, .recorderFailed] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.shortMessage.isEmpty)
            XCTAssertLessThanOrEqual(
                reason.shortMessage.count, 20,
                "the card and the pill hold about this much on one line")
        }
        // A machine with no input reports the same fact the synchronous
        // pre-check reports, so it lands on the same card.
        XCTAssertEqual(FailedRecordingStart.Reason.noAudioInput.indicatorState, .noMicrophone)
        XCTAssertEqual(
            FailedRecordingStart.Reason.recorderFailed.indicatorState,
            .recordingFailed(FailedRecordingStart.Reason.recorderFailed.shortMessage))
    }

    /// The regression itself: neither failure path may give the claim back
    /// silently. `AudioRecorder.shared` is wired to real hardware and neither
    /// failure can be provoked on a working Mac, so this is asserted where it
    /// can be - in the source.
    func testBothFailingStartsReportRatherThanReleaseSilently() throws {
        let recorder = try Self.source(of: "OpenSuperWhisper/AudioRecorder.swift")

        XCTAssertTrue(
            try Self.body(of: "func startRecording() -> RecordingSession? {", in: recorder)
                .contains("self.failStart(session, .noAudioInput)"),
            "a start that finds no microphone has to say so, not just release the claim")

        XCTAssertTrue(
            recorder.contains("failStart(session, .recorderFailed)"),
            "an AVAudioRecorder that threw has to say so too")

        XCTAssertFalse(
            try Self.body(of: "func startRecording() -> RecordingSession? {", in: recorder)
                .contains("self.releaseSession(session)"),
            "releasing without reporting is the bug this exists to keep out")

        XCTAssertTrue(
            try Self.body(of: "private func failStart(", in: recorder)
                .contains("releaseSession(session)"),
            "and the report must not leave the microphone claimed")
    }

    /// Every surface that takes the microphone listens for it - the dictation
    /// card, the Ask panel, and the main window's record button, which claims
    /// the same shared recorder and had nothing but `isRecording` going false to
    /// go on. That never happens on a start that found no audio input, so the
    /// window sat on a session naming a recording that never began.
    func testEverySurfaceHoldingTheMicrophoneListensForAFailedStart() throws {
        for path in [
            "OpenSuperWhisper/Indicator/IndicatorWindow.swift",
            "OpenSuperWhisper/Ask/AskPanelWindowController.swift",
            "OpenSuperWhisper/ContentView.swift",
        ] {
            let source = try Self.source(of: path)
            XCTAssertTrue(
                source.contains("$failedStart"),
                "\(path) starts recordings and so has to hear about starts that fail")
            XCTAssertTrue(
                source.contains("failure.ends("),
                "\(path) must act only on its own session's failure")
        }
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
