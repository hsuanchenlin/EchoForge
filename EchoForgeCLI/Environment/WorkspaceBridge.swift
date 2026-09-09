import AppKit
import Foundation

/// The three things this tool asks AppKit for: which copies of an app are
/// running, open one, and hand it files.
///
/// Kept in one small file so `CLISeamTests` can hold a simple rule - `AppKit`
/// appears here and nowhere else in `EchoForgeCLI/`. A command that reached
/// `NSWorkspace.shared` directly would be a command no test could run without
/// launching something on the developer's own desktop.
enum WorkspaceBridge {

    static func runningCopies(ofBundleIdentifier identifier: String) -> [RunningCopy] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .map {
                RunningCopy(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL,
                    launchDate: $0.launchDate)
            }
    }

    /// Opens a bundle the way the Finder does, and waits for the answer.
    ///
    /// `NSWorkspace.openApplication` is the macOS-native launch and it is
    /// asynchronous, so a tool that returned before it answered would exit
    /// before macOS had said whether the app started - and a launch failure
    /// would look exactly like a success. The wait is bounded, because a
    /// terminal that never comes back is its own kind of failure.
    @discardableResult
    static func open(_ url: URL, timeout: TimeInterval = 30) throws -> RunningCopy? {
        let configuration = NSWorkspace.OpenConfiguration()
        // Deliberately *not* `createsNewApplicationInstance`: a second copy of
        // a dictation app would fight the first one for the microphone and the
        // shortcuts. `StartCommand` has already refused if one is running.
        configuration.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        var started: RunningCopy?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            failure = error
            started = application.map {
                RunningCopy(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL,
                    launchDate: $0.launchDate)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CLIError(
                "macOS did not answer within \(Int(timeout))s when asked to open \(url.path).")
        }
        if let failure {
            throw CLIError("macOS refused to open \(url.path). \(failure.localizedDescription)")
        }
        return started
    }

    /// Hands files to an application the way the Finder's "Open With" does.
    ///
    /// `NSWorkspace.open(_:withApplicationAt:configuration:)` starts the app if
    /// it is not running and delivers the URLs to a copy that already is, which
    /// is exactly the behaviour `transcribe` wants: one Kongweh, one engine, one
    /// database. `activates` is **false** - a script that transcribes a folder
    /// should not pull the app in front of whatever the user is doing - and
    /// `createsNewApplicationInstance` is left alone for the reason `open(_:)`
    /// leaves it alone.
    @discardableResult
    static func open(
        files: [URL], withApplicationAt application: URL, timeout: TimeInterval = 30
    ) throws -> RunningCopy? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        var opened: RunningCopy?
        NSWorkspace.shared.open(
            files, withApplicationAt: application, configuration: configuration
        ) { runningApplication, error in
            failure = error
            opened = runningApplication.map {
                RunningCopy(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL,
                    launchDate: $0.launchDate)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CLIError(
                "macOS did not answer within \(Int(timeout))s when asked to open "
                    + "\(files.count) file(s) with \(application.path).")
        }
        if let failure {
            throw CLIError(
                "macOS refused to open the file with \(application.path). "
                    + failure.localizedDescription)
        }
        return opened
    }
}
