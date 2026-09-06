import XCTest

/// `update`'s two questions: does it route the decision correctly, and does it
/// route a *refusal* correctly.
///
/// The verification rules themselves are not re-tested here - they are
/// `EchoForgeCore`'s and `UpdateCheckerTests` asserts them. What these tests hold
/// is the part this tool added: that it asks before replacing anything, that
/// `--yes` skips only the question, that a verdict against the downloaded bytes
/// is reported as its own exit code, and that no path here reaches the real
/// updater at all.
final class UpdateCommandTests: XCTestCase {

    private func environment(
        installed: String = "0.9.4",
        running: [RunningCopy] = [],
        confirm: @escaping (String) -> Bool? = { _ in nil }
    ) -> (CLIEnvironment, FakeUpdates) {
        var environment = CLITestEnvironment.withInstalledApp(version: installed, build: "34")
        let updates = FakeUpdates()
        let applications = FakeRunningApplications()
        applications.copies = running
        environment.updates = updates
        environment.runningApplications = applications
        environment.confirm = confirm
        return (environment, updates)
    }

    // MARK: - check

    func testCheckComparesTheInstalledAppsVersionRatherThanTheTools() async throws {
        let (environment, updates) = self.environment(installed: "0.9.4")
        updates.availability = .available(.fixture(version: "1.0.0"))

        let execution = await runCLI(["update", "check", "--json"], environment: environment)

        // The tool's own version in the fixture is 9.9.9, so passing the wrong
        // identity would have produced "up to date".
        XCTAssertEqual(updates.checkedIdentities.first?.marketingVersion, "0.9.4")
        let json = try execution.decodedJSON()
        XCTAssertEqual(json["updateAvailable"] as? Bool, true)
        XCTAssertEqual(json["latest"] as? String, "1.0.0")
        XCTAssertEqual(json["publishesChecksum"] as? Bool, true)
    }

    func testUpToDateIsASuccessThatSaysSo() async throws {
        let (environment, updates) = self.environment()
        updates.availability = .upToDate(current: AppVersion("0.9.4")!)

        let execution = await runCLI(["update", "check", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertEqual(try execution.decodedJSON()["updateAvailable"] as? Bool, false)
    }

    /// A bare `update` is a check, because checking cannot do harm and
    /// installing can.
    func testBareUpdateChecksRatherThanInstalls() async throws {
        let (environment, updates) = self.environment()
        updates.availability = .available(.fixture())

        _ = await runCLI(["update"], environment: environment)

        XCTAssertTrue(updates.downloadedReleases.isEmpty)
        XCTAssertTrue(updates.installedStagedApps.isEmpty)
    }

    func testAFailedCheckIsReportedInItsOwnWords() async throws {
        let (environment, updates) = self.environment()
        updates.checkFailure = UpdateManifestError.untrustedDownloadHost("evil.example")

        let execution = await runCLI(["update", "check"], environment: environment)

        XCTAssertEqual(execution.exitCode, .failure)
        XCTAssertTrue(execution.diagnostic.contains("evil.example"))
    }

    // MARK: - install

    func testInstallWithoutYesAsksAndDoesNothingWhenTheAnswerIsNo() async throws {
        var asked: [String] = []
        let (environment, updates) = self.environment(confirm: {
            asked.append($0)
            return false
        })
        updates.availability = .available(.fixture(version: "1.0.0"))

        let execution = await runCLI(["update", "install", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .cancelled)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].contains("Replace Kongweh 0.9.4"))
        XCTAssertTrue(updates.downloadedReleases.isEmpty, "nothing may be downloaded before consent")
        XCTAssertEqual(try execution.decodedJSON()["reason"] as? String, "cancelled")
    }

    /// No terminal means no answer, and no answer means no.
    func testNoTerminalMeansNo() async throws {
        let (environment, updates) = self.environment(confirm: { _ in nil })
        updates.availability = .available(.fixture())

        let execution = await runCLI(["update", "install"], environment: environment)

        XCTAssertEqual(execution.exitCode, .cancelled)
        XCTAssertTrue(updates.downloadedReleases.isEmpty)
    }

    func testYesSkipsTheQuestionAndInstalls() async throws {
        var asked = 0
        let (environment, updates) = self.environment(confirm: { _ in
            asked += 1
            return true
        })
        updates.availability = .available(.fixture(version: "1.0.0"))

        let execution = await runCLI(["update", "install", "--yes", "--json"], environment: environment)

        XCTAssertEqual(asked, 0, "--yes must not ask")
        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertEqual(updates.downloadedReleases.map(\.version.description), ["1.0.0"])
        XCTAssertEqual(updates.installedStagedApps, [updates.stagedURL])
        XCTAssertEqual(try execution.decodedJSON()["installed"] as? Bool, true)
    }

    /// What must be replaced is the resolved bundle, and it must be checked
    /// against *its own* identity - not the tool's, which is what `Bundle.main`
    /// would have given the shared installer.
    func testItReplacesTheResolvedBundleAndChecksAgainstItsIdentity() async throws {
        let (environment, updates) = self.environment(confirm: { _ in true })
        updates.availability = .available(.fixture())

        _ = await runCLI(["update", "install", "--yes"], environment: environment)

        let replaced = try XCTUnwrap(updates.replacedApplications.first)
        XCTAssertEqual(replaced.url.path, "/Applications/EchoForge.app")
        XCTAssertEqual(replaced.identity.bundleIdentifier, AppDataLocation.storageIdentifier)
    }

    /// The swap renames the bundle, so the app has to be gone - and the refusal
    /// has to come before the download rather than after it.
    func testInstallRefusesWhileTheAppIsRunningAndBeforeDownloading() async throws {
        let (environment, updates) = self.environment(
            running: [
                RunningCopy(
                    processIdentifier: 4050,
                    bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
                    launchDate: nil)
            ],
            confirm: { _ in true })
        updates.availability = .available(.fixture())

        let execution = await runCLI(["update", "install", "--yes", "--json"], environment: environment)

        XCTAssertNotEqual(execution.exitCode, .success)
        XCTAssertTrue(updates.downloadedReleases.isEmpty, "it must refuse before downloading")
        XCTAssertEqual(try execution.decodedErrorJSON()["reason"] as? String, "appRunning")
    }

    func testInstallWithNothingNewerDoesNothing() async throws {
        let (environment, updates) = self.environment(confirm: { _ in true })
        updates.availability = .upToDate(current: AppVersion("0.9.4")!)

        let execution = await runCLI(["update", "install", "--yes", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertTrue(updates.downloadedReleases.isEmpty)
        XCTAssertEqual(try execution.decodedJSON()["reason"] as? String, "upToDate")
    }

    // MARK: - Verification routing

    /// The distinction a script must be able to make: bytes that failed a check
    /// are not a connection that dropped, and retrying will not fix them.
    func testAVerdictAgainstTheBytesGetsTheVerificationExitCode() async throws {
        for refusal: UpdateInstallError in [
            .checksumMismatch(expected: "aaa", found: "bbb"),
            .wrongBundleIdentifier(found: "com.example.other"),
            .wrongVersion(expected: "1.0.0", found: "0.1.0"),
            .signatureRejected("code object is not signed at all"),
            .unexpectedSize(expected: 10, received: 20),
        ] {
            let (environment, updates) = self.environment(confirm: { _ in true })
            updates.availability = .available(.fixture(version: "1.0.0"))
            updates.downloadFailure = refusal

            let execution = await runCLI(
                ["update", "install", "--yes", "--json"], environment: environment)

            XCTAssertEqual(
                execution.exitCode, .verificationFailed,
                "\(refusal) should be a verification failure")
            XCTAssertEqual(
                try execution.decodedErrorJSON()["reason"] as? String, "verificationFailed")
            XCTAssertTrue(updates.installedStagedApps.isEmpty, "nothing may be installed after a refusal")
        }
    }

    /// And the ones that are *not* a verdict on the bytes must not be reported
    /// as one: a dropped connection is worth retrying, a bad checksum is not.
    func testATransportFailureIsNotAVerificationFailure() async throws {
        for failure: UpdateInstallError in [
            .downloadFailed("the network went away"),
            .checksumUnavailable("the sidecar could not be read"),
        ] {
            let (environment, updates) = self.environment(confirm: { _ in true })
            updates.availability = .available(.fixture())
            updates.downloadFailure = failure

            let execution = await runCLI(
                ["update", "install", "--yes", "--json"], environment: environment)

            XCTAssertEqual(execution.exitCode, .failure, "\(failure) should not be a verification failure")
            XCTAssertEqual(try execution.decodedErrorJSON()["reason"] as? String, "downloadFailed")
        }
    }

    func testCancellationDuringADownloadIsCancelledRatherThanFailed() async throws {
        let (environment, updates) = self.environment(confirm: { _ in true })
        updates.availability = .available(.fixture())
        updates.downloadFailure = CancellationError()

        let execution = await runCLI(["update", "install", "--yes"], environment: environment)

        XCTAssertEqual(execution.exitCode, .cancelled)
    }

    /// There is no `--force`, and there must never be one: the flag that skips a
    /// question is not the flag that skips a check.
    func testThereIsNoFlagThatSkipsAVerification() {
        let spec = UpdateCommand.spec
        for forbidden in ["force", "skip-verification", "insecure", "no-verify", "allow-untrusted"] {
            XCTAssertFalse(spec.switches.contains(forbidden), "--\(forbidden) exists")
            XCTAssertFalse(spec.valueOptions.contains(forbidden), "--\(forbidden) exists")
        }
    }

    func testInstallRequiresAnAppToReplace() async throws {
        var environment = CLITestEnvironment.empty()
        environment.updates = FakeUpdates()
        let execution = await runCLI(["update", "install", "--yes"], environment: environment)

        XCTAssertEqual(execution.exitCode, .appNotFound)
    }
}
