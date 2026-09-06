import Foundation

/// A Kongweh app that is actually on this disk, with the version it actually
/// declares.
///
/// The only way to make one is `ApplicationLocator`, which reads the bundle. So
/// there is no path in this tool where a version comes from anywhere but the
/// `Info.plist` of a real bundle - not from the git checkout it was built in,
/// not from the tool's own version, not from a cached answer. `echoforge
/// version` reporting the repository's `MARKETING_VERSION` while the user runs
/// a months-old copy from `/Applications` is exactly the failure this shape
/// rules out.
struct InstalledApplication: Equatable {
    let url: URL
    let identity: AppBuildIdentity

    /// Whether this bundle is the app whose data directory this tool reads.
    ///
    /// False for a differently-identified bundle at `--app`, which is refused:
    /// installing an update over it, or reporting its version as Kongweh's,
    /// would both be wrong.
    var isKongweh: Bool { identity.bundleIdentifier == AppDataLocation.storageIdentifier }

    var json: JSONValue {
        .object([
            ("path", .string(url.path)),
            ("version", .string(identity.marketingVersion)),
            ("build", .string(identity.buildNumber)),
            ("bundleIdentifier", .string(identity.bundleIdentifier)),
        ])
    }
}

/// Where the tool looks for the app, in order, and what it refuses.
///
/// The order is fixed and documented rather than clever. LaunchServices could
/// answer "where is the app with this bundle identifier" and is deliberately
/// not asked: it returns whichever copy it saw last, including one in
/// `~/Downloads` or inside a mounted disk image, so the same command would
/// resolve differently on two Macs and differently on one Mac over time. A
/// script that updates an app has to know which app it is about to replace.
enum ApplicationLocator {

    /// `/Applications/EchoForge.app`, then `~/Applications/EchoForge.app`.
    ///
    /// `EchoForge.app` and not `Kongweh.app`: the product is called Kongweh but
    /// the bundle on disk carries the release identity (see the naming section
    /// of `AGENTS.md`), and that is the name `UpdateInstaller` swaps in too.
    static func defaultLocations(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/EchoForge.app"),
            homeDirectory.appendingPathComponent("Applications/EchoForge.app"),
        ]
    }

    /// Resolves the app this command is about.
    ///
    /// - Parameter override: the `--app` value. Must be an absolute path, so a
    ///   relative one cannot resolve against whatever directory a script
    ///   happened to be in when it replaced an application.
    static func locate(
        override: String?,
        in environment: CLIEnvironment
    ) throws -> InstalledApplication {
        if let override {
            return try locateOverride(override, in: environment)
        }
        for candidate in environment.defaultApplicationLocations {
            if let application = read(candidate, in: environment) {
                guard application.isKongweh else {
                    throw CLIError(
                        "\(candidate.path) is \(application.identity.bundleIdentifier), not Kongweh.",
                        exitCode: .appNotFound)
                }
                return application
            }
        }
        throw CLIError(
            "No Kongweh app is installed. Looked in: "
                + environment.defaultApplicationLocations.map(\.path).joined(separator: ", ")
                + ". Pass --app <absolute-path> to name a copy somewhere else.",
            exitCode: .appNotFound)
    }

    private static func locateOverride(
        _ override: String, in environment: CLIEnvironment
    ) throws -> InstalledApplication {
        guard override.hasPrefix("/") else {
            throw CLIError(
                "--app takes an absolute path; got \"\(override)\".", exitCode: .usage)
        }
        let url = URL(fileURLWithPath: override).standardizedFileURL
        guard environment.fileSystem.isDirectory(at: url) else {
            throw CLIError("There is no app bundle at \(url.path).", exitCode: .appNotFound)
        }
        guard let application = read(url, in: environment) else {
            throw CLIError(
                "\(url.path) has no readable Info.plist, so it is not an app bundle.",
                exitCode: .appNotFound)
        }
        // A `--app` copy is a *test copy of this app*, which is what the flag is
        // for. Pointing it at some other application and being told its version,
        // or worse having an update installed over it, is not a thing to allow.
        guard application.isKongweh else {
            throw CLIError(
                "\(url.path) identifies itself as \(application.identity.bundleIdentifier), "
                    + "not \(AppDataLocation.storageIdentifier).",
                exitCode: .appNotFound)
        }
        return application
    }

    /// Reads a bundle's identity, or nil when there is nothing readable there.
    ///
    /// `AppBuildIdentity.current(bundle:)` is the app's own reader, used here so
    /// the two versions of "what does this build call itself" cannot disagree -
    /// including its `0.0.0` fallback, which is what a bundle with no
    /// `CFBundleShortVersionString` honestly is.
    static func read(_ url: URL, in environment: CLIEnvironment) -> InstalledApplication? {
        guard environment.fileSystem.isDirectory(at: url),
            let info = environment.fileSystem.infoDictionary(forBundleAt: url)
        else { return nil }
        let identity = AppBuildIdentity(
            marketingVersion: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info["CFBundleVersion"] as? String ?? "0",
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "")
        return InstalledApplication(url: url, identity: identity)
    }

    /// The running copies of Kongweh, whatever path they were started from.
    ///
    /// Matched on the bundle identifier because that is what macOS matches on
    /// too: a second copy at another path does not become a second running app,
    /// it activates the first. `StartCommand` reports the path it found for
    /// exactly that reason.
    static func runningCopies(in environment: CLIEnvironment) -> [RunningCopy] {
        environment.runningApplications
            .runningCopies(ofBundleIdentifier: AppDataLocation.storageIdentifier)
    }
}
