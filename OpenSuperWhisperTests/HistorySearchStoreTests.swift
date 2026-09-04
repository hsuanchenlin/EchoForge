import GRDB
import XCTest

@testable import OpenSuperWhisper

/// History search where it actually runs: in SQL, against a real database.
///
/// The pure half is `HistorySearchQueryTests`. This is the other half, and it
/// exists for the reason `HistoryProvenanceStoreTests` does - history is paged,
/// so a search that matched over the loaded page would silently hide every older
/// row that matches, and the only way to know a phrase reaches a row is to ask
/// the database for it.
final class HistorySearchStoreTests: XCTestCase {

    private var databaseURL: URL!
    private var dbQueue: DatabaseQueue!

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-search-\(UUID().uuidString).sqlite")
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try RecordingStore.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws {
        dbQueue = nil
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        databaseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - No search

    func testAnEmptyPhraseLeavesTheListExactlyAsItWas() throws {
        try insert(recording(transcription: "one"), as: .dictation)
        try insert(recording(transcription: "two"), as: .ask)

        XCTAssertEqual(try count(searching: "", filter: .all), 2)
        XCTAssertEqual(try count(searching: "   ", filter: .all), 2)
        XCTAssertEqual(
            try count(searching: "", filter: .dictation), 1,
            "An empty phrase must not disturb the filter beside it.")
    }

    // MARK: - The words

    func testTheTranscriptIsMatchedCaseInsensitively() throws {
        try insert(recording(transcription: "Ship the Release Notes"), as: .dictation)

        for phrase in ["ship", "SHIP", "Release Notes", "release NOTES", "e rele"] {
            XCTAssertEqual(
                try count(searching: phrase, filter: .all), 1,
                "“\(phrase)” must find that transcript")
        }
        XCTAssertEqual(try count(searching: "deploy", filter: .all), 0)
    }

    /// The words behind "Show original" are on the card, one disclosure away,
    /// and they are the only record of what was actually said - so a user
    /// hunting for a phrase post-processing rewrote must be able to find it.
    func testTheOriginalBehindShowOriginalIsMatchedToo() throws {
        var row = recording(transcription: "Please review the pull request.")
        row.rawTranscription = "plz review the PR"
        try insert(row, as: .dictation)

        XCTAssertEqual(try count(searching: "plz", filter: .all), 1)
        XCTAssertEqual(try count(searching: "pull request", filter: .all), 1)
    }

    /// The sentence under the badge is the one thing a refused command leaves
    /// behind, and it is the row somebody opens History to read.
    func testTheProvenanceSentenceIsMatched() throws {
        try insert(
            recording(transcription: "Vali101"),
            as: .youTubeCommandNotOpened(
                reason: .channelUnknown,
                message: "No allowlisted YouTube channel answers to “Vali101”."))

        XCTAssertEqual(try count(searching: "allowlisted", filter: .all), 1)
        XCTAssertEqual(try count(searching: "answers to", filter: .all), 1)
    }

    /// LIKE has wildcards and a search field does not. Without escaping, `100%`
    /// asks for every row beginning `100` and `_` asks for every row at all.
    func testTheLikeWildcardsAreTypedRatherThanInterpreted() throws {
        try insert(recording(transcription: "up 100% on the week"), as: .dictation)
        try insert(recording(transcription: "100 units shipped"), as: .dictation)
        try insert(recording(transcription: "snake_case matters"), as: .dictation)

        XCTAssertEqual(
            try count(searching: "100%", filter: .all), 1,
            "“100%” must be the characters, not “anything starting 100”.")
        XCTAssertEqual(
            try count(searching: "_", filter: .all), 1,
            "“_” must be the character, not “any single character”.")
        XCTAssertEqual(try count(searching: "e_c", filter: .all), 1)
        XCTAssertEqual(try count(searching: "x_y", filter: .all), 0)
    }

    // MARK: - The badge

    func testAKindIsFoundByTheLabelOnItsBadge() throws {
        try insert(recording(transcription: "a sentence"), as: .dictation)
        try insert(recording(transcription: "another sentence"), as: .selectionEdit(instruction: "shorter"))
        try insert(recording(transcription: "a dropped file"), as: .fileTranscription)

        XCTAssertEqual(try count(searching: "Voice edit", filter: .all), 1)
        XCTAssertEqual(try count(searching: "voice edit", filter: .all), 1)
        XCTAssertEqual(try count(searching: "File transcription", filter: .all), 1)
        XCTAssertEqual(try count(searching: "Dictation", filter: .all), 1)
    }

    /// The NULL arm, again. A row from before provenance existed is shown as
    /// "Older recording", and typing that has to reach it - `provenanceKind IN
    /// (…)` never will.
    func testOlderRecordingFindsRowsWithNoProvenanceStored() throws {
        try insertPreProvenanceRow(transcription: "from before all this")
        try insert(recording(transcription: "recent"), as: .dictation)

        XCTAssertEqual(try count(searching: "Older recording", filter: .all), 1)
        let found = try fetch(searching: "Older recording", filter: .all)
        XCTAssertEqual(found.first?.transcription, "from before all this")
    }

    // MARK: - The date

    func testADayFindsTheRowsRecordedThatDay() throws {
        try insert(recording(transcription: "monday", at: "2026-09-04 09:15"), as: .dictation)
        try insert(recording(transcription: "tuesday", at: "2026-09-05 09:15"), as: .dictation)

        let found = try fetch(searching: "2026-09-04", filter: .all)
        XCTAssertEqual(found.map(\.transcription), ["monday"])
    }

    /// Half-open: the last second of the day is in and the first second of the
    /// next is out, which is the boundary an inclusive `<=` would get wrong.
    func testTheDayEndsWhereTheNextOneBegins() throws {
        try insert(recording(transcription: "last moment", at: "2026-09-04 23:59"), as: .dictation)
        try insert(recording(transcription: "first moment", at: "2026-09-05 00:00"), as: .dictation)

        XCTAssertEqual(
            try fetch(searching: "2026-09-04", filter: .all).map(\.transcription),
            ["last moment"])
    }

    func testAMonthFindsEveryRowInIt() throws {
        try insert(recording(transcription: "early", at: "2026-09-01 00:00"), as: .dictation)
        try insert(recording(transcription: "late", at: "2026-09-30 23:00"), as: .dictation)
        try insert(recording(transcription: "next month", at: "2026-10-01 00:00"), as: .dictation)

        XCTAssertEqual(try count(searching: "2026-09", filter: .all), 2)
    }

    // MARK: - The filter beside it

    /// The two are ANDed: choosing a kind narrows a search rather than replacing
    /// it, which is what a user who typed a word and then picked a kind expects.
    func testASearchAndAFilterNarrowEachOther() throws {
        try insert(recording(transcription: "shared word here"), as: .dictation)
        try insert(
            recording(transcription: "shared word there"),
            as: .selectionEdit(instruction: "shorter"))
        try insert(recording(transcription: "unrelated"), as: .selectionEdit(instruction: "shorter"))

        XCTAssertEqual(try count(searching: "shared word", filter: .all), 2)
        XCTAssertEqual(try count(searching: "shared word", filter: .selectionEdit), 1)
        XCTAssertEqual(try count(searching: "shared word", filter: .dictation), 1)
        XCTAssertEqual(try count(searching: "shared word", filter: .ask), 0)
    }

    // MARK: - Rows that are not finished

    /// A queued and a failed row are still rows, and a search must neither hide
    /// them behind a status check nor crash on their empty transcripts.
    func testPendingAndFailedRowsAreSearchableAndUnbroken() throws {
        var queued = recording(transcription: "", status: .transcribing)
        queued.progress = 0.4
        try insert(queued, as: .dictation)
        try insert(
            recording(transcription: "No engine could transcribe this.", status: .failed),
            as: .dictation)

        XCTAssertEqual(try count(searching: "engine", filter: .all), 1)
        XCTAssertEqual(
            try count(searching: "Dictation", filter: .all), 2,
            "A kind search reaches a row with no words in it at all.")
    }

    /// A file transcription is found by its words and by its badge, the same as
    /// a dictation - the brief's other half of "must work for both".
    func testAFileTranscriptionIsFoundTheSameWayADictationIs() throws {
        try insert(
            recording(transcription: "the interview recording"), as: .fileTranscription)

        XCTAssertEqual(try count(searching: "interview", filter: .all), 1)
        XCTAssertEqual(try count(searching: "File transcription", filter: .all), 1)
    }

    /// The path on the user's disk is not a searchable field. Its directories
    /// have never been on a card, and a match on one would be an accident of
    /// where they keep their files.
    func testTheStoredFilePathIsNotSearched() throws {
        try insert(
            recording(
                transcription: "the interview recording",
                sourceFileURL: "/Users/someone/Documents/Confidential Client/interview.m4a"),
            as: .fileTranscription)

        XCTAssertEqual(
            try count(searching: "Confidential Client", filter: .all), 0,
            "A directory name the card never showed must not be a way to find a row.")
        XCTAssertEqual(
            try count(searching: "interview", filter: .all), 1,
            "But the words are still found.")
    }

    /// The row's own audio file is a `UUID.wav` nobody has ever seen.
    func testTheInternalAudioFileNameIsNotSearched() throws {
        try insert(
            recording(transcription: "hello", fileName: "2E7B1C90-DEAD-BEEF.wav"),
            as: .dictation)

        XCTAssertEqual(try count(searching: "DEAD-BEEF", filter: .all), 0)
    }

    // MARK: - Helpers

    private func search(_ phrase: String) -> HistorySearchQuery {
        HistorySearchQuery(
            phrase, now: date("2026-09-04 12:00"), calendar: calendar,
            locale: Locale(identifier: "en_US"))
    }

    private func count(searching phrase: String, filter: HistoryProvenanceFilter) throws -> Int {
        try dbQueue.read {
            try RecordingStore.query(matching: filter, searching: search(phrase)).fetchCount($0)
        }
    }

    private func fetch(
        searching phrase: String, filter: HistoryProvenanceFilter
    ) throws -> [Recording] {
        try dbQueue.read {
            try RecordingStore.query(matching: filter, searching: search(phrase))
                .order(Recording.Columns.timestamp.desc)
                .fetchAll($0)
        }
    }

    private func insert(_ recording: Recording, as provenance: RecordingProvenance) throws {
        var row = recording
        row.provenance = provenance
        try dbQueue.write { try row.insert($0) }
    }

    private func recording(
        transcription: String,
        at moment: String = "2026-09-04 10:00",
        status: RecordingStatus = .completed,
        fileName: String? = nil,
        sourceFileURL: String? = nil
    ) -> Recording {
        Recording(
            id: UUID(),
            timestamp: date(moment),
            fileName: fileName ?? "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 3.0,
            status: status,
            progress: status == .completed ? 1.0 : 0.0,
            sourceFileURL: sourceFileURL
        )
    }

    private func insertPreProvenanceRow(transcription: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Recording.databaseTableName)
                    (id, timestamp, fileName, transcription, duration, status, progress)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID(), self.date("2026-09-04 08:00"), "legacy.wav",
                    transcription, 4.0, "completed", 1.0,
                ]
            )
        }
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }
}
