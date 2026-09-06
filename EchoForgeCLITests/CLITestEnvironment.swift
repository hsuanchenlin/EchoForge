import Foundation
import XCTest

/// The stand-ins every test in this bundle runs against.
///
/// The point of them is what they make *impossible*: nothing in this suite can
/// start Kongweh on the developer's desktop, replace the copy in
/// `/Applications`, read their dictation history, or reach GitHub. The
/// production implementations are chosen in exactly one place
/// (`CLIEnvironment.system()`), and it is the one place these tests do not
/// exercise.
enum CLITestEnvironment {

    /// An environment where nothing exists: no app, no history, no preferences,
    /// no log. The starting point every test adds to, so a test that forgets to
    /// arrange something gets "not installed" rather than the developer's Mac.
    static func empty(
        now: Date = Date(timeIntervalSince1970: 1_757_000_000)
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileSystem: FakeFileSystem(),
            runningApplications: FakeRunningApplications(),
            launcher: FakeLauncher(),
            history: FakeHistory(),
            preferences: FakePreferences(isReadable: true, values: [:]),
            log: FakeLog(),
            updates: FakeUpdates(),
            now: { now },
            defaultApplicationLocations: [URL(fileURLWithPath: "/Applications/EchoForge.app")],
            confirm: { _ in nil },
            toolIdentity: AppBuildIdentity(
                marketingVersion: "9.9.9", buildNumber: "99",
                bundleIdentifier: "com.hsuanchenlin.EchoForgeCLI"))
    }

    /// An environment with Kongweh 0.9.5 installed at the usual place and not
    /// running.
    static func withInstalledApp(
        version: String = "0.9.5",
        build: String = "35",
        bundleIdentifier: String = AppDataLocation.storageIdentifier,
        at path: String = "/Applications/EchoForge.app"
    ) -> CLIEnvironment {
        var environment = empty()
        let fileSystem = FakeFileSystem()
        fileSystem.directories.insert(path)
        fileSystem.bundles[path] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleIdentifier": bundleIdentifier,
        ]
        environment.fileSystem = fileSystem
        return environment
    }
}

/// A filesystem that only holds what a test put in it.
final class FakeFileSystem: FileSystemReading {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var bundles: [String: [String: Any]] = [:]
    var sizes: [String: Int64] = [:]
    var modificationDates: [String: Date] = [:]

    func fileExists(at url: URL) -> Bool {
        files[url.path] != nil || directories.contains(url.path)
    }

    func isDirectory(at url: URL) -> Bool { directories.contains(url.path) }

    func contentsOfDirectory(at url: URL) -> [URL] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let paths: [String] = Array(files.keys) + Array(directories)
        var children: Set<String> = []
        for path in paths where path.hasPrefix(prefix) && path != url.path {
            let relative = path.dropFirst(prefix.count)
            if let first = relative.split(separator: "/").first {
                children.insert(String(first))
            }
        }
        return children.sorted().map { url.appendingPathComponent($0) }
    }

    func fileSize(at url: URL) -> Int64? {
        sizes[url.path] ?? files[url.path].map { Int64($0.count) }
    }

    func modificationDate(at url: URL) -> Date? { modificationDates[url.path] }

    func contents(at url: URL) -> Data? { files[url.path] }

    func infoDictionary(forBundleAt url: URL) -> [String: Any]? { bundles[url.path] }
}

final class FakeRunningApplications: RunningApplicationsReading {
    var copies: [RunningCopy] = []

    func runningCopies(ofBundleIdentifier identifier: String) -> [RunningCopy] { copies }
}

final class FakeLauncher: ApplicationLaunching {
    private(set) var launched: [URL] = []
    var result: RunningCopy? = RunningCopy(
        processIdentifier: 4242,
        bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
        launchDate: nil)
    var failure: Error?

    func launch(at url: URL) throws -> RunningCopy? {
        launched.append(url)
        if let failure { throw failure }
        return result
    }
}

final class FakeHistory: HistoryReading {
    var page = HistoryPage(rows: [], totalMatching: 0, databasePath: "/fake/recordings.sqlite")
    var failure: Error?
    private(set) var requests: [HistoryRequest] = []

    func read(_ request: HistoryRequest, now: Date) throws -> HistoryPage {
        requests.append(request)
        if let failure { throw failure }
        return page
    }
}

struct FakePreferences: PreferencesReading {
    var isReadable: Bool
    var values: [String: Any]

    func value(forKey key: String) -> Any? { values[key] }
}

final class FakeLog: LogReading {
    var result = LogReadResult(source: .unified, entries: [], unavailableReason: nil)
    var failure: Error?
    private(set) var requests: [LogRequest] = []
    var followed: [LogEntry] = []

    func read(_ request: LogRequest) throws -> LogReadResult {
        requests.append(request)
        if let failure { throw failure }
        return result
    }

    func follow(_ request: LogRequest, onEntry: @escaping (LogEntry) -> Void) throws {
        requests.append(request)
        if let failure { throw failure }
        followed.forEach(onEntry)
    }
}

/// An updater that never touches the network and never replaces anything.
final class FakeUpdates: UpdateServicing, @unchecked Sendable {
    var availability: UpdateAvailability = .upToDate(current: AppVersion("0.9.5")!)
    var checkFailure: Error?
    var downloadFailure: Error?
    var installFailure: Error?
    var stagedURL = URL(fileURLWithPath: "/Applications/.EchoForgeUpdate-test/EchoForge.app")

    private(set) var checkedIdentities: [AppBuildIdentity] = []
    private(set) var downloadedReleases: [PublishedRelease] = []
    private(set) var replacedApplications: [InstalledApplication] = []
    private(set) var installedStagedApps: [URL] = []

    func check(current: AppBuildIdentity) async throws -> UpdateAvailability {
        checkedIdentities.append(current)
        if let checkFailure { throw checkFailure }
        return availability
    }

    func downloadAndVerify(
        _ release: PublishedRelease,
        replacing application: InstalledApplication,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        downloadedReleases.append(release)
        replacedApplications.append(application)
        if let downloadFailure { throw downloadFailure }
        return stagedURL
    }

    func installAndRelaunch(stagedApp: URL, replacing application: InstalledApplication) async throws {
        installedStagedApps.append(stagedApp)
        if let installFailure { throw installFailure }
    }
}

// MARK: - Fixtures

extension PublishedRelease {
    /// A release that has already passed `UpdateManifest.parse`, for tests about
    /// what happens *after* it did.
    static func fixture(
        version: String = "1.0.0",
        checksum: Bool = true
    ) -> PublishedRelease {
        PublishedRelease(
            version: AppVersion(version)!,
            tag: version,
            notes: "Notes for \(version)",
            downloadURL: URL(
                string:
                    "https://github.com/hsuanchenlin/EchoForge/releases/download/\(version)/EchoForge.dmg"
            )!,
            sizeInBytes: 11_371_721,
            checksumURL: checksum
                ? URL(
                    string:
                        "https://github.com/hsuanchenlin/EchoForge/releases/download/\(version)/EchoForge.dmg.sha256"
                )!
                : nil)
    }
}

extension Recording {
    static func fixture(
        transcription: String = "hello there",
        timestamp: Date = Date(timeIntervalSince1970: 1_756_000_000),
        status: RecordingStatus = .completed,
        provenance: RecordingProvenance = .dictation,
        rawTranscription: String? = nil
    ) -> Recording {
        var recording = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            timestamp: timestamp,
            fileName: "00000000-0000-0000-0000-0000000000AA.wav",
            transcription: transcription,
            duration: 3.5,
            status: status,
            progress: 1,
            sourceFileURL: nil,
            rawTranscription: rawTranscription)
        recording.provenance = provenance
        return recording
    }
}

/// Runs one command line against an environment and hands back everything it
/// produced.
///
/// Every test goes through `CommandRouter.execute` rather than calling a command
/// directly, so the argument parsing, the `--help` short-circuit, the JSON
/// switch and the exit code are all part of what is being asserted.
func runCLI(
    _ arguments: [String], environment: CLIEnvironment
) async -> CommandRouter.Execution {
    await CommandRouter.execute(arguments: arguments, environment: environment)
}

extension CommandRouter.Execution {
    /// The stdout document parsed back, so a test asserts the shape a script
    /// would actually see rather than a string this suite rendered itself.
    func decodedJSON(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = Data(output.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("stdout was not a JSON object: \(output)", file: file, line: line)
            return [:]
        }
        return object
    }

    /// The same, for a failure - which is written to stderr in both modes.
    func decodedErrorJSON(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = Data(diagnostic.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("stderr was not a JSON object: \(diagnostic)", file: file, line: line)
            return [:]
        }
        return object
    }
}
