import XCTest
@testable import OpenSuperWhisper

/// Why a capture's microphone never opened, as words.
///
/// The identity that used to live on a published `FailedRecordingStart` is
/// now the `RecordingCapture` handle itself; `RecordingCaptureTests` holds
/// that. What remains here is the two sentences each reason has to have,
/// because they are what the 200 pt card and the capsule pill actually hold.
final class FailedRecordingStartTests: XCTestCase {

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
        XCTAssertEqual(FailedRecordingStart.Reason.noAudioInput.notice, .noMicrophone)
        XCTAssertEqual(
            FailedRecordingStart.Reason.recorderFailed.notice,
            .recordingFailed(FailedRecordingStart.Reason.recorderFailed.shortMessage))
    }
}
