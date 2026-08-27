import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Provenance where it is durable: in the database, across the migration, and
/// through the query the history list is paged with.
///
/// The migration half matters most. Every user runs it against a history full of
/// transcripts they cannot get back, and the whole point of the feature is
/// undone if the upgrade decides on their behalf what their old rows were - so
/// what these hold is that it decides nothing at all.
final class HistoryProvenanceStoreTests: XCTestCase {

    private var databaseURL: URL!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-provenance-\(UUID().uuidString).sqlite")
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

    // MARK: - The migration

    func testTheThreeColumnsAreNullableWithNoDefault() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        for name in ["provenanceKind", "provenanceReason", "provenanceDetail"] {
            let column = try XCTUnwrap(try columnInfo(named: name), "\(name) is missing")
            XCTAssertEqual(column.type.uppercased(), "TEXT")
            XCTAssertFalse(
                column.isNotNull,
                "Existing recordings have no provenance, so \(name) must accept NULL.")
            XCTAssertNil(
                column.defaultValueSQL,
                "A default would write this build's guess into every row a user already has.")
        }
    }

    /// The load-bearing one: a recording made before this existed is an *older
    /// recording*, not a dictation. Back-filling `'dictation'` would have been
    /// one UPDATE, and would have relabelled every YouTube command the user ran
    /// before this shipped as ordinary typing - which is exactly the history
    /// they are opening History to read.
    func testAnExistingRecordingIsLegacyRatherThanRelabelled() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v3_add_raw_transcription")

        let id = UUID()
        try insertPreProvenanceRow(id: id, transcription: "Open YouTube channel Valley 101")

        try migrator.migrate(dbQueue)

        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.transcription, "Open YouTube channel Valley 101")
        XCTAssertNil(stored.provenanceKind)
        XCTAssertNil(stored.provenanceReason)
        XCTAssertNil(stored.provenanceDetail)
        XCTAssertEqual(stored.provenance, .unknown)
        XCTAssertEqual(stored.provenance.kind.label, "Older recording")
    }

    /// The same guard v2 and v3 carry, for the same reason: a database that
    /// somehow already has the column must migrate cleanly rather than failing
    /// with "duplicate column name" on every launch.
    func testTheMigrationToleratesAColumnThatAlreadyExists() throws {
        let migrator = RecordingStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v3_add_raw_transcription")
        try dbQueue.write { db in
            try db.execute(
                sql: "ALTER TABLE \(Recording.databaseTableName) ADD COLUMN provenanceKind TEXT")
        }

        XCTAssertNoThrow(try migrator.migrate(dbQueue))
        XCTAssertNotNil(try columnInfo(named: "provenanceKind"))
        XCTAssertNotNil(try columnInfo(named: "provenanceReason"))
        XCTAssertNotNil(try columnInfo(named: "provenanceDetail"))
    }

    // MARK: - Round trips

    func testARefusedCommandSurvivesTheDatabase() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        var recording = makeRecording(transcription: "Open YouTube channel Valley 101")
        recording.provenance = .youTubeCommandNotOpened(
            reason: .channelUnknown,
            message: "No allowlisted YouTube channel answers to “Vali101”.")

        try dbQueue.write { try recording.insert($0) }
        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })

        XCTAssertEqual(stored.provenance.kind, .youTubeCommandNotOpened)
        XCTAssertEqual(stored.provenance.refusal, .channelUnknown)
        XCTAssertEqual(
            stored.provenance.detail,
            "No allowlisted YouTube channel answers to “Vali101”.")
    }

    func testAnOpenedCommandSurvivesTheDatabase() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        var recording = makeRecording(transcription: "Valley 101")
        recording.provenance = .command(
            .opened(channel: "valley101", title: "An episode", match: .spacing))

        try dbQueue.write { try recording.insert($0) }
        let stored = try XCTUnwrap(try dbQueue.read { try Recording.fetchOne($0) })

        XCTAssertEqual(stored.provenance.kind, .youTubeCommandOpened)
        XCTAssertNil(stored.provenance.refusal)
        XCTAssertEqual(try XCTUnwrap(stored.provenance.detail).contains("valley101"), true)
    }

    /// The picker's own states are durable, and they are the ones most likely
    /// to be read the next morning: "it asked me something and I closed it" is
    /// exactly the press a user cannot otherwise reconstruct.
    func testThePickerStatesSurviveTheDatabase() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        for reason in [YouTubeCommandRefusal.pickerShown, .pickerCancelled,
                       .noChannelsConfigured] {
            var recording = makeRecording(transcription: "Vali101")
            recording.provenance = .youTubeCommandNotOpened(
                reason: reason, message: "about “Vali101”")
            try dbQueue.write { try recording.insert($0) }

            let stored = try XCTUnwrap(
                try dbQueue.read { try Recording.filter(key: recording.id).fetchOne($0) })
            XCTAssertEqual(stored.provenance.kind, .youTubeCommandNotOpened)
            XCTAssertEqual(stored.provenance.refusal, reason)
            XCTAssertEqual(stored.provenance.detail, "about “Vali101”")
        }
    }

    /// A row written by a build that knows a refusal this one does not comes
    /// back as an older recording rather than as a guess - which is what makes
    /// adding a reason a safe thing to do to a database full of transcripts
    /// nobody can get back.
    func testARefusalThisBuildDoesNotKnowIsAnOlderRecordingRatherThanAGuess() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        let provenance = RecordingProvenance.stored(
            kind: RecordingProvenanceKind.youTubeCommandNotOpened.rawValue,
            reason: "somethingAFutureBuildAdded",
            detail: "written by a newer Kongweh"
        )
        XCTAssertEqual(provenance, .unknown)
    }

    /// A picker row that the user later re-transcribes from History keeps its
    /// class - what that press did does not change - and loses only the sentence
    /// quoting the old spelling.
    func testAPickerRowRetranscribedFromHistoryKeepsItsClass() {
        let after = RecordingProvenance
            .youTubeCommandNotOpened(reason: .pickerCancelled, message: "about “Vali101”")
            .reTranscribed()

        XCTAssertEqual(after.refusal, .pickerCancelled)
        XCTAssertEqual(after.detail?.contains("Vali101"), false)
        XCTAssertEqual(after.detail?.contains("transcribed again from History"), true)
    }

    /// The list filters in SQL, and both picker outcomes belong to the group a
    /// user is looking for when they ask what did not open.
    func testThePickerRowsAreFoundByTheNotOpenedFilter() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        try insert(
            makeRecording(transcription: "Vali101"),
            as: .youTubeCommandNotOpened(reason: .pickerCancelled, message: "cancelled"))
        try insert(
            makeRecording(transcription: "Vali101 again"),
            as: .youTubeCommandNotOpened(reason: .pickerShown, message: "waiting"))
        try insert(
            makeRecording(transcription: "valley101"),
            as: .command(.opened(channel: "valley101", title: "A video", match: .picker(spoken: "Vali101"))))

        XCTAssertEqual(try count(matching: .youTubeCommandNotOpened), 2)
        XCTAssertEqual(try count(matching: .youTubeCommandOpened), 1)
        XCTAssertEqual(try count(matching: .dictation), 0, "A command is never filed as dictation.")
        XCTAssertEqual(try count(matching: .ask), 0, "And never as Ask.")
    }

    func testAssigningAProvenanceReplacesTheOneBeforeIt() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        var recording = makeRecording(transcription: "Veritasium")
        recording.provenance = .youTubeCommandNotOpened(
            reason: .didNotFinish, message: "not finished")
        // The real sequence: the row is written as not-opened, then the report
        // arrives. Nothing of the provisional value may survive it.
        recording.provenance = .command(
            .opened(channel: "Veritasium", title: "A video", match: .spokenName))

        XCTAssertNil(recording.provenanceReason)
        XCTAssertEqual(recording.provenance.kind, .youTubeCommandOpened)
    }

    // MARK: - The filter, in SQL

    /// The one arm a filter over the loaded page would get wrong, and the one
    /// SQL gets wrong by default: `provenanceKind IN (…)` is false for NULL, so
    /// "Older recording" has to ask for the NULL and every other filter has to
    /// leave it out.
    func testEachFilterSelectsItsOwnRowsIncludingTheOnesWithNothingStored() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)

        try insert(makeRecording(transcription: "typed into an editor"), as: .dictation)
        try insert(makeRecording(transcription: "a question"), as: .ask)
        try insert(
            makeRecording(transcription: "Veritasium"),
            as: .command(.opened(channel: "Veritasium", title: "A video", match: .spokenName)))
        try insert(
            makeRecording(transcription: "Vali101"),
            as: .youTubeCommandNotOpened(reason: .channelUnknown, message: "not in your list"))
        try insert(makeRecording(transcription: "a dropped file"), as: .fileTranscription)
        try insertPreProvenanceRow(id: UUID(), transcription: "from before all this")

        XCTAssertEqual(try count(matching: .all), 6)
        XCTAssertEqual(try count(matching: .dictation), 1)
        XCTAssertEqual(try count(matching: .ask), 1)
        XCTAssertEqual(try count(matching: .youTubeCommandOpened), 1)
        XCTAssertEqual(try count(matching: .youTubeCommandNotOpened), 1)
        XCTAssertEqual(try count(matching: .fileTranscription), 1)
        XCTAssertEqual(
            try count(matching: .unknown), 1,
            "A row with nothing stored is what “Older recording” is for.")

        let legacy = try fetch(matching: .unknown)
        XCTAssertEqual(legacy.first?.transcription, "from before all this")
    }

    /// A row stored *as* `.unknown` and a row with nothing stored are the same
    /// thing to a reader, so the one filter has to find both.
    func testTheLegacyFilterFindsBothWaysOfHavingNoProvenance() throws {
        try RecordingStore.makeMigrator().migrate(dbQueue)
        try insert(makeRecording(transcription: "explicitly unknown"), as: .unknown)
        try insertPreProvenanceRow(id: UUID(), transcription: "never had one")

        XCTAssertEqual(try count(matching: .unknown), 2)
        XCTAssertEqual(try count(matching: .dictation), 0)
    }

    func testEveryFilterHasATitleAndKnowsWhatItAdmits() {
        XCTAssertNil(HistoryProvenanceFilter.all.kinds)
        XCTAssertTrue(HistoryProvenanceFilter.all.includesUnrecorded)
        XCTAssertTrue(HistoryProvenanceFilter.unknown.includesUnrecorded)

        for filter in HistoryProvenanceFilter.allCases {
            XCTAssertFalse(filter.title.isEmpty, "\(filter) has no title")
            guard filter != .all, filter != .unknown else { continue }
            XCTAssertFalse(
                filter.includesUnrecorded,
                "\(filter) must not sweep up rows nobody wrote a provenance for")
        }

        // Every kind but `.unknown` is reachable from the control, so a row can
        // always be filtered to by its own label.
        let reachable = Set(HistoryProvenanceFilter.allCases.compactMap(\.kinds).flatMap { $0 })
        XCTAssertEqual(reachable, Set(RecordingProvenanceKind.allCases))
    }

    // MARK: - Helpers

    private func columnInfo(named name: String) throws -> ColumnInfo? {
        try dbQueue.read { db in
            try db.columns(in: Recording.databaseTableName).first { $0.name == name }
        }
    }

    private func count(matching filter: HistoryProvenanceFilter) throws -> Int {
        try dbQueue.read { try RecordingStore.query(matching: filter).fetchCount($0) }
    }

    private func fetch(matching filter: HistoryProvenanceFilter) throws -> [Recording] {
        try dbQueue.read { try RecordingStore.query(matching: filter).fetchAll($0) }
    }

    private func insert(_ recording: Recording, as provenance: RecordingProvenance) throws {
        var row = recording
        row.provenance = provenance
        try dbQueue.write { try row.insert($0) }
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
    /// build that predates provenance.
    private func insertPreProvenanceRow(id: UUID, transcription: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Recording.databaseTableName)
                    (id, timestamp, fileName, transcription, duration, status, progress)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, Date(timeIntervalSince1970: 1_600_000_000), "1600000000.wav",
                    transcription, 4.0, "completed", 1.0,
                ]
            )
        }
    }
}
