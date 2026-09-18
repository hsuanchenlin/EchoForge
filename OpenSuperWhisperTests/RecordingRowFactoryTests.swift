import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Two history rows never share an audio file.
///
/// They used to. A new row's `fileName` was the timestamp to the second,
/// computed inline at each of the five places a row was built, and several
/// files dropped together are queued microseconds apart - so three rows
/// pointed at one `.wav`, the queue's copy replaced the earlier recordings
/// with the last, and deleting any one of the rows removed the audio of all of
/// them. `Recording.newRow` is now the one place a new row is made and names
/// the file by the row's own id; this file holds that the names are distinct,
/// that the two file operations around them keep two recordings as two, and
/// that an older row named the old way is untouched.
///
/// Everything here runs against a database and a directory of its own, never
/// the user's.
final class RecordingRowFactoryTests: XCTestCase {

    private var root: URL!
    private var recordingsDirectory: URL!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("row-factory-\(UUID().uuidString)", isDirectory: true)
        recordingsDirectory = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: root.appendingPathComponent("recordings.sqlite").path)
        try RecordingStore.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws {
        dbQueue = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        recordingsDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Names

    /// The report's case, one order of magnitude up: a hundred rows made at
    /// the same instant have a hundred files.
    func testAHundredRowsMadeInOneInstantHaveAHundredDistinctURLs() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.25)
        let rows = (0..<100).map { _ in
            Recording.newRow(
                transcription: "", duration: 1, status: .pending, progress: 0,
                provenance: .fileTranscription)
        }
        for row in rows {
            XCTAssertEqual(
                row.timestamp.timeIntervalSince1970, Date().timeIntervalSince1970, accuracy: 5,
                "a row's timestamp is when it was made")
        }

        let pinned = (0..<100).map { _ in
            Recording.newRow(
                timestamp: instant,
                transcription: "", duration: 1, status: .pending, progress: 0,
                provenance: .fileTranscription)
        }
        XCTAssertEqual(Set(pinned.map(\.timestamp)).count, 1, "all made at the one instant")
        XCTAssertEqual(Set(pinned.map(\.fileName)).count, 100, "and every one has its own file")
        XCTAssertEqual(Set(pinned.map(\.url)).count, 100)
        XCTAssertEqual(Set(rows.map(\.fileName)).count, 100)
    }

    /// Why the factory exists, kept as the one line it was: two rows built a
    /// third of a second apart the old way had the same name.
    func testTheSecondGranularityNameTheFactoryReplacedDidCollide() {
        let first = Date(timeIntervalSince1970: 1_700_000_000.10)
        let second = first.addingTimeInterval(0.3)
        XCTAssertEqual(
            "\(Int(first.timeIntervalSince1970)).wav",
            "\(Int(second.timeIntervalSince1970)).wav")
        XCTAssertNotEqual(
            Recording.newRow(
                timestamp: first, transcription: "", duration: 1, status: .pending,
                progress: 0, provenance: .fileTranscription
            ).fileName,
            Recording.newRow(
                timestamp: second, transcription: "", duration: 1, status: .pending,
                progress: 0, provenance: .fileTranscription
            ).fileName)
    }

    /// The name is the row's id and nothing else: stable for the row's life,
    /// and one path component that resolves inside the recordings directory
    /// rather than beside it.
    func testTheFileNameIsTheRowsIdAsOneSafePathComponent() {
        let id = UUID()
        let row = Recording.newRow(
            id: id, transcription: "", duration: 1, status: .completed, progress: 1,
            provenance: .dictation)

        XCTAssertEqual(row.fileName, "\(id.uuidString).wav")
        XCTAssertEqual(row.fileName, Recording.audioFileName(for: id))
        XCTAssertFalse(row.fileName.contains("/"))
        XCTAssertFalse(row.fileName.contains(".."))
        XCTAssertTrue(row.fileName.hasSuffix(".wav"))
        XCTAssertEqual(row.url.lastPathComponent, row.fileName)
        XCTAssertEqual(row.url.deletingLastPathComponent().standardizedFileURL,
                       Recording.recordingsDirectory.standardizedFileURL)
        XCTAssertEqual(row.audioURL(in: recordingsDirectory),
                       recordingsDirectory.appendingPathComponent(row.fileName))
    }

    /// The factory names the file and does nothing else to what it is given:
    /// each of the five callers keeps its own status, provenance, texts,
    /// duration and time.
    func testEveryFieldACallerPassesIsStoredAsPassed() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let row = Recording.newRow(
            id: id,
            timestamp: timestamp,
            transcription: "Polished words.",
            duration: 12.5,
            status: .completed,
            progress: 1.0,
            sourceFileURL: "/Users/someone/Downloads/interview.m4a",
            rawTranscription: "polished words",
            provenance: .selectionEdit(instruction: "make it formal")
        )

        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.timestamp, timestamp)
        XCTAssertEqual(row.transcription, "Polished words.")
        XCTAssertEqual(row.duration, 12.5)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.progress, 1.0)
        XCTAssertEqual(row.sourceFileURL, "/Users/someone/Downloads/interview.m4a")
        XCTAssertEqual(row.rawTranscription, "polished words")
        XCTAssertEqual(row.provenance, .selectionEdit(instruction: "make it formal"))
        XCTAssertNil(row.aiCorrectedAt)
        XCTAssertFalse(row.isRegeneration)

        // And the defaults are the ones every caller relied on: a fresh id, a
        // row made now, no source, no raw copy.
        let bare = Recording.newRow(
            transcription: "Engine failed to load.", duration: 3, status: .failed,
            progress: 0, provenance: .dictation)
        XCTAssertNil(bare.sourceFileURL)
        XCTAssertNil(bare.rawTranscription)
        XCTAssertEqual(bare.provenance, .dictation)
        XCTAssertEqual(bare.timestamp.timeIntervalSince1970, Date().timeIntervalSince1970, accuracy: 5)

        // The round trip through the database keeps the name it was given.
        try dbQueue.write { try row.insert($0) }
        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })
        XCTAssertEqual(stored.fileName, "\(id.uuidString).wav")
        XCTAssertEqual(stored.provenance, .selectionEdit(instruction: "make it formal"))
    }

    // MARK: - The two file operations around the name

    /// The causal chain the defect ran along, with the new names: two files
    /// imported at one instant are two rows, the queue's placement keeps two
    /// files with their own bytes, and deleting one row - the row and the audio
    /// at its `url`, exactly what `RecordingStore.deleteRecording` removes -
    /// leaves the other's audio where it was.
    func testTwoImportedFixturesKeepTwoFilesAndDeletingOneKeepsTheOther() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.100)
        var rows: [Recording] = []
        var sources: [URL] = []
        for index in 0..<2 {
            let source = root.appendingPathComponent("drop-\(index).wav")
            try Data(repeating: UInt8(index + 1), count: 64).write(to: source)
            sources.append(source)
            let row = Recording.newRow(
                timestamp: instant.addingTimeInterval(Double(index) * 0.0002),
                transcription: "", duration: 1, status: .pending, progress: 0,
                sourceFileURL: source.path, provenance: .fileTranscription)
            try dbQueue.write { try row.insert($0) }
            rows.append(row)
        }

        for (row, source) in zip(rows, sources) {
            try TranscriptionQueue.placeAudio(from: source, at: row.audioURL(in: recordingsDirectory))
        }

        let placed = try FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path)
        XCTAssertEqual(Set(placed), Set(rows.map(\.fileName)), "two rows, two files")
        XCTAssertEqual(try Data(contentsOf: rows[0].audioURL(in: recordingsDirectory)),
                       Data(repeating: 1, count: 64), "the first recording's own bytes")
        XCTAssertEqual(try Data(contentsOf: rows[1].audioURL(in: recordingsDirectory)),
                       Data(repeating: 2, count: 64), "the second recording's own bytes")
        for source in sources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                          "a file the user pointed at is copied, never moved")
        }

        try dbQueue.write { _ = try rows[0].delete($0) }
        try FileManager.default.removeItem(at: rows[0].audioURL(in: recordingsDirectory))

        let remaining = try dbQueue.read { try Recording.fetchAll($0) }
        XCTAssertEqual(remaining.map(\.id), [rows[1].id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rows[0].audioURL(in: recordingsDirectory).path))
        XCTAssertEqual(try Data(contentsOf: rows[1].audioURL(in: recordingsDirectory)),
                       Data(repeating: 2, count: 64), "the other row still has its audio")
    }

    /// A regenerate copies a row's source over its own earlier audio, which is
    /// the one case the replacement in `placeAudio` exists for; and a source
    /// that already is the destination is left alone rather than removed.
    func testPlacementReplacesOnlyTheSameRowsEarlierAudio() throws {
        let source = root.appendingPathComponent("interview.m4a")
        try Data(repeating: 7, count: 32).write(to: source)
        let row = Recording.newRow(
            transcription: "", duration: 1, status: .pending, progress: 0,
            sourceFileURL: source.path, provenance: .fileTranscription)
        let final = row.audioURL(in: recordingsDirectory)

        try Data(repeating: 0, count: 8).write(to: final)  // this row's earlier pass
        try TranscriptionQueue.placeAudio(from: source, at: final)
        XCTAssertEqual(try Data(contentsOf: final), Data(repeating: 7, count: 32))

        try TranscriptionQueue.placeAudio(from: final, at: final)
        XCTAssertEqual(try Data(contentsOf: final), Data(repeating: 7, count: 32),
                       "placing a file onto itself keeps it")

        // The directory is created on the way, as the queue always did.
        let fresh = root.appendingPathComponent("elsewhere", isDirectory: true)
            .appendingPathComponent(row.fileName)
        try TranscriptionQueue.placeAudio(from: source, at: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Older rows

    /// A row written before the factory keeps the name it was written with.
    /// Nothing migrates or renames it: it is read back, its audio is found where
    /// it always was, and it is deleted the same way.
    func testARowNamedBeforeTheFactoryStillResolvesAndIsStillDeletable() throws {
        let migrator = RecordingStore.makeMigrator()
        let id = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recordings
                        (id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    id, Date(timeIntervalSince1970: 1_600_000_000), "1600000000.wav",
                    "an older dictation", 4.0, "completed", 1.0,
                ])
        }
        try migrator.migrate(dbQueue)

        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })
        XCTAssertEqual(stored.fileName, "1600000000.wav")
        XCTAssertEqual(stored.url, Recording.recordingsDirectory.appendingPathComponent("1600000000.wav"))

        let audio = stored.audioURL(in: recordingsDirectory)
        try Data(repeating: 9, count: 16).write(to: audio)
        XCTAssertEqual(try Data(contentsOf: audio), Data(repeating: 9, count: 16),
                       "its audio is found under the old name")

        try dbQueue.write { _ = try stored.delete($0) }
        try FileManager.default.removeItem(at: audio)
        XCTAssertEqual(try dbQueue.read { try Recording.fetchCount($0) }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
}
