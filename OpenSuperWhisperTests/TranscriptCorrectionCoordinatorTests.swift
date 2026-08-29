import XCTest

@testable import OpenSuperWhisper

/// Pins what a press of "Fix with AI" does to the card and to the row behind it.
///
/// Both seams are injected - the model call and the write - so every rule here
/// holds on a Mac with no Apple Intelligence and without touching the user's
/// real recordings database.
@MainActor
final class TranscriptCorrectionCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    /// Records every write the coordinator makes, in order.
    private final class Writes {
        private(set) var calls: [(id: UUID, text: String, original: String)] = []
        func record(_ id: UUID, _ text: String, _ original: String) {
            calls.append((id, text, original))
        }
    }

    private func recording(
        status: RecordingStatus = .completed,
        transcription: String = "我再開會",
        rawTranscription: String? = nil
    ) -> Recording {
        var recording = Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000.wav",
            transcription: transcription,
            duration: 4.0,
            status: status,
            progress: 1.0,
            sourceFileURL: nil
        )
        recording.rawTranscription = rawTranscription
        return recording
    }

    private func styled(
        _ request: TranscriptCorrectionRequest, corrected: String
    ) -> StyledTranscript {
        StyledTranscript(
            raw: request.original,
            transcript: request.text,
            final: corrected,
            status: .applied(styleID: TranscriptCorrection.styleID)
        )
    }

    private func kept(
        _ request: TranscriptCorrectionRequest, status: StyleRewriteStatus
    ) -> StyledTranscript {
        StyledTranscript(
            raw: request.original, transcript: request.text, final: request.text, status: status)
    }

    /// Waits for the coordinator to stop reporting this row as in flight.
    private func waitUntilFinished(
        _ coordinator: TranscriptCorrectionCoordinator, _ id: UUID,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0 ..< 400 {
            if !coordinator.isCorrecting(id) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the correction never finished", file: file, line: line)
    }

    // MARK: - The happy path

    func testAnAcceptedCorrectionIsWrittenToTheRowItCameFrom() async throws {
        let recording = self.recording(transcription: "我再開會")
        let writes = Writes()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in styled(request, corrected: "我在開會") },
            committing: { id, text, original, _ in
                writes.record(id, text, original)
                return .applied
            }
        )

        XCTAssertTrue(coordinator.correct(recording))
        try await waitUntilFinished(coordinator, recording.id)

        XCTAssertEqual(writes.calls.count, 1)
        XCTAssertEqual(writes.calls.first?.id, recording.id)
        XCTAssertEqual(writes.calls.first?.text, "我在開會")
        XCTAssertEqual(
            writes.calls.first?.original, "我再開會",
            "the words the row had before the press are the ones it must keep")
        XCTAssertNil(
            coordinator.note(for: recording.id),
            "a correction that landed has nothing to explain")
    }

    func testTheWriteComparesAgainstTheTranscriptGivenToTheModel() async throws {
        let recording = self.recording(transcription: "我再開會")
        var expectedTranscription: String?
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in styled(request, corrected: "我在開會") },
            committing: { _, _, _, expected in
                expectedTranscription = expected
                return .applied
            }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        XCTAssertEqual(expectedTranscription, "我再開會")
    }

    /// A row post-processing already changed keeps the engine's own words, not
    /// the text the earlier stage produced.
    func testTheStoredOriginalIsTheEnginesWordsWhereTheRowHasThem() async throws {
        let recording = self.recording(transcription: "我再開會。", rawTranscription: "我再開會")
        let writes = Writes()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in styled(request, corrected: "我在開會。") },
            committing: { id, text, original, _ in
                writes.record(id, text, original)
                return .applied
            }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        XCTAssertEqual(writes.calls.first?.original, "我再開會")
    }

    // MARK: - The spinner

    func testTheRowIsMarkedInFlightWhileTheModelWorks() async throws {
        let recording = self.recording()
        let started = expectation(description: "the model was asked")
        let release = expectation(description: "the model may answer")
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                started.fulfill()
                await self.fulfillment(of: [release], timeout: 5)
                return styled(request, corrected: "我在開會")
            },
            committing: { _, _, _, _ in .applied }
        )

        XCTAssertFalse(coordinator.isCorrecting(recording.id))
        coordinator.correct(recording)
        XCTAssertTrue(
            coordinator.isCorrecting(recording.id),
            "the card has to show the spinner from the press, not from the first suspension")

        await fulfillment(of: [started], timeout: 5)
        release.fulfill()
        try await waitUntilFinished(coordinator, recording.id)
        XCTAssertFalse(coordinator.isCorrecting(recording.id))
    }

    /// Two corrections racing to write the same row would decide the winner by
    /// which model call returned first.
    func testASecondPressWhileTheFirstIsRunningIsIgnored() async throws {
        let recording = self.recording()
        let release = expectation(description: "the model may answer")
        var asked = 0
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                asked += 1
                await self.fulfillment(of: [release], timeout: 5)
                return styled(request, corrected: "我在開會")
            },
            committing: { _, _, _, _ in .applied }
        )

        XCTAssertTrue(coordinator.correct(recording))
        XCTAssertFalse(coordinator.correct(recording))
        XCTAssertFalse(coordinator.correct(recording))

        release.fulfill()
        try await waitUntilFinished(coordinator, recording.id)
        XCTAssertEqual(asked, 1, "the row was handed to the model more than once")
    }

    /// The spinner must come down whatever the stage answered, or the card is
    /// stuck for the rest of the session.
    func testTheSpinnerComesDownWhenTheStageChangesNothing() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                kept(request, status: .unavailable(.appleIntelligenceOff))
            },
            committing: { _, _, _, _ in
                XCTFail("nothing may be written when nothing changed")
                return .failed
            }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        XCTAssertFalse(coordinator.isCorrecting(recording.id))
    }

    // MARK: - Failures are non-blocking

    func testASupersededWriteKeepsTheNewerRowAndLeavesANote() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in styled(request, corrected: "我在開會") },
            committing: { _, _, _, _ in .superseded }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        let note = try XCTUnwrap(coordinator.note(for: recording.id))
        XCTAssertTrue(note.contains("newer version was kept"))
    }

    func testAFailedWriteLeavesTheRowUnchangedAndLeavesANote() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in styled(request, corrected: "我在開會") },
            committing: { _, _, _, _ in .failed }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        let note = try XCTUnwrap(coordinator.note(for: recording.id))
        XCTAssertTrue(note.contains("could not save"))
    }

    func testAFailedCorrectionLeavesASentenceAndWritesNothing() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in kept(request, status: .failed("the model refused")) },
            committing: { _, _, _, _ in
                XCTFail("a failed correction must not touch the row")
                return .failed
            }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        let note = try XCTUnwrap(coordinator.note(for: recording.id))
        XCTAssertTrue(note.contains("the model refused"))
    }

    func testAModelThisMacCannotRunSaysSoInThisFeaturesWords() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                kept(request, status: .unavailable(.unsupportedSystem))
            },
            committing: { _, _, _, _ in .applied }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)

        let note = try XCTUnwrap(coordinator.note(for: recording.id))
        XCTAssertTrue(note.contains("Fixing with AI"))
        XCTAssertFalse(note.lowercased().contains("rewriting"))
    }

    func testANoteCanBeDismissed() async throws {
        let recording = self.recording()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in kept(request, status: .failed("offline")) },
            committing: { _, _, _, _ in .applied }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)
        XCTAssertNotNil(coordinator.note(for: recording.id))

        coordinator.dismissNote(for: recording.id)
        XCTAssertNil(coordinator.note(for: recording.id))
    }

    /// A retry must not leave the previous attempt's sentence under the spinner.
    func testANewPressClearsTheSentenceTheLastOneLeft() async throws {
        let recording = self.recording()
        var answers: [StyleRewriteStatus] = [.failed("offline"), .applied(styleID: "x")]
        let release = expectation(description: "the second press may answer")
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                let status = answers.removeFirst()
                if status.didRewrite {
                    await self.fulfillment(of: [release], timeout: 5)
                    return styled(request, corrected: "我在開會")
                }
                return kept(request, status: status)
            },
            committing: { _, _, _, _ in .applied }
        )

        coordinator.correct(recording)
        try await waitUntilFinished(coordinator, recording.id)
        XCTAssertNotNil(coordinator.note(for: recording.id))

        coordinator.correct(recording)
        XCTAssertNil(
            coordinator.note(for: recording.id),
            "the previous attempt's sentence was still on the card under the new spinner")

        release.fulfill()
        try await waitUntilFinished(coordinator, recording.id)
    }

    // MARK: - Rows that cannot be pressed

    func testARowWithNothingToCorrectIsLeftAlone() async {
        var asked = false
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                asked = true
                return kept(request, status: .notRequested)
            },
            committing: { _, _, _, _ in .applied }
        )

        for recording in [
            self.recording(status: .pending, transcription: ""),
            self.recording(status: .transcribing),
            self.recording(status: .failed, transcription: "no engine could transcribe this"),
            self.recording(transcription: "   "),
        ] {
            XCTAssertFalse(coordinator.correct(recording))
            XCTAssertFalse(coordinator.isCorrecting(recording.id))
        }
        XCTAssertFalse(asked, "a row with nothing to correct reached the model")
    }

    // MARK: - Rows are independent

    func testTwoRowsCanBeCorrectedAtOnceAndDoNotShareState() async throws {
        let first = recording(transcription: "我再開會")
        let second = recording(transcription: "他在那裡")
        let writes = Writes()
        let coordinator = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                request.text == "我再開會"
                    ? styled(request, corrected: "我在開會")
                    : kept(request, status: .failed("offline"))
            },
            committing: { id, text, original, _ in
                writes.record(id, text, original)
                return .applied
            }
        )

        coordinator.correct(first)
        coordinator.correct(second)
        try await waitUntilFinished(coordinator, first.id)
        try await waitUntilFinished(coordinator, second.id)

        XCTAssertEqual(writes.calls.map(\.id), [first.id])
        XCTAssertNil(coordinator.note(for: first.id))
        XCTAssertNotNil(coordinator.note(for: second.id))
    }
}
