import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Pins the schema history of the recordings database.
///
/// Every user upgrading the app runs these migrations against a database full
/// of transcripts they cannot get back, so the cases that matter are: a fresh
/// install ends up with the same schema as an upgraded one, and an upgrade
/// keeps every existing row exactly as it was.
final class RecordingMigrationTests: XCTestCase {

    private var databaseURL: URL!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-migration-\(UUID().uuidString).sqlite")
        dbQueue = try DatabaseQueue(path: databaseURL.path)
    }

    override func tearDownWithError() throws {
        dbQueue = nil
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        databaseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Fresh database

    func testMigrationOrderIsStable() {
        XCTAssertEqual(
            RecordingStore.makeMigrator().migrations,
            ["v1", "v2_add_status", "v3_add_raw_transcription", "v4_add_provenance"],
            "Migrations are identified by name and applied in order; renaming or reordering one re-runs it on databases that already have it."
        )
    }

    func testFreshDatabaseHasNullableRawTranscriptionColumn() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        let column = try XCTUnwrap(try columnInfo(named: "rawTranscription"))
        XCTAssertEqual(column.type.uppercased(), "TEXT")
        XCTAssertFalse(column.isNotNull, "Existing recordings have no raw transcription, so the column must accept NULL.")
        XCTAssertNil(column.defaultValueSQL)
    }

    func testFreshDatabaseKeepsEveryEarlierColumn() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        let names = try dbQueue.read { try $0.columns(in: Recording.databaseTableName).map(\.name) }
        XCTAssertEqual(
            Set(names),
            ["id", "timestamp", "fileName", "transcription", "duration",
             "status", "progress", "sourceFileURL", "rawTranscription",
             "provenanceKind", "provenanceReason", "provenanceDetail"]
        )
    }

    func testRecordingRoundTripsWithoutARawTranscription() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        let recording = makeRecording(transcription: "hello there")

        try dbQueue.write { try recording.insert($0) }
        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })

        XCTAssertEqual(stored.id, recording.id)
        XCTAssertEqual(stored.transcription, "hello there")
        XCTAssertNil(
            stored.rawTranscription,
            "A transcription that post-processing left alone keeps no second copy of itself."
        )
    }

    func testRecordingRoundTripsWithARawTranscription() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        var recording = makeRecording(transcription: "你好，世界")
        recording.rawTranscription = "你好,世界"

        try dbQueue.write { try recording.insert($0) }
        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })

        XCTAssertEqual(stored.transcription, "你好，世界")
        XCTAssertEqual(stored.rawTranscription, "你好,世界")
    }

    // MARK: - Upgrading an existing v2 database

    func testExistingV2RecordingSurvivesTheUpgrade() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v2_add_status")

        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try insertV2Row(
            id: id,
            timestamp: timestamp,
            fileName: "1700000000.wav",
            transcription: "the transcript a user would hate to lose",
            duration: 12.5,
            status: "completed",
            progress: 1.0,
            sourceFileURL: "/Users/someone/Downloads/interview.m4a"
        )

        try migrator.migrate(dbQueue)

        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(stored.fileName, "1700000000.wav")
        XCTAssertEqual(stored.transcription, "the transcript a user would hate to lose")
        XCTAssertEqual(stored.duration, 12.5, accuracy: 0.0001)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.progress, 1.0)
        XCTAssertEqual(stored.sourceFileURL, "/Users/someone/Downloads/interview.m4a")
        XCTAssertNil(stored.rawTranscription, "The upgrade must not invent a raw transcription for recordings made before it.")
    }

    func testUpgradeAppliesOnlyTheNewMigration() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v2_add_status")
        XCTAssertNil(try columnInfo(named: "rawTranscription"))

        try migrator.migrate(dbQueue)

        let applied = try dbQueue.read { try migrator.appliedIdentifiers($0) }
        XCTAssertEqual(
            applied,
            ["v1", "v2_add_status", "v3_add_raw_transcription", "v4_add_provenance"])
        XCTAssertNotNil(try columnInfo(named: "rawTranscription"))
    }

    func testMigratingAnAlreadyMigratedDatabaseChangesNothing() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue)
        let recording = makeRecording(transcription: "still here")
        try dbQueue.write { try recording.insert($0) }

        try migrator.migrate(dbQueue)

        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })
        XCTAssertEqual(stored.transcription, "still here")
        XCTAssertEqual(try dbQueue.read { try Recording.fetchCount($0) }, 1)
    }

    /// The v2 migration tolerates a column that is already there, because early
    /// builds added columns outside the migrator. v3 keeps that guard, so a
    /// database that somehow already has the column must still migrate cleanly
    /// instead of failing with "duplicate column name" on every launch.
    func testMigrationToleratesAColumnThatAlreadyExists() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v2_add_status")
        try dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE \(Recording.databaseTableName) ADD COLUMN rawTranscription TEXT")
        }

        XCTAssertNoThrow(try migrator.migrate(dbQueue))
        XCTAssertNotNil(try columnInfo(named: "rawTranscription"))
    }

    // MARK: - Helpers

    private func columnInfo(named name: String) throws -> ColumnInfo? {
        try dbQueue.read { db in
            try db.columns(in: Recording.databaseTableName).first { $0.name == name }
        }
    }

    private func makeRecording(transcription: String) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000.wav",
            transcription: transcription,
            duration: 3.0,
            status: .completed,
            progress: 1.0,
            sourceFileURL: nil
        )
    }

    /// Inserts through raw SQL, so the row looks exactly like one written by a
    /// build that predates `rawTranscription`.
    private func insertV2Row(
        id: UUID,
        timestamp: Date,
        fileName: String,
        transcription: String,
        duration: TimeInterval,
        status: String,
        progress: Double,
        sourceFileURL: String?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Recording.databaseTableName)
                    (id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL]
            )
        }
    }
}
