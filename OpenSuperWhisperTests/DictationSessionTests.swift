import Combine
import XCTest

@testable import OpenSuperWhisper

/// The rules one dictation holds, stated against fakes.
///
/// `DictationSession` is the orchestration that used to live inside
/// `IndicatorViewModel`, where it could only be reached through a real
/// microphone, a real engine and a two-second `Timer` - so every rule in it was
/// asserted by reading the source, if at all. Each test here is one of those
/// rules: the busy rule and what it does with the audio, the live fallback
/// table, keep-versus-discard when a transcription fails, what a voice edit
/// refuses, and the two different things a cancel means depending on which path
/// the dictation took.
///
/// Runs against a throwaway defaults suite - `Settings` is built from
/// preferences, and see `IsolatedPreferencesTestCase`.
@MainActor
final class DictationSessionTests: IsolatedPreferencesTestCase {

    private var recorder: FakeDictationRecorder!
    private var transcriber: FakeDictationTranscriber!
    private var history: FakeDictationHistory!
    private var queue: FakeDictationQueue!
    private var insertion: FakeDictationInsertion!
    private var asking: FakeDictationAsking!
    private var editor: FakeSelectionEditing!
    private var temporaryFiles: [URL] = []

    /// XCTest calls `setUp`/`tearDown` on the main thread but without actor
    /// isolation, and everything here is `@MainActor` - the same shape
    /// `LiveDictationSessionTests` uses.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { freshWorld() }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
            temporaryFiles = []
        }
        super.tearDown()
    }

    private func freshWorld() {
        recorder = FakeDictationRecorder()
        transcriber = FakeDictationTranscriber()
        history = FakeDictationHistory()
        queue = FakeDictationQueue()
        insertion = FakeDictationInsertion()
        asking = FakeDictationAsking()
        editor = FakeSelectionEditing()
    }

    // MARK: - Building one

    private func makeSession(
        purpose: DictationPurpose = .dictation,
        selectionEdit: SelectedTextCapture? = nil,
        live: FakeLiveDictation? = nil
    ) -> DictationSession {
        DictationSession(
            purpose: purpose,
            dictationTarget: nil,
            selectionEdit: selectionEdit,
            recorder: recorder,
            transcriber: transcriber,
            history: history,
            queue: queue,
            insertion: insertion,
            asking: asking,
            selectionEditor: editor,
            measurement: FixedAudioDuration(seconds: 3),
            makeLiveSession: { _, _, _ in live }
        )
    }

    /// A temporary file that stands for the capture the recorder wrote, so a
    /// test can assert the audio was deleted rather than assume it.
    private func makeTemporaryAudio() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-session-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        temporaryFiles.append(url)
        return url
    }

    /// Everything after the key goes up runs in a `Task`; this waits for the
    /// session to say it is over rather than guessing how long that takes.
    @discardableResult
    private func waitForEnd(
        _ session: DictationSession, timeout: TimeInterval = 5
    ) async -> DictationNotice?? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ended(let notice) = session.phase { return .some(notice) }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    private func endedNotice(_ session: DictationSession) -> DictationNotice? {
        guard case .ended(let notice) = session.phase else { return nil }
        return notice
    }

    // MARK: - Starting

    func testStartWithNoMicrophone_refusesAndNeverClaimsOne() {
        recorder.hasActiveInput = false
        let session = makeSession()

        session.start()

        XCTAssertEqual(session.phase, .ended(.noMicrophone))
        XCTAssertTrue(recorder.startedSessions.isEmpty,
                      "a refusal before the claim must not touch the recorder")
    }

    func testStartWhileTheEngineIsBusy_refusesWithoutKeepingAnything() {
        transcriber.isTranscribing = true
        let session = makeSession()

        session.start()

        XCTAssertEqual(session.phase, .ended(.busy(.startRefused)))
        XCTAssertTrue(recorder.startedSessions.isEmpty)
    }

    func testStartWhileTheMicrophoneIsHeld_refusesRatherThanSeizingIt() {
        recorder.refusesToStart = true
        let session = makeSession()

        session.start()

        XCTAssertEqual(session.phase, .ended(.busy(.startRefused)))
    }

    func testStart_claimsTheMicrophoneAndStartsTheLiveDecoder() async {
        let live = FakeLiveDictation(settings: Settings())
        let session = makeSession(live: live)

        session.start()

        XCTAssertEqual(session.phase, .recording)
        XCTAssertTrue(session.isCapturing)
        XCTAssertEqual(recorder.startedSessions.count, 1)
        // `start()` is a task of its own, so the decoder is opened without
        // holding up the press.
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(live.startCount, 1)
    }

    /// The failure that used to be reported to nobody: a start that was
    /// accepted, drawn as a recording, and then failed on the work queue.
    func testAStartThatNeverOpensTheMicrophone_endsTheSessionWithTheReason() async {
        let live = FakeLiveDictation(settings: Settings())
        let session = makeSession(live: live)
        session.start()

        recorder.failStart(reason: .recorderFailed)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(
            session.phase,
            .ended(.recordingFailed(FailedRecordingStart.Reason.recorderFailed.shortMessage)))
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(live.cancelledSessions.count, 1,
                       "the live decoder is a consumer of a microphone that never opened")
        XCTAssertNil(session.liveTranscript)
    }

    /// A failure belonging to somebody else's capture - ⌥A's, say - must not end
    /// a dictation. `AudioRecorder.failedStart` is replayed to every subscriber.
    func testAnotherSessionsFailedStart_isIgnored() async {
        let session = makeSession()
        session.start()

        // A session that is not this one. Claims number from one per
        // `RecordingSessionClaim`, so the second of a separate claim's is the
        // one that cannot collide with the recording in flight.
        let otherClaim = RecordingSessionClaim()
        let first = otherClaim.claim()!
        otherClaim.release(first)
        let other = otherClaim.claim()!
        recorder.failure.send(FailedRecordingStart(session: other, reason: .noAudioInput))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(session.phase, .recording)
    }

    func testAVoiceEditPressWithNothingToEdit_neverTakesTheMicrophone() {
        let session = makeSession(purpose: .selectionEdit)

        session.reportNothingToEdit()

        XCTAssertEqual(session.phase, .ended(.commandFailed("Nothing to edit")))
        XCTAssertTrue(recorder.startedSessions.isEmpty)
    }

    // MARK: - The ordinary dictation

    func testAFinishedDictation_isStoredInsertedAndEndsWithNothingToSay() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(.stub("hello there"))
        let session = makeSession()
        session.start()

        session.stop()
        XCTAssertEqual(session.phase, .decoding)
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), nil)
        XCTAssertEqual(insertion.inserted, ["hello there"])
        XCTAssertEqual(history.added.count, 1)
        XCTAssertEqual(history.added.first?.transcription, "hello there")
        XCTAssertEqual(recorder.moves.count, 1, "the capture is moved under the row's name")
        XCTAssertEqual(session.result, .inserted(styleNotice: nil))
    }

    func testADictationThatDecodesToNothing_isDiscardedAndSaysSo() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        transcriber.wholeFileResult = .success(.stub(""))
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(session.result, .noSpeech)
        XCTAssertTrue(history.added.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    /// A spoken question goes to the Ask panel and nowhere else. Nothing is
    /// pasted into the app the user was typing in, because they did not ask for
    /// that - but the recording is still kept and still searchable.
    func testASpokenQuestion_reachesTheAskPanelAndPastesNothing() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(
            .stub("what is the time", intent: .ask(query: "what is the time")))
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(asking.queries, ["what is the time"])
        XCTAssertTrue(insertion.inserted.isEmpty)
        XCTAssertEqual(history.added.count, 1)
        XCTAssertEqual(session.result, .asked)
    }

    /// The capture that was too short to keep: the recorder hands back no file,
    /// and the session ends without inventing one.
    func testAStopThatProducesNoFile_endsQuietly() async {
        recorder.stoppedURL = nil
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), nil)
        XCTAssertTrue(history.added.isEmpty)
        XCTAssertTrue(transcriber.wholeFileCalls.isEmpty)
    }

    func testASecondStop_doesNothing() async {
        recorder.stoppedURL = makeTemporaryAudio()
        let session = makeSession()
        session.start()

        session.stop()
        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(recorder.stoppedSessions.count, 1)
        XCTAssertEqual(transcriber.wholeFileCalls.count, 1)
    }

    // MARK: - The live fallback table

    /// The live path at its best: every utterance was decoded while the user
    /// was speaking, so the joined text is finished and the WAV is never
    /// decoded at all.
    func testACommittedLiveSession_finishesTheJoinedTextAndNeverDecodesTheFile() async {
        recorder.stoppedURL = makeTemporaryAudio()
        let live = FakeLiveDictation(
            settings: Settings(), outcome: .committed(raw: "live words"))
        transcriber.finishedResult = .success(.stub("Live words."))
        let session = makeSession(live: live)
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(transcriber.finishedRaws, ["live words"])
        XCTAssertTrue(transcriber.wholeFileCalls.isEmpty,
                      "a committed live session must not decode the file a second time")
        XCTAssertEqual(insertion.inserted, ["Live words."])
    }

    /// Every reason the live path can give up. None of them is a failure the
    /// user sees: the WAV is intact, and the whole-file decode is exactly what
    /// the dictation would have done without a live session at all.
    func testEveryLiveFallback_decodesTheWholeFileInstead() async {
        let reasons: [LiveDictationFallbackReason] = [
            .tapUnavailable("no input"),
            .decodeFailed("utterance 2"),
            .engineChanged,
            .bufferExceeded,
            .tailBelowMinimum,
            .notThisSession,
            .cancelled,
        ]

        for reason in reasons {
            freshWorld()
            let audio = makeTemporaryAudio()
            recorder.stoppedURL = audio
            transcriber.wholeFileResult = .success(.stub("from the file"))
            let live = FakeLiveDictation(settings: Settings(), outcome: .fallback(reason))
            let session = makeSession(live: live)
            session.start()

            session.stop()
            await waitForEnd(session)

            XCTAssertEqual(
                transcriber.wholeFileCalls, [audio],
                "\(reason) must fall back to the whole-file decode")
            XCTAssertTrue(
                transcriber.finishedRaws.isEmpty,
                "\(reason) commits nothing, so there is no joined text to finish")
            XCTAssertEqual(insertion.inserted, ["from the file"], "\(reason)")
            XCTAssertEqual(endedNotice(session), nil, "\(reason) is never shown to the user")
        }
    }

    /// A live session whose tap never opened is dropped at the stop, which puts
    /// the dictation back on the whole-file path - busy rule included.
    func testALiveSessionThatNeverStarted_isDroppedAndTheBusyRuleAppliesAgain() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        let live = FakeLiveDictation(
            settings: Settings(), state: .unavailable(.tapUnavailable("no input")))
        let session = makeSession(live: live)
        session.start()
        transcriber.isTranscribing = true

        session.stop()
        await waitForEnd(session)
        // The refusal is published at once; handing the audio to the queue is
        // the task that follows it.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(endedNotice(session), .busy(.audioQueued))
        XCTAssertEqual(queue.queued.count, 1)
        XCTAssertTrue(live.finishedSessions.isEmpty,
                      "a session that never started has nothing to finish")
    }

    // MARK: - The busy rule at the stop

    /// The engine is busy with another transcription, so the user's audio is
    /// queued rather than deleted - and the overlay says "queued" rather than
    /// "busy", because the words really are coming.
    func testAStopWhileTheEngineIsBusy_queuesTheAudio() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        let session = makeSession()
        session.start()
        transcriber.isTranscribing = true

        session.stop()

        XCTAssertEqual(session.phase, .ended(.busy(.audioQueued)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(queue.queued.count, 1)
        XCTAssertEqual(queue.queued.first?.url, audio)
        XCTAssertEqual(queue.queued.first?.provenance, RecordingProvenance.queued(for: .dictation))
        XCTAssertTrue(transcriber.wholeFileCalls.isEmpty)
    }

    /// The queue is the other half of "busy": a file still being transcribed
    /// there refuses a new dictation just as the engine does.
    func testAStopWhileTheQueueIsRunning_queuesTheAudioToo() async {
        recorder.stoppedURL = makeTemporaryAudio()
        let session = makeSession()
        session.start()
        queue.isProcessing = true

        session.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(endedNotice(session), .busy(.audioQueued))
        XCTAssertEqual(queue.queued.count, 1)
    }

    /// The live path is checked **before** the busy check. A live session's own
    /// utterance decode raises `isTranscribing` exactly like a queue item does,
    /// so a dictation that had been decoding itself all along would otherwise be
    /// queued as a file at the last moment.
    func testALiveSessionIsNeverQueuedBecauseItsOwnDecodeLooksBusy() async {
        recorder.stoppedURL = makeTemporaryAudio()
        let live = FakeLiveDictation(settings: Settings(), outcome: .committed(raw: "live"))
        transcriber.finishedResult = .success(.stub("Live."))
        let session = makeSession(live: live)
        session.start()
        transcriber.isTranscribing = true

        session.stop()
        await waitForEnd(session)

        XCTAssertTrue(queue.queued.isEmpty)
        XCTAssertEqual(transcriber.finishedRaws, ["live"])
    }

    /// A voice edit has nothing to queue: the words are an instruction about a
    /// selection that will be gone by the time the queue gets to them, so the
    /// press is refused and the audio goes.
    func testAVoiceEditStoppedWhileBusy_isRefusedAndItsAudioDeleted() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        let session = makeSession(
            purpose: .selectionEdit,
            selectionEdit: SelectedTextCapture(text: "some text", source: .selection))
        session.start()
        transcriber.isTranscribing = true

        session.stop()

        XCTAssertEqual(session.phase, .ended(.busy(.startRefused)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(queue.queued.isEmpty, "an instruction must never be queued as a dictation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: - Voice edits

    func testAVoiceEdit_pastesTheRewriteAndStoresBothTexts() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(.stub("make it shorter"))
        editor.result = .stub("Shorter.", status: .applied(styleID: "edit"))
        let capture = SelectedTextCapture(text: "a much longer sentence", source: .selection)
        let session = makeSession(purpose: .selectionEdit, selectionEdit: capture)
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(editor.instructions, ["make it shorter"])
        XCTAssertEqual(insertion.pasted.map(\.text), ["Shorter."])
        XCTAssertTrue(insertion.inserted.isEmpty,
                      "the spoken instruction must never be pasted as dictation")
        XCTAssertEqual(history.addedSync.first?.transcription, "Shorter.")
        XCTAssertEqual(history.addedSync.first?.rawTranscription, "a much longer sentence")
        XCTAssertEqual(endedNotice(session), nil)
    }

    func testAVoiceEditWhoseTargetWentAway_saysSoAndPastesNothingElse() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(.stub("make it shorter"))
        editor.result = .stub("Shorter.", status: .applied(styleID: "edit"))
        insertion.pasteSucceeds = false
        let session = makeSession(
            purpose: .selectionEdit,
            selectionEdit: SelectedTextCapture(text: "a much longer sentence", source: .selection))
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), .commandFailed("Target app unavailable"))
        XCTAssertNil(session.result)
    }

    /// A rewrite that did not happen keeps the original, and the overlay says
    /// which of the several ways it did not happen this was.
    func testAVoiceEditTheModelRefused_keepsTheOriginalAndNamesWhy() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(.stub("make it shorter"))
        editor.result = .stub("a much longer sentence", status: .timedOut)
        let session = makeSession(
            purpose: .selectionEdit,
            selectionEdit: SelectedTextCapture(text: "a much longer sentence", source: .selection))
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), .commandFailed("Edit timed out"))
        XCTAssertTrue(insertion.pasted.isEmpty,
                      "nothing was rewritten, so there is nothing to paste over the selection")
    }

    /// The model returned the captured text unchanged. Pasting it would replace
    /// a rich-text selection with a plain-string copy of itself.
    func testAVoiceEditThatChangedNothing_pastesNothing() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.wholeFileResult = .success(.stub("make it shorter"))
        editor.result = .stub("same text", status: .applied(styleID: "edit"))
        let session = makeSession(
            purpose: .selectionEdit,
            selectionEdit: SelectedTextCapture(text: "same text", source: .selection))
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertTrue(insertion.pasted.isEmpty)
        XCTAssertEqual(session.result, .inserted(styleNotice: nil))
        XCTAssertEqual(endedNotice(session), nil)
    }

    // MARK: - Keep versus discard

    /// The whole point of `DictationFailureOutcome`: a failure the user can fix
    /// must not take their audio with it.
    func testAFailureTheUserCanFix_keepsTheAudioAndSaysWhatIsWrong() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        transcriber.wholeFileResult = .failure(TranscriptionError.engineNotConfigured)
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), .noEngine)
        XCTAssertEqual(history.kept.count, 1)
        XCTAssertEqual(history.kept.first?.reason, EngineConfiguration.unavailableMessage)
        XCTAssertEqual(history.kept.first?.url, audio)
        XCTAssertNil(session.result,
                     "the message is already on screen; repeating it would replace what the user is reading")
    }

    func testAnOrdinaryFailure_discardsTheAudioAndReportsIt() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        transcriber.wholeFileResult = .failure(TranscriptionError.processingFailed)
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertEqual(endedNotice(session), nil)
        XCTAssertTrue(history.kept.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        guard case .failed = session.result else {
            return XCTFail("an ordinary failure is reported as the session's outcome")
        }
    }

    /// Moving the audio under the row's name is part of the dictation, so a
    /// failure there is a failed dictation and takes the keep-or-discard rule
    /// with it rather than leaving a row pointing at nothing.
    func testAnAudioMoveThatFails_isTreatedAsAFailedDictation() async {
        let audio = makeTemporaryAudio()
        recorder.stoppedURL = audio
        recorder.moveError = CocoaError(.fileWriteNoPermission)
        let session = makeSession()
        session.start()

        session.stop()
        await waitForEnd(session)

        XCTAssertTrue(insertion.inserted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: - Cancelling

    /// The whole-file path is interrupted, exactly as it always was.
    func testCancellingAWholeFileDecode_interruptsTheEngine() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.holdNextDecode()
        let session = makeSession()
        session.start()

        session.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.phase, .decoding)

        session.cancelWorkInFlight()
        XCTAssertEqual(transcriber.cancelCount, 1)

        transcriber.releaseDecode()
        await waitForEnd(session)
        XCTAssertNil(session.result, "a failure the user caused is not reported back to them")
        XCTAssertTrue(insertion.inserted.isEmpty)
    }

    /// A cancel on the live path is a discard, not an interrupt. The frame in
    /// flight may be a queue item's that this dictation is waiting behind - the
    /// busy check was skipped for it - so nothing on the engine is interrupted;
    /// the finish runs to its end and the result is refused.
    func testCancellingALiveDecode_neverInterruptsTheEngine() async {
        recorder.stoppedURL = makeTemporaryAudio()
        transcriber.holdNextDecode()
        let live = FakeLiveDictation(settings: Settings(), outcome: .committed(raw: "live"))
        let session = makeSession(live: live)
        session.start()

        session.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.phase, .decoding)

        session.cancelWorkInFlight()
        XCTAssertEqual(
            transcriber.cancelCount, 0,
            "the frame in flight may belong to somebody else's transcription")

        transcriber.releaseDecode()
        await waitForEnd(session)
        XCTAssertNil(session.result)
        XCTAssertTrue(insertion.inserted.isEmpty, "a cancelled dictation pastes nothing")
    }

    func testCancellingOutsideTheDecode_doesNothing() {
        let session = makeSession()
        session.start()

        session.cancelWorkInFlight()

        XCTAssertEqual(transcriber.cancelCount, 0)
        XCTAssertFalse(session.didCancelWorkInFlight)
    }

    /// Esc during the recording: the microphone goes back, the live decoder's
    /// words go with it, and nothing is stored.
    func testCancellingTheRecording_givesTheMicrophoneBackAndKeepsNothing() {
        let live = FakeLiveDictation(settings: Settings())
        let session = makeSession(live: live)
        session.start()
        let claimed = recorder.startedSessions.first!

        session.cancel()

        XCTAssertEqual(recorder.cancelledSessions, [claimed])
        XCTAssertEqual(live.cancelledSessions, [claimed])
        XCTAssertFalse(session.isCapturing)
        XCTAssertNil(session.liveTranscript)
        XCTAssertTrue(history.added.isEmpty)
    }

    func testCancellingTwice_onlyEndsTheOneRecording() {
        let session = makeSession()
        session.start()

        session.cancel()
        session.cancel()

        XCTAssertEqual(recorder.cancelledSessions.count, 1)
    }

    // MARK: - What the overlay follows

    /// The live decoder's committed line is republished here, so an overlay can
    /// draw it without knowing the decoder exists.
    func testTheCommittedLiveLine_isRepublished() async {
        let live = FakeLiveDictation(settings: Settings())
        let session = makeSession(live: live)
        session.start()

        live.commit(PartialTranscript(text: "hello", segment: "hello", segmentCount: 1))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(session.liveTranscript?.text, "hello")
    }
}
