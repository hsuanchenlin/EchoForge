import AVFoundation
import AppKit
import Foundation
import IOKit.hid

enum Permission {
    case microphone
    case accessibility
    case inputMonitoring
    /// Needed only to answer a question about the screen (⌥S). Like Input
    /// Monitoring it is conditional: it is read when that shortcut is used and
    /// at no other time, and it must never gate dictation.
    case screenRecording
}

/// The three TCC facts the permission UI reflects.
///
/// This exists as a protocol so the refresh and screen-transition logic can be
/// tested: `AXIsProcessTrusted()`, `AVCaptureDevice.authorizationStatus(for:)`
/// and `IOHIDCheckAccess` read the running process's real grants, and a test can
/// neither grant nor revoke them. Behind this seam only the three one-line
/// system calls in `SystemPermissionStatusReader` stay untested.
protocol PermissionStatusReading {
    func isMicrophoneGranted() -> Bool
    func isAccessibilityGranted() -> Bool
    func isInputMonitoringGranted() -> Bool
}

struct SystemPermissionStatusReader: PermissionStatusReading {
    func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    @Published var isInputMonitoringPermissionGranted = false
    /// Whether this app may record the screen, as of the last time anything
    /// asked.
    ///
    /// Deliberately not part of the polled check below. Screen Recording is
    /// needed by one shortcut (⌥S, `docs/screen-context.md`), reading it is a
    /// TCC round-trip like the others, and polling for a permission almost
    /// nobody's dictation depends on would cost every user main-thread time for
    /// a feature they may never press. It is read when that shortcut runs and
    /// when the Settings pane showing it appears.
    @Published private(set) var isScreenRecordingPermissionGranted = false
    /// False until the first async TCC check completes; the UI must not show
    /// "permission missing" warnings while the actual status is still unknown,
    /// otherwise they flash on every settings screen open.
    @Published private(set) var hasCompletedInitialCheck = false

    /// Whether the root view has to show the required-permissions screen instead
    /// of the app.
    ///
    /// Microphone and Accessibility are the two the app cannot run without.
    /// Input Monitoring is deliberately not part of it: it is only needed by the
    /// modifier-key and mouse-button shortcut modes, so it is requested from
    /// Settings by whoever picks one of those, and must never block everyone else.
    var isMissingRequiredPermission: Bool {
        hasCompletedInitialCheck
            && !(isMicrophonePermissionGranted && isAccessibilityPermissionGranted)
    }

    // TCC status queries (AVCaptureDevice.authorizationStatus, IOHIDCheckAccess)
    // are synchronous XPC round-trips to tccd taking 40-100 ms - they must
    // never run on the main thread (traces showed them dropping animation
    // frames every second while the polling timer was active).
    private let checkQueue = DispatchQueue(label: "com.opensuperwhisper.permissions", qos: .utility)
    private let statusReader: PermissionStatusReading
    private let screenRecordingAuthorizer: ScreenRecordingAuthorizing
    private var isCheckInFlight = false
    /// A refresh that arrived while a check was in flight. Without it a grant
    /// could be dropped: the in-flight check may have read tccd just before the
    /// user flipped the switch.
    private var hasPendingCheck = false

    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var catchUpWorkItems: [DispatchWorkItem] = []
    /// Polling is paused for the whole indicator session (prepare → hidden):
    /// every millisecond of the main runloop there belongs to the animation.
    private var isIndicatorSessionActive = false

    /// The system posts this when an app is added to or removed from the
    /// Accessibility trust list, to every process, whether or not it is frontmost.
    private static let accessibilityTrustDidChangeNotification = Notification.Name("com.apple.accessibility.api")

    /// `AXIsProcessTrusted()` can still report the old value for a moment after
    /// the trust list changes, so a refresh re-reads it a few times rather than
    /// once. Bounded and sparse on purpose: this is a settle-in, not a poll.
    private static let refreshCatchUpDelays: [TimeInterval] = [0.3, 1.0, 2.5]

    init(
        statusReader: PermissionStatusReading = SystemPermissionStatusReader(),
        screenRecordingAuthorizer: ScreenRecordingAuthorizing = SystemScreenRecordingAuthorizer()
    ) {
        self.statusReader = statusReader
        self.screenRecordingAuthorizer = screenRecordingAuthorizer

        checkAllPermissions()
        setupSystemSettingsObservers()
        setupWindowObservers()
    }

    deinit {
        stopPermissionChecking()
        cancelCatchUp()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// Accessibility is the one permission granted entirely outside this app: the
    /// user flips a switch in System Settings, and nothing calls back the way
    /// `AVCaptureDevice.requestAccess` and `IOHIDRequestAccess` call back for
    /// microphone and Input Monitoring. Two independent triggers stand in for
    /// that missing callback:
    ///
    /// 1. `com.apple.accessibility.api`, which arrives while the app is still in
    ///    the background, at the moment of the grant.
    /// 2. The app becoming active again, which is what "returned from System
    ///    Settings" actually looks like. This is the backstop, and unlike the
    ///    idle poll below it does not depend on any window becoming key - an app
    ///    reactivated into a closed, hidden or menu-bar-only state gets no
    ///    `didBecomeKey`, and used to sit on the permission screen forever.
    ///
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` used to be
    /// observed here instead. It is about display accommodations (Reduce Motion,
    /// Increase Contrast) and is never posted for a trust change, so it refreshed
    /// nothing.
    private func setupSystemSettingsObservers() {
        let trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.accessibilityTrustDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterPossibleSystemSettingsChange()
        }
        distributedObservers = [trustObserver]

        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterPossibleSystemSettingsChange()
        }
        windowObservers.append(activationObserver)
    }

    /// Re-reads every permission now, then again a few times, because the grant
    /// this is reacting to may not be visible to TCC yet.
    func refreshAfterPossibleSystemSettingsChange() {
        cancelCatchUp()
        checkAllPermissions()

        for delay in Self.refreshCatchUpDelays {
            let item = DispatchWorkItem { [weak self] in
                self?.checkAllPermissions()
            }
            catchUpWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func cancelCatchUp() {
        for item in catchUpWorkItems {
            item.cancel()
        }
        catchUpWorkItems.removeAll()
    }

    private func setupWindowObservers() {
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPermissionChecking()
        }

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }

        let hideObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }

        let indicatorShowObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowWillShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = true
        }

        let indicatorHideObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowDidHide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = false
        }

        windowObservers.append(contentsOf: [showObserver, closeObserver, hideObserver,
                                            indicatorShowObserver, indicatorHideObserver])

        if let window = NSApplication.shared.mainWindow, window.isKeyWindow {
            startPermissionChecking()
        }
    }

    private func startPermissionChecking() {
        guard permissionCheckTimer == nil else { return }
        // A grant can land while the window is not key, so the window becoming
        // key is itself a reason to re-read rather than to wait out the interval.
        checkAllPermissions()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isIndicatorSessionActive else { return }
            self.checkAllPermissions()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    private func checkAllPermissions() {
        guard !isCheckInFlight else {
            hasPendingCheck = true
            return
        }
        isCheckInFlight = true

        let reader = statusReader
        checkQueue.async { [weak self] in
            let microphone = reader.isMicrophoneGranted()
            let accessibility = reader.isAccessibilityGranted()
            let inputMonitoring = reader.isInputMonitoringGranted()

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckInFlight = false
                self.isMicrophonePermissionGranted = microphone
                self.isAccessibilityPermissionGranted = accessibility
                self.isInputMonitoringPermissionGranted = inputMonitoring
                self.hasCompletedInitialCheck = true

                if self.hasPendingCheck {
                    self.hasPendingCheck = false
                    self.checkAllPermissions()
                }
            }
        }
    }

    func checkMicrophonePermission() {
        let reader = statusReader
        checkQueue.async { [weak self] in
            let granted = reader.isMicrophoneGranted()
            DispatchQueue.main.async {
                self?.isMicrophonePermissionGranted = granted
            }
        }
    }

    func checkAccessibilityPermission() {
        let reader = statusReader
        checkQueue.async { [weak self] in
            let granted = reader.isAccessibilityGranted()
            DispatchQueue.main.async {
                self?.isAccessibilityPermissionGranted = granted
            }
        }
    }

    func checkInputMonitoringPermission() {
        let reader = statusReader
        checkQueue.async { [weak self] in
            let granted = reader.isInputMonitoringGranted()
            DispatchQueue.main.async {
                self?.isInputMonitoringPermissionGranted = granted
            }
        }
    }

    /// Whether the screen can be captured right now.
    ///
    /// `CGPreflightScreenCaptureAccess()` behind the injectable seam, read on
    /// demand: a screen query asks this before it records anything, and nothing
    /// else in the app asks at all.
    var isScreenRecordingGranted: Bool {
        screenRecordingAuthorizer.isScreenRecordingGranted()
    }

    @discardableResult
    func checkScreenRecordingPermission() -> Bool {
        let granted = isScreenRecordingGranted
        isScreenRecordingPermissionGranted = granted
        return granted
    }

    /// Shows the system Screen Recording prompt if it has not been decided yet,
    /// otherwise opens System Settings so the user can grant it manually.
    ///
    /// The same shape as the Input Monitoring request above, and for the same
    /// reason: macOS asks once, so an app that has already been refused has
    /// nothing left to prompt with.
    @discardableResult
    func requestScreenRecordingPermissionOrOpenSystemPreferences() -> Bool {
        if screenRecordingAuthorizer.isScreenRecordingGranted() {
            isScreenRecordingPermissionGranted = true
            return true
        }
        let granted = screenRecordingAuthorizer.requestScreenRecordingAccess()
        isScreenRecordingPermissionGranted = granted
        if !granted {
            openSystemPreferences(for: .screenRecording)
        }
        return granted
    }

    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        if statusReader.isAccessibilityGranted() {
            isAccessibilityPermissionGranted = true
        } else {
            openSystemPreferences(for: .accessibility)
        }
    }

    /// Shows the system Input Monitoring prompt if it hasn't been decided yet,
    /// otherwise opens System Settings so the user can grant it manually.
    func requestInputMonitoringPermissionOrOpenSystemPreferences() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            isInputMonitoringPermissionGranted = true
        case kIOHIDAccessTypeUnknown:
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            DispatchQueue.main.async { [weak self] in
                self?.isInputMonitoringPermissionGranted = granted
            }
        default:
            openSystemPreferences(for: .inputMonitoring)
        }
    }

    func requestMicrophonePermissionOrOpenSystemPreferences() {

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        case .authorized:
            self.isMicrophonePermissionGranted = true
        default:
            openSystemPreferences(for: .microphone)
        }
    }

    func openSystemPreferences(for permission: Permission) {
        Self.openSystemSettings(for: permission)
    }

    /// The same trip to System Settings, reachable without a manager.
    ///
    /// The Ask panel needs it: a screen query is the one place a permission is
    /// asked for outside the permission UI, and instantiating a
    /// `PermissionsManager` there would start its polling timer and its window
    /// observers for a single URL.
    static func openSystemSettings(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
