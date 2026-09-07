import Foundation

/// `echoforge status` - what is true about Kongweh on this Mac right now,
/// without changing any of it.
///
/// The command's one rule is that **"I cannot tell" is a different answer from
/// "no"**, and it is the reason so much of this file is about shapes rather than
/// values. An unavailable injected preference reader must not
/// report every switch as off; a Mac where the history database has never been
/// created must not report zero dictations as though the user had made none.
/// Each section therefore reports itself as available or not, with the reason.
///
/// The limitation worth stating plainly: **there is no live recording state
/// here, because there is nothing to read it from.** Kongweh has no IPC server,
/// no status file and no logging a tool could tail (`AGENTS.md`: `print` goes to
/// a stdout a shipped app does not have). Whether the microphone is open at this
/// instant lives only in a `@Published` property inside the running process.
/// Adding a socket or an always-running helper to answer it would be a new
/// permanently-listening surface on a local-first app, which is a much larger
/// decision than a status command - so this reports what is durable and says
/// what it cannot see, rather than approximating it. `activity` below is the
/// honest, durable half of the question: what the app has actually written down.
enum StatusCommand: CLICommand {
    static let spec = CommandSpec(
        name: "status",
        summary: "Report whether Kongweh is running, and its local state.",
        usage: "status [--app <absolute-path>] [--json]",
        valueOptions: ["app"],
        help: [
            "Reports the app, the process, what the queue has left to do, the stored engine",
            "choice, and which model weights are on disk.",
            "",
            "Live recording state is not reported: it exists only inside the running app,",
            "which has no local interface to ask. `activity` is what the app has written",
            "down, which is the part that survives the question being asked.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        // A named `--app` that resolves to nothing is a mistake and is thrown;
        // an empty default path is not. The rest of this command reads the
        // user's data, which outlives any particular installation and is
        // exactly what somebody asks about after deleting the app.
        let appResolution: DefaultApplicationResolution
        if let override = arguments.option("app") {
            appResolution = .installed(
                try ApplicationLocator.locate(override: override, in: environment))
        } else {
            appResolution = ApplicationLocator.resolveDefault(in: environment)
        }

        let running = ApplicationLocator.runningCopies(in: environment)
        let activity = QueueActivity.read(in: environment)
        let engine = EngineStatus.read(in: environment)
        let models = ModelStatus.read(in: environment)

        var lines: [String] = []
        switch appResolution {
        case .installed(let application):
            lines.append(
                "app       \(application.identity.marketingVersion) "
                    + "(\(application.identity.buildNumber))  \(application.url.path)")
        case .notInstalled:
            lines.append("app       not installed")
        case .unavailable(_, let reason):
            lines.append("app       unavailable - \(reason)")
        }
        if let copy = running.first {
            lines.append(
                "process   running, pid \(copy.processIdentifier)"
                    + (copy.launchDate.map { ", since \(Self.short($0))" } ?? ""))
        } else {
            lines.append("process   not running")
        }
        lines.append("recording \(StatusCommand.recordingSummary)")
        lines.append("activity  \(activity.summary)")
        lines.append("engine    \(engine.summary)")
        lines.append("models    \(models.summary)")

        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: .object([
                (
                    "app",
                    appJSON(for: appResolution)
                ),
                (
                    "process",
                    .object([
                        ("running", .bool(!running.isEmpty)),
                        ("processIdentifier", .int(running.first.map { Int($0.processIdentifier) })),
                        ("path", .string(running.first?.bundleURL?.path)),
                        ("launchedAt", .date(running.first?.launchDate)),
                    ])
                ),
                (
                    "recording",
                    .object([
                        ("available", .bool(false)),
                        ("reason", .string(Self.recordingSummary)),
                    ])
                ),
                ("activity", activity.json),
                ("engine", engine.json),
                ("models", models.json),
            ]))
    }

    static func appJSON(for resolution: DefaultApplicationResolution) -> JSONValue {
        switch resolution {
        case .installed(let application):
            return .object([
                ("available", .bool(true)),
                ("installed", .bool(true)),
                ("reason", .null),
                ("path", .string(application.url.path)),
                ("version", .string(application.identity.marketingVersion)),
                ("build", .string(application.identity.buildNumber)),
                ("bundleIdentifier", .string(application.identity.bundleIdentifier)),
            ])
        case .notInstalled:
            return .object([
                ("available", .bool(true)),
                ("installed", .bool(false)),
                ("reason", .null),
                ("path", .null),
            ])
        case .unavailable(let path, let reason):
            return .object([
                ("available", .bool(false)),
                ("installed", .null),
                ("reason", .string(reason)),
                ("path", .string(path.path)),
            ])
        }
    }

    /// Said the same way in both renderings, because it is the one thing this
    /// command deliberately does not know.
    static let recordingSummary =
        "unavailable - live capture state exists only inside the running app, which has no "
        + "local interface to ask"

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// What the transcription queue has left to do, read from the database.
///
/// This is real operational state and it is durable: `Recording.isPending` is
/// the app's own definition of "still to do", and `getNextPendingRecording`
/// hands the queue exactly these rows. A row sitting in `.transcribing` with the
/// app not running is the shape of the failure `TranscriptionQueueStep` exists
/// to bound, and being able to see it from a terminal is most of why this
/// command is worth having.
struct QueueActivity: Equatable {
    let isAvailable: Bool
    let unavailableReason: String?
    let pending: Int
    let total: Int
    let latest: Date?

    static func read(in environment: CLIEnvironment) -> QueueActivity {
        do {
            let page = try environment.history.read(
                HistoryRequest(limit: HistoryLimits.maximumLimit), now: environment.now())
            let pending = page.rows.filter(\.isPending).count
            return QueueActivity(
                isAvailable: true, unavailableReason: nil,
                pending: pending, total: page.totalMatching,
                latest: page.rows.first?.timestamp)
        } catch {
            return QueueActivity(
                isAvailable: false,
                unavailableReason: CLIError.wrapping(error).message,
                pending: 0, total: 0, latest: nil)
        }
    }

    var summary: String {
        guard isAvailable else { return "unavailable - \(unavailableReason ?? "unknown")" }
        // The pending count is over the most recent page rather than the whole
        // table, and says so: a row that has been pending since last year is not
        // what anybody is asking about, and counting the whole table would mean
        // decoding every recording the user has ever made.
        return "\(total) recordings, \(pending) still in flight in the newest "
            + "\(HistoryLimits.maximumLimit)"
    }

    var json: JSONValue {
        .object([
            ("available", .bool(isAvailable)),
            ("reason", .string(unavailableReason)),
            ("recordings", .int(isAvailable ? total : nil)),
            ("inFlight", .int(isAvailable ? pending : nil)),
            ("newestRecordingAt", .date(latest)),
        ])
    }
}

/// The engine the user chose, and the one that last actually loaded.
///
/// Two values and not one, because the app keeps them apart on purpose: the
/// selection is what the user asked for and `lastReadyEngine` is what worked,
/// and the gap between them is exactly what a person debugging "why is it using
/// Whisper" needs to see. The raw stored strings are reported rather than
/// prettified names - `EngineCatalog`'s copy is the app's, and a second copy of
/// it here would be a second answer to what an engine is called.
struct EngineStatus: Equatable {
    let isReadable: Bool
    let selected: String?
    let lastReady: String?
    let preparing: String?
    let language: String?

    static func read(in environment: CLIEnvironment) -> EngineStatus {
        let preferences = environment.preferences
        return EngineStatus(
            isReadable: preferences.isReadable,
            selected: preferences.value(forKey: PreferenceKeys.selectedEngine) as? String,
            lastReady: preferences.value(forKey: PreferenceKeys.lastReadyEngine) as? String,
            preparing: preferences.value(forKey: PreferenceKeys.pendingEnginePreparation) as? String,
            language: preferences.value(forKey: PreferenceKeys.whisperLanguage) as? String)
    }

    var summary: String {
        guard isReadable else { return "unavailable - the preference reader could not provide values" }
        var parts = ["selected \(selected ?? "not set")"]
        if let lastReady, lastReady != selected { parts.append("last ready \(lastReady)") }
        if let preparing { parts.append("preparing \(preparing)") }
        if let language { parts.append("language \(language)") }
        return parts.joined(separator: ", ")
    }

    var json: JSONValue {
        .object([
            ("available", .bool(isReadable)),
            ("selected", .string(selected)),
            ("lastReady", .string(lastReady)),
            ("preparing", .string(preparing)),
            ("dictationLanguage", .string(language)),
        ])
    }
}

/// Which model weights are on this disk.
///
/// Read as directories rather than asked of the engines, and that is a
/// deliberate limit rather than laziness: an engine can only answer "are my
/// weights ready" by loading FluidAudio and its CoreML stack, which is a large
/// dependency to add to a status command and would make this tool able to start
/// compiling a model for the Neural Engine as a side effect of being asked a
/// question.
///
/// So it reports what is observably there. One root is this project's own
/// (`AppDataLocation.whisperModelsDirectory`); the other is FluidAudio's, which
/// this project does not choose and only reads - `AppDataLocation` says so, and
/// `AppDataLocationTests` pins it against the pinned FluidAudio so a version
/// that moved it fails a test rather than reporting "no models" forever.
struct ModelStatus: Equatable {
    struct Root: Equatable {
        let label: String
        let path: String
        let exists: Bool
        let isReadable: Bool
        let unavailableReason: String?
        let entries: [String]?
        let bytes: Int64?
    }

    let roots: [Root]

    static func read(in environment: CLIEnvironment) -> ModelStatus {
        let roots = [
            ("whisper", AppDataLocation.whisperModelsDirectory()),
            ("on-device engines", AppDataLocation.fluidAudioModelsDirectory()),
        ]
        return ModelStatus(
            roots: roots.map { label, url in
                guard environment.fileSystem.isDirectory(at: url) else {
                    return Root(
                        label: label, path: url.path, exists: false, isReadable: true,
                        unavailableReason: nil, entries: [], bytes: 0)
                }
                do {
                    let children = try environment.fileSystem.contentsOfDirectory(at: url)
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    return Root(
                        label: label, path: url.path, exists: true, isReadable: true,
                        unavailableReason: nil, entries: children.map(\.lastPathComponent),
                        bytes: children.reduce(0) {
                            $0 + (environment.fileSystem.fileSize(at: $1) ?? 0)
                        })
                } catch {
                    return Root(
                        label: label, path: url.path, exists: true, isReadable: false,
                        unavailableReason: error.localizedDescription, entries: nil, bytes: nil)
                }
            })
    }

    var summary: String {
        roots
            .map { root in
                guard root.isReadable else { return "\(root.label) unavailable - not readable" }
                guard root.exists else { return "\(root.label) none" }
                let entries = root.entries ?? []
                return "\(root.label) \(entries.count)"
                    + (entries.isEmpty ? "" : " (\(entries.joined(separator: ", ")))")
            }
            .joined(separator: "; ")
    }

    var json: JSONValue {
        .array(
            roots.map { root in
                .object([
                    ("label", .string(root.label)),
                    ("path", .string(root.path)),
                    ("exists", .bool(root.exists)),
                    ("available", .bool(root.isReadable)),
                    ("reason", .string(root.unavailableReason)),
                    ("entries", root.entries.map { .array($0.map { .string($0) }) } ?? .null),
                    // Only the top level is measured: a model cache is a tree,
                    // and walking every one of them to add up bytes is not what
                    // a status command should spend a user's disk on.
                    ("topLevelBytes", .int(root.bytes.map(Int.init))),
                ])
            })
    }
}
