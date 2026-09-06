import Foundation
import GRDB

/// What `echoforge history` asks for.
struct HistoryRequest: Equatable {
    /// The phrase, resolved by `HistorySearchQuery` exactly as the History pane
    /// resolves what the user types into its search field.
    let query: String?

    /// How many rows to return. Always set - there is no "all".
    let limit: Int

    /// Which kinds of row to include, the History pane's own filter.
    let filter: HistoryProvenanceFilter

    init(query: String? = nil, limit: Int = HistoryLimits.defaultLimit, filter: HistoryProvenanceFilter = .all) {
        self.query = query
        self.limit = limit
        self.filter = filter
    }
}

/// The bounds on a history read.
enum HistoryLimits {
    /// What a bare `echoforge history` returns.
    ///
    /// Bounded rather than unbounded, and bounded at a screenful: this database
    /// holds every dictation the user has ever made, and a tool that answered
    /// `history` by writing all of them to a terminal would be unusable exactly
    /// on the machines that have the most to say.
    static let defaultLimit = 20

    /// The most `--limit` may ask for. A ceiling rather than no ceiling, for
    /// the same reason: `--limit 500000` is not a request anybody means.
    static let maximumLimit = 1000
}

/// One page of history, and what it was drawn from.
struct HistoryPage: Equatable {
    let rows: [Recording]

    /// How many rows match, which is not `rows.count` when the limit cut it
    /// off. Reported so a script can tell "that is all of them" from "there is
    /// more" without asking twice.
    let totalMatching: Int

    let databasePath: String
}

protocol HistoryReading {
    func read(_ request: HistoryRequest, now: Date) throws -> HistoryPage
}

/// Reads the app's recordings database without being able to change it.
///
/// Three things make that true rather than intended. The connection is opened
/// **read-only**, so a bug in this tool cannot write a row. It never runs the
/// migrator, so a tool built from a newer checkout cannot upgrade the schema
/// under an older app - the app is the only thing that migrates, and this reads
/// what it finds. And the queries are `RecordingSchema`'s own, the ones the
/// History pane runs, so a search here means what a search there means.
struct ReadOnlyHistoryReader: HistoryReading {
    let databaseURL: URL
    let fileSystem: FileSystemReading

    init(
        databaseURL: URL = AppDataLocation.recordingsDatabaseURL(),
        fileSystem: FileSystemReading = SystemFileSystem()
    ) {
        self.databaseURL = databaseURL
        self.fileSystem = fileSystem
    }

    func read(_ request: HistoryRequest, now: Date) throws -> HistoryPage {
        guard fileSystem.fileExists(at: databaseURL) else {
            throw CLIError(
                "No history database at \(databaseURL.path). Kongweh writes it the first time it "
                    + "runs, so this usually means the app has not been started on this Mac yet.",
                exitCode: .sourceUnavailable)
        }

        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        } catch {
            throw CLIError(
                "The history database could not be opened. \(error.localizedDescription)",
                exitCode: .sourceUnavailable)
        }

        // Resolved here rather than in the query, because the phrase's meaning
        // depends on a clock and this tool takes its clock from the environment.
        let search = HistorySearchQuery(request.query ?? "", now: now)
        let matching = RecordingSchema.query(matching: request.filter, searching: search)

        do {
            return try queue.read { database in
                let total = try matching.fetchCount(database)
                let rows = try matching
                    .order(Recording.Columns.timestamp.desc)
                    .limit(request.limit)
                    .fetchAll(database)
                return HistoryPage(rows: rows, totalMatching: total, databasePath: databaseURL.path)
            }
        } catch {
            // A column the app added and this build has never heard of lands
            // here as a decoding failure. Saying which file and what to do is
            // the difference between a bug report and a shrug.
            throw CLIError(
                "The history database could not be read. It may have been written by a newer "
                    + "Kongweh than this tool was built from. \(error.localizedDescription)",
                exitCode: .sourceUnavailable)
        }
    }
}
