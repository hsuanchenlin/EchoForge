import XCTest

/// `echoforge transcribe` - the whole surface, with nothing installed, nothing
/// running and no audio anywhere.
///
/// The command never loads a model: it hands the file to Kongweh and waits for
/// the row Kongweh writes. That is what makes every case here reachable from a
/// test - the "app" is `FakeLauncher`, and what it "produced" is whatever the
/// test put in `FakeHistory`.
final class TranscribeCommandTests: XCTestCase {

    private let audio = URL(fileURLWithPath: "/Users/someone/Recordings/interview.m4a")
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    /// An environment with Kongweh installed and one audio file on disk.
    private func environment() -> (CLIEnvironment, FakeHistory, FakeLauncher) {
        var environment = CLITestEnvironment.withInstalledApp()
        let fileSystem = FakeFileSystem()
        fileSystem.directories.insert("/Applications/EchoForge.app")
        fileSystem.bundles["/Applications/EchoForge.app"] = [
            "CFBundleShortVersionString": "0.9.5",
            "CFBundleVersion": "35",
            "CFBundleIdentifier": AppDataLocation.storageIdentifier,
        ]
        fileSystem.files[audio.path] = Data("not really audio".utf8)
        environment.fileSystem = fileSystem

        let history = FakeHistory()
        environment.history = history
        let launcher = FakeLauncher()
        environment.launcher = launcher
        environment.now = { self.now }
        return (environment, history, launcher)
    }

    private func finished(
        _ text: String = "hello there",
        status: RecordingStatus = .completed,
        rawTranscription: String? = nil,
        at timestamp: Date? = nil
    ) -> Recording {
        var recording = Recording.fixture(
            transcription: text,
            timestamp: timestamp ?? now.addingTimeInterval(1),
            status: status,
            provenance: .fileTranscription,
            rawTranscription: rawTranscription)
        recording.sourceFileURL = audio.path
        return recording
    }

    // MARK: - The happy path

    func testItHandsTheFileToTheAppAndPrintsWhatComesBack() async throws {
        var (environment, history, launcher) = environment()
        history.recordingsBySourceFile[audio.path] = [finished()]
        environment.history = history
        environment.launcher = launcher

        let execution = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertEqual(execution.output, "hello there\n")
        XCTAssertEqual(launcher.opened.count, 1)
        XCTAssertEqual(launcher.opened.first?.files, [audio])
        XCTAssertEqual(
            launcher.opened.first?.application, URL(fileURLWithPath: "/Applications/EchoForge.app"))
    }

    /// The app is the only thing that transcribes: the tool never starts a
    /// second copy and never loads a model of its own.
    func testItNeverLaunchesASecondCopy() async throws {
        let (environment, history, launcher) = environment()
        history.recordingsBySourceFile[audio.path] = [finished()]

        _ = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertTrue(launcher.launched.isEmpty, "transcribe used the `start` path")
    }

    func testItWaitsUntilTheRowSettles() async throws {
        let (environment, history, _) = environment()
        var inFlight = finished()
        inFlight.status = .transcribing
        inFlight.transcription = ""
        history.sourceFileSequence = [[], [inFlight], [finished("the answer")]]

        let execution = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertEqual(execution.output, "the answer\n")
        XCTAssertEqual(history.sourceFileLookups.count, 3)
    }

    /// A row from an earlier run over the same file is not this run's answer.
    func testAnOlderRowForTheSameFileIsIgnored() async throws {
        let (environment, history, _) = environment()
        let stale = finished("last week's transcript", at: now.addingTimeInterval(-86400))
        history.sourceFileSequence = [[stale], [finished("today's transcript"), stale]]

        let execution = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertEqual(execution.output, "today's transcript\n")
    }

    // MARK: - JSON

    func testTheJSONCarriesTheTranscriptAndWhatProducedIt() async throws {
        let (environment, history, _) = environment()
        history.recordingsBySourceFile[audio.path] = [
            finished("Kubernetes it is", rawTranscription: "kubernetes it is")
        ]

        let execution = await runCLI(["transcribe", audio.path, "--json"], environment: environment)
        let json = try execution.decodedJSON()

        XCTAssertEqual(json["transcript"] as? String, "Kubernetes it is")
        XCTAssertEqual(json["originalTranscript"] as? String, "kubernetes it is")
        XCTAssertEqual(json["status"] as? String, "completed")
        XCTAssertEqual(json["file"] as? String, audio.path)
        XCTAssertEqual(json["kind"] as? String, "fileTranscription")
    }

    /// Null rather than a copy of the transcript, so a script can tell
    /// "post-processing changed nothing" from "the original was not stored" -
    /// the same rule `history --json` follows.
    func testAnUnchangedTranscriptHasNoOriginal() async throws {
        let (environment, history, _) = environment()
        history.recordingsBySourceFile[audio.path] = [finished()]

        let json = try await runCLI(["transcribe", audio.path, "--json"], environment: environment)
            .decodedJSON()

        XCTAssertTrue(json["originalTranscript"] is NSNull)
    }

    // MARK: - Failures

    func testAFailedTranscriptionIsItsOwnExitCode() async throws {
        let (environment, history, _) = environment()
        history.recordingsBySourceFile[audio.path] = [
            finished("The audio could not be read.", status: .failed)
        ]

        let execution = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertEqual(execution.exitCode, .failure)
        XCTAssertTrue(execution.output.contains("could not be transcribed"))
    }

    func testAFileThatIsNotThereIsReportedBeforeAnythingIsStarted() async throws {
        let (environment, _, launcher) = environment()

        let execution = await runCLI(
            ["transcribe", "/Users/someone/missing.wav"], environment: environment)

        XCTAssertEqual(execution.exitCode, .sourceUnavailable)
        XCTAssertTrue(launcher.opened.isEmpty, "the app was asked to open a file that is not there")
    }

    /// A row in the user's History for something that was never a recording is
    /// worse than a refusal, so the extension is checked before the hand-over.
    func testSomethingThatIsNotAudioIsRefused() async throws {
        var (environment, _, launcher) = environment()
        let fileSystem = FakeFileSystem()
        fileSystem.directories.insert("/Applications/EchoForge.app")
        fileSystem.bundles["/Applications/EchoForge.app"] = [
            "CFBundleShortVersionString": "0.9.5",
            "CFBundleVersion": "35",
            "CFBundleIdentifier": AppDataLocation.storageIdentifier,
        ]
        fileSystem.files["/Users/someone/notes.txt"] = Data()
        environment.fileSystem = fileSystem

        let execution = await runCLI(
            ["transcribe", "/Users/someone/notes.txt"], environment: environment)

        XCTAssertEqual(execution.exitCode, .usage)
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testNoFileIsAUsageError() async throws {
        let (environment, _, _) = environment()
        let execution = await runCLI(["transcribe"], environment: environment)
        XCTAssertEqual(execution.exitCode, .usage)
    }

    func testSeveralFilesAreRefusedRatherThanHalfDone() async throws {
        let (environment, _, launcher) = environment()
        let execution = await runCLI(
            ["transcribe", audio.path, audio.path], environment: environment)

        XCTAssertEqual(execution.exitCode, .usage)
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testNoAppInstalledIsItsOwnExitCode() async throws {
        var environment = CLITestEnvironment.empty()
        let fileSystem = FakeFileSystem()
        fileSystem.files[audio.path] = Data()
        environment.fileSystem = fileSystem

        let execution = await runCLI(["transcribe", audio.path], environment: environment)

        XCTAssertEqual(execution.exitCode, .appNotFound)
    }

    /// Timing out is not a failure of the transcription: the app is still
    /// working and the transcript still lands in History, so the message has to
    /// say so rather than read as "it did not work".
    func testTimingOutSaysTheAppIsStillWorking() async throws {
        var (environment, history, _) = environment()
        history.sourceFileSequence = []
        var clock = now
        environment.now = {
            clock = clock.addingTimeInterval(30)
            return clock
        }

        let execution = await runCLI(
            ["transcribe", audio.path, "--timeout", "60"], environment: environment)

        XCTAssertEqual(execution.exitCode, .failure)
        XCTAssertTrue(execution.diagnostic.contains("still working"), execution.diagnostic)
    }

    func testAnOutOfRangeTimeoutIsRefusedByName() async throws {
        let (environment, _, _) = environment()
        let execution = await runCLI(
            ["transcribe", audio.path, "--timeout", "999999"], environment: environment)

        XCTAssertEqual(execution.exitCode, .usage)
        XCTAssertTrue(execution.diagnostic.contains("--timeout"))
    }

    // MARK: - The contract with the rest of the tool

    /// There is deliberately no `--engine`: the app owns that preference and
    /// this tool never writes one (`AGENTS.md`).
    func testThereIsNoWayToChooseAnEngineFromHere() {
        XCTAssertFalse(TranscribeCommand.spec.valueOptions.contains("engine"))
        XCTAssertFalse(TranscribeCommand.spec.valueOptions.contains("language"))
    }

    func testTheHelpNamesTheOneThingThatSurprisesPeople() {
        let help = TranscribeCommand.spec.helpText
        XCTAssertTrue(help.contains("Open With"))
        XCTAssertTrue(help.contains("History"))
    }
}
