import AppKit
import Combine
import XCTest

@testable import OpenSuperWhisper

/// The required-permissions screen has to disappear on its own once the user
/// grants Accessibility in System Settings and comes back - without a relaunch
/// and without an unrelated click.
///
/// Platform limitation: the real statuses cannot be driven from a test. TCC
/// grants belong to the running process, so a test can neither call
/// `AXIsProcessTrusted()` into returning true nor revoke a grant it already has,
/// and the notification the system posts on a trust change
/// (`com.apple.accessibility.api`) comes from another process over
/// `DistributedNotificationCenter`, which a unit test cannot post credibly
/// either. So these tests drive `PermissionsManager` through its
/// `PermissionStatusReading` seam and through the in-process half of its refresh
/// triggers - `NSApplication.didBecomeActiveNotification`, which is what
/// "returned from System Settings" looks like. What stays uncovered is only
/// `SystemPermissionStatusReader`'s three one-line system calls and the delivery
/// of the distributed notification itself.
final class PermissionsManagerRefreshTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - The reported bug

    func testAccessibilityGrantedInSystemSettingsClearsThePermissionScreenOnReturn() {
        let reader = FakePermissionStatusReader(microphone: true, accessibility: false)
        let manager = PermissionsManager(statusReader: reader)

        waitUntil(manager, "the first check completes") { manager.hasCompletedInitialCheck }
        XCTAssertTrue(manager.isMissingRequiredPermission, "the permission screen has to be up first")

        // The user grants Accessibility in System Settings, then switches back.
        reader.accessibility = true
        NSApplication.shared.postDidBecomeActiveForTest()

        waitUntil(manager, "Accessibility is seen as granted") { manager.isAccessibilityPermissionGranted }
        XCTAssertFalse(
            manager.isMissingRequiredPermission,
            "the root view has to leave the permission screen once both required permissions are granted"
        )
    }

    /// The grant is not always visible to TCC the instant the app is reactivated,
    /// so a refresh re-reads a few more times instead of giving up on one answer.
    func testRefreshCatchesAGrantThatBecomesVisibleShortlyAfterTheRefresh() {
        let reader = FakePermissionStatusReader(microphone: true, accessibility: false)
        let manager = PermissionsManager(statusReader: reader)

        waitUntil(manager, "the first check completes") { manager.hasCompletedInitialCheck }

        // Nothing further triggers a refresh: only the catch-up re-reads can see this.
        manager.refreshAfterPossibleSystemSettingsChange()
        reader.accessibility = true

        waitUntil(manager, "the catch-up re-read sees the grant") { manager.isAccessibilityPermissionGranted }
        XCTAssertFalse(manager.isMissingRequiredPermission)
    }

    func testRevokedAccessibilityBringsThePermissionScreenBack() {
        let reader = FakePermissionStatusReader(microphone: true, accessibility: true)
        let manager = PermissionsManager(statusReader: reader)

        waitUntil(manager, "the first check completes") { manager.hasCompletedInitialCheck }
        XCTAssertFalse(manager.isMissingRequiredPermission)

        reader.accessibility = false
        NSApplication.shared.postDidBecomeActiveForTest()

        waitUntil(manager, "the revocation is seen") { manager.isMissingRequiredPermission }
    }

    // MARK: - The other permissions keep their behaviour

    func testMissingMicrophoneAlsoHoldsThePermissionScreen() {
        let reader = FakePermissionStatusReader(microphone: false, accessibility: true)
        let manager = PermissionsManager(statusReader: reader)

        waitUntil(manager, "the first check completes") { manager.hasCompletedInitialCheck }
        XCTAssertTrue(manager.isMissingRequiredPermission)

        reader.microphone = true
        NSApplication.shared.postDidBecomeActiveForTest()

        waitUntil(manager, "the microphone grant is seen") { !manager.isMissingRequiredPermission }
    }

    /// Input Monitoring is only needed by the modifier-key and mouse-button
    /// shortcut modes, so it must never hold the required-permissions screen up.
    func testMissingInputMonitoringDoesNotHoldThePermissionScreen() {
        let reader = FakePermissionStatusReader(microphone: true, accessibility: true, inputMonitoring: false)
        let manager = PermissionsManager(statusReader: reader)

        waitUntil(manager, "the first check completes") { manager.hasCompletedInitialCheck }

        XCTAssertFalse(manager.isInputMonitoringPermissionGranted)
        XCTAssertFalse(
            manager.isMissingRequiredPermission,
            "Input Monitoring is conditional on the shortcut choice and must not gate the app"
        )
    }

    /// The screen must not flash before anything is actually known: the first
    /// check is asynchronous, and this assertion runs while the main queue is
    /// still occupied, so no result can have been published yet.
    func testNothingIsReportedMissingBeforeTheFirstCheckCompletes() {
        let reader = FakePermissionStatusReader(microphone: false, accessibility: false)
        let manager = PermissionsManager(statusReader: reader)

        XCTAssertFalse(manager.hasCompletedInitialCheck)
        XCTAssertFalse(manager.isMissingRequiredPermission)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ manager: PermissionsManager,
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) {
        guard !condition() else { return }

        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if condition() { reached.fulfill() }
            }
            .store(in: &cancellables)

        let result = XCTWaiter().wait(for: [reached], timeout: timeout)
        XCTAssertEqual(result, .completed, "timed out waiting until \(description)", file: file, line: line)
    }
}

private extension NSApplication {
    /// The app becoming active is delivered as an ordinary notification, so the
    /// observer under test can be exercised without actually activating the app -
    /// which a test run must not do.
    func postDidBecomeActiveForTest() {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: self)
    }
}

/// Statuses the test owns. Read on `PermissionsManager`'s background check queue
/// and written from the test's main thread, hence the lock.
private final class FakePermissionStatusReader: PermissionStatusReading {
    private let lock = NSLock()
    private var _microphone: Bool
    private var _accessibility: Bool
    private var _inputMonitoring: Bool

    init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool = true) {
        self._microphone = microphone
        self._accessibility = accessibility
        self._inputMonitoring = inputMonitoring
    }

    var microphone: Bool {
        get { lock.withLock { _microphone } }
        set { lock.withLock { _microphone = newValue } }
    }

    var accessibility: Bool {
        get { lock.withLock { _accessibility } }
        set { lock.withLock { _accessibility = newValue } }
    }

    var inputMonitoring: Bool {
        get { lock.withLock { _inputMonitoring } }
        set { lock.withLock { _inputMonitoring = newValue } }
    }

    func isMicrophoneGranted() -> Bool { microphone }
    func isAccessibilityGranted() -> Bool { accessibility }
    func isInputMonitoringGranted() -> Bool { inputMonitoring }
}
