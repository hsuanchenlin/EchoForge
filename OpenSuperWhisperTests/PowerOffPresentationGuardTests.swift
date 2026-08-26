import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// A sheet on screen makes AppKit refuse the quit Apple Event that loginwindow
/// sends, so the user's restart is cancelled and Kongweh is named in a dialog.
/// These tests drive the whole path that stops that happening - the workspace
/// signal in, a sheet off the screen out - with no shutdown involved.
@MainActor
final class PowerOffPresentationGuardTests: XCTestCase {

    /// A name of this test's own, posted into a centre of this test's own.
    /// Nothing here can be woken by the real system, and nothing here can wake
    /// the real app.
    private let powerOff = Notification.Name("PowerOffPresentationGuardTests.willPowerOff")
    private var workspace: NotificationCenter!
    private var app: NotificationCenter!
    private var guardUnderTest: PowerOffPresentationGuard!

    override func setUp() {
        super.setUp()
        workspace = NotificationCenter()
        app = NotificationCenter()
        guardUnderTest = PowerOffPresentationGuard(
            observing: workspace, broadcastingOn: app, powerOffNotification: powerOff)
    }

    override func tearDown() {
        guardUnderTest?.stop()
        guardUnderTest = nil
        workspace = nil
        app = nil
        super.tearDown()
    }

    // MARK: - The notification boundary

    func testItAsksForModalPresentationsToBeDismissedWhenTheMacIsPoweringOff() {
        let broadcasts = countBroadcasts()
        guardUnderTest.start()

        workspace.post(name: powerOff, object: nil)

        XCTAssertEqual(broadcasts.value, 1, "the power-off broadcast did not reach the app")
    }

    /// A guard nobody started must be inert - otherwise the seam is not a seam
    /// and a test could not own its own centre.
    func testItBroadcastsNothingBeforeItIsStarted() {
        let broadcasts = countBroadcasts()

        workspace.post(name: powerOff, object: nil)

        XCTAssertEqual(broadcasts.value, 0)
    }

    func testItBroadcastsNothingAfterItIsStopped() {
        let broadcasts = countBroadcasts()
        guardUnderTest.start()
        guardUnderTest.stop()

        workspace.post(name: powerOff, object: nil)

        XCTAssertEqual(broadcasts.value, 0)
    }

    /// `applicationDidFinishLaunching` is not the only thing that could ever
    /// call `start()`, and a second observer would take every sheet down twice.
    func testStartingTwiceRegistersOneObserver() {
        let broadcasts = countBroadcasts()
        guardUnderTest.start()
        guardUnderTest.start()

        workspace.post(name: powerOff, object: nil)

        XCTAssertEqual(broadcasts.value, 1)
    }

    /// The guard reads the workspace centre, which is a different centre from
    /// the app's own. Posting the power-off name on the wrong one must do
    /// nothing, or the injection point is decorative.
    func testItDoesNotListenOnTheApplicationCentre() {
        let broadcasts = countBroadcasts()
        guardUnderTest.start()

        app.post(name: powerOff, object: nil)

        XCTAssertEqual(broadcasts.value, 0)
    }

    /// The real name, on the real kind of centre. This is the one assertion that
    /// pins *which* system signal is read: `NSWorkspace.willPowerOffNotification`
    /// covers restart, shut down and log out, and it arrives before the quit
    /// Apple Event that a sheet would refuse.
    func testTheShippedGuardWatchesTheWorkspacePowerOffNotification() {
        let center = NotificationCenter()
        let app = NotificationCenter()
        let shipped = PowerOffPresentationGuard(observing: center, broadcastingOn: app)
        defer { shipped.stop() }
        var broadcasts = 0
        let token = app.addObserver(
            forName: .dismissModalPresentations, object: nil, queue: nil
        ) { _ in broadcasts += 1 }
        defer { app.removeObserver(token) }

        shipped.start()
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)

        XCTAssertEqual(broadcasts, 1)
    }

    // MARK: - Helpers

    private final class Counter { var value = 0 }

    private func countBroadcasts() -> Counter {
        let counter = Counter()
        let token = app.addObserver(
            forName: .dismissModalPresentations, object: nil, queue: nil
        ) { _ in counter.value += 1 }
        addTeardownBlock { [app] in app?.removeObserver(token) }
        return counter
    }
}
