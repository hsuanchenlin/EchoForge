import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One capturable window, reduced to what choosing between windows depends on.
///
/// A value type rather than an `SCWindow` for the reason every other decision in
/// this app is separated from its framework: which window a screen query is
/// about is a rule with edge cases - the Dock, a menu, this app's own overlays,
/// a 1-pixel helper window - and none of them can be asserted against a window
/// server a test does not have. `ScreenCaptureTargetResolver` is that rule, and
/// `ScreenCaptureServiceTests` states every case of it.
struct CapturableWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String?
    let title: String?
    /// In points, as ScreenCaptureKit reports it.
    let frame: CGRect
    /// The window server layer. Ordinary application windows are 0; menus, the
    /// Dock, status items and floating panels sit above it.
    let layer: Int
    let isOnScreen: Bool

    var area: CGFloat { max(0, frame.width) * max(0, frame.height) }
}

extension CapturableWindow {
    init(_ window: SCWindow) {
        self.init(
            windowID: window.windowID,
            processIdentifier: window.owningApplication?.processID ?? -1,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName,
            title: window.title,
            frame: window.frame,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen
        )
    }
}

/// What a screen query ended up looking at.
enum ScreenCaptureTarget: Equatable, Sendable {
    /// One window of the app the user was in.
    case window(CapturableWindow)
    /// The whole screen, because no window of theirs could be used.
    case display
}

/// Which window - if any - a screen query is about.
///
/// Pure, and deliberately so: it is the half of `ScreenCaptureService` that has
/// rules rather than system calls.
enum ScreenCaptureTargetResolver {

    /// Smaller than this and a window is not what the user is looking at: apps
    /// keep 1×1 and toolbar-sized helper windows on screen, and one of those
    /// would otherwise win simply by being frontmost.
    static let minimumWindowArea: CGFloat = 120 * 120

    /// The window to capture for the app that was frontmost, or nil when there
    /// is none and the caller should fall back to the display.
    ///
    /// Three rules, and each is a bug that happened without it:
    ///
    /// - **Never this app.** Kongweh is frontmost by the time the Ask panel is
    ///   up, and a screenshot of our own HUD answers nothing. Its windows are
    ///   excluded whatever pid is asked for.
    /// - **Ordinary windows only.** Layer 0 is where documents live; the Dock, a
    ///   menu that happens to be open and every floating panel are above it.
    /// - **The largest one.** An app frequently has several on screen - an
    ///   inspector, a find bar, a document - and the document is the one the
    ///   question is about.
    static func resolve(
        windows: [CapturableWindow],
        frontmostProcessID: pid_t?,
        ownProcessID: pid_t
    ) -> CapturableWindow? {
        guard let frontmostProcessID, frontmostProcessID != ownProcessID else { return nil }
        return windows
            .filter { $0.processIdentifier == frontmostProcessID }
            .filter { $0.processIdentifier != ownProcessID }
            .filter { $0.isOnScreen && $0.layer == 0 && $0.area >= minimumWindowArea }
            .max { lhs, rhs in
                // Ties broken by window id so the choice is stable rather than
                // whatever order the window server happened to answer in.
                (lhs.area, lhs.windowID) < (rhs.area, rhs.windowID)
            }
    }
}

/// Why a screen query has no screenshot.
///
/// Every case carries the sentence the Ask panel shows: a query the user started
/// with a shortcut and is now watching cannot end in nothing happening.
enum ScreenCaptureError: LocalizedError, Equatable {
    /// Screen Recording has not been granted to this app.
    case permissionDenied
    /// Nothing on this Mac could be captured - no window and no display.
    case nothingToCapture
    /// ScreenCaptureKit refused or failed.
    case captureFailed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "Kongweh needs Screen Recording permission to answer questions about your "
                + "screen. Grant it in System Settings › Privacy & Security › Screen Recording, "
                + "then try again."
        case .nothingToCapture:
            return "There was nothing on screen to capture."
        case .captureFailed(let reason):
            return "The screenshot failed: \(reason)"
        }
    }

    var errorDescription: String? { message }
}

/// Whether this app may record the screen, behind a seam.
///
/// The two calls are one-line and untestable - they read and write the running
/// process's real TCC state, which a test can neither grant nor revoke - so they
/// are the only thing this protocol keeps out of the tests.
protocol ScreenRecordingAuthorizing: Sendable {
    func isScreenRecordingGranted() -> Bool
    /// Shows the system prompt the first time, and reports what the answer is
    /// now. Already-denied apps get no second prompt - macOS only ever asks
    /// once - so a false here means "send them to System Settings".
    @discardableResult
    func requestScreenRecordingAccess() -> Bool
}

struct SystemScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The request is remembered in `screenRecordingAccessRequested` on its way
    /// through, whichever caller makes it: macOS only ever shows its dialog
    /// once and has no API for asking whether it already did, and the Ask panel
    /// needs to tell the first refusal from every later one.
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        AppPreferences.shared.screenRecordingAccessRequested = true
        return CGRequestScreenCaptureAccess()
    }
}

/// Anything that can hand a screen query a picture of what the user is looking
/// at. Injected into the Ask panel so the panel's own rules are testable on a
/// machine with no window server.
protocol ScreenCapturing: Sendable {
    /// - Parameter processIdentifier: the app the user was in when they pressed
    ///   the shortcut, read **before** this app comes forward. `nil` - or an app
    ///   with no usable window - captures the display instead.
    func captureScreen(ofProcess processIdentifier: pid_t?) async throws -> ScreenObservation
}

/// The screenshot half of the screen-query feature: ScreenCaptureKit, and the
/// smallest amount of policy that cannot be pulled out of it.
///
/// `docs/screen-context.md` is the feature's whole story. Two things here are
/// load-bearing:
///
/// - **This app is never in the picture.** A window capture refuses our own pid,
///   and a display capture excludes our whole application from the filter, so
///   neither the Ask panel nor the capsule HUD ends up in the shot the model is
///   asked about.
/// - **The image is capped as it is taken.** `ScreenshotDownscale` sizes the
///   capture itself rather than resampling a 6000-pixel-wide screenshot
///   afterwards, which is both the faster path and the one that never holds a
///   24 MB image the model would not have used.
struct ScreenCaptureService: ScreenCapturing {
    static let shared = ScreenCaptureService()

    let authorizer: ScreenRecordingAuthorizing

    init(authorizer: ScreenRecordingAuthorizing = SystemScreenRecordingAuthorizer()) {
        self.authorizer = authorizer
    }

    func captureScreen(ofProcess processIdentifier: pid_t?) async throws -> ScreenObservation {
        guard authorizer.isScreenRecordingGranted() else { throw ScreenCaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let target = ScreenCaptureTargetResolver.resolve(
            windows: content.windows.map(CapturableWindow.init),
            frontmostProcessID: processIdentifier,
            ownProcessID: ownProcessID
        )

        if let target, let window = content.windows.first(where: { $0.windowID == target.windowID }) {
            let image = try await capture(filter: SCContentFilter(desktopIndependentWindow: window))
            return ScreenObservation(
                image: image,
                source: .window(
                    applicationName: target.applicationName, title: target.title
                )
            )
        }

        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
            throw ScreenCaptureError.nothingToCapture
        }

        // The one place this app's own windows have to be named: a display shot
        // taken while the Ask panel is up would otherwise be a picture of the
        // Ask panel.
        let ownApplications = content.applications.filter { $0.processID == ownProcessID }
        let filter = SCContentFilter(
            display: display, excludingApplications: ownApplications, exceptingWindows: []
        )
        let image = try await capture(filter: filter)
        return ScreenObservation(image: image, source: .display)
    }

    private func capture(filter: SCContentFilter) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        // Both dimensions must be set: a configuration left at its defaults
        // captures nothing usable. The size is the capped one, so the image is
        // never larger than the model will be given.
        let size = ScreenshotDownscale.fittedSize(
            for: CGSize(
                width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                height: filter.contentRect.height * CGFloat(filter.pointPixelScale)
            )
        )
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        // The pointer is where the user's hand happens to be, not part of what
        // they are asking about, and a cursor drawn over a word costs the OCR
        // that word.
        configuration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
