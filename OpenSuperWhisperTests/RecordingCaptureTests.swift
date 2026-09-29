import XCTest
@testable import OpenSuperWhisper

/// The per-claim handle `AudioRecorder.startRecording` returns.
///
/// `AudioRecorder` is a singleton wired to real CoreAudio, so the two ways a
/// start can fail cannot be provoked here. The handle is its own type for that
/// reason: a clean start, a failed start, and a second start while the first
/// is held are ordinary assertions against a fake controller.
final class RecordingCaptureTests: XCTestCase {

    private final class FakeController: RecordingCaptureControlling, @unchecked Sendable {
        let claim: RecordingSessionClaim
        var stoppedURL: URL?
        private(set) var stopped: [RecordingSession] = []
        private(set) var cancelled: [RecordingSession] = []

        init(claim: RecordingSessionClaim) {
            self.claim = claim
        }

        func stopRecording(_ session: RecordingSession) async -> URL? {
            stopped.append(session)
            guard claim.release(session) else { return nil }
            return stoppedURL
        }

        func cancelRecording(_ session: RecordingSession) {
            cancelled.append(session)
            _ = claim.release(session)
        }
    }

    private func makeCapture() throws -> (RecordingCapture, FakeController, RecordingSessionClaim) {
        let claim = RecordingSessionClaim()
        let session = try XCTUnwrap(claim.claim())
        let controller = FakeController(claim: claim)
        return (RecordingCapture(session: session, controller: controller), controller, claim)
    }

    private func assertStarted(
        _ result: Result<Void, FailedRecordingStart.Reason>,
        _ expected: Result<Void, FailedRecordingStart.Reason>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.success, .success):
            break
        case (.failure(let got), .failure(let want)):
            XCTAssertEqual(got, want, file: file, line: line)
        default:
            XCTFail("started() was \(result), expected \(expected)", file: file, line: line)
        }
    }

    /// A start that opens the microphone resolves `started()` as success, and
    /// every later waiter sees the same answer.
    func testACleanStartResolvesStartedAsSuccess() async throws {
        let (capture, _, _) = try makeCapture()

        capture.completeStart(.success(()))

        let first = await capture.started()
        let second = await capture.started()
        assertStarted(first, .success(()))
        assertStarted(second, .success(()))
    }

    /// Recording beginning is itself a successful start, so a capture that
    /// reaches `.recording` does not leave `started()` pending.
    func testRecordingNotesResolveTheStartAsSuccess() async throws {
        let (capture, _, _) = try makeCapture()

        capture.noteRecording(true)

        let result = await capture.started()
        assertStarted(result, .success(()))
    }

    /// Connecting is not success: a Bluetooth headset can still fail to open
    /// after connecting has been published.
    func testConnectingDoesNotResolveTheStart() async throws {
        let (capture, _, _) = try makeCapture()
        capture.noteConnecting(true)

        let stillPending = expectation(description: "started stays pending through connecting")
        stillPending.isInverted = true
        let waiter = Task {
            _ = await capture.started()
            stillPending.fulfill()
        }
        await fulfillment(of: [stillPending], timeout: 0.05)

        capture.completeStart(.failure(.noAudioInput))
        _ = await waiter.value
        assertStarted(await capture.started(), .failure(.noAudioInput))
    }

    /// A start that never opened the microphone resolves `started()` with the
    /// reason, and stop then hands back no audio - the claim is already gone.
    func testAFailedStartResolvesStartedWithTheReasonAndStopHandsBackNothing() async throws {
        let (capture, controller, claim) = try makeCapture()
        controller.stoppedURL = URL(fileURLWithPath: "/tmp/should-not-return.wav")

        XCTAssertTrue(claim.isHeld)
        _ = claim.release(capture.session)
        capture.completeStart(.failure(.recorderFailed))

        assertStarted(await capture.started(), .failure(.recorderFailed))
        let afterFailure = await capture.stop()
        XCTAssertNil(afterFailure)
        XCTAssertEqual(controller.stopped, [capture.session])
        XCTAssertFalse(claim.isHeld)
    }

    func testEachFailureReasonIsDistinguishableOnTheHandle() async throws {
        for reason in [FailedRecordingStart.Reason.noAudioInput, .recorderFailed] {
            let (capture, _, claim) = try makeCapture()
            _ = claim.release(capture.session)
            capture.completeStart(.failure(reason))
            assertStarted(await capture.started(), .failure(reason))
        }
    }

    /// One holder at a time, at the handle: a second claim is refused while
    /// the first capture is still held, and cancelling the first is what lets
    /// the next start through.
    func testASecondStartIsRefusedWhileTheFirstCaptureIsHeld() throws {
        let claim = RecordingSessionClaim()
        let controller = FakeController(claim: claim)
        let firstSession = try XCTUnwrap(claim.claim())
        let first = RecordingCapture(session: firstSession, controller: controller)

        XCTAssertNil(claim.claim(), "a second start is refused while the first capture is held")
        XCTAssertTrue(claim.isHeld)

        first.cancel()
        XCTAssertEqual(controller.cancelled, [firstSession])
        XCTAssertFalse(claim.isHeld)

        let secondSession = try XCTUnwrap(claim.claim())
        XCTAssertNotEqual(firstSession, secondSession)
    }

    /// Two captures do not share a start result. Completing one cannot resolve
    /// or fail the other - that is the whole point of the handle over a
    /// replaying `@Published`.
    func testTwoCapturesDoNotShareAStartResult() async throws {
        let firstClaim = RecordingSessionClaim()
        let firstSession = try XCTUnwrap(firstClaim.claim())
        firstClaim.release(firstSession)
        let first = RecordingCapture(
            session: firstSession, controller: FakeController(claim: firstClaim))

        let secondClaim = RecordingSessionClaim()
        let secondSession = try XCTUnwrap(secondClaim.claim())
        let second = RecordingCapture(
            session: secondSession, controller: FakeController(claim: secondClaim))

        first.completeStart(.failure(.noAudioInput))
        second.completeStart(.success(()))

        assertStarted(await first.started(), .failure(.noAudioInput))
        assertStarted(await second.started(), .success(()))
    }

    /// Stop names this capture's session. A second stop, or a stop after
    /// cancel, owns nothing and hands back no audio.
    func testStopAndCancelNameThisCapture() async throws {
        let (capture, controller, claim) = try makeCapture()
        controller.stoppedURL = URL(fileURLWithPath: "/tmp/capture.wav")
        capture.completeStart(.success(()))

        let url = await capture.stop()
        XCTAssertEqual(url, controller.stoppedURL)
        XCTAssertEqual(controller.stopped, [capture.session])
        XCTAssertFalse(claim.isHeld)

        let secondStop = await capture.stop()
        XCTAssertNil(secondStop, "a second stop owns nothing")
        capture.cancel()
        XCTAssertEqual(controller.cancelled, [capture.session])
    }
}
