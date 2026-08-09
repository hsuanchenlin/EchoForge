import Foundation
import AppKit

/// Why a downloaded build was refused.
///
/// Every case here is a reason not to run something that arrived over the
/// network, so each one ends the install rather than degrading it. There is
/// deliberately no "install anyway".
enum UpdateInstallError: LocalizedError, Equatable {
    case downloadFailed(String)
    case unexpectedSize(expected: Int, received: Int)
    case diskImageCouldNotBeOpened(String)
    case noApplicationInDiskImage
    case wrongBundleIdentifier(found: String)
    case wrongVersion(expected: String, found: String)
    case signatureRejected(String)
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "The update could not be downloaded. \(detail)"
        case .unexpectedSize(let expected, let received):
            return "The download was \(received) bytes but the release says \(expected). It was discarded."
        case .diskImageCouldNotBeOpened(let detail):
            return "The downloaded disk image could not be opened. \(detail)"
        case .noApplicationInDiskImage:
            return "The downloaded disk image does not contain EchoForge.app."
        case .wrongBundleIdentifier(let found):
            return "The downloaded app identifies itself as \(found), not EchoForge. It was discarded."
        case .wrongVersion(let expected, let found):
            return "The downloaded app is version \(found), not the \(expected) that was offered. It was discarded."
        case .signatureRejected(let detail):
            return "The downloaded app failed signature verification and was discarded. \(detail)"
        case .replacementFailed(let detail):
            return "EchoForge could not be replaced. \(detail)"
        }
    }
}

/// What an update is doing, as one value reported out of `downloadAndVerify`.
///
/// Downloading and verifying are separate cases because from outside they look
/// identical - the app is busy with an update - and a pane still showing a
/// download bar while `hdiutil` and `codesign` work through a 222 MB image is
/// indistinguishable from the stall this watchdog exists to catch.
enum UpdateProgress: Equatable, Sendable {
    case downloading(fraction: Double)
    case verifying
}

/// How a download is carried, and how long it is allowed to deliver nothing
/// before it is treated as dead.
///
/// `URLSession.shared` is deliberately not used. Its
/// `timeoutIntervalForResource` is seven days, and neither of `URLSession`'s
/// timeouts describes the failure this type is about: a connection that was
/// established, answered nothing, and never reported an error. On a Mac moving
/// between networks mid-request that is not exotic - it is what wedged an
/// update at "Downloading - 0%" indefinitely, with no bytes, no error and no way
/// out of the pane.
///
/// The watchdog therefore measures **silence, not throughput**. A rate floor
/// would be wrong: the asset is tens of megabytes, a slow link is a normal way
/// to take an update, and a transfer that is merely slow must complete. Only a
/// transfer that has delivered nothing at all for `stallInterval` is refused.
struct UpdateDownloadSettings {
    /// How long the transfer may say nothing. Long enough that no live
    /// connection reaches it - bytes arrive continuously at any rate - and short
    /// enough that a user is told rather than left watching 0%.
    static let defaultStallInterval: TimeInterval = 30

    /// A ceiling on the whole transfer, under the watchdog rather than instead
    /// of it: the watchdog is what actually catches a stall, and this is the
    /// backstop for anything that keeps trickling bytes forever.
    static let resourceTimeout: TimeInterval = 30 * 60

    /// Per-request timeout. `URLSession` resets this on every byte received, so
    /// it only ever fires before the response arrives.
    static let requestTimeout: TimeInterval = 60

    /// A configuration rather than a session, because each download has to own
    /// its session: progress is only ever delivered to a session's *own*
    /// delegate (see `UpdateDownload`), and that delegate is fixed when the
    /// session is created.
    ///
    /// Ephemeral because caching a disk image this size, on the way to
    /// installing it once, has no purpose.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    let configuration: URLSessionConfiguration
    let stallInterval: TimeInterval

    /// `stallInterval` is injected so a test can prove the watchdog fires
    /// without waiting out the shipped interval.
    init(configuration: URLSessionConfiguration = UpdateDownloadSettings.makeConfiguration(),
         stallInterval: TimeInterval = UpdateDownloadSettings.defaultStallInterval) {
        self.configuration = configuration
        self.stallInterval = stallInterval
    }
}

/// The last moment a download delivered anything.
///
/// Monotonic (`DispatchTime`) rather than `Date`, so a clock adjustment cannot
/// move the watchdog; lock-protected because the delegate writes it on
/// `URLSession`'s queue while the watchdog reads it from its own task.
final class DownloadActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = DispatchTime.now()

    func recordActivity() {
        lock.lock()
        lastActivity = DispatchTime.now()
        lock.unlock()
    }

    /// Seconds of silence. Starts counting from when the clock was made, which
    /// is when the download started: a request that is never answered at all is
    /// the stall that was reported from the field, and it has no first byte to
    /// measure from.
    var secondsSinceActivity: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastActivity.uptimeNanoseconds
        return TimeInterval(elapsed) / 1_000_000_000
    }
}

/// What has to be true of a downloaded app bundle before it is allowed to
/// replace the running one.
///
/// Separated from the file and process work so the rules can be asserted
/// directly - they are the part that must not quietly weaken.
///
/// The signature check is `codesign --verify --deep --strict`. On these builds
/// that is an *ad-hoc* signature, not a Developer ID one, because this fork has
/// no Developer ID certificate (`CLAUDE.md`, `docs/install.md`). So the check
/// proves the bundle is internally consistent and unmodified since it was
/// signed; it does not prove who signed it. What carries that weight instead is
/// `UpdateManifest`, which will only ever hand this code a URL on GitHub's
/// release hosts under this repository. Both halves are needed, and the About
/// pane says so rather than implying a notarized update path that does not
/// exist.
struct DownloadedBuildRequirements: Equatable {
    let expectedBundleIdentifier: String
    let expectedVersion: String

    static func forOffered(_ release: PublishedRelease,
                           bundleIdentifier: String = AppBuildIdentity.current().bundleIdentifier)
        -> DownloadedBuildRequirements {
        DownloadedBuildRequirements(
            expectedBundleIdentifier: bundleIdentifier,
            expectedVersion: release.version.description
        )
    }

    /// Checks the identity a downloaded bundle claims. The signature is checked
    /// separately, because it needs a process and this does not.
    func validateIdentity(bundleIdentifier: String?, version: String?) -> UpdateInstallError? {
        guard let bundleIdentifier, bundleIdentifier == expectedBundleIdentifier else {
            return .wrongBundleIdentifier(found: bundleIdentifier ?? "nothing")
        }
        guard let version, version == expectedVersion else {
            return .wrongVersion(expected: expectedVersion, found: version ?? "nothing")
        }
        return nil
    }
}

/// Runs a command and reports whether it succeeded. A seam, so the install steps
/// can be driven without mounting disk images in a test.
protocol CommandRunning: Sendable {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String)

    /// Starts a command and returns without waiting for it. Its own method
    /// because the swap script deliberately outlives this process: waiting for
    /// it would deadlock, since the first thing it does is wait for this process
    /// to exit.
    func launchDetached(_ executable: String, _ arguments: [String]) throws
}

struct SystemCommandRunner: CommandRunning {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func launchDetached(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// Downloads a release, checks it, and replaces the running app with it.
///
/// The replacement is the part macOS makes awkward: a running application cannot
/// reliably swap its own bundle out from under itself. The documented-safe
/// sequence this uses, and the reason for each step:
///
/// 1. Download to a temporary directory with `URLSession`. Downloading this way
///    rather than through LaunchServices means no quarantine attribute is
///    applied, so the replacement does not hand the user a Gatekeeper prompt for
///    a build they already trusted.
/// 2. Mount the image read-only with `hdiutil attach -nobrowse -readonly`, and
///    always detach it again.
/// 3. Verify the bundle inside: identifier, version, and
///    `codesign --verify --deep --strict`.
/// 4. `ditto` the verified bundle to a staging directory beside the installed
///    app, so the final move is on one volume and therefore atomic.
/// 5. Hand the swap to a detached shell script that waits for this process to
///    exit, replaces the bundle, and reopens it. Nothing modifies the bundle of
///    a process that is still running.
///
/// Everything is user-confirmed: nothing here starts without an explicit press,
/// and there is no background or automatic update path anywhere in the app.
@MainActor
final class UpdateInstaller {
    private let commandRunner: CommandRunning
    private let fileManager: FileManager
    private let installedAppURL: URL

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        installedAppURL: URL = Bundle.main.bundleURL
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.installedAppURL = installedAppURL
    }

    /// Downloads and verifies the release, returning the staged bundle that is
    /// ready to be swapped in. Does not replace anything.
    func downloadAndVerify(
        _ release: PublishedRelease,
        settings: UpdateDownloadSettings = UpdateDownloadSettings(),
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        let downloaded = try await download(release, settings: settings, progress: progress)
        defer { try? fileManager.removeItem(at: downloaded.deletingLastPathComponent()) }

        // Everything from here is local work on a file that has already landed:
        // mounting, checking a signature and copying a bundle. It takes seconds,
        // it reports no fraction, and saying so is the difference between "still
        // working" and the stuck download this class now refuses to produce.
        progress(.verifying)
        // The user may have cancelled while the last bytes were arriving; the
        // one honest place to notice is before anything is mounted or staged.
        try Task.checkCancellation()

        let attributes = try? fileManager.attributesOfItem(atPath: downloaded.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size == release.sizeInBytes else {
            throw UpdateInstallError.unexpectedSize(expected: release.sizeInBytes, received: size)
        }

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForgeUpdate-\(UUID().uuidString)", isDirectory: true)
        let attach = try await run(
            "/usr/bin/hdiutil",
            ["attach", downloaded.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attach.status == 0 else {
            throw UpdateInstallError.diskImageCouldNotBeOpened(attach.output)
        }
        defer { detachDiskImage(at: mountPoint) }

        let mountedApp = mountPoint.appendingPathComponent("EchoForge.app", isDirectory: true)
        guard fileManager.fileExists(atPath: mountedApp.path) else {
            throw UpdateInstallError.noApplicationInDiskImage
        }

        try await verify(mountedApp, against: .forOffered(release))

        // A staged copy from an earlier attempt that was never installed - "Not
        // Now", a crash, or the app quitting before install - would otherwise
        // sit here forever; this is the one place guaranteed to run again
        // before another one is staged.
        removeStaleStagingDirectories()

        // Staged beside the installed app so the final move is a same-volume
        // rename rather than a copy that could be interrupted half way.
        let staging = installedAppURL.deletingLastPathComponent()
            .appendingPathComponent(".EchoForgeUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("EchoForge.app", isDirectory: true)
        let copy = try await run("/usr/bin/ditto", [mountedApp.path, staged.path])
        guard copy.status == 0 else {
            try? fileManager.removeItem(at: staging)
            throw UpdateInstallError.replacementFailed(copy.output)
        }
        return staged
    }

    /// Checks the identity and the signature of a bundle that is about to be
    /// installed. Throws on the first thing that is wrong.
    func verify(_ app: URL, against requirements: DownloadedBuildRequirements) async throws {
        let info = Bundle(url: app)?.infoDictionary
        if let failure = requirements.validateIdentity(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String
        ) {
            throw failure
        }

        let signature = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else {
            throw UpdateInstallError.signatureRejected(signature.output)
        }
    }

    /// Removes any `.EchoForgeUpdate-*` staging directory left beside the
    /// installed app by an earlier attempt that was never installed. Not
    /// `private` so a test can drive it directly against a throwaway directory
    /// rather than a real download.
    func removeStaleStagingDirectories() {
        let parent = installedAppURL.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(".EchoForgeUpdate-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Swaps the staged bundle in and reopens the app.
    ///
    /// The swap runs in a detached `/bin/sh` that first waits for this process to
    /// exit, because replacing the bundle of a running application is what
    /// produces the "the application is damaged" failures this is written to
    /// avoid. This function only launches the script and returns its path;
    /// quitting is the caller's half of the bargain (`UpdateViewModel`), and it
    /// has to happen promptly, because the script is already waiting on this
    /// pid.
    @discardableResult
    func installAndRelaunch(stagedApp: URL) throws -> URL {
        let installed = installedAppURL
        let staging = stagedApp.deletingLastPathComponent()
        // Deliberately *outside* the staging directory: the script's last act is
        // to remove that directory, and a script that deletes the directory it
        // is being read from is not something to rely on. It also keeps staging
        // holding exactly one thing - the bundle about to be installed - so the
        // sweep in `removeStaleStagingDirectories` and the `mv` below never race
        // an executable being written beside their target.
        let script = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForge-install-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let log = fileManager.temporaryDirectory.appendingPathComponent("EchoForge-update-install.log")

        // `while kill -0` polls for the old process actually being gone rather
        // than sleeping a guessed number of seconds. The `mv` pair is two
        // same-volume renames, so the window in which neither bundle is in place
        // is as short as the filesystem can make it. A trap on EXIT restores the
        // original bundle if anything after the first `mv` fails, so a failed
        // swap never leaves the user with no app at its expected path, and
        // relaunches either way. Everything the script prints goes to a fixed
        // log file rather than `/dev/null`, since it is detached and has no
        // other way to report a failure.
        let body = """
            #!/bin/sh
            exec >> "\(log.path)" 2>&1
            echo "---- $(date) EchoForge update install ----"
            set -e
            while kill -0 \(pid); do sleep 0.2; done

            installed="\(installed.path)"
            staged="\(stagedApp.path)"
            staging="\(staging.path)"
            script="\(script.path)"
            old="$installed.old"

            rollback_and_relaunch() {
                status=$?
                if [ "$status" -ne 0 ] && [ -d "$old" ] && [ ! -e "$installed" ]; then
                    echo "swap failed with status $status, restoring original bundle"
                    mv "$old" "$installed"
                fi
                rm -f "$script"
                open "$installed"
                exit "$status"
            }
            trap rollback_and_relaunch EXIT

            rm -rf "$old"
            mv "$installed" "$old"
            mv "$staged" "$installed"
            rm -rf "$old"
            rm -rf "$staging"
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Detached: the script's first act is to wait for this process to exit,
        // so waiting for the script would wait forever.
        try commandRunner.launchDetached("/bin/sh", [script.path])
        return script
    }

    // MARK: - Private

    /// Runs a blocking command off the main actor. `Task.detached` genuinely
    /// runs its body on a background thread, so mounting, copying and
    /// verifying a real app bundle - each of which can take seconds - never
    /// freezes the UI; this method only awaits the result.
    private func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let runner = commandRunner
        return try await Task.detached(priority: .utility) {
            try runner.run(executable, arguments)
        }.value
    }

    /// Detaches the mounted disk image without waiting for or blocking on it,
    /// matching the original best-effort `try?` semantics while keeping the
    /// `Process` wait off the main actor.
    private func detachDiskImage(at mountPoint: URL) {
        let runner = commandRunner
        Task.detached(priority: .utility) {
            try? runner.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }
    }

    /// Streams the asset to a temporary file, reporting a byte fraction as it
    /// goes, and failing it if it goes quiet.
    ///
    /// A download *task* rather than `URLSession.bytes`: the asset is tens of
    /// megabytes and `bytes` yields one `UInt8` at a time, which turns a network
    /// wait into a CPU one. The delegate is where the progress fraction comes
    /// from, and it is a real byte fraction - the size is known up front from
    /// both the release metadata and `Content-Length`. It is also what feeds the
    /// stall watchdog: the same callback that proves the bar should move is the
    /// proof the transfer is alive.
    private func download(
        _ release: PublishedRelease,
        settings: UpdateDownloadSettings,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForgeDownload-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UpdateManifest.assetName)

        let activity = DownloadActivityClock()
        let transfer = UpdateDownload(
            expectedBytes: release.sizeInBytes,
            destination: destination,
            activity: activity
        ) { fraction in
            progress(.downloading(fraction: fraction))
        }
        let session = URLSession(configuration: settings.configuration, delegate: transfer, delegateQueue: nil)
        // Sessions with a delegate hold on to it until they are invalidated, and
        // this one exists for exactly one download.
        defer { session.finishTasksAndInvalidate() }

        let url = release.downloadURL
        do {
            let response = try await withStallWatchdog(interval: settings.stallInterval, activity: activity) {
                try await transfer.run(session: session, url: url)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateInstallError.downloadFailed("The server returned an unexpected response.")
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        progress(.downloading(fraction: 1))
        return destination
    }

    /// Which half of the race finished first.
    private enum StallRace<Value: Sendable>: Sendable {
        case completed(Value)
        case stalled
    }

    /// Runs `work` against a watchdog that fails it once `activity` has reported
    /// nothing for `interval`.
    ///
    /// A race rather than a `URLSession` timeout because no `URLSession` timeout
    /// expresses this: `timeoutIntervalForRequest` is reset by every byte and so
    /// never fires mid-transfer, and `timeoutIntervalForResource` is a ceiling on
    /// the whole download that cannot tell a big slow file from a dead one. The
    /// losing side is cancelled on the way out of the group - which for the
    /// download means `URLSession` cancels the task and discards its partial
    /// file - and its error is discarded with it.
    ///
    /// User cancellation is *not* a stall: cancelling the surrounding task
    /// cancels both children, and the error that surfaces is the download's own
    /// cancellation, which callers re-read as cancellation rather than failure.
    private func withStallWatchdog<Value: Sendable>(
        interval: TimeInterval,
        activity: DownloadActivityClock,
        work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard interval > 0 else { return try await work() }

        return try await withThrowingTaskGroup(of: StallRace<Value>.self) { group in
            group.addTask { .completed(try await work()) }
            group.addTask {
                // Polled rather than scheduled off each byte: bytes arrive
                // thousands of times a second on a healthy transfer, and a
                // rescheduled timer per callback would cost more than the check.
                let poll = max(0.05, min(interval / 4, 1))
                while true {
                    try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                    if activity.secondsSinceActivity >= interval { return .stalled }
                }
            }

            guard let first = try await group.next() else {
                throw UpdateInstallError.downloadFailed("The download ended without a result.")
            }
            group.cancelAll()

            switch first {
            case .completed(let value):
                return value
            case .stalled:
                // Rounded up, never to zero: a test injects a sub-second
                // interval, and "stopped receiving data for 0 seconds" is not a
                // sentence to ship.
                let seconds = max(1, Int(interval.rounded(.up)))
                throw UpdateInstallError.downloadFailed(
                    "It stopped receiving data for \(seconds) seconds. Check your connection and try again."
                )
            }
        }
    }
}

/// One download: it owns the `URLSession`, turns byte counts into the fraction
/// the About pane shows, keeps the stall watchdog's clock, moves the finished
/// file somewhere that outlives the callback, and answers the caller.
///
/// It has to own the session, and that is the whole reason this type exists.
/// `URLSession.download(from:delegate:)` accepts a `URLSessionDownloadDelegate`
/// and compiles, but it never calls `didWriteData` on it - measured against a
/// 4 MB transfer: zero progress callbacks to a task-supplied delegate, fourteen
/// to a session's own. That is why the pane could only ever show 0% and then
/// jump to done, and it is why a stalled transfer looked exactly like a healthy
/// one that had not finished yet. Progress goes to the *session's* delegate, so
/// the download creates the session it needs.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int
    private let destination: URL
    private let activity: DownloadActivityClock?
    private let report: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var moveFailure: Error?
    private var hasFinished = false

    init(expectedBytes: Int,
         destination: URL,
         activity: DownloadActivityClock? = nil,
         report: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.activity = activity
        self.report = report
    }

    /// Runs the transfer, returning the response once the bytes are at
    /// `destination`. Cancelling the surrounding task cancels the transfer,
    /// which is how the About pane's Cancel reaches the socket.
    func run(session: URLSession, url: URL) async throws -> URLResponse {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Stamped here rather than by whoever passes `report`: this is the one
        // callback that means bytes actually arrived, so the watchdog's notion
        // of "alive" cannot drift from the bar's.
        activity?.recordActivity()

        // The server's own figure is preferred when it gives one; the release
        // metadata is the fallback, and the size is checked against the metadata
        // again once the file has landed.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedBytes)
        guard total > 0 else { return }
        report(min(Double(totalBytesWritten) / Double(total), 1))
    }

    /// The file `URLSession` hands over here is deleted the moment this returns,
    /// so it is moved now rather than remembered.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            moveFailure = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let alreadyFinished = hasFinished
        hasFinished = true
        let moveFailure = self.moveFailure
        lock.unlock()
        guard let pending, !alreadyFinished else { return }

        if let error {
            return pending.resume(throwing: error)
        }
        if let moveFailure {
            return pending.resume(
                throwing: UpdateInstallError.downloadFailed("It could not be written to disk. \(moveFailure.localizedDescription)")
            )
        }
        guard let response = task.response else {
            return pending.resume(throwing: UpdateInstallError.downloadFailed("The server returned no response."))
        }
        pending.resume(returning: response)
    }

    /// GitHub's API only ever hands back a `github.com` URL; the bytes
    /// actually come from a redirect to its object store. `UpdateManifest`
    /// documents `allowedDownloadHosts` as the only hosts this app will ever
    /// download from, but nothing enforced that at the point a redirect is
    /// actually followed - this is that enforcement. Declining the redirect
    /// (by handing back `nil`) fails the download rather than silently
    /// following it, since the response becomes the un-followed 3xx.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(UpdateManifest.isAllowedRedirectHost(request.url) ? request : nil)
    }
}
