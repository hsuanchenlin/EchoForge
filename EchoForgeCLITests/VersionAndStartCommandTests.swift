import XCTest

/// `version` has one job and one way to get it wrong: reporting a number that
/// did not come from the bundle the user is running.
final class VersionCommandTests: XCTestCase {

    func testItReportsTheInstalledBundlesOwnVersionAndTheToolsSeparately() async throws {
        let environment = CLITestEnvironment.withInstalledApp(version: "0.9.4", build: "34")
        let execution = await runCLI(["version"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertTrue(execution.output.contains("Kongweh 0.9.4 (34)"))
        // The tool's own version is 9.9.9 in the fixture precisely so a test
        // that confused the two would fail loudly.
        XCTAssertTrue(execution.output.contains("cli: 9.9.9 (99)"))
    }

    func testWithNoAppInstalledItFailsWithItsOwnExitCode() async throws {
        let execution = await runCLI(["version"], environment: CLITestEnvironment.empty())

        XCTAssertEqual(execution.exitCode, .appNotFound)
        XCTAssertTrue(execution.output.isEmpty, "a failure must not write to stdout")
        XCTAssertTrue(execution.diagnostic.contains("No Kongweh app is installed"))
    }

    /// The version comes from whichever bundle was resolved, so `--app` reports
    /// that copy rather than the one in `/Applications`.
    func testAppOverrideReportsTheOverriddenCopy() async throws {
        var environment = CLITestEnvironment.withInstalledApp(version: "0.9.4")
        let fileSystem = environment.fileSystem as! FakeFileSystem
        fileSystem.directories.insert("/tmp/build/EchoForge.app")
        fileSystem.bundles["/tmp/build/EchoForge.app"] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "99",
            "CFBundleIdentifier": AppDataLocation.storageIdentifier,
        ]
        environment.fileSystem = fileSystem

        let execution = await runCLI(
            ["version", "--app", "/tmp/build/EchoForge.app", "--json"], environment: environment)

        let json = try execution.decodedJSON()
        let app = json["app"] as? [String: Any]
        XCTAssertEqual(app?["version"] as? String, "1.2.3")
        XCTAssertEqual(app?["path"] as? String, "/tmp/build/EchoForge.app")
    }

    /// A relative `--app` would resolve against whatever directory a script
    /// happened to be in, which is not a thing to allow for a flag that also
    /// names what an update replaces.
    func testRelativeAppPathIsRefused() async throws {
        let execution = await runCLI(
            ["version", "--app", "build/EchoForge.app"],
            environment: CLITestEnvironment.withInstalledApp())

        XCTAssertEqual(execution.exitCode, .usage)
        XCTAssertTrue(execution.diagnostic.contains("absolute path"))
    }

    /// Pointing `--app` at some other application must not report its version as
    /// Kongweh's - nor, later, have an update installed over it.
    func testAppOverrideRefusesABundleThatIsNotKongweh() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let fileSystem = environment.fileSystem as! FakeFileSystem
        fileSystem.directories.insert("/Applications/TextEdit.app")
        fileSystem.bundles["/Applications/TextEdit.app"] = [
            "CFBundleShortVersionString": "1.19",
            "CFBundleVersion": "1",
            "CFBundleIdentifier": "com.apple.TextEdit",
        ]
        environment.fileSystem = fileSystem

        let execution = await runCLI(
            ["version", "--app", "/Applications/TextEdit.app"], environment: environment)

        XCTAssertEqual(execution.exitCode, .appNotFound)
        XCTAssertTrue(execution.diagnostic.contains("com.apple.TextEdit"))
    }

    func testHelpAndVersionNeedNothingInstalled() async throws {
        for arguments in [["--help"], ["version", "--help"], ["--version"], []] {
            let execution = await runCLI(arguments, environment: CLITestEnvironment.empty())
            XCTAssertEqual(execution.exitCode, .success, "\(arguments) should succeed with nothing installed")
            XCTAssertFalse(execution.output.isEmpty, "\(arguments) printed nothing")
        }
    }
}

/// `start`'s whole contract is "one Kongweh, and tell me which one".
final class StartCommandTests: XCTestCase {

    func testItLaunchesTheResolvedAppWhenNothingIsRunning() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let launcher = FakeLauncher()
        environment.launcher = launcher

        let execution = await runCLI(["start"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertEqual(launcher.launched.map(\.path), ["/Applications/EchoForge.app"])
        XCTAssertTrue(execution.output.contains("Started Kongweh 0.9.5"))
    }

    func testItStartsNothingWhenACopyIsAlreadyRunning() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let launcher = FakeLauncher()
        let running = FakeRunningApplications()
        running.copies = [
            RunningCopy(
                processIdentifier: 4050,
                bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
                launchDate: nil)
        ]
        environment.launcher = launcher
        environment.runningApplications = running

        let execution = await runCLI(["start", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success, "already running is not a failure")
        XCTAssertTrue(launcher.launched.isEmpty, "it must not launch a second copy")
        let json = try execution.decodedJSON()
        XCTAssertEqual(json["started"] as? Bool, false)
        XCTAssertEqual(json["alreadyRunning"] as? Bool, true)
        XCTAssertEqual(json["processIdentifier"] as? Int, 4050)
    }

    /// The case `--app` makes possible: a test copy is named while the installed
    /// one is running. macOS would activate the running copy rather than start
    /// the named one, so the command says so instead of appearing to do nothing.
    func testItRefusesToStartATestCopyWhileAnotherIsRunning() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let fileSystem = environment.fileSystem as! FakeFileSystem
        fileSystem.directories.insert("/tmp/build/EchoForge.app")
        fileSystem.bundles["/tmp/build/EchoForge.app"] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "99",
            "CFBundleIdentifier": AppDataLocation.storageIdentifier,
        ]
        environment.fileSystem = fileSystem
        let launcher = FakeLauncher()
        let running = FakeRunningApplications()
        running.copies = [
            RunningCopy(
                processIdentifier: 4050,
                bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
                launchDate: nil)
        ]
        environment.launcher = launcher
        environment.runningApplications = running

        let execution = await runCLI(
            ["start", "--app", "/tmp/build/EchoForge.app"], environment: environment)

        XCTAssertTrue(launcher.launched.isEmpty)
        XCTAssertTrue(execution.output.contains("/Applications/EchoForge.app"))
        XCTAssertTrue(
            execution.output.contains("not the copy you named"),
            "it has to say the running copy is a different one: \(execution.output)")
    }

    /// The decision on its own, without a filesystem or a bundle.
    func testDecisionPrefersTheCopyAtTheRequestedPath() {
        let requested = URL(fileURLWithPath: "/tmp/EchoForge.app")
        let other = RunningCopy(
            processIdentifier: 1, bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
            launchDate: nil)
        let match = RunningCopy(processIdentifier: 2, bundleURL: requested, launchDate: nil)

        XCTAssertEqual(StartDecision.decide(requested: requested, running: []), .start)
        XCTAssertEqual(
            StartDecision.decide(requested: requested, running: [other, match]),
            .alreadyRunning(match))
        XCTAssertEqual(
            StartDecision.decide(requested: requested, running: [other]),
            .alreadyRunning(other))
    }

    func testALaunchFailureIsReportedRatherThanReportedAsSuccess() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let launcher = FakeLauncher()
        launcher.failure = CLIError("macOS refused to open it.")
        environment.launcher = launcher

        let execution = await runCLI(["start"], environment: environment)

        XCTAssertEqual(execution.exitCode, .failure)
        XCTAssertTrue(execution.diagnostic.contains("macOS refused"))
    }
}
