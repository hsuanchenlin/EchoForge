import AppKit
import Foundation

/// Opening one URL in a browser, as a seam.
///
/// A protocol because the tests must be able to prove what would have been
/// opened without a browser opening it, and because "what this app does with a
/// URL" is small enough to state completely: it hands one validated URL to
/// macOS, and that is all it can do. There is no scripting, no automation
/// permission, no page content, and no way for this seam to touch a tab that is
/// already open.
protocol BrowserOpening: Sendable {
    /// Opens `url` in a new tab. Throws when the browser is not there or macOS
    /// refused to launch it.
    func openInNewTab(_ url: URL) async throws
}

/// Why a URL did not reach the browser.
enum BrowserOpenError: LocalizedError, Equatable {
    case chromeNotInstalled
    case refusedURL
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotInstalled:
            return "Google Chrome was not found, so nothing was opened. Install Chrome, or open the video yourself."
        case .refusedURL:
            return "That link was not a YouTube video URL, so nothing was opened."
        case .launchFailed(let reason):
            return "Google Chrome could not open the video: \(reason)"
        }
    }

    /// The few words a dictation overlay has room for.
    var shortMessage: String {
        switch self {
        case .chromeNotInstalled: return "Chrome was not found"
        case .refusedURL: return "That link was refused"
        case .launchFailed: return "Chrome could not open it"
        }
    }
}

/// Opens a video in Google Chrome, in a new tab, and does nothing else.
///
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` is the whole
/// implementation, and the choice is the point. It is the ordinary macOS "open
/// this URL with this app" call - the same thing clicking a link does - so:
///
/// - **Nothing existing is touched.** Chrome decides where the URL lands, and
///   what it does with a URL handed to a running instance is open a new tab.
///   This app cannot read, close, reorder or navigate a tab, because the call it
///   makes cannot express any of those.
/// - **No automation and no scraping.** There is no AppleScript, no `osascript`,
///   no shell, no injected JavaScript and no Accessibility driving of another
///   app - so nothing here needs Automation consent, and nothing here can be
///   turned into a way to read what the user has open.
/// - **Playback is Chrome's business.** Whether the video starts on its own, and
///   whether it starts muted, is the browser's autoplay policy and the site's,
///   and nothing in this app tries to influence either.
///
/// Chrome specifically, by bundle identifier, because the command says Chrome. An
/// install without it is told so rather than being sent to whatever browser
/// happens to be the default - opening the user's video somewhere they did not
/// ask for is exactly the surprise this feature is written to avoid.
struct ChromeBrowserOpener: BrowserOpening {
    static let chromeBundleIdentifier = "com.google.Chrome"

    /// Where Chrome is, as a seam: the tests state the answer rather than
    /// depending on what is installed on the machine running them.
    private let locateChrome: @Sendable () -> URL?
    private let open: @Sendable (URL, URL) async throws -> Void

    init(
        locateChrome: @escaping @Sendable () -> URL? = {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: ChromeBrowserOpener.chromeBundleIdentifier
            )
        },
        open: @escaping @Sendable (URL, URL) async throws -> Void = { url, application in
            let configuration = NSWorkspace.OpenConfiguration()
            // The user just asked for this video, so the browser comes forward.
            configuration.activates = true
            // A second Chrome process would be a second browser, with its own
            // windows and none of the user's tabs. The running one is the one
            // they meant.
            configuration.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: application, configuration: configuration
            )
        }
    ) {
        self.locateChrome = locateChrome
        self.open = open
    }

    func openInNewTab(_ url: URL) async throws {
        // Checked again here, after the feed check, because this is the last
        // place before the URL leaves the app and this type must be safe on its
        // own terms rather than because of who called it.
        guard YouTubeVideoURL.validate(url.absoluteString) != nil else {
            throw BrowserOpenError.refusedURL
        }
        guard let chrome = locateChrome() else { throw BrowserOpenError.chromeNotInstalled }
        do {
            try await open(url, chrome)
        } catch {
            throw BrowserOpenError.launchFailed(error.localizedDescription)
        }
    }
}
