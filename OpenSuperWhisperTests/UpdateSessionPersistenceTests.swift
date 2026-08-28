import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// An update outlives the pane that started it.
///
/// Settings builds only the tab that is showing (`SettingsSheetLayout`), so
/// every switch to Models or General destroys `AboutSettingsView` and every
/// switch back builds a new one. While the update lived in a `@StateObject` on
/// that view it had the view's lifetime: a glance at another tab abandoned the
/// transfer and the pane came back offering to start the 222 MB download again.
///
/// These tests hold that boundary from both sides - the pane may be torn down
/// and rebuilt at will, and the session underneath must not notice - and they
/// tear down a *real* `NSHostingView`, because the whole failure was a SwiftUI
/// lifetime and a test that never hosts the view cannot observe one.
@MainActor
final class UpdateSessionPersistenceTests: XCTestCase {

    private var workDirectory: URL!
    private var installedApp: URL!
    private var partialStore: PartialDownloadStore!
    private var server: LoopbackDownloadServer?

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

    // MARK: - The pane observes, it does not own

    /// The fix, stated as the property it produces: every `AboutSettingsView`
    /// draws from the same app-lifetime session, so the pane Settings rebuilds
    /// after a tab switch is looking at the update the previous one started.
    func testEveryAboutPaneDrawsFromTheOneAppLifetimeSession() {
        XCTAssertTrue(
            AboutSettingsView().viewModel === UpdateViewModel.shared,
            "the pane must observe the app's update session rather than make one of its own")
        XCTAssertTrue(
            AboutSettingsView().viewModel === AboutSettingsView().viewModel,
            "two panes that disagree about the session are two panes that disagree about the download")
    }

    /// The regression guard for the shape rather than the symptom. `@StateObject`
    /// is ownership, and ownership by a view Settings destroys on every tab
    /// switch is exactly what made a download disposable.
    func testNoViewOwnsTheUpdateSessionAsStateObject() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        guard let files = FileManager.default.enumerator(atPath: sources.path)?
            .allObjects as? [String]
        else {
            throw XCTSkip("Sources are not beside the tests: \(sources.path)")
        }

        var scanned = 0
        for file in files where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            scanned += 1
            for line in text.split(separator: "\n") where line.contains("@StateObject") {
                XCTAssertFalse(
                    line.contains("UpdateViewModel"),
                    "\(file) owns the update session as a @StateObject: \(line.trimmingCharacters(in: .whitespaces)). "
                        + "A pane Settings rebuilds on every tab switch must observe the session, not own it.")
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources, so it proved almost nothing")
    }

    /// The user's own sequence: press Download in About, switch to another tab,
    /// switch back. The rebuilt pane must be looking at the live transfer, and
    /// must say so in the words the card actually draws.
    func testAPaneRebuiltMidDownloadShowsTheDownloadRatherThanAnInvitationToStart() async throws {
        let release = try serve(.completing(bytes: 240_000, chunks: 24, pause: 0.04))
        let session = UpdateViewModel(installer: makeInstaller())

        var hosted = host(AboutSettingsView(viewModel: session))
        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilDownloading(session)

        // The tab switch.
        await switchAwayFromPane(&hosted)

        // …and the switch back. A brand new pane value, exactly as
        // `SettingsSheetLayout` builds it.
        var rebuilt = host(AboutSettingsView(viewModel: session))
        defer { closePane(&rebuilt) }

        guard case .downloading(let shown, let progress) = rebuilt.pane.viewModel.state else {
            return XCTFail("the rebuilt pane found \(rebuilt.pane.viewModel.state), not the live download")
        }
        XCTAssertEqual(shown, release)
        XCTAssertGreaterThan(progress.receivedBytes, 0)
        let line = UpdateCardView.statusText(for: rebuilt.pane.viewModel.state)
        XCTAssertTrue(line.contains("Downloading"), line)
        XCTAssertTrue(line.contains(DownloadProgressText.bytes(progress)), line)

        // And it is on the screen, not merely in the state.
        let drawn = try textDrawn(by: rebuilt)
        XCTAssertTrue(folded(drawn).contains("downloading"), "OCR read: \(drawn)")
        XCTAssertTrue(
            folded(drawn).contains("cancel"),
            "a live download the user can call off, not an offer to start one; OCR read: \(drawn)")
        XCTAssertFalse(
            folded(drawn).contains(folded("never checks or installs updates on its own")),
            "the rebuilt pane fell back to the idle explainer, which is the bug; OCR read: \(drawn)")
    }

    // MARK: - Teardown cancels nothing

    /// The headline requirement: the view going away must not take the transfer
    /// with it. The download is genuinely in flight when the hosting view is
    /// released - asserted, not assumed - and it has to reach a verified staged
    /// bundle anyway.
    func testTearingThePaneDownDoesNotCancelAnInFlightDownload() async throws {
        let release = try serve(.completing(bytes: 240_000, chunks: 24, pause: 0.04))
        let session = UpdateViewModel(installer: makeInstaller())

        var hosted = host(AboutSettingsView(viewModel: session))
        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilDownloading(session)

        await switchAwayFromPane(&hosted)

        let staged = try await waitForReadyToInstall(session)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.path),
            "the download the user started before switching tabs has to finish")
    }

    /// The other half: a download that has already finished leaves a verified
    /// bundle beside the app, and a tab switch is not a decision about it. The
    /// pane must come back offering "Install and Relaunch", with the bundle it
    /// names still on disk.
    func testTearingThePaneDownDoesNotDiscardAStagedBundle() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let session = UpdateViewModel(installer: makeInstaller())

        var hosted = host(AboutSettingsView(viewModel: session))
        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        let staged = try await waitForReadyToInstall(session)
        await switchAwayFromPane(&hosted)

        XCTAssertEqual(session.state, .readyToInstall(release, stagedApp: staged))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.path),
            "a verified bundle is not something a tab switch throws away")

        var rebuilt = host(AboutSettingsView(viewModel: session))
        defer { closePane(&rebuilt) }
        XCTAssertTrue(
            UpdateCardView.statusText(for: rebuilt.pane.viewModel.state).contains("downloaded and verified"),
            "the rebuilt pane must offer the install it already earned")

        let drawn = try textDrawn(by: rebuilt)
        XCTAssertTrue(
            folded(drawn).contains("installandrelaunch"),
            "the action button is the whole point of coming back to the pane; OCR read: \(drawn)")
    }

    /// Persistence has not quietly turned into a leak: the things that *are*
    /// decisions about a staged bundle still discard it. "Not Now" and starting
    /// another download are pinned in `UpdateInstallerStagingTests`; this is the
    /// third, a fresh check, which supersedes the release the bundle was for.
    func testStartingAFreshCheckStillDiscardsAStagedBundle() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let session = UpdateViewModel(
            checker: UpdateChecker(fetcher: FailingReleaseMetadataFetcher()),
            installer: makeInstaller())

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        let staged = try await waitForReadyToInstall(session)

        session.checkForUpdates()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
            "a check asks the question the staged bundle was the answer to")
    }

    // MARK: - Reopening Settings

    /// An app-lifetime session also outlives the question its answers were to.
    /// Reopening Settings hours later must not present a check from breakfast as
    /// though it had just run, nor offer a retry for a network fault that is long
    /// over.
    func testReopeningSettingsDropsAResultNobodyIsWaitingOn() async throws {
        let upToDate = UpdateViewModel(
            checker: UpdateChecker(
                fetcher: OlderReleaseMetadataFetcher(),
                current: AppBuildIdentity(
                    marketingVersion: "9.9.9", buildNumber: "1",
                    bundleIdentifier: AppBuildIdentity.current().bundleIdentifier)),
            installer: makeInstaller())
        upToDate.checkForUpdates()
        try await waitUntil(upToDate) { $0 == .upToDate }
        upToDate.settingsDidOpen()
        XCTAssertEqual(upToDate.state, .idle, "a stale 'you are up to date' answered nobody's question")

        let failed = UpdateViewModel(
            checker: UpdateChecker(fetcher: FailingReleaseMetadataFetcher()),
            installer: makeInstaller())
        failed.checkForUpdates()
        try await waitUntil(failed) { if case .failed = $0 { return true } else { return false } }
        failed.settingsDidOpen()
        XCTAssertEqual(failed.state, .idle, "a failure from a fault that is over is not worth reopening on")
    }

    /// The other half, and the one the whole change exists for: reopening
    /// Settings must not disturb work in flight or bytes already fetched.
    func testReopeningSettingsLeavesLiveWorkAlone() async throws {
        let release = try serve(.completing(bytes: 400_000, chunks: 40, pause: 0.05))
        let session = UpdateViewModel(installer: makeInstaller())

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilDownloading(session)

        session.settingsDidOpen()

        guard case .downloading = session.state else {
            return XCTFail("reopening Settings took the download down: \(session.state)")
        }
        session.prepareForTermination()
    }

    func testReopeningSettingsLeavesAStagedBundleAlone() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let session = UpdateViewModel(installer: makeInstaller())

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        let staged = try await waitForReadyToInstall(session)

        session.settingsDidOpen()

        XCTAssertEqual(session.state, .readyToInstall(release, stagedApp: staged))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.path),
            "reopening Settings threw away a verified bundle the user had already paid 222 MB for")
    }

    /// Reaching the session from Settings has the same constraint the quit path
    /// has: a user who never opens About must never end up with an updater.
    /// Read off the source, because the alternative is presenting a real sheet.
    func testSettingsReachesTheSessionWithoutCreatingOne() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Settings.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(
            text.contains("UpdateViewModel.sharedIfCreated?.settingsDidOpen()"),
            "nothing clears a stale check when the Settings sheet opens")
        XCTAssertFalse(
            text.contains("UpdateViewModel.shared."),
            "opening Settings must not be what constructs an updater for a user who "
                + "never opens About")
    }

    // MARK: - Quitting

    /// Quitting stands an in-flight transfer down rather than leaving a
    /// `URLSession` to call back into a process that is going away. The partial
    /// stays on disk, which is what makes the next launch a resume.
    func testQuittingStandsAnInFlightDownloadDownAndKeepsThePartial() async throws {
        let release = try serve(.completing(bytes: 400_000, chunks: 40, pause: 0.05))
        let session = UpdateViewModel(installer: makeInstaller())

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilDownloading(session)

        session.prepareForTermination()

        // Left to run, this transfer reaches `.readyToInstall` in about two
        // seconds. It must not, because it was called off.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        if case .readyToInstall = session.state {
            XCTFail("the download kept running after the app was told it was quitting")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partialStore.partialFile(for: release.version).path),
            "the bytes already fetched are what makes the next launch a resume rather than a restart")
    }

    /// Verification is the one stretch a quit cannot simply cancel: it runs as
    /// detached work whose result is awaited, and `applicationWillTerminate` can
    /// neither delay the exit nor await the `defer` that would unmount the image.
    /// So the detach has to have already happened by the time this call returns,
    /// not be scheduled to happen after it.
    func testQuittingDuringVerificationSynchronouslyDetachesTheDiskImage() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let runner = MockCommandRunner()
        runner.codesignDelay = 1
        let session = UpdateViewModel(installer: makeInstaller(runner))

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilCodesignStarts(runner)
        XCTAssertEqual(
            session.state, .verifying(release),
            "this test is only about the window the pane spends in .verifying")

        session.prepareForTermination()

        let mounted = try XCTUnwrap(mountPoint(from: runner))
        let detach = runner.invocations.first {
            $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "detach"
        }
        XCTAssertNotNil(
            detach,
            "the image was left mounted with no app to own it - the `defer` that would "
                + "have detached it never gets to run once the process exits")
        XCTAssertTrue(detach?.arguments.contains("-force") == true)
        XCTAssertEqual(detach?.arguments.dropFirst().first, mounted)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mounted),
            "the detach was issued but the image is still mounted, which is the state "
                + "this is supposed to rule out rather than the command that rules it out")
    }

    /// The window the previous round left open. Mounting a 222 MB image takes
    /// seconds the pane already spends in `.verifying`, and `hdiutil` is a child
    /// process, so it outlives the app: detaching while the attach is still
    /// running takes down nothing, and the attach then finishes and mounts an
    /// image the exiting process can no longer reach. The attach has to be
    /// stopped, not raced.
    func testQuittingWhileTheDiskImageIsStillMountingLeavesNothingMounted() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let runner = MockCommandRunner()
        runner.attachDelay = 0.5
        let session = UpdateViewModel(installer: makeInstaller(runner))

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilAttachStarts(runner)
        let mounted = try XCTUnwrap(mountPoint(from: runner))

        session.prepareForTermination()

        // Past the moment the un-terminated attach would have mounted it.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mounted),
            "the attach was left running and mounted the image after the app was gone")
    }

    /// The same leak reached from the other side: the last byte can land while
    /// the app is already going away, and the cancellation check sits *before*
    /// verification rather than inside it. Nothing may start mounting an image
    /// at that point.
    func testQuittingBeforeVerificationStartsNeverMountsTheImage() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let runner = MockCommandRunner()
        let installer = makeInstaller(runner)

        installer.prepareForTermination()
        _ = try? await installer.downloadAndVerify(
            release, settings: UpdateDownloadSettings(stallInterval: 30)
        ) { _ in }

        XCTAssertFalse(
            runner.invocations.contains {
                $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "attach"
            },
            "verification mounted a disk image after the app had been told it was quitting")
    }

    /// Pulling the image out from under a running `codesign` makes it fail, and
    /// that failure looks exactly like a signature verdict against the bytes -
    /// which is the one thing that deletes the 222 MB the next launch resumes
    /// from. A quit is not such a verdict.
    func testQuittingDuringVerificationKeepsTheDownloadedBytes() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let runner = MockCommandRunner()
        runner.codesignDelay = 0.5
        let session = UpdateViewModel(installer: makeInstaller(runner))

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        try await waitUntilCodesignStarts(runner)

        session.prepareForTermination()

        // The detach has already happened; this is the `codesign` that was
        // reading the image coming back to find it gone, which is the moment the
        // partial was being thrown away.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partialStore.partialFile(for: release.version).path),
            "the quit was read as a verdict against the bytes and threw the whole download away")
    }

    /// The bundle a user has already downloaded and verified survives the quit.
    /// Nothing here may delete it: the sweep that reclaims an abandoned one is
    /// `UpdateInstaller.removeStaleStagingDirectories`, and it runs before the
    /// next download is staged rather than during a quit.
    func testQuittingLeavesAStagedBundleAlone() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let session = UpdateViewModel(installer: makeInstaller())

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        let staged = try await waitForReadyToInstall(session)

        session.prepareForTermination()

        XCTAssertEqual(session.state, .readyToInstall(release, stagedApp: staged))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    /// The quit that matters most: the one "Install and Relaunch" starts. The
    /// detached swap script is at this moment waiting on this pid, and the
    /// staged bundle is the thing it is waiting to move.
    func testQuittingDuringAnInstallLeavesTheBundleForTheSwapScript() async throws {
        let release = try serve(.completing(bytes: 4_096, chunks: 1, pause: 0))
        let terminator = SpyTerminator()
        let session = UpdateViewModel(installer: makeInstaller(), terminator: terminator)

        session.download(release, settings: UpdateDownloadSettings(stallInterval: 30))
        let staged = try await waitForReadyToInstall(session)
        session.installAndRelaunch(release, stagedApp: staged)
        XCTAssertEqual(terminator.terminateCount, 1)

        session.prepareForTermination()

        XCTAssertEqual(session.state, .installing(release, stagedApp: staged))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.path),
            "deleting this is how 'Install and Relaunch' silently reopened the old version")
    }

    /// The delegate has to reach the session on the way out, and it has to do it
    /// without *creating* one: a user who never opened About has no updater, and
    /// quitting is not a reason to give them one. Read off the source, because
    /// the alternative is a test that quits the test runner.
    func testTheAppDelegateStandsTheSessionDownWithoutCreatingOne() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/OpenSuperWhisperApp.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(
            text.contains("func applicationWillTerminate("),
            "nothing tells the update session the app is going away")
        XCTAssertTrue(
            text.contains("UpdateViewModel.sharedIfCreated?.prepareForTermination()"),
            "quitting must stand the update session down through sharedIfCreated, "
                + "which cannot bring an updater into existence just by asking")
        XCTAssertFalse(
            text.contains("UpdateViewModel.shared."),
            "reaching the session through `shared` on the quit path constructs an updater "
                + "for every user, including the ones who never opened About")
    }

    // MARK: - Hosting

    /// A hosted pane and the offscreen window holding it, kept together so a
    /// test can put one on screen and take it away again in one move.
    private struct HostedPane {
        let pane: AboutSettingsView
        var hosting: NSHostingView<AboutSettingsView>?
        var window: NSWindow?
        /// Non-owning, so the teardown below can assert the view really went
        /// away rather than merely being unreferenced by the test.
        weak var released: NSHostingView<AboutSettingsView>?
    }

    /// Puts the pane in a real, never-shown window and lays it out, so SwiftUI
    /// builds its body exactly as Settings does.
    private func host(_ pane: AboutSettingsView) -> HostedPane {
        let hosting = NSHostingView(rootView: pane)
        hosting.frame = CGRect(x: 0, y: 0, width: 520, height: 460)
        // Opaque and light, so what is read back below does not depend on the
        // appearance the test host happened to inherit. The window is never
        // ordered front - `cacheDisplay` draws without it ever appearing.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return HostedPane(pane: pane, hosting: hosting, window: window, released: hosting)
    }

    /// The tab switch. Everything holding the pane is dropped and the view is
    /// asserted gone, because "the view was deallocated" is the premise every
    /// test here rests on - a pane that merely stopped being drawn would prove
    /// nothing about a download surviving one that was not.
    private func switchAwayFromPane(
        _ hosted: inout HostedPane, file: StaticString = #filePath, line: UInt = #line
    ) async {
        closePane(&hosted)
        // An `NSHostingView` built in this frame is still held by the enclosing
        // autorelease pool, which a synchronous test never drains. One suspension
        // is what actually lets it go, and letting it go is the point.
        await Task.yield()
        XCTAssertNil(
            hosted.released,
            "the hosting view is still alive, so this test is not observing a torn-down pane",
            file: file, line: line)
    }

    /// Drops the window and the view without asserting anything, for the pane a
    /// test is merely finished with rather than deliberately tearing down.
    private func closePane(_ hosted: inout HostedPane) {
        autoreleasepool {
            hosted.window?.contentView = NSView()
            hosted.window?.close()
            hosted.hosting = nil
            hosted.window = nil
        }
    }

    /// What the pane actually put on screen, read back out of its own pixels.
    ///
    /// The words are asserted elsewhere through `UpdateCardView.statusText`, the
    /// same composition the body draws; this is the layer that catches a state
    /// the pane holds but never renders - a blank card that every string-level
    /// assertion still passes. Same technique as `UpdateCardRenderTests`, which
    /// documents why `cacheDisplay` rather than `ImageRenderer`.
    private func textDrawn(by hosted: HostedPane) throws -> String {
        let view = try XCTUnwrap(hosted.hosting, "nothing is hosted to read")
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, "no image behind the pane")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Byte counts and version numbers are not prose; language correction
        // "fixes" them into words.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// OCR is trusted for glyphs, not for spacing.
    private func folded(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - Fixtures

    private func makeInstaller(_ runner: MockCommandRunner = MockCommandRunner()) -> UpdateInstaller {
        UpdateInstaller(
            commandRunner: runner,
            installedAppURL: installedApp,
            partialStore: partialStore,
            checksumFetcher: StubChecksumFetcher.unavailable
        )
    }

    /// Starts the scripted loopback server and returns the release it serves.
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

    private func waitUntilDownloading(_ session: UpdateViewModel, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .downloading(_, let progress) = session.state, progress.receivedBytes > 0 { return }
            if case .failed(let message, _) = session.state {
                return XCTFail("the download failed before it started: \(message)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for bytes to start arriving, state is \(session.state)")
    }

    private func waitUntilCodesignStarts(_ runner: MockCommandRunner, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runner.invocations.contains(where: { $0.executable == "/usr/bin/codesign" }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for verification to start")
    }

    private func waitUntil(
        _ session: UpdateViewModel,
        timeout: TimeInterval = 10,
        _ isSatisfied: (UpdateState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSatisfied(session.state) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out; the state is \(session.state)")
    }

    private func waitUntilAttachStarts(_ runner: MockCommandRunner, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runner.invocations.contains(where: {
                $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "attach"
            }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for the disk image to start mounting")
    }

    /// The mount point `hdiutil attach` was pointed at, so a detach can be
    /// checked against the image it is supposed to be taking down.
    private func mountPoint(from runner: MockCommandRunner) -> String? {
        guard let attach = runner.invocations.first(where: {
            $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "attach"
        }), let index = attach.arguments.firstIndex(of: "-mountpoint") else { return nil }
        return attach.arguments[index + 1]
    }

    private func waitForReadyToInstall(
        _ session: UpdateViewModel, timeout: TimeInterval = 20
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .readyToInstall(_, let stagedApp) = session.state { return stagedApp }
            if case .failed(let message, _) = session.state {
                XCTFail("update failed: \(message)")
                throw UpdateInstallError.replacementFailed(message)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for .readyToInstall, state is \(session.state)")
        throw UpdateInstallError.replacementFailed("timeout")
    }
}

/// A metadata fetcher that only ever fails, for a test that needs a *check* to
/// happen and does not care what it finds.
/// Answers with a real, well-formed release that is older than the build asking,
/// which is how a check reaches `.upToDate` without a network.
private struct OlderReleaseMetadataFetcher: ReleaseMetadataFetching {
    func fetchLatestReleaseMetadata() async throws -> Data {
        let document: [String: Any] = [
            "tag_name": "v0.3.0",
            "draft": false,
            "prerelease": false,
            "body": "notes",
            "assets": [[
                "name": "EchoForge.dmg",
                "browser_download_url":
                    "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.3.0/EchoForge.dmg",
                "size": 30_000_000,
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }
}

private struct FailingReleaseMetadataFetcher: ReleaseMetadataFetching {
    func fetchLatestReleaseMetadata() async throws -> Data {
        throw UpdateManifestError.noPublishedRelease
    }
}
