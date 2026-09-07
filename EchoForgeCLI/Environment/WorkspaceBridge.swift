import AppKit
import Foundation

/// The two things this tool asks AppKit for: which copies of an app are running,
/// and open one.
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
}
