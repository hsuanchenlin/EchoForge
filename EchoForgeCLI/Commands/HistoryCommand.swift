import Foundation

/// `echoforge history` - the History pane, in a terminal, read-only.
///
/// Three things about it are load-bearing.
///
/// **It runs the app's own query.** `RecordingSchema.query(matching:searching:)`
/// is what the History pane runs, and a phrase is resolved by
/// `HistorySearchQuery` exactly as the search field resolves it - so "voice
/// edit" finds a `selectionEdit` row here for the same reason it does there, and
/// `100%` is a literal here for the same reason. A second implementation would
/// have been a second set of semantics, and the one thing worse than a search
/// that finds nothing is two searches that disagree.
///
/// **It is bounded.** A bare `history` returns
/// `HistoryLimits.defaultLimit` rows; `--limit` has a ceiling. This database
/// holds every dictation a user has ever made, and the machines with the most in
/// it are exactly the ones where an unbounded dump would be worst.
///
/// **It cannot write.** The connection is opened read-only
/// (`ReadOnlyHistoryReader`), there is no delete, no regenerate, no export that
/// writes, and nothing here touches the network. Export is a thing the app does
/// through an `NSSavePanel` (`docs/history-search-export.md`); a tool that wrote
/// files would need to decide where, and `> file` already answers that.
enum HistoryCommand: CLICommand {
    static let spec = CommandSpec(
        name: "history",
        summary: "List recent transcripts, newest first.",
        usage: "history [--query <text>] [--limit <n>] [--json]",
        valueOptions: ["query", "limit"],
        help: [
            "--query matches the transcript, the original a rewrite kept, the sentence under",
            "the badge, the badge's own label (\"voice edit\") and dates the card shows -",
            "case-insensitively, the same as Kongweh's own History search.",
            "",
            "--limit defaults to \(HistoryLimits.defaultLimit) and may not exceed "
                + "\(HistoryLimits.maximumLimit).",
            "Read-only: nothing here deletes, re-transcribes or sends anything anywhere.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let limit =
            try arguments.integerOption("limit", maximum: HistoryLimits.maximumLimit)
            ?? HistoryLimits.defaultLimit
        let query = arguments.option("query")

        let page = try environment.history.read(
            HistoryRequest(query: query, limit: limit), now: environment.now())

        return CommandResult(text: text(for: page, query: query), json: json(for: page, query: query))
    }

    static func text(for page: HistoryPage, query: String?) -> String {
        guard !page.rows.isEmpty else {
            return query.map { "No recordings match \"\($0)\"." }
                ?? "No recordings yet."
        }

        let rows = page.rows.map { recording -> [String] in
            [
                Self.timestamp(recording.timestamp),
                recording.provenance.kind.label,
                TranscriptPreview.line(for: recording),
            ]
        }
        var out = Table.render(rows: rows, flexibleColumn: 2)
        if page.totalMatching > page.rows.count {
            out += "\n\nShowing \(page.rows.count) of \(page.totalMatching). Use --limit for more."
        }
        return out
    }

    static func json(for page: HistoryPage, query: String?) -> JSONValue {
        .object([
            ("query", .string(query)),
            ("returned", .int(page.rows.count)),
            ("totalMatching", .int(page.totalMatching)),
            (
                "recordings",
                .array(
                    page.rows.map { recording in
                        .object([
                            ("id", .string(recording.id.uuidString)),
                            ("timestamp", .date(recording.timestamp)),
                            ("status", .string(recording.status.rawValue)),
                            ("durationSeconds", .double(recording.duration)),
                            // The kind's *label* as well as its stored value:
                            // the raw value is a storage detail nobody has seen
                            // ("selectionEdit"), and the label is what the card
                            // says ("Voice edit").
                            ("kind", .string(recording.provenance.kind.rawValue)),
                            ("kindLabel", .string(recording.provenance.kind.label)),
                            ("detail", .string(recording.provenance.detail)),
                            ("transcript", .string(recording.transcription)),
                            // The engine's own words, when the row kept them.
                            // Null rather than a copy of the transcript, so a
                            // script can tell "unchanged" from "not stored".
                            ("originalTranscript", .string(recording.rawTranscription)),
                            ("correctedByAIAt", .date(recording.aiCorrectedAt)),
                        ])
                    })
            ),
            // The path, so somebody can back the file up or point a `sqlite3` at
            // it. The row's own audio file name is deliberately not here, for
            // the same reason `HistorySearchQuery` does not search it: it is an
            // internal `UUID.wav` the card has never shown.
            ("databasePath", .string(page.databasePath)),
        ])
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// The one-line form of a transcript.
///
/// "Safe" here means safe to put in a terminal, not redacted: this is the user's
/// own history and they asked for it. What it removes is the two things that
/// would wreck the output - the newlines a dictated paragraph contains, which
/// would break every row of the table, and the control characters a transcript
/// can carry, which a terminal would interpret rather than print. `--json`
/// carries the whole transcript, unmodified, which is what a script wants.
enum TranscriptPreview {
    static let maximumLength = 72

    static func line(for recording: Recording) -> String {
        let text = collapsed(recording.transcription)
        guard !text.isEmpty else {
            // A row with no transcript is not a blank row: it is a failed or
            // in-flight one, and saying which is more useful than empty space.
            return "(\(recording.status.rawValue))"
        }
        guard text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength - 1)) + "…"
    }

    static func collapsed(_ text: String) -> String {
        let scrubbed = String(
            text.map { character in
                character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
                    ? " " : character
            })
        return scrubbed.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Columns that line up, with one column allowed to take what is left.
///
/// A terminal table and not a dependency: two fixed columns and a preview is the
/// whole requirement, and the width rule below - the flexible column is never
/// padded - is what keeps the output usable when it is piped into `grep`.
enum Table {
    static func render(rows: [[String]], flexibleColumn: Int) -> String {
        guard let width = rows.first?.count, width > 0 else { return "" }
        let columnWidths = (0..<width).map { column in
            rows.map { $0[column].count }.max() ?? 0
        }
        return rows
            .map { row in
                row.enumerated()
                    .map { index, value in
                        index == flexibleColumn || index == width - 1
                            ? value
                            : value.padding(
                                toLength: columnWidths[index], withPad: " ", startingAt: 0)
                    }
                    .joined(separator: "  ")
            }
            .joined(separator: "\n")
    }
}
