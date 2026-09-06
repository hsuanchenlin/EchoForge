import Foundation

/// Where `echoforge logs` can read from.
///
/// Two, and both are things that already exist rather than things this tool
/// added. Kongweh has no logging framework: it writes `print`, and a shipped app
/// launched by the Finder has no stdout for that to reach - which is stated in
/// `AGENTS.md` as the reason History exists at all. So there is no
/// "EchoForge log" to tail, and pretending otherwise would be the fake status
/// this tool must not invent.
enum LogSource: String, CaseIterable, Equatable {
    /// The macOS unified log, filtered to the app's process.
    ///
    /// What it carries is the *system's* messages about Kongweh - CoreAudio
    /// opening an input device, the camera-capture stack, a crash - and not
    /// Kongweh's own. That is genuinely useful for the questions this command
    /// gets asked ("did the microphone open?") and it is worth being plain that
    /// it is not application logging.
    case unified

    /// The update installer's own log, at a fixed path in the temporary
    /// directory, written by the detached swap script.
    ///
    /// The one log this project deliberately writes to a file, and it exists
    /// because that script is detached and has no other way to report a
    /// failure. See `UpdateInstaller.installAndRelaunch`.
    case updateInstall

    var label: String {
        switch self {
        case .unified: return "macOS unified log (process EchoForge)"
        case .updateInstall: return "update installer log"
        }
    }
}

struct LogRequest: Equatable {
    let source: LogSource

    /// How many entries to print, counting back from the newest.
    let tail: Int

    /// How far back to look, as `log show --last` spells it ("30m", "2h").
    let since: String

    let follow: Bool
}

enum LogLimits {
    /// A bounded tail by default. The unified log for a long-running app is
    /// thousands of lines an hour, and the default has to be something a person
    /// can read.
    static let defaultTail = 50
    static let maximumTail = 5000

    /// How far back a bare `echoforge logs` looks.
    static let defaultSince = "1h"
}

struct LogEntry: Equatable {
    let timestamp: Date?
    let category: String?
    let message: String

    func json(redaction: Redaction) -> JSONValue {
        .object([
            ("timestamp", .date(timestamp)),
            ("category", .string(category.map(redaction.redact))),
            ("message", .string(redaction.redact(message))),
        ])
    }
}

struct LogReadResult: Equatable {
    let source: LogSource
    let entries: [LogEntry]

    /// Set when the source could not be read at all, which is different from
    /// reading it and finding nothing.
    let unavailableReason: String?
}

protocol LogReading {
    func read(_ request: LogRequest) throws -> LogReadResult

    /// Streams until the process is interrupted. Only `.unified` supports it;
    /// everything else throws, and `LogsCommand` says so before starting.
    func follow(_ request: LogRequest, onEntry: @escaping (LogEntry) -> Void) throws
}

/// Reads the unified log through `/usr/bin/log`, and the installer log as a
/// file.
///
/// `log show --style ndjson` rather than parsing the human format: the compact
/// style puts the message, the process and the category on one line with no
/// delimiter that a message cannot itself contain, so any parse of it is a guess
/// about somebody else's text. NDJSON gives one object per entry.
struct SystemLogReader: LogReading {
    let runner: CommandRunning
    let fileSystem: FileSystemReading
    let installerLogURL: URL

    init(
        runner: CommandRunning = SystemCommandRunner(),
        fileSystem: FileSystemReading = SystemFileSystem(),
        installerLogURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoForge-update-install.log")
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.installerLogURL = installerLogURL
    }

    /// The predicate. Written once, here, because it is the whole definition of
    /// what this command shows and it must not be assembled from user input:
    /// `--since` and `--tail` are numbers and a duration, and neither reaches
    /// the predicate.
    static let unifiedPredicate = #"process == "EchoForge""#

    func read(_ request: LogRequest) throws -> LogReadResult {
        switch request.source {
        case .unified:
            return try readUnified(request)
        case .updateInstall:
            return readInstallerLog(request)
        }
    }

    private func readUnified(_ request: LogRequest) throws -> LogReadResult {
        let arguments = [
            "show",
            "--predicate", Self.unifiedPredicate,
            "--last", request.since,
            "--style", "ndjson",
            "--info",
        ]
        let result: (status: Int32, output: String)
        do {
            result = try runner.run("/usr/bin/log", arguments)
        } catch {
            return LogReadResult(
                source: .unified, entries: [],
                unavailableReason:
                    "/usr/bin/log could not be run. \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            return LogReadResult(
                source: .unified, entries: [],
                unavailableReason:
                    "/usr/bin/log exited with status \(result.status). "
                    + Redaction.truncated(result.output))
        }
        let entries = Self.parseNDJSON(result.output)
        return LogReadResult(
            source: .unified, entries: Array(entries.suffix(request.tail)),
            unavailableReason: nil)
    }

    private func readInstallerLog(_ request: LogRequest) -> LogReadResult {
        guard fileSystem.fileExists(at: installerLogURL),
            let data = fileSystem.contents(at: installerLogURL)
        else {
            return LogReadResult(
                source: .updateInstall, entries: [],
                unavailableReason:
                    "No installer log at \(installerLogURL.path). It is written the first time an "
                    + "update is installed, and the temporary directory is cleared on restart.")
        }
        // The script has no per-line timestamps - it prints a dated header per
        // run and then the shell's own output - so the lines are carried as they
        // are rather than given a timestamp this would have to invent.
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogEntry(timestamp: nil, category: nil, message: String($0)) }
            .filter { !$0.message.isEmpty }
        return LogReadResult(
            source: .updateInstall, entries: Array(lines.suffix(request.tail)),
            unavailableReason: nil)
    }

    /// One JSON object per line, as `log show --style ndjson` writes it.
    ///
    /// Anything that does not parse is skipped rather than guessed at: `log`
    /// prints a bare `[` and `]` around the stream in some versions, and a
    /// parser that tried to make entries out of those would report punctuation
    /// as log lines.
    static func parseNDJSON(_ output: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let message = object["eventMessage"] as? String ?? ""
            guard !message.isEmpty else { continue }
            let category = [object["subsystem"] as? String, object["category"] as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ":")
            entries.append(
                LogEntry(
                    timestamp: (object["timestamp"] as? String).flatMap(Self.parseTimestamp),
                    category: category.isEmpty ? nil : category,
                    message: message))
        }
        return entries
    }

    /// `log` writes `2026-09-06 09:28:15.416870+0800`, which is not ISO 8601
    /// (a space instead of `T`, microseconds, no colon in the offset).
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        timestampFormatter.date(from: raw)
    }

    func follow(_ request: LogRequest, onEntry: @escaping (LogEntry) -> Void) throws {
        guard request.source == .unified else {
            throw CLIError(
                "--follow only works on the unified log; \(request.source.label) is a file.",
                exitCode: .usage)
        }
        try LogStream.run(
            arguments: ["stream", "--predicate", Self.unifiedPredicate, "--style", "ndjson"],
            onLine: { line in
                for entry in Self.parseNDJSON(line) { onEntry(entry) }
            })
    }
}
