import Foundation
import GRDB
import XCTest

/// `history` against a real database, because the parts worth testing are the
/// SQL ones.
///
/// The database is built here by running `RecordingSchema.makeMigrator()` on a
/// throwaway file - the app's own migrations, not a hand-written schema - which
/// is the point: if this suite had to write its own `CREATE TABLE`, the tool
/// would have a second schema and these tests would be asserting it against
/// itself.
final class HistoryCommandTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("echoforge-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("recordings.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeDatabase(_ recordings: [Recording]) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try RecordingSchema.makeMigrator().migrate(queue)
        try queue.write { database in
            for recording in recordings { try recording.insert(database) }
        }
    }

    private func reader() -> ReadOnlyHistoryReader {
        ReadOnlyHistoryReader(databaseURL: databaseURL, fileSystem: SystemFileSystem())
    }

    private func environment(_ recordings: [Recording]) throws -> CLIEnvironment {
        try makeDatabase(recordings)
        var environment = CLITestEnvironment.empty()
        environment.history = reader()
        return environment
    }

    private func recording(
        _ text: String, at offset: TimeInterval, provenance: RecordingProvenance = .dictation
    ) -> Recording {
        var value = Recording.fixture(
            transcription: text,
            timestamp: Date(timeIntervalSince1970: 1_756_000_000 + offset),
            provenance: provenance)
        value = Recording(
            id: UUID(), timestamp: value.timestamp, fileName: "\(UUID().uuidString).wav",
            transcription: text, duration: 1, status: .completed, progress: 1,
            sourceFileURL: nil)
        value.provenance = provenance
        return value
    }

    // MARK: - Bounds

    func testABareHistoryIsBoundedToTheDefaultPage() async throws {
        let many = (0..<60).map { recording("line \($0)", at: TimeInterval($0)) }
        let execution = await runCLI(["history", "--json"], environment: try environment(many))

        let json = try execution.decodedJSON()
        XCTAssertEqual(json["returned"] as? Int, HistoryLimits.defaultLimit)
        XCTAssertEqual(json["totalMatching"] as? Int, 60)
        XCTAssertEqual((json["recordings"] as? [Any])?.count, HistoryLimits.defaultLimit)
    }

    func testTheTextRenderingSaysWhenItTruncated() async throws {
        let many = (0..<30).map { recording("line \($0)", at: TimeInterval($0)) }
        let execution = await runCLI(["history", "--limit", "5"], environment: try environment(many))

        XCTAssertTrue(execution.output.contains("Showing 5 of 30"))
    }

    func testLimitIsHonouredAndCapped() async throws {
        let many = (0..<10).map { recording("line \($0)", at: TimeInterval($0)) }
        let environment = try environment(many)

        let three = await runCLI(["history", "--limit", "3", "--json"], environment: environment)
        XCTAssertEqual(try three.decodedJSON()["returned"] as? Int, 3)

        let overLimit = await runCLI(
            ["history", "--limit", "\(HistoryLimits.maximumLimit + 1)"], environment: environment)
        XCTAssertEqual(overLimit.exitCode, .usage)
    }

    // MARK: - Search

    func testSearchIsCaseInsensitiveOverTheTranscript() async throws {
        let environment = try environment([
            recording("Meeting notes for Tuesday", at: 0),
            recording("grocery list", at: 10),
        ])

        let execution = await runCLI(
            ["history", "--query", "MEETING", "--json"], environment: environment)

        let json = try execution.decodedJSON()
        XCTAssertEqual(json["totalMatching"] as? Int, 1)
        let first = (json["recordings"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["transcript"] as? String, "Meeting notes for Tuesday")
    }

    /// The reason the search runs through `HistorySearchQuery` rather than a
    /// `LIKE` this tool wrote: the badge's label is not in any column.
    func testSearchFindsARowByTheLabelItsBadgeShows() async throws {
        let environment = try environment([
            recording("make this shorter", at: 0, provenance: .selectionEdit(instruction: "shorten")),
            recording("ordinary dictation", at: 10),
        ])

        let execution = await runCLI(
            ["history", "--query", "voice edit", "--json"], environment: environment)

        let json = try execution.decodedJSON()
        XCTAssertEqual(json["totalMatching"] as? Int, 1)
        XCTAssertEqual(
            (json["recordings"] as? [[String: Any]])?.first?["kindLabel"] as? String,
            RecordingProvenanceKind.selectionEdit.label)
    }

    /// LIKE's own wildcards are neutralised, so a user typing `100%` is asking
    /// for a percent sign.
    func testSearchTreatsLikeWildcardsAsLiterals() async throws {
        let environment = try environment([
            recording("100% done", at: 0),
            recording("100 done", at: 10),
        ])

        let execution = await runCLI(["history", "--query", "100%", "--json"], environment: environment)

        XCTAssertEqual(try execution.decodedJSON()["totalMatching"] as? Int, 1)
    }

    func testNoMatchesSaysSoAndStillSucceeds() async throws {
        let execution = await runCLI(
            ["history", "--query", "nothing here"],
            environment: try environment([recording("hello", at: 0)]))

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertTrue(execution.output.contains("No recordings match"))
    }

    // MARK: - Unavailable

    func testAMissingDatabaseIsItsOwnExitCodeRatherThanAnEmptyList() async throws {
        var environment = CLITestEnvironment.empty()
        environment.history = reader()

        let execution = await runCLI(["history"], environment: environment)

        XCTAssertEqual(execution.exitCode, .sourceUnavailable)
        XCTAssertTrue(execution.diagnostic.contains("has not been started on this Mac yet"))
    }

    // MARK: - Read-only

    /// The load-bearing one. If this connection could write, a bug in this tool
    /// would be a bug in the user's dictation history.
    func testTheConnectionCannotWrite() throws {
        try makeDatabase([recording("hello", at: 0)])
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        XCTAssertThrowsError(
            try queue.write { database in
                try database.execute(sql: "DELETE FROM recordings")
            })
    }

    /// And it never migrates: a tool built from a newer checkout must not
    /// upgrade the schema under an older app.
    func testReadingDoesNotChangeTheSchemaVersion() async throws {
        let environment = try environment([recording("hello", at: 0)])
        let before = try appliedMigrations()

        _ = await runCLI(["history"], environment: environment)

        XCTAssertEqual(try appliedMigrations(), before)
    }

    private func appliedMigrations() throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try queue.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }
}

/// The preview is the only place a transcript is reshaped, and it is reshaped
/// for a terminal rather than for privacy - `--json` carries the whole thing.
final class TranscriptPreviewTests: XCTestCase {

    func testItCollapsesNewlinesSoOneRowStaysOneRow() {
        let recording = Recording.fixture(transcription: "first line\nsecond line")
        XCTAssertEqual(TranscriptPreview.line(for: recording), "first line second line")
    }

    /// A terminal interprets control characters; a transcript can contain them.
    func testItStripsControlCharacters() {
        let recording = Recording.fixture(transcription: "before\u{1B}[31mafter")
        let line = TranscriptPreview.line(for: recording)
        XCTAssertFalse(line.contains("\u{1B}"))
        XCTAssertTrue(line.contains("before"))
    }

    func testItTruncatesLongTranscriptsWithAMarker() {
        let recording = Recording.fixture(transcription: String(repeating: "x", count: 500))
        let line = TranscriptPreview.line(for: recording)
        XCTAssertEqual(line.count, TranscriptPreview.maximumLength)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    /// An empty transcript is a failed or in-flight row, and saying which is
    /// more useful than a blank line.
    func testAnEmptyTranscriptShowsTheStatusInstead() {
        let recording = Recording.fixture(transcription: "", status: .failed)
        XCTAssertEqual(TranscriptPreview.line(for: recording), "(failed)")
    }

    /// `--json` is for scripts and must not carry a truncated transcript.
    func testJSONCarriesTheWholeTranscript() {
        let long = String(repeating: "y", count: 500)
        let page = HistoryPage(
            rows: [Recording.fixture(transcription: long)], totalMatching: 1,
            databasePath: "/fake.sqlite")
        let json = HistoryCommand.json(for: page, query: nil).serialized

        XCTAssertTrue(json.contains(long))
    }
}
