import Foundation
import GRDB

/// The recordings database's schema and its two history queries.
///
/// Split out of `RecordingStore` when the `echoforge` command-line tool began
/// reading the same file. The store still owns *running* the migrations - it is
/// the only thing that writes, and the CLI opens the database read-only - but
/// the migrations and the queries themselves live here so there is exactly one
/// declaration of each. A CLI with its own copy of `WHERE` would drift from the
/// History pane it exists to mirror, and a CLI with its own copy of the schema
/// would be a second schema.
///
/// Schema changes still go in a **new named migration**; never edit an applied
/// one, since the identifier is what decides whether a user's database already
/// ran it.
enum RecordingSchema {
    /// The full schema history of the recordings database.
    ///
    /// Exposed separately from `setupDatabase()` so migrations can be exercised
    /// against a throwaway database instead of the user's real one.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
        
        migrator.registerMigration("v2_add_status") { db in
            let columns = try db.columns(in: Recording.databaseTableName)
            let columnNames = columns.map { $0.name }
            
            if !columnNames.contains("status") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "status", .text).notNull().defaults(to: "completed")
                }
            }
            if !columnNames.contains("progress") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "progress", .double).notNull().defaults(to: 1.0)
                }
            }
            if !columnNames.contains("sourceFileURL") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "sourceFileURL", .text)
                }
            }
        }

        migrator.registerMigration("v3_add_raw_transcription") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            if !columnNames.contains("rawTranscription") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "rawTranscription", .text)
                }
            }
        }

        /// Provenance: what kind of session produced a row, and what became of
        /// it (`RecordingProvenance`).
        ///
        /// All three columns are nullable with no default, and that is the
        /// migration's whole safety story: every recording a user already has
        /// gets NULL, reads back as `.unknown`, and is shown as "Older
        /// recording". Back-filling them with `'dictation'` would have been one
        /// `UPDATE` and would have written the app's guess into the user's
        /// record - including onto every YouTube command they ran before this
        /// existed, which is exactly the history they are trying to read.
        migrator.registerMigration("v4_add_provenance") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            for column in ["provenanceKind", "provenanceReason", "provenanceDetail"]
            where !columnNames.contains(column) {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: column, .text)
                }
            }
        }

        /// When "Fix with AI" last corrected a row (`TranscriptCorrection`).
        ///
        /// Nullable with no default, for the reason every column added here is:
        /// every recording a user already has gets NULL and reads back as a row
        /// nobody has corrected, which is exactly what it is. Nothing is
        /// back-filled and nothing is inferred.
        migrator.registerMigration("v5_add_ai_correction") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            if !columnNames.contains("aiCorrectedAt") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "aiCorrectedAt", .datetime)
                }
            }
        }

        return migrator
    }

    /// The history query for one filter.
    ///
    /// In SQL rather than over the loaded page, because history is paged: a
    /// filter applied to the hundred rows that happen to be in memory would
    /// quietly hide every older row that matches, which is the opposite of what
    /// somebody looking for a command that failed last week is asking for.
    ///
    /// The NULL arm is the load-bearing part. Every recording made before
    /// provenance existed has no kind stored, and `provenanceKind IN (...)` is
    /// false for NULL in SQL - so "Older recording" has to ask for the NULL
    /// explicitly, and every other filter has to leave it out.
    static func query(
        matching filter: HistoryProvenanceFilter
    ) -> QueryInterfaceRequest<Recording> {
        guard let kinds = filter.kinds else { return Recording.all() }
        let raw = kinds.map(\.rawValue)
        let named = raw.contains(Recording.Columns.provenanceKind)
        return Recording.filter(
            filter.includesUnrecorded ? (named || Recording.Columns.provenanceKind == nil) : named
        )
    }

    /// The history query for one filter **and** one search phrase.
    ///
    /// The two are ANDed, and that is the contract the list depends on: choosing
    /// a kind narrows a search rather than replacing it, so a user who has typed
    /// a word and then picked "Voice edit" sees the voice edits carrying that
    /// word rather than every voice edit they have ever made.
    ///
    /// The phrase itself is ORed across the four things a card shows and the
    /// database can answer for: the transcript, the original the "Show original"
    /// disclosure holds, the provenance sentence under the badge, and - through
    /// `HistorySearchQuery`, which resolved them before the query was built -
    /// the badge's own label and the row's date. Nothing here reaches `fileName`
    /// or `sourceFileURL`: one is an internal `UUID.wav` and the other an
    /// absolute path whose directories the user has never been shown.
    static func query(
        matching filter: HistoryProvenanceFilter,
        searching search: HistorySearchQuery
    ) -> QueryInterfaceRequest<Recording> {
        let filtered = query(matching: filter)
        guard !search.isEmpty else { return filtered }

        let pattern = "%\(escapedForLike(search.text))%"
        var matches = Recording.Columns.transcription
            .like(pattern, escape: likeEscapeCharacter).collating(.nocase)
        matches = matches
            || Recording.Columns.rawTranscription
                .like(pattern, escape: likeEscapeCharacter).collating(.nocase)
        matches = matches
            || Recording.Columns.provenanceDetail
                .like(pattern, escape: likeEscapeCharacter).collating(.nocase)

        if !search.matchedKinds.isEmpty {
            matches = matches
                || search.matchedKinds.map(\.rawValue)
                    .contains(Recording.Columns.provenanceKind)
        }
        // The same NULL arm `query(matching:)` needs, for the same reason:
        // "Older recording" is what a row with nothing stored is *shown* as, and
        // `provenanceKind IN (…)` is false for NULL.
        if search.matchesUnrecordedProvenance {
            matches = matches || (Recording.Columns.provenanceKind == nil)
        }
        if let interval = search.dateInterval {
            matches = matches
                || (Recording.Columns.timestamp >= interval.start
                    && Recording.Columns.timestamp < interval.end)
        }

        return filtered.filter(matches)
    }

    /// Every row the app wrote for one source file, newest first.
    ///
    /// This is the one place `sourceFileURL` is queried, and the asymmetry with
    /// the search above is deliberate rather than an oversight. A *search* must
    /// never touch that column, because the user's phrase would then match the
    /// directories of files they were handed - a path is not something the card
    /// has ever shown them. Asking for the exact path a caller has just handed
    /// to the app is a different question: `echoforge transcribe` gave the app
    /// this file a moment ago and is asking what became of it.
    ///
    /// The comparison is against the four spellings one file can reach the app
    /// under, and no others. What is stored is whatever `path` LaunchServices
    /// delivered, and `/tmp/a.wav` arrives as `/private/tmp/a.wav` while
    /// `~/x/../a.wav` arrives standardized - so the exact string can differ from
    /// the one the caller typed for a file that is unambiguously the same one.
    /// Every candidate is still an **exact** match: nothing here matches by
    /// filename, prefix or similarity.
    static func query(forSourceFile url: URL) -> QueryInterfaceRequest<Recording> {
        let candidates = Array(Set([
            url.path,
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
            url.standardizedFileURL.resolvingSymlinksInPath().path,
        ]))
        return Recording
            .filter(candidates.contains(Recording.Columns.sourceFileURL))
            .order(Recording.Columns.timestamp.desc)
    }

    /// The escape character the search patterns are built with.
    ///
    /// LIKE has wildcards of its own, and a search field does not: without this
    /// a user typing `100%` would be asking for every row starting `100`, and
    /// one typing `_` for every row at all. See `escapedForLike`.
    private static let likeEscapeCharacter = "\\"

    /// Neutralises the three characters LIKE reads as syntax.
    ///
    /// The backslash first, or escaping the wildcards would escape the escapes
    /// that were just added.
    static func escapedForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

}
