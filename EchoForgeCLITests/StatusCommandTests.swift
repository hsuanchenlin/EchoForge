import XCTest

/// `status`'s contract is that it never turns "I could not read that" into a
/// value. Every test here is a way that could go wrong.
final class StatusCommandTests: XCTestCase {

    func testItReportsTheAppAndTheProcessSeparately() async throws {
        var environment = CLITestEnvironment.withInstalledApp(version: "0.9.4", build: "34")
        let running = FakeRunningApplications()
        running.copies = [
            RunningCopy(
                processIdentifier: 4050,
                bundleURL: URL(fileURLWithPath: "/Applications/EchoForge.app"),
                launchDate: Date(timeIntervalSince1970: 1_756_000_000))
        ]
        environment.runningApplications = running

        let json = try await runCLI(["status", "--json"], environment: environment).decodedJSON()

        XCTAssertEqual((json["app"] as? [String: Any])?["version"] as? String, "0.9.4")
        XCTAssertEqual((json["app"] as? [String: Any])?["installed"] as? Bool, true)
        let process = json["process"] as? [String: Any]
        XCTAssertEqual(process?["running"] as? Bool, true)
        XCTAssertEqual(process?["processIdentifier"] as? Int, 4050)
        XCTAssertNotNil(process?["launchedAt"] as? String)
    }

    /// An app that is not installed is a fact about this Mac, not a failure -
    /// the rest of the report is about the user's data, which outlives it.
    func testAMissingAppIsReportedRatherThanThrown() async throws {
        let execution = await runCLI(["status", "--json"], environment: CLITestEnvironment.empty())

        XCTAssertEqual(execution.exitCode, .success)
        let json = try execution.decodedJSON()
        XCTAssertEqual((json["app"] as? [String: Any])?["installed"] as? Bool, false)
        XCTAssertEqual((json["process"] as? [String: Any])?["running"] as? Bool, false)
    }

    /// A named `--app` is different: if it resolves to nothing, that is a typo.
    func testANamedAppThatResolvesToNothingIsAFailure() async throws {
        let execution = await runCLI(
            ["status", "--app", "/nowhere/EchoForge.app"], environment: CLITestEnvironment.empty())

        XCTAssertEqual(execution.exitCode, .appNotFound)
    }

    /// The limitation, stated in the output rather than hidden.
    func testLiveRecordingStateIsReportedAsUnavailableAndNeverAsFalse() async throws {
        let execution = await runCLI(
            ["status", "--json"], environment: CLITestEnvironment.withInstalledApp())

        let recording = try execution.decodedJSON()["recording"] as? [String: Any]
        XCTAssertEqual(recording?["available"] as? Bool, false)
        XCTAssertTrue((recording?["reason"] as? String ?? "").contains("no local interface"))
        // What must not be there: a claim either way about whether it is
        // recording right now.
        XCTAssertNil(recording?["recording"])
        XCTAssertNil(recording?["isRecording"])
    }

    func testAnUnreadableHistoryIsUnavailableRatherThanZero() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let history = FakeHistory()
        history.failure = CLIError("No history database.", exitCode: .sourceUnavailable)
        environment.history = history

        let execution = await runCLI(["status", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success, "one unreadable section must not fail the report")
        let activity = try execution.decodedJSON()["activity"] as? [String: Any]
        XCTAssertEqual(activity?["available"] as? Bool, false)
        XCTAssertTrue(activity?["recordings"] is NSNull, "an unreadable count must not read as 0")
        XCTAssertTrue(activity?["inFlight"] is NSNull)
    }

    func testAnUnreadablePreferencesDomainIsUnavailableRatherThanNoEngine() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        environment.preferences = FakePreferences(isReadable: false, values: [:])

        let execution = await runCLI(["status", "--json"], environment: environment)

        let engine = try execution.decodedJSON()["engine"] as? [String: Any]
        XCTAssertEqual(engine?["available"] as? Bool, false)
        XCTAssertTrue(engine?["selected"] is NSNull)
    }

    /// The gap between the two engine values is the thing worth seeing.
    func testItReportsTheChosenEngineAndTheOneThatLastLoaded() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        environment.preferences = FakePreferences(
            isReadable: true,
            values: [
                PreferenceKeys.selectedEngine: "sensevoice",
                PreferenceKeys.lastReadyEngine: "whisper",
                PreferenceKeys.pendingEnginePreparation: "sensevoice",
                PreferenceKeys.whisperLanguage: "zh",
            ])

        let execution = await runCLI(["status", "--json"], environment: environment)

        let engine = try execution.decodedJSON()["engine"] as? [String: Any]
        XCTAssertEqual(engine?["selected"] as? String, "sensevoice")
        XCTAssertEqual(engine?["lastReady"] as? String, "whisper")
        XCTAssertEqual(engine?["preparing"] as? String, "sensevoice")
        XCTAssertEqual(engine?["dictationLanguage"] as? String, "zh")

        // And the text rendering says it too, because the gap between the two is
        // what somebody debugging "why is it still using Whisper" is looking for.
        let readable = await runCLI(["status"], environment: environment)
        XCTAssertTrue(
            readable.output.contains("selected sensevoice"), readable.output)
        XCTAssertTrue(readable.output.contains("last ready whisper"), readable.output)
    }

    func testInFlightRowsAreCountedFromTheDatabase() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let history = FakeHistory()
        history.page = HistoryPage(
            rows: [
                Recording.fixture(status: .completed),
                Recording.fixture(status: .transcribing),
                Recording.fixture(status: .pending),
            ],
            totalMatching: 3,
            databasePath: "/fake.sqlite")
        environment.history = history

        let activity = try await runCLI(["status", "--json"], environment: environment)
            .decodedJSON()["activity"] as? [String: Any]

        XCTAssertEqual(activity?["recordings"] as? Int, 3)
        XCTAssertEqual(activity?["inFlight"] as? Int, 2)
    }

    /// A model root that is not there is `exists: false` with the path, not a
    /// missing section - so the reader can see where it looked.
    func testModelRootsReportWhereTheyLookedEvenWhenEmpty() async throws {
        let execution = await runCLI(
            ["status", "--json"], environment: CLITestEnvironment.withInstalledApp())

        let models = try XCTUnwrap(execution.decodedJSON()["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        for root in models {
            XCTAssertEqual(root["exists"] as? Bool, false)
            XCTAssertFalse((root["path"] as? String ?? "").isEmpty)
        }
    }

    func testModelsAreListedWhenTheyAreOnDisk() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let fileSystem = environment.fileSystem as! FakeFileSystem
        let whisper = AppDataLocation.whisperModelsDirectory().path
        fileSystem.directories.insert(whisper)
        fileSystem.files["\(whisper)/ggml-large-v3-turbo.bin"] = Data(repeating: 0, count: 1024)
        environment.fileSystem = fileSystem

        let execution = await runCLI(["status", "--json"], environment: environment)

        let models = try XCTUnwrap(execution.decodedJSON()["models"] as? [[String: Any]])
        let whisperRoot = try XCTUnwrap(models.first { $0["label"] as? String == "whisper" })
        XCTAssertEqual(whisperRoot["exists"] as? Bool, true)
        XCTAssertEqual(whisperRoot["entries"] as? [String], ["ggml-large-v3-turbo.bin"])
        XCTAssertEqual(whisperRoot["topLevelBytes"] as? Int, 1024)
    }

    func testAnUnreadableModelRootIsUnavailableRatherThanEmpty() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let fileSystem = environment.fileSystem as! FakeFileSystem
        let whisper = AppDataLocation.whisperModelsDirectory().path
        fileSystem.directories.insert(whisper)
        fileSystem.unreadableDirectories.insert(whisper)
        environment.fileSystem = fileSystem

        let execution = await runCLI(["status", "--json"], environment: environment)
        let models = try XCTUnwrap(execution.decodedJSON()["models"] as? [[String: Any]])
        let root = try XCTUnwrap(models.first { $0["label"] as? String == "whisper" })
        XCTAssertEqual(root["exists"] as? Bool, true)
        XCTAssertEqual(root["available"] as? Bool, false)
        XCTAssertTrue(root["entries"] is NSNull)
        XCTAssertNotNil(root["reason"] as? String)
        let text = await runCLI(["status"], environment: environment)
        XCTAssertTrue(text.output.contains("unavailable - not readable"))
    }

    /// Nothing in a status read may change anything.
    func testStatusLaunchesNothingAndInstallsNothing() async throws {
        var environment = CLITestEnvironment.withInstalledApp()
        let launcher = FakeLauncher()
        let updates = FakeUpdates()
        environment.launcher = launcher
        environment.updates = updates

        _ = await runCLI(["status"], environment: environment)

        XCTAssertTrue(launcher.launched.isEmpty)
        XCTAssertTrue(updates.checkedIdentities.isEmpty, "status must not reach the network")
        XCTAssertTrue(updates.downloadedReleases.isEmpty)
    }
}
