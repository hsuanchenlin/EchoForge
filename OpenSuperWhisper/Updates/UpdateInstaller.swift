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
    case checksumUnavailable(String)
    case checksumMismatch(expected: String, found: String)
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
        case .checksumUnavailable(let detail):
            return "The published checksum for this release could not be read, so the download was not "
                + "installed. \(detail)"
        case .checksumMismatch(let expected, let found):
            return "The download does not match the checksum this release publishes "
                + "(\(found.prefix(12))… instead of \(expected.prefix(12))…). It was discarded."
        case .diskImageCouldNotBeOpened(let detail):
            return "The downloaded disk image could not be opened. \(detail)"
        case .noApplicationInDiskImage:
            return "The downloaded disk image does not contain the Kongweh app."
        case .wrongBundleIdentifier(let found):
            return "The downloaded app identifies itself as \(found), not Kongweh. It was discarded."
        case .wrongVersion(let expected, let found):
            return "The downloaded app is version \(found), not the \(expected) that was offered. It was discarded."
        case .signatureRejected(let detail):
            return "The downloaded app failed signature verification and was discarded. \(detail)"
        case .replacementFailed(let detail):
            return "Kongweh could not be replaced. \(detail)"
        }
    }

    /// Whether this failure is a verdict against the downloaded bytes
    /// themselves. Only such a verdict is a reason to throw the partial away:
    /// a check that could not run - a sidecar that would not fetch, a staging
    /// copy that failed - has not found the bytes wanting, and keeping them
    /// costs nothing because the retry re-verifies whatever it resumes onto in
    /// full.
    var indictsDownloadedBytes: Bool {
        switch self {
        case .unexpectedSize, .checksumMismatch, .diskImageCouldNotBeOpened,
             .noApplicationInDiskImage, .wrongBundleIdentifier, .wrongVersion,
             .signatureRejected:
            return true
        case .downloadFailed, .checksumUnavailable, .replacementFailed:
            return false
        }
    }
}

/// What an update is doing, as one value reported out of `downloadAndVerify`.
///
/// Three cases rather than one bar, because from outside they look identical -
/// the app is busy with an update - and telling them apart is the whole
/// difference between a user who can see progress and one watching a number that
/// will not move:
///
/// - `connecting` is the stretch before the first byte, which used to be
///   rendered as "0%". On a healthy link it is half a second; on a bad one it is
///   the part worth saying out loud, and it is not the same thing as a transfer
///   that has started and is slow.
/// - `downloading` carries byte counts, not a bare fraction. The percentage was
///   the whole problem: 0% covered everything up to the first 1.1 MB of a 212 MB
///   asset, so "downloading slowly" and "downloading nothing" looked the same.
/// - `verifying` is the stretch where `hdiutil`, `codesign` and `ditto` work
///   through the image with no fraction to report.
enum UpdateProgress: Equatable, Sendable {
    case connecting(DownloadProgress)
    case downloading(DownloadProgress)
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
    /// delegate (see `ResumableDownload`), and that delegate is fixed when the
    /// session is created.
    ///
    /// Ephemeral because caching a disk image this size, on the way to
    /// installing it once, has no purpose. The partial file
    /// `ResumableDownload` writes is what a resumed transfer picks up from -
    /// deliberately not `URLCache`, which has no notion of resuming and would
    /// keep a second copy of the asset.
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

    /// Terminates every command already running and refuses to start another
    /// through `run`.
    ///
    /// A command is a child process, so it outlives the app that started it. An
    /// `hdiutil attach` still running when the app goes away therefore finishes
    /// and mounts an image nobody is left to detach - and stopping it has to be
    /// a decision this runner makes, because launching and stopping have to be
    /// mutually exclusive to be a decision at all: a check the caller makes
    /// before calling `run` can always be overtaken by the launch it guards.
    func terminateInFlightCommands()

    /// Runs a command the refusal above does not apply to: the cleanup a quit
    /// still has to get through once everything else has been stood down.
    @discardableResult
    func runDuringTermination(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, output: String)
}

/// Fetches the SHA-256 a release publishes beside its disk image. A protocol so
/// the "the digest did not match" path can be asserted without a network.
protocol ChecksumFetching: Sendable {
    func fetchChecksumDocument(from url: URL) async throws -> String
}

/// Re-checks every redirect the sidecar fetch follows against the release-host
/// allow-list, the same rule the asset download enforces: the boundary is where
/// the bytes actually come from, not the URL the metadata named. Refusing hands
/// the 3xx back as the result, which the status check then rejects.
private final class ChecksumRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard UpdateManifest.isAllowedRedirectHost(request.url) else { return completionHandler(nil) }
        completionHandler(request)
    }
}

/// One small GET against the same allow-listed hosts as the asset itself.
///
/// Deliberately its own short-lived session rather than the download's: this
/// runs after the bytes are down, it is 80 bytes, and it must not inherit a
/// half-hour resource timeout meant for a 212 MB transfer.
struct GitHubChecksumFetcher: ChecksumFetching {
    static let timeout: TimeInterval = 20

    func fetchChecksumDocument(from url: URL) async throws -> String {
        guard UpdateManifest.isTrustedAssetURL(url) else {
            throw UpdateInstallError.checksumUnavailable("It is not published where Kongweh releases are.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: ChecksumRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateInstallError.checksumUnavailable("The server returned an unexpected response.")
        }
        guard data.count <= UpdateManifest.maximumChecksumBytes else {
            throw UpdateInstallError.checksumUnavailable("The document is not a checksum.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A class rather than a struct because it has to remember what it is running:
/// terminating an in-flight command means holding on to its `Process`.
final class SystemCommandRunner: CommandRunning, @unchecked Sendable {
    /// What a command that was refused or killed on the way out reports. Nothing
    /// reads it as a verdict - `UpdateInstaller` knows it is terminating - but a
    /// non-zero status is what every caller already treats as "did not happen".
    static let terminatedStatus: Int32 = -1

    /// How long the sweep waits for a signalled command to actually go away.
    ///
    /// `hdiutil` answers SIGTERM in milliseconds, so this is a ceiling rather
    /// than a cost. It is bounded at all because the sweep runs inside
    /// `applicationWillTerminate`, where blocking the main thread until a command
    /// that is ignoring the signal decides to exit would hang the quit rather
    /// than tidy up after it.
    static let terminationGracePeriod: TimeInterval = 2

    private let lock = NSLock()
    private var inFlight: [Process] = []
    private var isTerminating = false

    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        try run(executable, arguments, ignoringTermination: false)
    }

    @discardableResult
    func runDuringTermination(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, output: String) {
        try run(executable, arguments, ignoringTermination: true)
    }

    func terminateInFlightCommands() {
        lock.lock()
        isTerminating = true
        let running = inFlight
        inFlight.removeAll()
        lock.unlock()

        for process in running where process.isRunning {
            process.terminate()
        }

        // `terminate()` only raises SIGTERM; it returns long before the process
        // it signalled is gone. Without this wait the caller's next step acts on
        // a state that has not settled - an `hdiutil attach` that has been
        // signalled but is still finishing its mount would be detached before
        // that mount exists, which is the leak the signalling is here to close.
        // Signalled first and waited on second, so several commands overlap
        // their exits rather than queueing them.
        let deadline = Date().addingTimeInterval(Self.terminationGracePeriod)
        for process in running {
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    /// The launch and the sweep above take the same lock, which is the whole
    /// point: a command that has not started when the sweep runs is refused, and
    /// one that has is in `inFlight` and gets terminated. There is no third
    /// outcome for the launch to slip through.
    private func run(
        _ executable: String, _ arguments: [String], ignoringTermination: Bool
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.lock()
        if isTerminating, !ignoringTermination {
            lock.unlock()
            return (Self.terminatedStatus, "Kongweh is quitting.")
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            throw error
        }
        if !ignoringTermination {
            inFlight.append(process)
        }
        lock.unlock()

        defer { forget(process) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func forget(_ process: Process) {
        lock.lock()
        inFlight.removeAll { $0 === process }
        lock.unlock()
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
    private let partialStore: PartialDownloadStore
    private let checksumFetcher: ChecksumFetching
    /// The image this installer has attached, if any, so a quit can detach it
    /// without waiting for the `defer` that normally would.
    private var mountedDiskImage: URL?
    private var isTerminating = false

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        installedAppURL: URL = Bundle.main.bundleURL,
        partialStore: PartialDownloadStore = PartialDownloadStore(),
        checksumFetcher: ChecksumFetching = GitHubChecksumFetcher()
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.installedAppURL = installedAppURL
        self.partialStore = partialStore
        self.checksumFetcher = checksumFetcher
    }

    /// Downloads and verifies the release, returning the staged bundle that is
    /// ready to be swapped in. Does not replace anything.
    ///
    /// The partial download outlives a failure on purpose: a transfer that dies
    /// at 95% of 212 MB used to be thrown away, so "Retry" meant another twelve
    /// minutes and a flaky link could never converge. It does *not* outlive a
    /// verification failure - bytes that fail a checksum or a signature are not
    /// something to resume onto.
    func downloadAndVerify(
        _ release: PublishedRelease,
        settings: UpdateDownloadSettings = UpdateDownloadSettings(),
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        let downloaded = try await download(release, settings: settings, progress: progress)

        // Everything from here is local work on a file that has already landed:
        // hashing, mounting, checking a signature and copying a bundle. It takes
        // seconds, it reports no fraction, and saying so is the difference
        // between "still working" and the stuck download this class refuses to
        // produce.
        progress(.verifying)
        // The user may have cancelled while the last bytes were arriving; the
        // one honest place to notice is before anything is mounted or staged.
        try Task.checkCancellation()

        do {
            let staged = try await verifyAndStage(downloaded, release: release)
            partialStore.discardPartial(for: release.version)
            return staged
        } catch {
            // Cancelling, or a check that could not run, is not a reason to
            // throw away 212 MB: the same press that stopped it can start it
            // again where it stopped. Only a verdict against the bytes
            // themselves discards them - and a check that failed because
            // `prepareForTermination` pulled the disk image out from under it is
            // not such a verdict, however much it looks like one from here.
            if let refusal = error as? UpdateInstallError, refusal.indictsDownloadedBytes, !isTerminating {
                partialStore.discardPartial(for: release.version)
            }
            throw error
        }
    }

    /// Checks the bytes and produces the staged bundle. Split out so the
    /// download's own error handling does not have to reason about which
    /// failures invalidate the partial file.
    private func verifyAndStage(_ downloaded: URL, release: PublishedRelease) async throws -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: downloaded.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size == release.sizeInBytes else {
            throw UpdateInstallError.unexpectedSize(expected: release.sizeInBytes, received: size)
        }

        try await verifyChecksum(of: downloaded, for: release)

        // The last byte can land while the app is already going away, and
        // `downloadAndVerify` checked cancellation before this call rather than
        // during it. Mounting an image at that point starts work nothing is left
        // to finish.
        guard !isTerminating else { throw CancellationError() }

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForgeUpdate-\(UUID().uuidString)", isDirectory: true)
        // Claimed *before* the attach rather than after it. `hdiutil attach` on
        // a 222 MB image takes seconds, and for all of them the pane is already
        // in `.verifying`; a quit in that window would otherwise find nothing to
        // detach and leave the image mounted after the app was gone. Claiming it
        // early costs at most one best-effort detach of a path that never
        // mounted, on the failure paths below.
        mountedDiskImage = mountPoint
        defer { detachDiskImage(at: mountPoint) }
        let attach = try await run(
            "/usr/bin/hdiutil",
            ["attach", downloaded.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attach.status == 0 else {
            throw UpdateInstallError.diskImageCouldNotBeOpened(attach.output)
        }

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

    /// Unmounts a disk image this installer attached, synchronously, because the
    /// process is about to go away.
    ///
    /// Verification is the one stretch that cannot simply be cancelled: it runs
    /// as `Task.detached` work whose result is awaited, so cancelling the task
    /// waiting on it stops nothing, and `applicationWillTerminate` can neither
    /// delay the exit nor await the `defer` that would normally detach. Left
    /// alone, quitting between `hdiutil attach` and that `defer` leaves the image
    /// mounted with no app to own it. This runs the detach inline instead, on the
    /// way out, and hands the `defer` a claim that is already released.
    ///
    /// Standing the commands down comes first, and detaching second. Detaching
    /// while `hdiutil attach` is still running does nothing - there is no mount
    /// yet to take down - and the attach then completes and mounts an image the
    /// exiting process can no longer reach. Terminating first is what makes the
    /// detach that follows a decision about a settled state rather than a race
    /// against one: either the attach mounted the image and this takes it back
    /// down, or it never got that far and there is nothing to take down.
    ///
    /// "Settled" is the whole of what `terminateInFlightCommands` waits for, and
    /// it waits with a bound (`SystemCommandRunner.terminationGracePeriod`)
    /// because this runs on the way out and cannot hang the quit. A command still
    /// alive at the end of that bound is one this cannot speak for, and the
    /// detach below is then the same best-effort attempt it always was.
    ///
    /// It also marks the session as terminating, which is what keeps all of this
    /// from being mistaken for a verdict on the downloaded bytes: a `codesign` or
    /// `ditto` killed here, or reading an image that has just vanished, fails,
    /// and that failure must not discard the partial the next launch resumes
    /// from.
    func prepareForTermination() {
        isTerminating = true
        commandRunner.terminateInFlightCommands()
        guard let mountPoint = mountedDiskImage else { return }
        mountedDiskImage = nil
        try? commandRunner.runDuringTermination("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
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
    ///
    /// Does nothing if the claim has already been released, which is how the
    /// ordinary `defer` and the synchronous detach `prepareForTermination` runs
    /// stay one detach rather than two.
    private func detachDiskImage(at mountPoint: URL) {
        guard mountedDiskImage == mountPoint else { return }
        mountedDiskImage = nil
        let runner = commandRunner
        Task.detached(priority: .utility) {
            try? runner.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }
    }

    /// Checks the downloaded bytes against the digest the release publishes.
    ///
    /// A release with no `.sha256` sidecar is not a failure: every release up to
    /// v0.5.1 published none, and those users have to be able to update *to* a
    /// build that does. What is a failure is a sidecar that exists and does not
    /// match, and a sidecar that exists and cannot be read - because "carry on
    /// without checking" is a downgrade anyone who can make one HTTP request
    /// fail could choose for us. Failing costs one press now that the bytes
    /// survive a failure and the retry resumes.
    private func verifyChecksum(of file: URL, for release: PublishedRelease) async throws {
        guard let checksumURL = release.checksumURL else { return }

        let document = try await checksumFetcher.fetchChecksumDocument(from: checksumURL)
        guard let expected = FileDigest.parseChecksumDocument(document, expectedFileName: UpdateManifest.assetName)
        else {
            throw UpdateInstallError.checksumUnavailable("It does not name \(UpdateManifest.assetName).")
        }

        let path = file.path
        let actual = try await Task.detached(priority: .utility) {
            try FileDigest.sha256(of: URL(fileURLWithPath: path))
        }.value

        guard actual == expected else {
            throw UpdateInstallError.checksumMismatch(expected: expected, found: actual)
        }
    }

    /// Streams the asset to a partial file that survives a failure, reporting
    /// byte counts as it goes, and failing it if it goes quiet.
    ///
    /// Two things it does that the previous download task could not. It
    /// **resumes**: whatever a previous attempt left on disk is what this one
    /// appends to, conditioned on `If-Range` so a changed asset restarts instead
    /// of being spliced. And it reports **bytes**, so the pane can say
    /// `45.2 MB of 212 MB` rather than a percentage that spends its first
    /// 1.1 MB reading `0%`.
    ///
    /// The delegate is still the session's own - progress callbacks are never
    /// delivered to a per-task delegate, which is the platform fact the whole
    /// shape of this is built around - and the same callback that moves the bar
    /// is what feeds the stall watchdog, so the two cannot disagree about
    /// whether the transfer is alive.
    private func download(
        _ release: PublishedRelease,
        settings: UpdateDownloadSettings,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        let version = release.version
        let declaredBytes = Int64(release.sizeInBytes)
        try partialStore.prepareDirectory(for: version)
        // A half-download of a release nobody is going to install any more is
        // hundreds of megabytes of nothing; starting a new one is the moment the
        // app knows which version is still wanted.
        partialStore.discardPartialsOtherThan(version)

        let destination = partialStore.partialFile(for: version)
        var existingBytes = partialStore.resumableBytes(for: version, sourceURL: release.downloadURL)
        if existingBytes > declaredBytes {
            // Longer than the asset it claims to be part of: not something to
            // append to under any interpretation.
            partialStore.discardPartial(for: version)
            existingBytes = 0
        }
        let validator = existingBytes > 0 ? partialStore.metadata(for: version) : nil

        // Said before the request is even made: this is the stretch that used to
        // render as "0%", and it is a different thing from a transfer that has
        // started and is slow.
        progress(.connecting(DownloadProgress(receivedBytes: existingBytes, totalBytes: declaredBytes)))

        let activity = DownloadActivityClock()
        let metadataURL = partialStore.metadataFile(for: version)
        let transfer = ResumableDownload(
            sourceURL: release.downloadURL,
            destination: destination,
            declaredBytes: declaredBytes,
            existingBytes: existingBytes,
            activity: activity,
            onValidator: { metadata in
                guard let data = try? JSONEncoder().encode(metadata) else { return }
                try? data.write(to: metadataURL, options: .atomic)
            },
            report: { progress(.downloading($0)) }
        )
        let session = URLSession(configuration: settings.configuration, delegate: transfer, delegateQueue: nil)
        // Sessions with a delegate hold on to it until they are invalidated, and
        // this one exists for exactly one download.
        defer { session.finishTasksAndInvalidate() }

        let request = ResumableDownload.makeRequest(
            url: release.downloadURL,
            existingBytes: existingBytes,
            validator: validator
        )
        // Deliberately no `catch` that deletes the partial: everything this can
        // throw - a stall, a dropped connection, the user cancelling - is a
        // reason to keep the bytes and resume, and the caller discards them only
        // when *verification* fails.
        let outcome = try await StallWatchdog.run(interval: settings.stallInterval, activity: activity) {
            try await transfer.run(session: session, request: request)
        }

        progress(.downloading(DownloadProgress(
            receivedBytes: outcome.totalBytes,
            totalBytes: outcome.totalBytes
        )))
        return destination
    }

}
