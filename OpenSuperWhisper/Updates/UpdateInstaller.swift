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
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloaded = try await download(release, session: session, progress: progress)
        defer { try? fileManager.removeItem(at: downloaded.deletingLastPathComponent()) }

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
    /// avoid. Once the script is launched this function terminates the app; the
    /// script does the rest.
    func installAndRelaunch(stagedApp: URL) throws {
        let installed = installedAppURL
        let staging = stagedApp.deletingLastPathComponent()
        let script = staging.appendingPathComponent("install.sh")
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
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done

            installed="\(installed.path)"
            staged="\(stagedApp.path)"
            staging="\(staging.path)"
            old="$installed.old"

            rollback_and_relaunch() {
                status=$?
                if [ "$status" -ne 0 ] && [ -d "$old" ] && [ ! -e "$installed" ]; then
                    echo "swap failed with status $status, restoring original bundle"
                    mv "$old" "$installed"
                fi
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
    /// goes.
    ///
    /// A download *task* rather than `URLSession.bytes`: the asset is tens of
    /// megabytes and `bytes` yields one `UInt8` at a time, which turns a network
    /// wait into a CPU one. The delegate is where the progress fraction comes
    /// from, and it is a real byte fraction - the size is known up front from
    /// both the release metadata and `Content-Length`.
    private func download(
        _ release: PublishedRelease,
        session: URLSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let observer = DownloadProgressObserver(expectedBytes: release.sizeInBytes, report: progress)
        let (temporary, response) = try await session.download(from: release.downloadURL, delegate: observer)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: temporary)
            throw UpdateInstallError.downloadFailed("The server returned an unexpected response.")
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForgeDownload-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UpdateManifest.assetName)
        // `download` hands back a file URL that is deleted when this returns, so
        // it is moved rather than referenced.
        try fileManager.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }
}

/// Turns `URLSession`'s byte counts into the fraction the About pane shows, and
/// re-checks every redirect the download follows against the host allow-list.
///
/// Not `private`: a test constructs one directly to exercise the redirect
/// check without a real network call.
final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let expectedBytes: Int
    private let report: @Sendable (Double) -> Void

    init(expectedBytes: Int, report: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The server's own figure is preferred when it gives one; the release
        // metadata is the fallback, and the size is checked against the metadata
        // again once the file has landed.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedBytes)
        guard total > 0 else { return }
        report(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Required by the protocol; the async `download(from:delegate:)` takes
        // care of handing the file back to the caller.
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
