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
private struct FailingReleaseMetadataFetcher: ReleaseMetadataFetching {
    func fetchLatestReleaseMetadata() async throws -> Data {
        throw UpdateManifestError.noPublishedRelease
    }
}
