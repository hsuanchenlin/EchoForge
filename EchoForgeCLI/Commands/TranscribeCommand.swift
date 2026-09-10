import Foundation

/// `echoforge transcribe <file>` - transcribe an audio file and print the text.
///
/// **How it works, and why it works that way.** The tool does not load a model.
/// It hands the file to Kongweh exactly as the Finder's "Open With" does, then
/// watches the recordings database - read-only, as always - until the row the
/// app wrote for that file settles. Everything the app does to a dropped file
/// therefore happens here too: the engine the user selected, their personal
/// terms, the Chinese output script, the rewriting stage, the row in History.
///
/// The alternative - linking whisper.cpp and the model runtimes into this
/// binary - was rejected, and not on size. `AGENTS.md` states that the app is
/// the single owner of the microphone, the model cache and the recordings
/// database. A tool that loaded its own model would be a second process holding
/// the same 200 MB of weights, competing for the Neural Engine with the app that
/// is dictating; a tool that wrote its own rows would be a second writer to a
/// database exactly one thing is allowed to migrate. Handing the file over adds
/// neither, and it is the only design here in which `transcribe` and a file the
/// user drags onto the window cannot produce different text.
///
/// **What it is honest about.** Kongweh has to be installed, and it will be
/// started if it is not running. The engine cannot be chosen from here - the app
/// owns that preference and this tool never writes one - and `--json` says which
/// engine's output it got by saying nothing about it, because the row does not
/// record one. `docs/cli.md` says all of this where a user reads it.
enum TranscribeCommand: CLICommand {
    static let spec = CommandSpec(
        name: "transcribe",
        summary: "Transcribe an audio file with the running app and print the text.",
        usage: "transcribe <file> [--timeout <seconds>] [--app <absolute-path>] [--json]",
        valueOptions: ["app", "timeout"],
        positional: "file",
        help: [
            "Hands the file to Kongweh the way \"Open With\" does, waits for it to finish, and",
            "prints the transcript. The app is started if it is not running.",
            "",
            "The transcription is the app's own: the engine you selected, your personal terms,",
            "your output script and your rewriting style, and it lands in History like any",
            "other file you drop. There is no --engine: this tool never writes a preference.",
            "",
            "--timeout defaults to \(TranscribeCommand.defaultTimeoutSeconds)s and may not "
                + "exceed \(TranscribeCommand.maximumTimeoutSeconds)s. Timing out exits 1 and",
            "leaves the app working - the transcript still lands in History.",
        ])

    /// How long to wait for a transcript before giving up.
    ///
    /// Generous, because the wait is not this tool's: a first transcription can
    /// include a model download and, on the Neural Engine engines, a compile
    /// that takes minutes. Bounded anyway, because a terminal that never comes
    /// back is its own kind of failure.
    static let defaultTimeoutSeconds = 600
    static let maximumTimeoutSeconds = 7200

    /// How often the database is asked. Short enough that a two-second
    /// dictation does not feel like a five-second one, long enough that a ten
    /// minute wait is not thousands of queries.
    static let pollIntervalSeconds: TimeInterval = 0.5

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let file = try audioFile(arguments, in: environment)
        let timeout = try arguments.integerOption("timeout", maximum: maximumTimeoutSeconds)
            ?? defaultTimeoutSeconds
        let application = try ApplicationLocator.locate(
            override: arguments.option("app"), in: environment)

        // Rows written before this moment belong to an earlier run over the same
        // file, and a script that transcribed the same recording twice must not
        // be handed the first answer. A second of slack absorbs the clock skew
        // between reading `now` here and the app stamping its row.
        let startedAt = environment.now().addingTimeInterval(-1)

        _ = try environment.launcher.open(files: [file], withApplicationAt: application.url)

        let deadline = environment.now().addingTimeInterval(TimeInterval(timeout))
        while true {
            if let settled = try settledRecording(for: file, after: startedAt, in: environment) {
                return result(for: settled, file: file, application: application)
            }
            guard environment.now() < deadline else {
                throw CLIError(
                    "Kongweh did not finish transcribing \(file.lastPathComponent) within "
                        + "\(timeout)s. It is still working - the transcript will appear in "
                        + "History, and `echoforge history` will show it.",
                    details: [
                        ("file", .string(file.path)),
                        ("timedOut", .bool(true)),
                    ])
            }
            try await environment.sleep(pollIntervalSeconds)
        }
    }

    // MARK: - The file

    /// The one positional argument, checked before anything is started.
    ///
    /// Refused early and by extension rather than by content: this tool never
    /// reads the audio, and asking the app to open a text file would put a row
    /// in the user's History for something that was never a recording.
    static func audioFile(
        _ arguments: ParsedArguments, in environment: CLIEnvironment
    ) throws -> URL {
        guard let first = arguments.positionals.first else {
            throw CLIError("transcribe needs a file. See `echoforge transcribe --help`.",
                exitCode: .usage)
        }
        guard arguments.positionals.count == 1 else {
            throw CLIError(
                "transcribe takes one file at a time; got \(arguments.positionals.count). "
                    + "Loop in the shell to do several.",
                exitCode: .usage)
        }

        let url = URL(fileURLWithPath: first).standardizedFileURL
        guard environment.fileSystem.fileExists(at: url),
              !environment.fileSystem.isDirectory(at: url)
        else {
            throw CLIError("No file at \(url.path).", exitCode: .sourceUnavailable)
        }
        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
            throw CLIError(
                "\(url.lastPathComponent) is not an audio file this tool will hand over "
                    + "(\(audioExtensions.sorted().joined(separator: ", "))).",
                exitCode: .usage)
        }
        return url
    }

    /// The extensions the app's own file-transcription path accepts, spelled
    /// out rather than asked of the system: `UTType` answers differently
    /// depending on what is installed, and a tool refusing a file the app would
    /// have taken is a worse failure than a permissive list.
    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "aifc", "caf", "flac", "ogg", "opus",
        "mp4", "m4b", "mov", "wma",
    ]

    // MARK: - Waiting

    /// The row for this file, once the app has finished with it.
    ///
    /// `nil` while the row does not exist yet or is still `pending`,
    /// `converting` or `transcribing` - the three statuses
    /// `RecordingStore.getNextPendingRecording` counts as still-to-do, so this
    /// waits on exactly what the app considers unfinished.
    static func settledRecording(
        for file: URL, after startedAt: Date, in environment: CLIEnvironment
    ) throws -> Recording? {
        let rows = try environment.history.recordings(forSourceFile: file)
        // Newest first, and only rows this invocation could have caused.
        guard let row = rows.first(where: { $0.timestamp >= startedAt }) else { return nil }
        return row.isPending ? nil : row
    }

    // MARK: - Reporting

    static func result(
        for recording: Recording, file: URL, application: InstalledApplication
    ) -> CommandResult {
        let failed = recording.status == .failed
        return CommandResult(
            text: failed
                ? "\(file.lastPathComponent) could not be transcribed. "
                    + collapsed(recording.transcription)
                : recording.transcription,
            json: .object([
                ("file", .string(file.path)),
                ("status", .string(recording.status.rawValue)),
                ("transcript", .string(failed ? nil : recording.transcription)),
                // The engine's own words, when post-processing changed them.
                // Null rather than a copy of the transcript, so a script can
                // tell "unchanged" from "not stored" - the same rule
                // `echoforge history --json` follows.
                ("originalTranscript", .string(recording.rawTranscription)),
                ("durationSeconds", .double(recording.duration)),
                ("timestamp", .date(recording.timestamp)),
                ("id", .string(recording.id.uuidString)),
                ("kind", .string(recording.provenance.kind.rawValue)),
                ("kindLabel", .string(recording.provenance.kind.label)),
                ("error", .string(failed ? recording.transcription : nil)),
                ("app", application.json),
            ]),
            exitCode: failed ? .failure : .success)
    }

    /// A failure message is the app's own sentence, and a terminal is not the
    /// place for the newlines it may contain.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
