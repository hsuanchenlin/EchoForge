import GRDB
import XCTest

@testable import OpenSuperWhisper

/// Pins what a manual history edit writes, and what Cancel refuses to.
///
/// The store half runs against a database of its own, never the user's. The
/// session half is the card-local state: typing is not a model call, so it
/// lives on the row and Cancel is simply not writing.
@MainActor
final class ManualTranscriptEditTests: XCTestCase {

    private var databaseURL: URL!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-edit-\(UUID().uuidString).sqlite")
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

    // MARK: - What Save decides

    func testAFirstEditKeepsTheCurrentTranscriptAsTheOriginal() {
        let recording = recording(transcription: "I am in a meeting")
        let edit = ManualTranscriptEdit.preparing(
            draft: "I'm in a meeting", on: recording)
        XCTAssertEqual(edit?.transcription, "I'm in a meeting")
        XCTAssertEqual(edit?.preservedOriginal, "I am in a meeting")
    }

    /// An empty raw column is the same as a missing one: nothing to disclose
    /// yet, so the text on the card becomes the original.
    func testAnEmptyRawIsTreatedAsMissing() {
        var recording = recording(transcription: "hello")
        recording.rawTranscription = ""
        let edit = ManualTranscriptEdit.preparing(draft: "Hello", on: recording)
        XCTAssertEqual(edit?.preservedOriginal, "hello")
    }

    /// A row post-processing or Fix with AI already filled keeps the engine's
    /// words. A second edit must not overwrite that copy with the text the
    /// first one produced.
    func testALaterEditLeavesAnExistingOriginalAlone() {
        var recording = recording(transcription: "I'm in a meeting")
        recording.rawTranscription = "I am in a meeting"
        let edit = ManualTranscriptEdit.preparing(
            draft: "I am in the meeting", on: recording)
        XCTAssertEqual(edit?.transcription, "I am in the meeting")
        XCTAssertNil(edit?.preservedOriginal)
    }

    func testSavingUnchangedTextWithAnOriginalAlreadyStoredIsANoOp() {
        var recording = recording(transcription: "hello")
        recording.rawTranscription = "helo"
        XCTAssertNil(ManualTranscriptEdit.preparing(draft: "hello", on: recording))
    }

    /// Blanking the card would draw "No speech detected" and hide Edit, so
    /// the original words could not be typed back.
    func testAnEmptyDraftIsNotAWrite() {
        let recording = recording(transcription: "hello")
        XCTAssertNil(ManualTranscriptEdit.preparing(draft: "", on: recording))
        XCTAssertNil(ManualTranscriptEdit.preparing(draft: "   \n", on: recording))
    }

    // MARK: - Cancel

    func testCancelingDropsTheDraftWithoutProducingAWrite() {
        var session = HistoryTranscriptEditing()
        session.begin(transcript: "hello")
        session.draftTranscription = "hello world"
        session.cancel()

        XCTAssertFalse(session.isEditing)
        XCTAssertEqual(session.draftTranscription, "")
        XCTAssertNil(session.save(on: recording(transcription: "hello")))
    }

    func testSavingReturnsTheWriteWithoutLeavingTheSession() {
        var session = HistoryTranscriptEditing()
        session.begin(transcript: "hello")
        session.draftTranscription = "Hello"
        let recording = recording(transcription: "hello")

        let edit = session.save(on: recording)
        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(session.draftTranscription, "Hello")
        XCTAssertEqual(edit?.transcription, "Hello")
        XCTAssertEqual(edit?.preservedOriginal, "hello")
    }

    func testSavingAnEmptyDraftWritesNothingAndKeepsTheSession() {
        var session = HistoryTranscriptEditing()
        session.begin(transcript: "hello")
        session.draftTranscription = "   "

        XCTAssertFalse(session.canSave)
        XCTAssertNil(session.save(on: recording(transcription: "hello")))
        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(session.draftTranscription, "   ")
    }

    func testAFailedWriteLeavesTheEditorOpen() {
        XCTAssertTrue(ManualEditCommitResult.applied.closesEditor)
        XCTAssertTrue(ManualEditCommitResult.superseded.closesEditor)
        XCTAssertFalse(ManualEditCommitResult.failed.closesEditor)
    }

    // MARK: - The store

    func testTheStoreWritesTheEditAndTheNewlyPreservedOriginal() async throws {
        let row = recording(transcription: "I am in a meeting")
        try await dbQueue.write { try row.insert($0) }
        let store = RecordingStore(database: dbQueue, recordings: [row])

        let result = await store.applyManualEdit(
            row.id, transcription: "I'm in a meeting",
            preservedOriginal: "I am in a meeting",
            expectedTranscription: "I am in a meeting")

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(store.recordings.first?.transcription, "I'm in a meeting")
        XCTAssertEqual(store.recordings.first?.rawTranscription, "I am in a meeting")
        XCTAssertNil(store.recordings.first?.aiCorrectedAt)

        let stored = try await storedRecording()
        XCTAssertEqual(stored.transcription, "I'm in a meeting")
        XCTAssertEqual(stored.rawTranscription, "I am in a meeting")
        XCTAssertNil(stored.aiCorrectedAt)
    }

    func testTheStoreLeavesAnExistingOriginalInPlace() async throws {
        var row = recording(transcription: "I'm in a meeting")
        row.rawTranscription = "I am in a meeting"
        let inserted = row
        try await dbQueue.write { try inserted.insert($0) }
        let store = RecordingStore(database: dbQueue, recordings: [row])

        let result = await store.applyManualEdit(
            row.id, transcription: "I am in the meeting",
            preservedOriginal: nil,
            expectedTranscription: "I'm in a meeting")

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(store.recordings.first?.transcription, "I am in the meeting")
        XCTAssertEqual(store.recordings.first?.rawTranscription, "I am in a meeting")

        let stored = try await storedRecording()
        XCTAssertEqual(stored.transcription, "I am in the meeting")
        XCTAssertEqual(stored.rawTranscription, "I am in a meeting")
    }

    /// A regeneration that lands while the editor is open must not be
    /// overwritten by the stale draft.
    func testAStaleEditDoesNotOverwriteANewerTranscript() async throws {
        let row = recording(transcription: "hello")
        try await dbQueue.write { try row.insert($0) }
        let store = RecordingStore(database: dbQueue, recordings: [row])

        let result = await store.applyManualEdit(
            row.id, transcription: "Hello",
            preservedOriginal: "hello",
            expectedTranscription: "something else")

        XCTAssertEqual(result, .superseded)
        let stored = try await storedRecording()
        XCTAssertEqual(stored.transcription, "hello")
        XCTAssertNil(stored.rawTranscription)
    }

    func testAManualEditClearsTheAICorrectionMark() async throws {
        var row = recording(transcription: "I'm in a meeting")
        row.rawTranscription = "I am in a meeting"
        row.aiCorrectedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let inserted = row
        try await dbQueue.write { try inserted.insert($0) }
        let store = RecordingStore(database: dbQueue, recordings: [row])

        let result = await store.applyManualEdit(
            row.id, transcription: "I am in the meeting",
            preservedOriginal: nil,
            expectedTranscription: "I'm in a meeting")

        XCTAssertEqual(result, .applied)
        XCTAssertNil(store.recordings.first?.aiCorrectedAt)
        let stored = try await storedRecording()
        XCTAssertNil(stored.aiCorrectedAt)
    }

    func testTheStorePostsANotificationWhenTheEditLands() async throws {
        let row = recording(transcription: "hello")
        try await dbQueue.write { try row.insert($0) }
        let store = RecordingStore(database: dbQueue, recordings: [row])

        let arrived = expectation(description: "the list hears about the edit")
        let observer = NotificationCenter.default.addObserver(
            forName: RecordingStore.recordingDidManuallyEditNotification,
            object: nil, queue: .main
        ) { notification in
            let info = notification.userInfo
            XCTAssertEqual(info?["id"] as? UUID, row.id)
            XCTAssertEqual(info?["transcription"] as? String, "Hello")
            XCTAssertEqual(info?["rawTranscription"] as? String, "hello")
            arrived.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await store.applyManualEdit(
            row.id, transcription: "Hello",
            preservedOriginal: "hello",
            expectedTranscription: "hello")
        XCTAssertEqual(result, .applied)
        await fulfillment(of: [arrived], timeout: 1)
    }

    func testTheVisibleListAppliesAManualEditAndClearsTheAIMark() {
        var row = recording(transcription: "hello")
        row.rawTranscription = "helo"
        row.aiCorrectedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let viewModel = ContentViewModel()
        viewModel.recordings = [row]

        viewModel.handleManualEdit(
            id: row.id, transcription: "Hello", preservedOriginal: nil)

        XCTAssertEqual(viewModel.recordings.first?.transcription, "Hello")
        XCTAssertEqual(viewModel.recordings.first?.rawTranscription, "helo")
        XCTAssertNil(viewModel.recordings.first?.aiCorrectedAt)
    }

    func testTheVisibleListStoresANewlyPreservedOriginal() {
        let row = recording(transcription: "hello")
        let viewModel = ContentViewModel()
        viewModel.recordings = [row]

        viewModel.handleManualEdit(
            id: row.id, transcription: "Hello", preservedOriginal: "hello")

        XCTAssertEqual(viewModel.recordings.first?.transcription, "Hello")
        XCTAssertEqual(viewModel.recordings.first?.rawTranscription, "hello")
    }

    // MARK: - Fixtures

    private func recording(transcription: String) -> Recording {
        Recording.newRow(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            transcription: transcription,
            duration: 4.0,
            status: .completed,
            progress: 1.0,
            provenance: .dictation)
    }

    private func storedRecording() async throws -> Recording {
        let fetched = try await dbQueue.read { try Recording.fetchOne($0) }
        return try XCTUnwrap(fetched)
    }
}
