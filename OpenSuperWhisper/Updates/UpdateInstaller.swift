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
}

/// Fetches the SHA-256 a release publishes beside its disk image. A protocol so
/// the "the digest did not match" path can be asserted without a network.
protocol ChecksumFetching: Sendable {
    func fetchChecksumDocument(from url: URL) async throws -> String
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
            throw UpdateInstallError.checksumUnavailable("It is not published where EchoForge releases are.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
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
    private let partialStore: PartialDownloadStore
    private let checksumFetcher: ChecksumFetching

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
        } catch is CancellationError {
            // Cancelling is not a reason to throw away 212 MB: the same press
            // that stopped it can start it again where it stopped.
            throw CancellationError()
        } catch {
            partialStore.discardPartial(for: release.version)
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
