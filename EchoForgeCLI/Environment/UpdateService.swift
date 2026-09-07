import Foundation

/// The tool's whole relationship with updating, as one seam.
///
/// It exists so `UpdateCommandTests` can drive every branch - up to date, an
/// offer declined, an offer accepted, a checksum that did not match - without a
/// network and without replacing the developer's own `/Applications` copy. What
/// it must never become is a *second updater*: the production implementation
/// below adds no rule of its own and skips none, it calls the same
/// `UpdateChecker` and `UpdateInstaller` the About pane calls.
protocol UpdateServicing {
    /// Asks GitHub whether there is a newer release than `current`.
    func check(current: AppBuildIdentity) async throws -> UpdateAvailability

    /// Downloads, verifies and stages a release, returning the staged bundle.
    /// Replaces nothing.
    func downloadAndVerify(
        _ release: PublishedRelease,
        replacing application: InstalledApplication,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL

    /// Swaps the staged bundle in. The caller must exit promptly afterwards:
    /// the script this starts is already waiting on this process to go away.
    func installAndRelaunch(
        stagedApp: URL, replacing application: InstalledApplication
    ) async throws
}

/// The production implementation: the app's own updater, pointed at a bundle
/// this process is not running out of.
///
/// Three values are injected that the app leaves to default, and each of them is
/// a place where `Bundle.main` would be the tool rather than Kongweh:
///
/// - `UpdateChecker(current:)` decides whether there is anything newer, and
///   comparing the *tool's* version against the release would offer an update
///   to whoever's numbers happened to be lower.
/// - `UpdateInstaller(installedAppURL:)` decides what gets replaced, and its
///   default is the bundle the running process lives in - which for a tool in
///   `/usr/local/bin` is not a bundle at all.
/// - `expectedBundleIdentifier` decides what the downloaded build must call
///   itself, and the tool's own identity is not it.
///
/// Everything else - the host allow-list, the exact asset name, the published
/// checksum, the signature, the version match, the staging and the swap script -
/// is `EchoForgeCore`'s, unchanged and unbypassed.
struct SharedUpdateService: UpdateServicing {
    let settings: UpdateDownloadSettings

    init(settings: UpdateDownloadSettings = UpdateDownloadSettings()) {
        self.settings = settings
    }

    func check(current: AppBuildIdentity) async throws -> UpdateAvailability {
        try await UpdateChecker(current: current).check()
    }

    func downloadAndVerify(
        _ release: PublishedRelease,
        replacing application: InstalledApplication,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws -> URL {
        let installer = await makeInstaller(for: application)
        return try await installer.downloadAndVerify(
            release, settings: settings, progress: progress)
    }

    func installAndRelaunch(
        stagedApp: URL, replacing application: InstalledApplication
    ) async throws {
        let installer = await makeInstaller(for: application)
        try await installer.installAndRelaunch(stagedApp: stagedApp)
    }

    /// A fresh installer per call, which is safe because the only state an
    /// `UpdateInstaller` keeps between calls is the disk image it has mounted
    /// and whether the app is quitting - both of which belong to a
    /// `downloadAndVerify` in flight, and neither of which `installAndRelaunch`
    /// reads. The staged bundle is passed between the two as a path.
    @MainActor
    private func makeInstaller(for application: InstalledApplication) -> UpdateInstaller {
        UpdateInstaller(
            installedAppURL: application.url,
            expectedBundleIdentifier: application.identity.bundleIdentifier)
    }
}
