import AppKit
import CoreGraphics
import XCTest

@testable import OpenSuperWhisper

/// Which window a screen query is about, and what happens when it cannot have
/// one.
///
/// Platform limitation: the capture itself cannot run here. ScreenCaptureKit
/// needs a window server and a Screen Recording grant that belongs to the
/// running process, and a test can neither grant nor revoke it - the same
/// constraint `PermissionsManagerRefreshTests` documents for TCC. So everything
/// that is a *rule* lives behind `ScreenCaptureTargetResolver` and
/// `ScreenRecordingAuthorizing`, and what stays uncovered is only
/// `SystemScreenRecordingAuthorizer`'s two one-line calls and the
/// `SCScreenshotManager` round-trip.
final class ScreenCaptureServiceTests: XCTestCase {

    private let ownProcessID: pid_t = 501
    private let frontmostProcessID: pid_t = 900

    // MARK: - Choosing the window

    private func window(
        id: CGWindowID,
        pid: pid_t,
        size: CGSize = CGSize(width: 1200, height: 800),
        layer: Int = 0,
        isOnScreen: Bool = true,
        title: String? = "Document",
        applicationName: String? = "Pages"
    ) -> CapturableWindow {
        CapturableWindow(
            windowID: id,
            processIdentifier: pid,
            bundleIdentifier: "com.example.\(pid)",
            applicationName: applicationName,
            title: title,
            frame: CGRect(origin: .zero, size: size),
            layer: layer,
            isOnScreen: isOnScreen
        )
    }

    private func resolve(_ windows: [CapturableWindow], frontmost: pid_t? = 900) -> CapturableWindow? {
        ScreenCaptureTargetResolver.resolve(
            windows: windows, frontmostProcessID: frontmost, ownProcessID: ownProcessID
        )
    }

    /// An app usually has several windows on screen - an inspector, a find bar,
    /// the document - and the document is the one the question is about.
    func testTheLargestWindowOfTheFrontmostAppIsChosen() {
        let inspector = window(id: 1, pid: frontmostProcessID, size: CGSize(width: 300, height: 700))
        let document = window(id: 2, pid: frontmostProcessID, size: CGSize(width: 1400, height: 900))

        XCTAssertEqual(resolve([inspector, document]), document)
        XCTAssertEqual(resolve([document, inspector]), document)
    }

    func testWindowsOfEveryOtherApplicationAreIgnored() {
        let otherApp = window(id: 1, pid: 42, size: CGSize(width: 2000, height: 1400))
        let theirs = window(id: 2, pid: frontmostProcessID)

        XCTAssertEqual(resolve([otherApp, theirs]), theirs)
        XCTAssertNil(resolve([otherApp]))
    }

    /// EchoForge is frontmost by the time its own panel is up, and a screenshot
    /// of our own HUD answers nothing.
    func testThisAppIsNeverCaptured() {
        let ours = window(id: 1, pid: ownProcessID, size: CGSize(width: 1600, height: 1000))

        XCTAssertNil(resolve([ours], frontmost: ownProcessID))
        XCTAssertNil(resolve([ours]))
    }

    func testAWindowOffScreenOrAboveTheDocumentLayerIsNotTheTarget() {
        let hidden = window(id: 1, pid: frontmostProcessID, isOnScreen: false)
        let menu = window(id: 2, pid: frontmostProcessID, layer: 25)

        XCTAssertNil(resolve([hidden, menu]))
    }

    /// Apps keep 1×1 and toolbar-sized helper windows on screen; one of those
    /// would otherwise win simply by belonging to the frontmost app.
    func testAWindowTooSmallToBeWhatTheUserIsLookingAtIsSkipped() {
        let helper = window(id: 1, pid: frontmostProcessID, size: CGSize(width: 1, height: 1))
        XCTAssertNil(resolve([helper]))

        let justUnder = sqrt(ScreenCaptureTargetResolver.minimumWindowArea) - 1
        XCTAssertNil(resolve([window(id: 2, pid: frontmostProcessID,
                                     size: CGSize(width: justUnder, height: justUnder))]))

        let justOver = sqrt(ScreenCaptureTargetResolver.minimumWindowArea) + 1
        XCTAssertNotNil(resolve([window(id: 3, pid: frontmostProcessID,
                                        size: CGSize(width: justOver, height: justOver))]))
    }

    /// Nothing to capture is an answer, not a crash: the caller falls back to
    /// the display.
    func testNoFrontmostApplicationResolvesToNoWindow() {
        XCTAssertNil(resolve([window(id: 1, pid: frontmostProcessID)], frontmost: nil))
        XCTAssertNil(resolve([]))
    }

    /// Two windows of the same size must not resolve differently run to run:
    /// the window server does not promise an order.
    func testAnEqualSizedPairResolvesTheSameWayEveryTime() {
        let first = window(id: 7, pid: frontmostProcessID)
        let second = window(id: 9, pid: frontmostProcessID)

        XCTAssertEqual(resolve([first, second]), resolve([second, first]))
    }

    // MARK: - Permission

    /// The check happens before anything else, so a Mac that has never granted
    /// Screen Recording never reaches ScreenCaptureKit at all.
    func testCapturingWithoutPermissionFailsBeforeItTouchesTheSystem() async {
        let service = ScreenCaptureService(authorizer: FixedAuthorizer(granted: false))

        do {
            _ = try await service.captureScreen(ofProcess: frontmostProcessID)
            XCTFail("a capture without permission has to fail")
        } catch let error as ScreenCaptureError {
            XCTAssertEqual(error, .permissionDenied)
            XCTAssertTrue(error.message.contains("Screen Recording"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Every failure carries a sentence, because a query the user started with a
    /// shortcut and is watching cannot end in nothing happening.
    func testEveryCaptureFailureCarriesSomethingToSay() {
        for error in [ScreenCaptureError.permissionDenied, .nothingToCapture, .captureFailed("boom")] {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
            XCTAssertEqual(error.errorDescription, error.message, "\(error)")
        }
        XCTAssertTrue(ScreenCaptureError.captureFailed("boom").message.contains("boom"))
    }

    /// Screen Recording is conditional on one shortcut and must never hold the
    /// app up, the way Input Monitoring must not - see
    /// `PermissionsManager.isMissingRequiredPermission`.
    func testScreenRecordingIsReadOnDemandAndNeverGatesTheApp() {
        let manager = PermissionsManager(
            statusReader: GrantingStatusReader(),
            screenRecordingAuthorizer: FixedAuthorizer(granted: false)
        )

        XCTAssertFalse(manager.isScreenRecordingGranted)
        XCTAssertFalse(manager.checkScreenRecordingPermission())
        XCTAssertFalse(manager.isScreenRecordingPermissionGranted)

        let checked = expectation(
            for: NSPredicate { _, _ in manager.hasCompletedInitialCheck },
            evaluatedWith: manager
        )
        wait(for: [checked], timeout: 10)
        XCTAssertFalse(
            manager.isMissingRequiredPermission,
            "a missing Screen Recording grant must never hold the app up"
        )
    }

    /// The granted path is the only half of the request that a test may run: the
    /// refused half opens System Settings, which a test run must not do.
    func testRequestingAnAlreadyGrantedPermissionAsksForNothing() {
        let authorizer = FixedAuthorizer(granted: true)
        let manager = PermissionsManager(
            statusReader: GrantingStatusReader(), screenRecordingAuthorizer: authorizer
        )

        XCTAssertTrue(manager.requestScreenRecordingPermissionOrOpenSystemPreferences())
        XCTAssertTrue(manager.isScreenRecordingPermissionGranted)
        XCTAssertEqual(authorizer.requestCount, 0, "an app that already has the grant must not prompt")
    }

    // MARK: - What the panel says it looked at

    func testTheSourceNamesWhatWasCaptured() {
        XCTAssertEqual(
            ScreenCaptureSource.window(applicationName: "Safari", title: "Invoice").label,
            "Safari - Invoice"
        )
        XCTAssertEqual(
            ScreenCaptureSource.window(applicationName: "Safari", title: "  ").label, "Safari"
        )
        XCTAssertEqual(
            ScreenCaptureSource.window(applicationName: nil, title: "Invoice").label, "Invoice"
        )
        XCTAssertEqual(
            ScreenCaptureSource.window(applicationName: nil, title: nil).label, "Window"
        )
        XCTAssertEqual(ScreenCaptureSource.display.label, "Screen")
    }
}

/// A grant this test owns.
private final class FixedAuthorizer: ScreenRecordingAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let granted: Bool
    private var requests = 0

    init(granted: Bool) {
        self.granted = granted
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func isScreenRecordingGranted() -> Bool { granted }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        lock.withLock { requests += 1 }
        return granted
    }
}

/// The required permissions, granted, so a screen-recording assertion is about
/// screen recording and nothing else.
private struct GrantingStatusReader: PermissionStatusReading {
    func isMicrophoneGranted() -> Bool { true }
    func isAccessibilityGranted() -> Bool { true }
    func isInputMonitoringGranted() -> Bool { true }
}
