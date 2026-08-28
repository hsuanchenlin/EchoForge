import Combine
import Network
import XCTest

@testable import OpenSuperWhisper

/// Records every command it was asked to run, and answers each of `hdiutil
/// attach`, `codesign` and `ditto` well enough that `downloadAndVerify` can be
/// driven end to end without a real disk image: `attach` synthesizes a fake
/// mounted `EchoForge.app` (with an `Info.plist` matching the requested
/// identity) at the mount point it was asked for, `codesign` reports success,
/// and `ditto` performs a real file copy so the returned staged bundle exists
/// on disk for assertions.
final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Invocation {
        let executable: String
        let arguments: [String]
    }

    var bundleIdentifier = AppBuildIdentity.current().bundleIdentifier
    var version = "0.3.0"
    /// When set, `launchDetached` throws it, standing in for the swap script
    /// never starting.
    var launchFailure: Error?
    /// Makes `hdiutil attach` take real time, standing in for mounting a real
    /// 200 MB image - which is what the pane has to have something to say about.
    var attachDelay: TimeInterval = 0

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
            if attachDelay > 0 { Thread.sleep(forTimeInterval: attachDelay) }
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
final class SpyTerminator: AppTerminating {
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}

/// Answers every request with canned bytes, so a real network call is never
/// made in these tests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

/// Staging a downloaded update never leaves a leaked bundle behind, in the
/// scenarios the app can actually observe: a previous attempt that crashed or
/// quit before install (`removeStaleStagingDirectories`), and a `UpdateViewModel`
/// that abandons its own `.readyToInstall` state.
final class UpdateInstallerStagingTests: XCTestCase {

    private var workDirectory: URL!
    private var installedApp: URL!
    private var partialStore: PartialDownloadStore!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installedApp = workDirectory.appendingPathComponent("EchoForge.app")
        try? FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        partialStore = PartialDownloadStore(root: workDirectory.appendingPathComponent("partials", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    @MainActor
    private func makeInstaller(_ runner: MockCommandRunner = MockCommandRunner()) -> UpdateInstaller {
        UpdateInstaller(
            commandRunner: runner,
            installedAppURL: installedApp,
            partialStore: partialStore,
            checksumFetcher: StubChecksumFetcher.unavailable
        )
    }

    @MainActor
    func testRemovesStaleStagingDirectoriesButLeavesTheInstalledAppAlone() throws {
        let stale = workDirectory.appendingPathComponent(".EchoForgeUpdate-crashed-attempt")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let unrelated = workDirectory.appendingPathComponent("SomeOtherFile.txt")
        try Data().write(to: unrelated)

        let installer = makeInstaller()
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
        let installer = await makeInstaller(runner)

        let staged = try await installer.downloadAndVerify(
            release(sizeInBytes: 42),
            settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration())
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
        let installer = makeInstaller()
        let viewModel = UpdateViewModel(installer: installer)

        viewModel.download(release(sizeInBytes: 10), settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration()))
        let stagedApp = try await waitForReadyToInstall(viewModel)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedApp.path))
        viewModel.dismissMessage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.deletingLastPathComponent().path))
    }

    @MainActor
    func testViewModelDiscardsThePreviousStagedBundleWhenDownloadingAgain() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x3, count: 10)
        StubURLProtocol.statusCode = 200
        let installer = makeInstaller()
        let viewModel = UpdateViewModel(installer: installer)

        viewModel.download(release(sizeInBytes: 10), settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration()))
        let firstStagedApp = try await waitForReadyToInstall(viewModel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStagedApp.path))

        viewModel.download(release(sizeInBytes: 10), settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration()))
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
        let installer = makeInstaller()
        let terminator = SpyTerminator()
        let viewModel = UpdateViewModel(installer: installer, terminator: terminator)

        viewModel.download(offered, settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration()))
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
        let installer = makeInstaller(runner)
        let terminator = SpyTerminator()
        let viewModel = UpdateViewModel(installer: installer, terminator: terminator)

        viewModel.download(offered, settings: UpdateDownloadSettings(configuration: StubURLProtocol.makeConfiguration()))
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
            if case .failed(let message, _) = viewModel.state {
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

/// A loopback HTTP server that serves one scripted transfer: a size it
/// announces, an amount it actually delivers, in chunks, with a pause before
/// each. When it delivers less than it announced it then goes quiet and stays
/// quiet - no more bytes, no completion, no error - which is exactly the wedge
/// seen in the field.
///
/// A real socket rather than a `URLProtocol` stub, and the reason is the thing
/// under test. A stubbed protocol hands `URLSession` its body in one piece, so
/// `didWriteData` - the delegate callback the progress bar and the stall
/// watchdog both live on - fires once, at the end. Only a real connection makes
/// `URLSession` report progress the way it does against GitHub, and progress
/// arriving *incrementally* is the whole signal being asserted here.
final class LoopbackDownloadServer: @unchecked Sendable {
    struct Script {
        /// What `Content-Length` claims.
        var announcedBytes: Int
        /// What is actually sent. Less than `announcedBytes` means the transfer
        /// never completes.
        var deliveredBytes: Int
        var chunks: Int
        var pauseBeforeEachChunk: TimeInterval

        /// Whether the server honours `Range`. `false` is a real thing servers
        /// do - and the reason a resumed download has to notice a 200 and start
        /// again rather than appending a whole file to a partial one.
        var honoursRange = true

        /// What the server calls its copy. A resumed request carries the tag it
        /// recorded in `If-Range`; changing this between attempts is how "the
        /// asset was replaced under us" is simulated.
        var entityTag = "\"loopback-v1\""

        /// The byte written throughout the body. Changing it alongside
        /// `entityTag` gives the second version different *content*, so a test
        /// can prove which copy the bytes on disk came from.
        var fillByte: UInt8 = 0xAB

        static func completing(bytes: Int, chunks: Int, pause: TimeInterval) -> Script {
            Script(announcedBytes: bytes, deliveredBytes: bytes, chunks: chunks, pauseBeforeEachChunk: pause)
        }

        /// Starts, delivers a little, and then says nothing for as long as
        /// anyone waits.
        static func stalling(announcing bytes: Int, delivering delivered: Int) -> Script {
            Script(announcedBytes: bytes, deliveredBytes: delivered, chunks: 1, pauseBeforeEachChunk: 0)
        }
    }

    private let listener: NWListener
    private var _script: Script
    /// Replaced in place rather than by starting a second server, because a new
    /// server means a new port and therefore a new URL - and a resumed download
    /// is only allowed to resume against the URL its partial came from. A test
    /// about resuming has to be able to change the server's behaviour without
    /// changing where the asset lives.
    func setScript(_ script: Script) {
        lock.lock()
        _script = script
        lock.unlock()
    }

    private var script: Script {
        lock.lock()
        defer { lock.unlock() }
        return _script
    }

    private let queue = DispatchQueue(label: "LoopbackDownloadServer")
    private let deliveryQueue = DispatchQueue(label: "LoopbackDownloadServer.delivery", attributes: .concurrent)
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0

    init(script: Script) throws {
        self._script = script
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and returns only once the port is known, so a test never
    /// races the URL it is about to download from.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            throw UpdateInstallError.downloadFailed("the loopback server never became ready")
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    /// Where the asset appears to live.
    var assetURL: URL { URL(string: "http://127.0.0.1:\(port)/\(UpdateManifest.assetName)")! }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        readRequest(on: connection)
    }

    private func readRequest(on connection: NWConnection, received: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else { return }
            var accumulated = received
            if let data { accumulated.append(data) }
            let text = String(decoding: accumulated, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                return self.readRequest(on: connection, received: accumulated)
            }
            self.recordRequest(text)
            self.respond(on: connection, to: text)
        }
    }

    /// The headers of every request served, so a test can assert that a resume
    /// actually asked for a range rather than merely ending up with the right
    /// number of bytes.
    private(set) var requests: [String] = []

    private func recordRequest(_ text: String) {
        lock.lock()
        requests.append(text)
        lock.unlock()
    }

    /// `bytes=<n>-`, when the request asked for one.
    private func requestedRangeStart(in request: String) -> Int? {
        for line in request.split(separator: "\r\n") where line.lowercased().hasPrefix("range:") {
            guard let equals = line.firstIndex(of: "="), let dash = line.lastIndex(of: "-") else { continue }
            return Int(line[line.index(after: equals)..<dash])
        }
        return nil
    }

    private func respond(on connection: NWConnection, to request: String) {
        let script = self.script
        let rangeStart = script.honoursRange ? requestedRangeStart(in: request) : nil
        deliveryQueue.async {
            let headers: String
            let firstByte: Int
            let bodyBytes: Int

            if let rangeStart {
                guard rangeStart < script.announcedBytes else {
                    // Asked for a range past the end: the answer is 416, and the
                    // client has to work out whether what it holds is the whole
                    // asset or something that cannot be part of it.
                    let refusal = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                        + "Content-Range: bytes */\(script.announcedBytes)\r\n"
                        + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(refusal.utf8), completion: .contentProcessed { _ in })
                    return
                }
                firstByte = rangeStart
                bodyBytes = max(0, min(script.deliveredBytes, script.announcedBytes - rangeStart))
                headers = "HTTP/1.1 206 Partial Content\r\n"
                    + "Content-Length: \(script.announcedBytes - rangeStart)\r\n"
                    + "Content-Range: bytes \(rangeStart)-\(script.announcedBytes - 1)/\(script.announcedBytes)\r\n"
                    + "ETag: \(script.entityTag)\r\n"
                    + "Accept-Ranges: bytes\r\n"
                    + "Content-Type: application/octet-stream\r\n"
                    + "Connection: close\r\n\r\n"
            } else {
                firstByte = 0
                bodyBytes = script.deliveredBytes
                headers = "HTTP/1.1 200 OK\r\n"
                    + "Content-Length: \(script.announcedBytes)\r\n"
                    + "ETag: \(script.entityTag)\r\n"
                    + "Accept-Ranges: bytes\r\n"
                    + "Content-Type: application/octet-stream\r\n"
                    + "Connection: close\r\n\r\n"
            }
            _ = firstByte
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })

            let chunkSize = max(1, bodyBytes / max(1, script.chunks))
            var sent = 0
            while sent < bodyBytes {
                if script.pauseBeforeEachChunk > 0 {
                    Thread.sleep(forTimeInterval: script.pauseBeforeEachChunk)
                }
                let size = min(chunkSize, bodyBytes - sent)
                connection.send(
                    content: Data(repeating: script.fillByte, count: size),
                    completion: .contentProcessed { _ in }
                )
                sent += size
            }
            // Deliberately no close and no further bytes when less was sent than
            // announced: the client is left waiting on a live connection that
            // will never say anything again.
        }
    }
}

/// The update download can no longer wedge silently.
///
/// A 0.5.0 install sat at "Downloading - 0%" indefinitely: no open connection,
/// no CPU, no bytes and no error, against `URLSession.shared`'s seven-day
/// resource timeout, so nothing was ever going to end it. These pin the four
/// things that answer that - progress while alive, failure when silent,
/// tolerance of slow-but-alive, and a way out by hand - with the watchdog
/// interval injected so they stay quick.
final class UpdateDownloadWatchdogTests: XCTestCase {

    private var workDirectory: URL!
    private var installedApp: URL!
    private var server: LoopbackDownloadServer!
    /// Partial downloads survive a failure, so they have to be written
    /// somewhere - and it must not be the developer's real Caches directory.
    private var partialStore: PartialDownloadStore!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installedApp = workDirectory.appendingPathComponent("EchoForge.app")
        try? FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        partialStore = PartialDownloadStore(root: workDirectory.appendingPathComponent("partials", isDirectory: true))
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    /// Starts the scripted server and returns the release it is serving.
    private func serve(_ script: LoopbackDownloadServer.Script) throws -> PublishedRelease {
        server?.stop()
        let server = try LoopbackDownloadServer(script: script)
        try server.start()
        self.server = server
        return PublishedRelease(
            version: AppVersion("0.3.0")!,
            tag: "v0.3.0",
            notes: "",
            downloadURL: server.assetURL,
            sizeInBytes: script.announcedBytes
        )
    }

    private func settings(stallInterval: TimeInterval) -> UpdateDownloadSettings {
        UpdateDownloadSettings(stallInterval: stallInterval)
    }

    @MainActor
    private func makeInstaller(
        _ runner: MockCommandRunner = MockCommandRunner(),
        checksumFetcher: ChecksumFetching = StubChecksumFetcher.unavailable
    ) -> UpdateInstaller {
        UpdateInstaller(
            commandRunner: runner,
            installedAppURL: installedApp,
            partialStore: partialStore,
            checksumFetcher: checksumFetcher
        )
    }

    /// The staging directories beside the installed app. The check used to be
    /// "the work directory contains only the app", which stopped being true when
    /// partial downloads gained somewhere to live - so it now names the thing it
    /// was always about.
    private func stagedBundleNames() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []
        return entries.filter { $0.hasPrefix(".EchoForgeUpdate-") }.sorted()
    }

    /// What is on disk for a release that has not finished downloading.
    private func partialBytes(for release: PublishedRelease) -> Int64 {
        let path = partialStore.partialFile(for: release.version).path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    /// (a) The bar moves *while* bytes are arriving, and the pane is told when
    /// the download gives way to verification.
    func testReportsProgressWhileTheTransferIsRunningAndThenVerification() async throws {
        let release = try serve(.completing(bytes: 512 * 1024, chunks: 8, pause: 0.05))
        let installer = await makeInstaller()

        let reports = ProgressRecorder()
        _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) {
            reports.record($0)
        }

        let fractions = reports.fractions
        XCTAssertTrue(
            fractions.contains { $0 > 0 && $0 < 1 },
            "expected progress during the transfer, got \(fractions)"
        )
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(reports.all.last, .verifying, "verification is what follows the bar filling")
    }

    /// (b) A transfer that goes quiet fails on the watchdog's own interval, and
    /// says what happened.
    func testAStalledTransferFailsWithinTheWatchdogInterval() async throws {
        let release = try serve(.stalling(announcing: 512 * 1024, delivering: 4 * 1024))
        let installer = await makeInstaller()

        let stallInterval: TimeInterval = 1
        let started = Date()
        do {
            _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: stallInterval)) { _ in }
            XCTFail("a transfer that delivered nothing for \(stallInterval)s must not succeed")
        } catch let error as UpdateInstallError {
            guard case .downloadFailed(let detail) = error else {
                return XCTFail("expected .downloadFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("stopped receiving data"), detail)
            XCTAssertTrue(
                error.errorDescription?.contains("could not be downloaded") == true,
                "the pane shows this string: \(error.errorDescription ?? "nil")"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), stallInterval + 4,
            "the watchdog must end it, not a URLSession timeout"
        )
        XCTAssertEqual(
            stagedBundleNames(), [],
            "a failed download stages nothing"
        )
        XCTAssertGreaterThan(
            partialBytes(for: release), 0,
            "what did arrive is kept, so the retry resumes rather than starting again"
        )
    }

    /// (c) The watchdog measures silence, not speed. This transfer takes several
    /// times the stall interval end to end and never once goes quiet for it, so
    /// it must complete - the regression a rate floor, or a bound on total
    /// transfer time, would introduce for anyone on a slow link.
    func testASlowButLiveTransferIsNotTreatedAsAStall() async throws {
        let release = try serve(.completing(bytes: 512 * 1024, chunks: 10, pause: 0.15))
        let installer = await makeInstaller()

        let staged = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 0.5)) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    /// (d) The user's own way out of the state the wedge left them in.
    @MainActor
    func testCancellingADownloadRestoresTheOfferAndStagesNothing() async throws {
        let offered = try serve(.stalling(announcing: 512 * 1024, delivering: 4 * 1024))
        let installer = makeInstaller()
        let viewModel = UpdateViewModel(installer: installer)

        // A long interval, so what ends this download is the press and nothing else.
        viewModel.download(offered, settings: settings(stallInterval: 60))
        try await waitUntil("the download is under way") {
            if case .downloading = viewModel.state { return true }
            return false
        }

        viewModel.cancelDownload()

        XCTAssertEqual(viewModel.state, .available(offered))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(viewModel.state, .available(offered), "a cancelled download must not report back")
        XCTAssertEqual(stagedBundleNames(), [], "a cancelled download stages nothing")
    }

    /// The stall reaches the user as a message they can act on, with the release
    /// still on offer - and taking that offer works.
    @MainActor
    func testAStalledDownloadFailsWithARetryableReleaseThatSucceedsOnRetry() async throws {
        let offered = try serve(.stalling(announcing: 512 * 1024, delivering: 4 * 1024))
        let installer = makeInstaller()
        let viewModel = UpdateViewModel(installer: installer)

        viewModel.download(offered, settings: settings(stallInterval: 1))
        try await waitUntil("the stall is reported", timeout: 10) {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message, let retryable) = viewModel.state else {
            return XCTFail("expected .failed, got \(viewModel.state)")
        }
        XCTAssertTrue(message.contains("stopped receiving data"), message)
        XCTAssertEqual(retryable, offered, "the pane has to be able to offer the same release again")

        // The same release, from a server that now behaves: the retry is a
        // press, not a reopened pane and another check.
        let recovered = try serve(.completing(bytes: 512 * 1024, chunks: 4, pause: 0))
        viewModel.download(recovered, settings: settings(stallInterval: 5))
        try await waitUntil("the retry lands", timeout: 10) {
            if case .readyToInstall = viewModel.state { return true }
            return false
        }
    }

    /// A slow verify is not a stuck download, and the pane has to say which one
    /// it is.
    @MainActor
    func testShowsVerifyingBetweenTheDownloadAndTheInstallOffer() async throws {
        let offered = try serve(.completing(bytes: 64 * 1024, chunks: 2, pause: 0))
        let runner = MockCommandRunner()
        runner.attachDelay = 0.3
        let installer = makeInstaller(runner)
        let viewModel = UpdateViewModel(installer: installer)

        var observed: [UpdateState] = []
        let subscription = viewModel.$state.sink { observed.append($0) }
        defer { subscription.cancel() }

        viewModel.download(offered, settings: settings(stallInterval: 5))
        try await waitUntil("the download is verified", timeout: 10) {
            if case .readyToInstall = viewModel.state { return true }
            return false
        }

        let verifyingIndex = observed.firstIndex { $0 == .verifying(offered) }
        let readyIndex = observed.firstIndex { if case .readyToInstall = $0 { return true } else { return false } }
        XCTAssertNotNil(verifyingIndex, "a slow verify must not be left looking like a download: \(observed)")
        XCTAssertLessThan(try XCTUnwrap(verifyingIndex), try XCTUnwrap(readyIndex))
    }

    // MARK: - Resuming

    /// The bytes a failed transfer left behind are what the next one starts
    /// from. Before this, a download that died at 95% of 212 MB was thrown away,
    /// so "Retry" meant starting again - and on a link bad enough to have caused
    /// the failure, it could never converge.
    func testAFailedTransferLeavesItsBytesForTheNextAttemptToResumeFrom() async throws {
        let total = 512 * 1024
        let delivered = 128 * 1024
        let release = try serve(.stalling(announcing: total, delivering: delivered))
        let installer = await makeInstaller()

        do {
            _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 1)) { _ in }
            XCTFail("the stalled transfer must not succeed")
        } catch {}

        XCTAssertEqual(
            partialBytes(for: release), Int64(delivered),
            "what arrived before the stall has to survive it"
        )

        // The same server, now behaving. It has to be the same one: a resume is
        // only allowed against the URL its partial came from, and a second
        // server would be a second port.
        server.setScript(.completing(bytes: total, chunks: 4, pause: 0))
        let reports = ProgressRecorder()
        _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) {
            reports.record($0)
        }

        let ranged = server.requests.filter { $0.lowercased().contains("range: bytes=") }
        XCTAssertEqual(ranged.count, 1, "the retry must ask for a range: \(server.requests)")
        XCTAssertTrue(
            ranged[0].contains("bytes=\(delivered)-"),
            "it must ask for exactly what is missing: \(ranged[0])"
        )
        XCTAssertEqual(
            reports.connectingReports.last?.receivedBytes, Int64(delivered),
            "the pane says what it is resuming from rather than starting at zero"
        )
        XCTAssertTrue(
            reports.receivedByteCounts.contains { $0 > Int64(delivered) },
            "progress continues from the partial rather than restarting"
        )
    }

    /// A server that ignores `Range` answers 200 with the whole asset. Appending
    /// that to a partial would produce a file of the right length made of the
    /// wrong bytes, which is the failure mode this whole design is arranged
    /// around.
    func testAServerThatIgnoresRangeStartsTheFileOverInsteadOfAppending() async throws {
        let total = 256 * 1024
        let delivered = 64 * 1024
        let release = try serve(.stalling(announcing: total, delivering: delivered))
        let installer = await makeInstaller()
        _ = try? await installer.downloadAndVerify(release, settings: settings(stallInterval: 1)) { _ in }
        XCTAssertEqual(partialBytes(for: release), Int64(delivered))

        var script = LoopbackDownloadServer.Script.completing(bytes: total, chunks: 4, pause: 0)
        script.honoursRange = false
        server.setScript(script)

        _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }
        // The size check inside `downloadAndVerify` is what would have caught an
        // append; reaching here at all means it wrote the file from the start.
    }

    /// `If-Range` exists for this: the asset was replaced between attempts, so
    /// the server sends the whole of the *new* one and the old prefix is
    /// discarded rather than spliced onto it.
    func testAReplacedAssetIsDownloadedWholeRatherThanSplicedOntoTheOldOne() async throws {
        let total = 256 * 1024
        var first = LoopbackDownloadServer.Script.stalling(announcing: total, delivering: 64 * 1024)
        first.entityTag = "\"v1\""
        first.fillByte = 0x11
        let served = try serve(first)
        // The digest of the *new* copy, whole. Splicing 64 KB of the old copy in
        // front of it would produce a file of exactly the right length and the
        // wrong contents, which only a checksum can tell apart - so this is what
        // the assertion is made of rather than a byte count.
        let expected = try FileDigest.sha256(of: try writeTemporaryFile(Data(repeating: 0x22, count: total)))
        let release = PublishedRelease(
            version: served.version, tag: served.tag, notes: served.notes,
            downloadURL: served.downloadURL, sizeInBytes: served.sizeInBytes,
            checksumURL: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg.sha256")!
        )
        let installer = await makeInstaller(
            MockCommandRunner(),
            checksumFetcher: StubChecksumFetcher(document: "\(expected)  EchoForge.dmg\n")
        )
        _ = try? await installer.downloadAndVerify(release, settings: settings(stallInterval: 1)) { _ in }
        XCTAssertEqual(partialBytes(for: release), 64 * 1024, "the old copy's prefix is on disk")

        // A different copy of the asset, with different content. A server
        // implementing `If-Range` answers 200 rather than 206 when its copy has
        // changed, which is what `honoursRange = false` stands in for here.
        var second = LoopbackDownloadServer.Script.completing(bytes: total, chunks: 2, pause: 0)
        second.entityTag = "\"v2\""
        second.fillByte = 0x22
        second.honoursRange = false
        server.setScript(second)

        let staged = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    /// Cancelling is not the same as failing: the point of stopping a download
    /// is to get on with something else, and the bytes are still good.
    @MainActor
    func testCancellingKeepsThePartialSoTheNextPressResumes() async throws {
        let offered = try serve(.completing(bytes: 512 * 1024, chunks: 32, pause: 0.05))
        let viewModel = UpdateViewModel(installer: makeInstaller())

        viewModel.download(offered, settings: settings(stallInterval: 60))
        try await waitUntil("some bytes have arrived") {
            if case .downloading(_, let progress) = viewModel.state { return progress.receivedBytes > 0 }
            return false
        }
        viewModel.cancelDownload()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertGreaterThan(
            partialBytes(for: offered), 0,
            "a cancelled download that threw its bytes away would make the next press start over"
        )
    }

    // MARK: - Checksums

    /// A release that publishes a digest gets checked against it, and a
    /// mismatch is refused - along with the bytes that produced it, which are
    /// not something to resume onto.
    func testADownloadThatDoesNotMatchThePublishedChecksumIsRefusedAndDiscarded() async throws {
        let served = try serve(.completing(bytes: 64 * 1024, chunks: 2, pause: 0))
        let release = PublishedRelease(
            version: served.version, tag: served.tag, notes: served.notes,
            downloadURL: served.downloadURL, sizeInBytes: served.sizeInBytes,
            checksumURL: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg.sha256")!
        )
        let wrongDigest = String(repeating: "a", count: 64)
        let fetcher = StubChecksumFetcher(document: "\(wrongDigest)  EchoForge.dmg\n")
        let installer = await makeInstaller(MockCommandRunner(), checksumFetcher: fetcher)

        do {
            _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }
            XCTFail("a download that does not match the published digest must not be installed")
        } catch let error as UpdateInstallError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
        }

        XCTAssertEqual(fetcher.requests.count, 1)
        XCTAssertEqual(
            partialBytes(for: release), 0,
            "bytes that failed a checksum are not something to resume onto"
        )
    }

    /// The digest that matches installs, and the file it was computed over is
    /// the one that was downloaded.
    func testADownloadThatMatchesThePublishedChecksumIsInstalled() async throws {
        let served = try serve(.completing(bytes: 64 * 1024, chunks: 2, pause: 0))
        let release = PublishedRelease(
            version: served.version, tag: served.tag, notes: served.notes,
            downloadURL: served.downloadURL, sizeInBytes: served.sizeInBytes,
            checksumURL: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg.sha256")!
        )
        // The loopback server fills the body with one repeated byte, so the
        // digest is computable here without downloading anything first.
        let expected = try FileDigest.sha256(of: try writeTemporaryFile(Data(repeating: 0xAB, count: 64 * 1024)))
        let fetcher = StubChecksumFetcher(document: "\(expected)  EchoForge.dmg\n")
        let installer = await makeInstaller(MockCommandRunner(), checksumFetcher: fetcher)

        let staged = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    /// Releases up to v0.5.1 publish no sidecar, and those users have to be able
    /// to update to a build that does.
    func testAReleaseWithNoPublishedChecksumStillInstalls() async throws {
        let release = try serve(.completing(bytes: 64 * 1024, chunks: 2, pause: 0))
        XCTAssertNil(release.checksumURL)
        let fetcher = StubChecksumFetcher(document: nil)
        let installer = await makeInstaller(MockCommandRunner(), checksumFetcher: fetcher)

        _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }

        XCTAssertTrue(fetcher.requests.isEmpty, "nothing is fetched when nothing is published")
    }

    /// A sidecar that exists and cannot be read fails the install rather than
    /// quietly skipping the check - which is a downgrade anyone who can make one
    /// HTTP request fail could choose for us. It costs one press, because the
    /// bytes survive and the retry resumes.
    func testAnUnreadableChecksumFailsRatherThanBeingSkipped() async throws {
        let served = try serve(.completing(bytes: 64 * 1024, chunks: 2, pause: 0))
        let release = PublishedRelease(
            version: served.version, tag: served.tag, notes: served.notes,
            downloadURL: served.downloadURL, sizeInBytes: served.sizeInBytes,
            checksumURL: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg.sha256")!
        )
        let installer = await makeInstaller(
            MockCommandRunner(),
            checksumFetcher: StubChecksumFetcher(document: "this is not a checksum document")
        )

        do {
            _ = try await installer.downloadAndVerify(release, settings: settings(stallInterval: 5)) { _ in }
            XCTFail("an unreadable sidecar must not be treated as no sidecar")
        } catch let error as UpdateInstallError {
            guard case .checksumUnavailable = error else {
                return XCTFail("expected .checksumUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(
            partialBytes(for: release), Int64(64 * 1024),
            "a check that could not run has not found the bytes wanting, and the retry re-verifies them"
        )
    }

    private func writeTemporaryFile(_ data: Data) throws -> URL {
        let url = workDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting until \(what)")
    }
}

/// Collects what `downloadAndVerify` reported, from whichever thread it
/// reported on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [UpdateProgress] = []

    func record(_ progress: UpdateProgress) {
        lock.lock()
        _all.append(progress)
        lock.unlock()
    }

    var all: [UpdateProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _all
    }

    var fractions: [Double] {
        all.compactMap { if case .downloading(let progress) = $0 { return progress.fraction } else { return nil } }
    }

    /// Every byte count the pane was told about, which is what it now renders
    /// instead of a percentage.
    var receivedByteCounts: [Int64] {
        all.compactMap {
            if case .downloading(let progress) = $0 { return progress.receivedBytes } else { return nil }
        }
    }

    var connectingReports: [DownloadProgress] {
        all.compactMap { if case .connecting(let progress) = $0 { return progress } else { return nil } }
    }
}
