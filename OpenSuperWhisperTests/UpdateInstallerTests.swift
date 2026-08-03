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
        lock.unlock()
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
            downloadURL: URL(string: "https://github.com/hsuanchenlin/OpenSuperWhisper/releases/download/v0.3.0/EchoForge.dmg")!,
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

        try installer.installAndRelaunch(stagedApp: stagedApp)

        let script = try String(contentsOf: staging.appendingPathComponent("install.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("trap rollback_and_relaunch EXIT"), script)
        XCTAssertTrue(script.contains("mv \"$old\" \"$installed\""), script)
        XCTAssertTrue(script.contains("exec >>"), script)
        XCTAssertFalse(script.contains("/dev/null"), script)

        XCTAssertEqual(runner.invocations.last?.executable, "/bin/sh")
    }
}
