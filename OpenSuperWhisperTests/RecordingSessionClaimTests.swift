import XCTest
@testable import OpenSuperWhisper

/// Who holds the microphone.
///
/// This is the rule four recording entry points rest on, and every seizure the
/// Ask panel and dictation keys have had came from a caller acting on a session
/// it did not own. `RecordingSessionClaim` exists as its own type so that rule
/// can be asserted here rather than inferred from `AudioRecorder`, which is a
/// singleton wired to real hardware and cannot be exercised in a test at all.
final class RecordingSessionClaimTests: XCTestCase {

    /// One holder at a time. This is the whole point: `AudioRecorder`'s
    /// `performStart` deletes the recording in flight and re-points its file, so
    /// a second start that was allowed through destroyed the first caller's
    /// audio - the dictation's, or the Ask panel's question.
    func testOnlyOneCallerCanHoldTheMicrophoneAtATime() {
        let claim = RecordingSessionClaim()
        XCTAssertFalse(claim.isHeld)

        XCTAssertNotNil(claim.claim())
        XCTAssertTrue(claim.isHeld, "the claim has to be visible immediately, not a runloop turn later")
        XCTAssertNil(claim.claim(), "a second caller is refused rather than taking it over")
        XCTAssertNil(claim.claim(), "and refused again - refusing does not consume anything")
    }

    /// Giving it back is what lets the next press have it, and the claim really
    /// is free again afterwards rather than merely reported as free.
    func testReleasingTheHolderHandsTheMicrophoneToTheNextCaller() throws {
        let claim = RecordingSessionClaim()
        let mine = try XCTUnwrap(claim.claim())

        XCTAssertTrue(claim.release(mine))
        XCTAssertFalse(claim.isHeld)

        let theirs = try XCTUnwrap(claim.claim())
        XCTAssertNotEqual(mine, theirs, "each claim is its own session, or a stale one would be honoured")
    }

    /// The rule that makes stopping safe. A caller can be holding a session that
    /// is no longer in flight - its start gave the claim back on the recorder's
    /// work queue when the microphone turned out to be gone - and somebody else
    /// may hold the microphone by then. Presenting the stale one must change
    /// nothing at all: it is what let the Ask panel's stop return a dictation's
    /// audio, which was then pasted into the user's document.
    func testAStaleSessionCanNeitherEndNorFreeTheOneInFlight() throws {
        let claim = RecordingSessionClaim()
        let stale = try XCTUnwrap(claim.claim())
        XCTAssertTrue(claim.release(stale))

        let inFlight = try XCTUnwrap(claim.claim())

        XCTAssertFalse(claim.release(stale), "a stale session must be told it owns nothing")
        XCTAssertTrue(claim.isHeld, "and must not have freed the session that does own the microphone")
        XCTAssertTrue(claim.release(inFlight), "which is still the holder's to give back")
    }

    /// Releasing twice is the double-stop a hotkey key-up and a second press
    /// make between them. Exactly one of them may carry the stop out, or two
    /// callers both act on one recording.
    func testOnlyTheFirstReleaseOfASessionIsHonoured() throws {
        let claim = RecordingSessionClaim()
        let session = try XCTUnwrap(claim.claim())

        XCTAssertTrue(claim.release(session))
        XCTAssertFalse(claim.release(session))
        XCTAssertFalse(claim.isHeld)
    }

    /// Claims and releases arrive from the main queue, the recorder's work queue
    /// and its stop-tail timer, so the compare-and-clear has to be atomic. Under
    /// contention the invariant is still "one holder": every claim that succeeds
    /// is released by its own holder, and no two overlap.
    func testTheClaimHoldsUnderConcurrentCallers() {
        let claim = RecordingSessionClaim()
        let tally = Tally()

        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            guard let session = claim.claim() else { return }
            tally.enter()
            tally.leave()
            if !claim.release(session) { tally.recordRefusedOwnRelease() }
        }

        XCTAssertEqual(tally.overlaps, 0, "two callers held the microphone at once")
        XCTAssertEqual(tally.refusedOwnReleases, 0, "a holder must always be able to give its own claim back")
        XCTAssertFalse(claim.isHeld)
    }

    /// Counts holders across threads without XCTest assertions off the main
    /// thread, so a failure is reported once, from the test body.
    private final class Tally {
        private let lock = NSLock()
        private var holders = 0
        private(set) var overlaps = 0
        private(set) var refusedOwnReleases = 0

        func enter() {
            lock.lock()
            holders += 1
            if holders > 1 { overlaps += 1 }
            lock.unlock()
        }

        func leave() {
            lock.lock()
            holders -= 1
            lock.unlock()
        }

        func recordRefusedOwnRelease() {
            lock.lock()
            refusedOwnReleases += 1
            lock.unlock()
        }
    }
}
