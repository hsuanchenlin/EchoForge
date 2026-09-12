import AVFoundation
import XCTest

@testable import OpenSuperWhisper

/// `LiveAudioTap` against the real input device, which is the one thing about
/// it the fake-tap suite cannot say: that an `AVAudioEngine` tap pinned to the
/// chosen microphone starts, delivers 16 kHz mono frames, and stops.
///
/// Runs only on a host that already holds the microphone grant, like the
/// `MicrophoneService*` hardware cases: an ad-hoc test host asking for the
/// microphone gets a TCC dialog that hangs the whole run, so anything short of
/// `.authorized` skips rather than asks.
final class LiveAudioTapHardwareTests: XCTestCase {

    private func requireMicrophone() throws {
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "the test host holds no microphone grant; this case needs real hardware and TCC")
        try XCTSkipUnless(
            MicrophoneService.shared.getActiveMicrophone() != nil,
            "no input device")
    }

    func testTheTapDeliversSixteenKilohertzMonoFrames() throws {
        try requireMicrophone()

        let tap = LiveAudioTap()
        let lock = NSLock()
        var received: [Float] = []
        var callbacks = 0
        let firstFrames = expectation(description: "frames arrive")
        firstFrames.assertForOverFulfill = false

        try tap.start { frames in
            lock.lock()
            received.append(contentsOf: frames)
            callbacks += 1
            lock.unlock()
            firstFrames.fulfill()
        }
        defer { tap.stop() }

        wait(for: [firstFrames], timeout: 5)
        Thread.sleep(forTimeInterval: 1.0)
        tap.stop()

        lock.lock()
        let samples = received
        let count = callbacks
        lock.unlock()

        // At least half a second of the second that was listened to, at the
        // engines' rate: the converter is resampling, and a wrong ratio here
        // is a transcript of chipmunks.
        XCTAssertGreaterThan(samples.count, Int(PCMAudioLoader.sampleRate / 2), "too few samples for one second")
        XCTAssertLessThan(samples.count, Int(PCMAudioLoader.sampleRate * 3), "too many samples for one second")
        XCTAssertGreaterThan(count, 1, "frames arrive in more than one callback")
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 }, "frames are float PCM in -1...1")
    }

    func testStopIsIdempotentAndARestartWorks() throws {
        try requireMicrophone()

        let tap = LiveAudioTap()
        let arrived = expectation(description: "frames arrive")
        arrived.assertForOverFulfill = false
        try tap.start { _ in arrived.fulfill() }
        wait(for: [arrived], timeout: 5)
        tap.stop()
        tap.stop()

        let again = expectation(description: "frames arrive again")
        again.assertForOverFulfill = false
        try tap.start { _ in again.fulfill() }
        wait(for: [again], timeout: 5)
        tap.stop()
    }
}
