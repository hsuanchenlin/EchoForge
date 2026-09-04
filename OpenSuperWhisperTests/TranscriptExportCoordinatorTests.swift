import XCTest

@testable import OpenSuperWhisper

/// The Export press, end to end, without a modal panel.
///
/// The panel and the write are both injected, which is what makes the four
/// outcomes assertable at all: a cancelled save, a refused write, a row with
/// nothing to export and a file that landed each have a case, and three of the
/// four have to leave a sentence on the card - a press that produced no file and
/// said nothing is indistinguishable from one that silently worked.
@MainActor
final class TranscriptExportCoordinatorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The file that lands

    func testAnAcceptedSaveWritesTheDocumentAndSaysWhereItWent() throws {
        let destination = directory.appendingPathComponent("transcript.md")
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in destination },
            writing: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) })

        let row = recording(transcription: "Ship the release notes.")
        let outcome = coordinator.export(row)

        XCTAssertEqual(outcome, .saved(fileName: "transcript.md"))
        XCTAssertEqual(coordinator.note(for: row.id), "Exported to “transcript.md”.")
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.contains("Ship the release notes."))
        XCTAssertTrue(written.contains("# Transcript"))
    }

    /// The panel is offered a name; it is never the writer. The URL that comes
    /// back is the only destination, so nothing is ever written beside the
    /// recording or anywhere else the user did not point at.
    func testTheOnlyFileWrittenIsTheOneThePanelReturned() throws {
        let destination = directory.appendingPathComponent("chosen.md")
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in destination },
            writing: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) })

        coordinator.export(recording(transcription: "words"))

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        XCTAssertEqual(contents, ["chosen.md"])
    }

    /// A user who typed their own name may have left the extension off, and a
    /// Markdown document called `notes` opens in nothing.
    func testAMissingExtensionIsSuppliedRatherThanLeftOff() throws {
        let coordinator = TranscriptExportCoordinator(
            choosing: { [directory] _, _ in directory!.appendingPathComponent("notes") },
            writing: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) })

        let outcome = coordinator.export(recording(transcription: "words"))

        XCTAssertEqual(outcome, .saved(fileName: "notes.md"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("notes.md").path))
    }

    func testThePlainTextFormatIsWrittenWhenItIsAskedFor() throws {
        let destination = directory.appendingPathComponent("transcript.txt")
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in destination },
            writing: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) })

        coordinator.export(recording(transcription: "Ship it."), format: .plainText)

        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.contains("Ship it."))
        XCTAssertFalse(written.contains("```"))
    }

    /// The name the panel opens with comes from the row, not from a counter, so
    /// two exports of the same row propose the same name - and the panel's own
    /// overwrite confirmation is the only thing that decides what happens next.
    /// Nothing here replaces a file behind the user.
    func testASecondExportOfTheSameRowProposesTheSameNameAndOverwritesOnlyWhenChosen() throws {
        let destination = directory.appendingPathComponent("transcript.md")
        var proposed: [String] = []
        let coordinator = TranscriptExportCoordinator(
            choosing: { name, _ in
                proposed.append(name)
                return destination
            },
            writing: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) })

        let row = recording(transcription: "first words")
        coordinator.export(row)

        var second = row
        second.transcription = "second words"
        let outcome = coordinator.export(second)

        XCTAssertEqual(outcome, .saved(fileName: "transcript.md"))
        XCTAssertEqual(proposed.count, 2)
        XCTAssertEqual(proposed[0], proposed[1], "The proposed name is a fact about the row.")
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(
            written.contains("second words"),
            "A destination the user chose again is the destination they chose again.")
    }

    // MARK: - The presses that write nothing

    /// A cancelled save leaves no sentence: the user knows what they just did,
    /// and a card that answered it would be scolding them for it.
    func testACancelledSaveWritesNothingAndSaysNothing() {
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in nil },
            writing: { _, _ in XCTFail("A cancelled save must not write.") })

        let row = recording(transcription: "words")
        XCTAssertEqual(coordinator.export(row), .cancelled)
        XCTAssertNil(coordinator.note(for: row.id))
    }

    /// A refused write does leave one, and it carries the system's own reason -
    /// the only description of it the user can act on.
    func testARefusedWriteSaysWhyOnTheCard() {
        let refusal = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "You don’t have permission to save here."])
        let coordinator = TranscriptExportCoordinator(
            choosing: { [directory] _, _ in directory!.appendingPathComponent("x.md") },
            writing: { _, _ in throw refusal })

        let row = recording(transcription: "words")
        let outcome = coordinator.export(row)

        XCTAssertEqual(
            outcome, .failed(reason: "You don’t have permission to save here."))
        XCTAssertEqual(
            coordinator.note(for: row.id),
            "Export failed: You don’t have permission to save here.")
    }

    /// A real refusal, not a stubbed one: a directory that does not exist is the
    /// closest a test can get to a volume the app has no grant for.
    func testARealFailedWriteIsReportedRatherThanSwallowed() {
        let unreachable = directory
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("transcript.md")
        let coordinator = TranscriptExportCoordinator(choosing: { _, _ in unreachable })

        let row = recording(transcription: "words")
        let outcome = coordinator.export(row)

        guard case .failed(let reason) = outcome else {
            return XCTFail("A write into a folder that does not exist must fail, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotNil(coordinator.note(for: row.id))
    }

    /// A row with no words never reaches the panel at all.
    func testARowWithNothingToExportNeverOpensThePanel() {
        var opened = false
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in
                opened = true
                return nil
            },
            writing: { _, _ in XCTFail("Nothing to write.") })

        let row = recording(transcription: "", status: .completed)
        XCTAssertEqual(coordinator.export(row), .nothingToExport)
        XCTAssertFalse(opened, "There is no destination to ask for.")
        XCTAssertEqual(
            coordinator.note(for: row.id),
            "There is no transcript on this recording to export yet.")
    }

    func testAQueuedRowIsRefusedTheSameWay() {
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in XCTFail("No panel for a row still in the queue."); return nil },
            writing: { _, _ in })

        XCTAssertEqual(
            coordinator.export(recording(transcription: "partial", status: .transcribing)),
            .nothingToExport)
    }

    // MARK: - The note

    func testANewPressClearsTheSentenceTheLastOneLeft() {
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in nil }, writing: { _, _ in })

        let row = recording(transcription: "")
        coordinator.export(row)
        XCTAssertNotNil(coordinator.note(for: row.id))

        // A cancelled press over a stale failure must not leave the failure up.
        coordinator.export(recording(transcription: "words", id: row.id))
        XCTAssertNil(coordinator.note(for: row.id))
    }

    func testTheUserCanDismissTheSentence() {
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in nil }, writing: { _, _ in })

        let row = recording(transcription: "")
        coordinator.export(row)
        coordinator.dismissNote(for: row.id)
        XCTAssertNil(coordinator.note(for: row.id))
    }

    /// A sentence belongs to the row it was left on. Two rows exported in a row
    /// must not answer for each other.
    func testSentencesAreKeptPerRow() {
        let coordinator = TranscriptExportCoordinator(
            choosing: { _, _ in nil }, writing: { _, _ in })

        let empty = recording(transcription: "")
        let full = recording(transcription: "words")
        coordinator.export(empty)
        coordinator.export(full)

        XCTAssertNotNil(coordinator.note(for: empty.id))
        XCTAssertNil(coordinator.note(for: full.id), "That press was cancelled.")
    }

    // MARK: - Helpers

    private func recording(
        transcription: String,
        status: RecordingStatus = .completed,
        id: UUID = UUID()
    ) -> Recording {
        var row = Recording(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_772_616_600),
            fileName: "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 8.0,
            status: status,
            progress: status == .completed ? 1.0 : 0.3,
            sourceFileURL: nil
        )
        row.provenance = .dictation
        return row
    }
}
