import XCTest
@testable import OpenSuperWhisper

/// The release package, and the checks that stand between it and a user.
///
/// v0.3.0 was signed correctly by every measure the project had - `codesign
/// --verify --deep --strict` passed on the published DMG - and could not start
/// on any Mac, because hardened runtime turns on library validation and an
/// ad-hoc signature (all this fork can produce) carries no Team ID for it to
/// match. `Scripts/verify_release_package.sh` is what now decides whether an
/// artifact is publishable, and `LaunchDiagnostics` is what lets it start the
/// build safely. These tests pin the halves to each other.
final class ReleasePackagingTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OpenSuperWhisperTests
            .deletingLastPathComponent() // repository root
    }

    private func source(of relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - LaunchDiagnostics

    func testReportsOnlyTheBundlesOwnImages() {
        let report = LaunchDiagnostics.report(
            loadedImagePaths: [
                "/Applications/EchoForge.app/Contents/MacOS/EchoForge",
                "/Applications/EchoForge.app/Contents/Frameworks/libomp.dylib",
                "/usr/lib/libSystem.B.dylib",
                "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            ],
            bundlePath: "/Applications/EchoForge.app"
        )

        XCTAssertEqual(
            report.bundleImages,
            ["Contents/Frameworks/libomp.dylib", "Contents/MacOS/EchoForge"],
            "The report exists to say what the *package* loaded; system libraries would bury that."
        )
    }

    func testReportMatchesImagesDespiteADoubledSeparator() {
        // dyld hands back whatever path the process was launched with, and
        // $TMPDIR on macOS ends in a slash - so the verifier, which copies the
        // bundle there before starting it, produces exactly this.
        let report = LaunchDiagnostics.report(
            loadedImagePaths: ["/Applications/EchoForge.app/Contents/Frameworks/libomp.dylib"],
            bundlePath: "/Applications//EchoForge.app"
        )

        XCTAssertEqual(report.bundleImages, ["Contents/Frameworks/libomp.dylib"])
    }

    func testReportMatchesImagesReachedThroughASymlinkedPath() throws {
        // The other half of the same problem: $TMPDIR is under /var, which is a
        // symlink to /private/var, and dyld reports the two sides
        // inconsistently. Built on the file system rather than from string
        // literals because symlink resolution only happens for paths that exist
        // - which loaded images, by definition, are.
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LaunchDiagnostics-\(UUID().uuidString)")
        let frameworks = root.appendingPathComponent("EchoForge.app/Contents/Frameworks")
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let dylib = frameworks.appendingPathComponent("libomp.dylib")
        try Data().write(to: dylib)

        let symlinkedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LaunchDiagnostics-link-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: symlinkedRoot, withDestinationURL: root)
        defer { try? fileManager.removeItem(at: symlinkedRoot) }

        let report = LaunchDiagnostics.report(
            loadedImagePaths: [dylib.path],
            bundlePath: symlinkedRoot.appendingPathComponent("EchoForge.app").path
        )

        XCTAssertEqual(report.bundleImages, ["Contents/Frameworks/libomp.dylib"])
    }

    func testReportIgnoresABundleThatMerelySharesAPrefix() {
        let report = LaunchDiagnostics.report(
            loadedImagePaths: ["/Applications/EchoForgeHelper.app/Contents/MacOS/EchoForgeHelper"],
            bundlePath: "/Applications/EchoForge.app"
        )

        XCTAssertEqual(report.bundleImages, [])
    }

    func testLaunchCheckIsOffUnlessAskedFor() {
        // Anything looser would mean an ordinary launch could exit instead of
        // starting the app.
        XCTAssertFalse(
            ProcessInfo.processInfo.environment.keys.contains(LaunchDiagnostics.environmentKey),
            "Nothing in the test environment should be setting the launch-check variable."
        )
        XCTAssertFalse(LaunchDiagnostics.isRequested)
    }

    // MARK: - The app and the verifier have to agree

    func testVerifierUsesTheLaunchCheckContractTheAppImplements() throws {
        let verifier = try source(of: "Scripts/verify_release_package.sh")

        XCTAssertTrue(
            verifier.contains("readonly LAUNCH_CHECK_ENV=\"\(LaunchDiagnostics.environmentKey)\""),
            "The verifier would start the app normally and time out."
        )
        XCTAssertTrue(
            verifier.contains("readonly LAUNCH_CHECK_MARKER=\"\(LaunchDiagnostics.successMarker)\""),
            "The marker is how the verifier tells a real launch check from a build that predates it."
        )
    }

    func testTheEntryPointRunsTheLaunchCheckBeforeTheApp() throws {
        // The check has to happen before SwiftUI builds the App value, whose
        // stored properties reach AppPreferences and MicrophoneService: an
        // operator verifying a release must not have their preferences migrated
        // or their model cache written to by the build they are checking.
        let entryPoint = try source(of: "OpenSuperWhisper/OpenSuperWhisperApp.swift")

        let launchCheck = entryPoint.range(of: "LaunchDiagnostics.runAndExit()")
        let appStart = entryPoint.range(of: "OpenSuperWhisperApp.main()")
        XCTAssertNotNil(launchCheck, "The entry point no longer runs the launch check.")
        XCTAssertNotNil(appStart, "The entry point no longer starts the app.")
        if let launchCheck, let appStart {
            XCTAssertTrue(launchCheck.upperBound < appStart.lowerBound)
        }
    }

    // MARK: - The release path cannot skip verification

    func testReleaseBuildVerifiesWhatItProduces() throws {
        let build = try source(of: "Scripts/build_release.sh")

        XCTAssertTrue(
            build.contains("Scripts/verify_release_package.sh"),
            "A release build that does not verify its artifact is how v0.3.0 shipped."
        )
        XCTAssertTrue(
            build.contains("ENABLE_HARDENED_RUNTIME=${HARDENED_RUNTIME}"),
            "Hardened runtime has to be chosen by signing mode, not inherited from the project."
        )
        XCTAssertTrue(
            build.contains("HARDENED_RUNTIME=\"NO\""),
            "The ad-hoc path must turn hardened runtime off; with it on the app cannot load its own dylibs."
        )
    }

    // MARK: - A release is thin

    /// The release must not carry model weights.
    ///
    /// Every release from v0.3.0 to v0.5.2 shipped a 222 MB disk image whose
    /// 212 MB was one bundled speech model - and models live in Application
    /// Support and survive an app replacement, so an updating user downloaded
    /// those megabytes, verified them, mounted them, copied them into place and
    /// never read them. Measured across v0.5.1 to v0.5.2: two files changed, the
    /// binary and `Info.plist`, and 94% of the bundle's bytes were identical.
    ///
    /// Asserted in three places because it can regress in three ways: the build
    /// phase could start packaging again, the verifier could stop checking, and
    /// the release script could stop asking it to.
    func testTheBuildPackagesNoStarterModelUnlessAskedTo() throws {
        let script = try source(of: "Scripts/package_starter_model.sh")

        XCTAssertTrue(
            script.contains("ECHOFORGE_BUNDLE_STARTER_MODEL:-0") && script.contains("!= \"1\""),
            "Bundling weights has to be opt-in; the default is a thin app."
        )
    }

    func testTheReleaseBuildRefusesAnArtifactCarryingWeights() throws {
        let build = try source(of: "Scripts/build_release.sh")
        let verifier = try source(of: "Scripts/verify_release_package.sh")

        XCTAssertTrue(
            build.contains("--forbid-starter-model"),
            "A release has to be verified as thin, not merely built thin."
        )
        XCTAssertTrue(
            verifier.contains("forbid_starter_model"),
            "The verifier is what decides whether an artifact is publishable."
        )
    }

    /// The other half: an offline install medium is still buildable, and
    /// verifies the opposite way.
    func testAnOfflineMediumCanStillBeBuiltAndIsVerifiedAsCarryingWeights() throws {
        let build = try source(of: "Scripts/build_release.sh")

        XCTAssertTrue(build.contains("--require-starter-model"), build)
        XCTAssertTrue(build.contains("ECHOFORGE_BUNDLE_STARTER_MODEL"), build)
    }

    func testMakeReleaseGoesThroughTheOneBuildPath() throws {
        let makeRelease = try source(of: "make_release.sh")
        let notarize = try source(of: "notarize_app.sh")

        XCTAssertTrue(makeRelease.contains("Scripts/build_release.sh"))
        XCTAssertTrue(notarize.contains("Scripts/build_release.sh"))
    }

    // MARK: - The verifier itself

    /// Runs the verifier against synthesised bundles that are broken in the ways
    /// a release can be broken - including v0.3.0's exact defect, rebuilt from
    /// first principles with clang so it needs no models, submodules or network.
    ///
    /// The script never starts a fixture that cannot start, which is what keeps
    /// this test silent: a bundle that dies in dyld is killed by SIGABRT, and
    /// running that from a test suite put a crash report and a "Fixture.app quit
    /// unexpectedly" dialog on the screen for every execution. The script's own
    /// header says how each case is asserted instead.
    func testVerifierRejectsUnlaunchablePackages() throws {
        let script = repositoryRoot
            .appendingPathComponent("Scripts/tests/verify_release_package_test.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "verify_release_package_test.sh failed:\n\(log)")
    }
}
