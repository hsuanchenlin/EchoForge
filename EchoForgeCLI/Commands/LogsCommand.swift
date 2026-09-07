import Foundation

/// `echoforge logs` - what this Mac has recorded about Kongweh.
///
/// Worth being plain about what this is, because the name promises more than
/// macOS delivers. Kongweh has **no logging framework**: it writes `print`, and
/// a shipped app launched by the Finder has no stdout for that to reach - which
/// is stated in `AGENTS.md` as one of the reasons History exists. So this does
/// not tail the app's own log, because there is not one.
///
/// What there is, this reads. The macOS unified log carries the *system's*
/// messages about the process - CoreAudio opening an input device, the capture
/// stack, a crash - which is genuinely what this command gets asked about. And
/// the update installer writes one real file, because its swap script is
/// detached and has no other way to report a failure.
///
/// Everything printed goes through `Redaction` first. That is defensive rather
/// than reactive: nothing Kongweh writes reaches the unified log today, and the
/// day it does, `print("Transcription result: …")` is somebody's dictation.
enum LogsCommand: CLICommand {
    static let spec = CommandSpec(
        name: "logs",
        summary: "Read what macOS has logged about Kongweh.",
        usage: "logs [--tail <n>] [--since <duration>] [--source <name>] [--follow] [--json]",
        valueOptions: ["tail", "since", "source"],
        switches: ["follow"],
        help: [
            "--source unified (default) reads the macOS unified log for the app's process.",
            "--source update-install reads the installer's own log file.",
            "",
            "--since takes 30s, 15m, 2h or 7d; the default is \(LogLimits.defaultSince).",
            "--tail defaults to \(LogLimits.defaultTail) and may not exceed "
                + "\(LogLimits.maximumTail).",
            "--follow streams the unified log until Ctrl-C, which stops the reader too.",
            "",
            "Kongweh has no log of its own: it writes to a stdout a shipped app does not",
            "have. Credentials, transcripts and your home directory are redacted from",
            "everything printed here.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let request = try parse(arguments)
        let redaction = Redaction(homeDirectory: NSHomeDirectory())

        if request.follow {
            guard !arguments.wantsJSON else {
                throw CLIError(
                    "--follow and --json cannot be combined: a stream has no end, so there is no "
                        + "document to close.",
                    exitCode: .usage)
            }
            return try follow(request, redaction: redaction, in: environment)
        }

        let result = try environment.log.read(request)
        if let reason = result.unavailableReason {
            // Unavailable is not empty and not an error worth a stack trace: it
            // is usually "the app has never updated on this Mac". Reported with
            // its own exit code so a script can tell it from "read it, nothing
            // there".
            return CommandResult(
                text: "\(result.source.label): \(redaction.redact(reason))",
                json: .object([
                    ("source", .string(result.source.rawValue)),
                    ("available", .bool(false)),
                    ("reason", .string(redaction.redact(reason))),
                    ("entries", .array([])),
                ]),
                exitCode: .sourceUnavailable)
        }

        return CommandResult(
            text: text(for: result, redaction: redaction),
            json: .object([
                ("source", .string(result.source.rawValue)),
                ("available", .bool(true)),
                ("reason", .null),
                ("since", .string(request.since)),
                ("entries", .array(result.entries.map { $0.json(redaction: redaction) })),
            ]))
    }

    static func parse(_ arguments: ParsedArguments) throws -> LogRequest {
        let tail = try arguments.integerOption("tail", maximum: LogLimits.maximumTail)
            ?? LogLimits.defaultTail
        let since = arguments.option("since") ?? LogLimits.defaultSince
        guard LogDuration.isValid(since) else {
            throw CLIError(
                "--since takes a number followed by s, m, h or d - \"30m\", \"2h\", \"7d\". "
                    + "Got \"\(since)\".",
                exitCode: .usage)
        }
        let sourceName = arguments.option("source") ?? LogSource.unified.commandLineName
        guard let source = LogSource(commandLineName: sourceName) else {
            throw CLIError(
                "Unknown --source \"\(sourceName)\". Expected one of: "
                    + LogSource.allCases.map(\.commandLineName).joined(separator: ", ") + ".",
                exitCode: .usage)
        }
        return LogRequest(
            source: source, tail: tail, since: since, follow: arguments.switches.contains("follow"))
    }

    static func text(for result: LogReadResult, redaction: Redaction) -> String {
        guard !result.entries.isEmpty else {
            return "\(result.source.label): nothing in the window asked for."
        }
        return result.entries.map { line(for: $0, redaction: redaction) }.joined(separator: "\n")
    }

    static func line(for entry: LogEntry, redaction: Redaction) -> String {
        var parts: [String] = []
        if let timestamp = entry.timestamp {
            parts.append(ISO8601DateFormatter.cliFormatter.string(from: timestamp))
        }
        if let category = entry.category, !category.isEmpty {
            parts.append("[\(redaction.redact(category))]")
        }
        parts.append(redaction.redact(entry.message))
        return parts.joined(separator: " ")
    }

    private static func follow(
        _ request: LogRequest, redaction: Redaction, in environment: CLIEnvironment
    ) throws -> CommandResult {
        // Printed before the stream starts, on stderr's terms: it is a note
        // about the command rather than a log line, and a reader piping this to
        // a file wants the lines and not the banner.
        StandardStreams.error("Streaming \(request.source.label). Ctrl-C to stop.")
        try environment.log.follow(request) { entry in
            StandardStreams.output(line(for: entry, redaction: redaction) + "\n")
        }
        return CommandResult(text: "", json: .object([("followed", .bool(true))]))
    }
}

extension LogSource {
    /// The `--source` spelling. Hyphenated rather than camel-cased, because
    /// that is how a flag reads.
    var commandLineName: String {
        switch self {
        case .unified: return "unified"
        case .updateInstall: return "update-install"
        }
    }

    init?(commandLineName: String) {
        guard let match = LogSource.allCases.first(where: { $0.commandLineName == commandLineName })
        else { return nil }
        self = match
    }
}

/// The `--since` grammar.
///
/// Validated here rather than passed through, and that is the point: `--since`
/// is the one user-supplied value that reaches the argument list of a process
/// this tool starts. `log show` takes the same spelling, so nothing has to be
/// translated - but nothing unvalidated is handed on either.
enum LogDuration {
    static func isValid(_ text: String) -> Bool {
        guard let unit = text.last, "smhd".contains(unit) else { return false }
        let number = text.dropLast()
        return !number.isEmpty && number.allSatisfy(\.isNumber) && (Int(number) ?? 0) > 0
    }
}
