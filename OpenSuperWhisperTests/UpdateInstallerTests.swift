import XCTest

@testable import OpenSuperWhisper

/// Records every command it was asked to run, and answers each of `hdiutil
/// attach`, `codesign` and `ditto` well enough that `downloadAndVerify` can be
/// driven end to end without a real disk image: `attach` synthesizes a fake
/// mounted `EchoForge.app` (with an `Info.plist` matching the requested
/// identity) at the mount point it was asked for, `codesign` reports success,
/// and `ditto` performs a real file copy so the returned staged bundle exists
/// on disk for assertions.
private final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Invocation {
        let executable: String
        let arguments: [String]
    }

    var bundleIdentifier = AppBuildIdentity.current().bundleIdentifier
    var version = "0.3.0"
    /// When set, `launchDetached` throws it, standing in for the swap script
    /// never starting.
    var launchFailure: Error?

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return _invocations
    }

    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        lock.lock()
        _invocations.append(Invocation(executable: executable, arguments: arguments))
        lock.unlock()

        switch executable {
        case "/usr/bin/hdiutil" where arguments.first == "attach":
            if let mountIndex = arguments.firstIndex(of: "-mountpoint") {
                let mountedApp = URL(fileURLWithPath: arguments[mountIndex + 1])
                    .appendingPathComponent("EchoForge.app", isDirectory: true)
                let contents = mountedApp.appendingPathComponent("Contents", isDirectory: true)
                try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let info: [String: Any] = [
                    "CFBundleIdentifier": bundleIdentifier,
                    "CFBundleShortVersionString": version,
                ]
                if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
                    try? data.write(to: contents.appendingPathComponent("Info.plist"))
                }
            }
            return (0, "")
        case "/usr/bin/ditto":
            if arguments.count == 2 {
                try? FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
            }
            return (0, "")
        default:
            return (0, "")
        }
    }

    func launchDetached(_ executable: String, _ arguments: [String]) throws {
        lock.lock()
        _invocations.append(Invocation(executable: executable, arguments: arguments))
        let failure = launchFailure
        lock.unlock()
        if let failure {
            throw failure
        }
    }
}

/// Records that the app was asked to quit instead of actually quitting the
/// test runner.
@MainActor
private final class SpyTerminator: AppTerminating {
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}

/// Answers every request with canned bytes, so a real network call is never
/// made in these tests.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseData = Data()
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Staging a downloaded update never leaves a leaked bundle behind, in the
/// scenarios the app can actually observe: a previous attempt that crashed or
/// quit before install (`removeStaleStagingDirectories`), and a `UpdateViewModel`
/// that abandons its own `.readyToInstall` state.
final class UpdateInstallerStagingTests: XCTestCase {

    private var workDirectory: URL!
    private var installedApp: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installedApp = workDirectory.appendingPathComponent("EchoForge.app")
        try? FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    @MainActor
    func testRemovesStaleStagingDirectoriesButLeavesTheInstalledAppAlone() throws {
        let stale = workDirectory.appendingPathComponent(".EchoForgeUpdate-crashed-attempt")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let unrelated = workDirectory.appendingPathComponent("SomeOtherFile.txt")
        try Data().write(to: unrelated)

        let installer = UpdateInstaller(commandRunner: MockCommandRunner(), installedAppURL: installedApp)
        installer.removeStaleStagingDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func release(sizeInBytes: Int) -> PublishedRelease {
        PublishedRelease(
            version: AppVersion("0.3.0")!,
            tag: "v0.3.0",
            notes: "",
            downloadURL: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg")!,
            sizeInBytes: sizeInBytes
        )
    }

    /// A staged bundle from a download that was never installed must be swept
    /// away before the next one is staged - the only cleanup path that still
    /// runs after the app quit and relaunched.
    func testStagesANewDownloadAndSweepsAPriorAbandonedOne() async throws {
        let priorAttempt = workDirectory.appendingPathComponent(".EchoForgeUpdate-abandoned")
        try FileManager.default.createDirectory(at: priorAttempt, withIntermediateDirectories: true)

        StubURLProtocol.responseData = Data(repeating: 0x1, count: 42)
        StubURLProtocol.statusCode = 200
        let runner = MockCommandRunner()
        let installer = await UpdateInstaller(commandRunner: runner, installedAppURL: installedApp)

        let staged = try await installer.downloadAndVerify(
            release(sizeInBytes: 42),
            session: StubURLProtocol.makeSession()
        ) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: priorAttempt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(staged.deletingLastPathComponent().lastPathComponent.hasPrefix(".EchoForgeUpdate-"))
    }

    /// `UpdateViewModel` must discard a staged bundle the moment its
    /// `.readyToInstall` state is abandoned - by "Not Now" or by starting
    /// another download - rather than only when the app is next launched.
    @MainActor
    func testViewModelDiscardsTheStagedBundleWhenDismissed() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x2, count: 10)
        StubURLProtocol.statusCode = 200
        let installer = UpdateInstaller(commandRunner: MockCommandRunner(), installedAppURL: installedApp)
        let viewModel = UpdateViewModel(installer: installer)

        viewModel.download(release(sizeInBytes: 10), session: StubURLProtocol.makeSession())
        let stagedApp = try await waitForReadyToInstall(viewModel)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedApp.path))
        viewModel.dismissMessage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.deletingLastPathComponent().path))
    }

    @MainActor
    func testViewModelDiscardsThePreviousStagedBundleWhenDownloadingAgain() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x3, count: 10)
        StubURLProtocol.statusCode = 200
        let installer = UpdateInstaller(commandRunner: MockCommandRunner(), installedAppURL: installedApp)
        let viewModel = UpdateViewModel(installer: installer)

        viewModel.download(release(sizeInBytes: 10), session: StubURLProtocol.makeSession())
        let firstStagedApp = try await waitForReadyToInstall(viewModel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStagedApp.path))

        viewModel.download(release(sizeInBytes: 10), session: StubURLProtocol.makeSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStagedApp.deletingLastPathComponent().path))
        _ = try await waitForReadyToInstall(viewModel)
    }

    /// The failure "Install and Relaunch" was reported for, at the level it
    /// actually happened: pressing install used to leave `.readyToInstall`
    /// without arriving anywhere that owned the staged bundle, so the bundle was
    /// deleted while the detached swap script was still waiting for this process
    /// to exit. The script found nothing to move, its rollback trap restored the
    /// old bundle, and the user was reopened into the version they had just
    /// updated away from.
    @MainActor
    func testInstallingLeavesTheStagedBundleInPlaceForTheSwapScript() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x4, count: 10)
        StubURLProtocol.statusCode = 200
        let offered = release(sizeInBytes: 10)
        let installer = UpdateInstaller(commandRunner: MockCommandRunner(), installedAppURL: installedApp)
        let terminator = SpyTerminator()
        let viewModel = UpdateViewModel(installer: installer, terminator: terminator)

        viewModel.download(offered, session: StubURLProtocol.makeSession())
        let stagedApp = try await waitForReadyToInstall(viewModel)

        viewModel.installAndRelaunch(offered, stagedApp: stagedApp)

        XCTAssertEqual(viewModel.state, .installing(offered, stagedApp: stagedApp))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stagedApp.path),
            "the staged bundle belongs to the swap script from here on and must survive"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedApp.deletingLastPathComponent().path))
        XCTAssertEqual(terminator.terminateCount, 1, "the script is waiting on this process to exit")
    }

    /// The other half of the same rule: if the script never started there is no
    /// one to hand the bundle to, so it is discarded again rather than leaked.
    @MainActor
    func testAFailedInstallDiscardsTheStagedBundleAndDoesNotQuit() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x5, count: 10)
        StubURLProtocol.statusCode = 200
        let offered = release(sizeInBytes: 10)
        let runner = MockCommandRunner()
        let installer = UpdateInstaller(commandRunner: runner, installedAppURL: installedApp)
        let terminator = SpyTerminator()
        let viewModel = UpdateViewModel(installer: installer, terminator: terminator)

        viewModel.download(offered, session: StubURLProtocol.makeSession())
        let stagedApp = try await waitForReadyToInstall(viewModel)
        runner.launchFailure = UpdateInstallError.replacementFailed("no shell")

        viewModel.installAndRelaunch(offered, stagedApp: stagedApp)

        guard case .failed = viewModel.state else {
            return XCTFail("expected .failed, got \(viewModel.state)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.deletingLastPathComponent().path))
        XCTAssertEqual(terminator.terminateCount, 0, "nothing is going to replace the app, so do not quit")
    }

    @MainActor
    private func waitForReadyToInstall(_ viewModel: UpdateViewModel, timeout: TimeInterval = 5) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .readyToInstall(_, let stagedApp) = viewModel.state {
                return stagedApp
            }
            if case .failed(let message) = viewModel.state {
                XCTFail("update failed: \(message)")
                throw UpdateInstallError.replacementFailed(message)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for .readyToInstall")
        throw UpdateInstallError.replacementFailed("timeout")
    }
}

/// The detached swap script: it must roll the rename back and still relaunch
/// on failure, and it must leave a trail, since nothing else observes it once
/// this process has quit.
final class UpdateInstallerSwapScriptTests: XCTestCase {

    @MainActor
    func testWritesARollbackScriptThatLogsInsteadOfDiscardingItsOutput() throws {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installedApp = workDirectory.appendingPathComponent("EchoForge.app")
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        let staging = workDirectory.appendingPathComponent(".EchoForgeUpdate-test")
        let stagedApp = staging.appendingPathComponent("EchoForge.app")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let runner = MockCommandRunner()
        let installer = UpdateInstaller(commandRunner: runner, installedAppURL: installedApp)

        let scriptURL = try installer.installAndRelaunch(stagedApp: stagedApp)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("trap rollback_and_relaunch EXIT"), script)
        XCTAssertTrue(script.contains("mv \"$old\" \"$installed\""), script)
        XCTAssertTrue(script.contains("exec >>"), script)
        XCTAssertFalse(script.contains("/dev/null"), script)

        XCTAssertEqual(runner.invocations.last?.executable, "/bin/sh")
        XCTAssertEqual(runner.invocations.last?.arguments, [scriptURL.path])
    }

    /// The script removes the staging directory, so it must not live inside it:
    /// a `/bin/sh` deleting the directory it is being read from is not something
    /// to depend on, and staging must contain only the bundle being installed.
    @MainActor
    func testWritesTheSwapScriptOutsideTheStagingDirectory() throws {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installedApp = workDirectory.appendingPathComponent("EchoForge.app")
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        let staging = workDirectory.appendingPathComponent(".EchoForgeUpdate-test")
        let stagedApp = staging.appendingPathComponent("EchoForge.app")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let installer = UpdateInstaller(commandRunner: MockCommandRunner(), installedAppURL: installedApp)

        let scriptURL = try installer.installAndRelaunch(stagedApp: stagedApp)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        XCTAssertFalse(
            scriptURL.path.hasPrefix(staging.path),
            "the script must not sit in the directory it deletes: \(scriptURL.path)"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            ["EchoForge.app"]
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))
        // Its own cleanup, since nothing in this app is alive to do it.
        XCTAssertTrue(try String(contentsOf: scriptURL, encoding: .utf8).contains("rm -f \"$script\""))
    }
}
