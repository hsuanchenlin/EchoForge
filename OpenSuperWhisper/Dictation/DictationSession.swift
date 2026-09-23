import Combine
import Foundation

/// One dictation, from the press that claims the microphone to the words
/// landing in whatever the user was typing in.
///
/// This is the whole of it: claiming the microphone and giving it back, the live
/// decoder that may run alongside the recording, the busy rule, the whole-file
/// decode, the spoken-intent branches, history, the failure rule that decides
/// whether the audio is kept, and the paste. An overlay reads `phase` and
/// `result` and calls `start`, `stop`, `cancel` and `cancelWorkInFlight`;
/// nothing else about a dictation is visible from outside.
///
/// It was carved out of `IndicatorViewModel`, which is now what its name says -
/// the card's view model. The split is where it is because these two things
/// have different lifetimes and different reasons to change: a dictation is a
/// piece of work with a beginning and an end, and an overlay is a thing on
/// screen with timers and animations. Keeping them in one type meant the
/// orchestration could only be exercised through a `Timer` and a real
/// microphone; stated here against the ports in `DictationSessionPorts.swift`
/// it is ordinary assertions, which is what `DictationSessionTests` is.
///
/// Four rules hold, and none of them is new - they are the reason the code
/// below is shaped the way it is.
///
/// **The microphone is owned.** Every recording is a `RecordingSession` claimed
/// from `AudioRecorder`, and every stop and cancel names the session it means.
/// A session that was refused holds nothing and touches nothing.
/// (`RecordingSessionClaim`)
///
/// **Nothing between engine and paste may fail or invent.** The live path is a
/// speed-up and never a failure mode: every way it can break answers
/// `.fallback` and the WAV is decoded whole, exactly as it would have been
/// without it. (`docs/live-dictation.md`, `docs/text-post-processing.md`)
///
/// **A failure the user can fix keeps their audio.** `DictationFailureOutcome`
/// is the one rule, shared with the main window, and the kept recording carries
/// the sentence that says what to do. (`docs/history-storage.md`)
///
/// **What the press captured decides what happens to the words.** The purpose,
/// the target app and the selected text are read once, at the start, because by
/// the time the audio is decoded the frontmost app may be something else.
/// (`docs/spoken-intents.md`, `docs/app-aware-style.md`)
@MainActor
final class DictationSession: ObservableObject {

    /// Where this dictation has got to. The one value an overlay follows.
    @Published private(set) var phase: DictationPhase = .idle

    /// What the live decoder has committed so far, republished from the session
    /// so an overlay can draw it without knowing the session exists. Nil while
    /// nothing is committed, and nil again the moment the session falls back.
    @Published private(set) var liveTranscript: PartialTranscript?

    /// What the key that started this session captures.
    ///
    /// Read once, at the start, because what happens to the words has to be
    /// decided by the press that captured them. A `.youTubeCommand` session
    /// never inserts anything into `dictationTarget`; the app is still captured
    /// because the session's other machinery is shared, and it is simply not
    /// used. A `.selectionEdit` session pastes into it, but the words it pastes
    /// are the rewrite of the captured text, not the spoken instruction.
    let purpose: DictationPurpose

    /// The app this dictation is going into, read once when the session starts.
    ///
    /// Once, and not again: the text is on its way into whatever the user was
    /// typing in when they pressed the shortcut, and by the time it is decoded
    /// the frontmost app may be something they alt-tabbed to while speaking. It
    /// is also the value the capsule's chip is resolved from, so what the chip
    /// promised and what the pipeline did cannot disagree.
    let dictationTarget: DictationTargetApp?

    /// The text a voice-edit session will rewrite, captured before recording
    /// started. Nil on every other purpose, and nil on a voice-edit press that
    /// found nothing to edit (those never take the microphone).
    let selectionEdit: SelectedTextCapture?

    /// What this dictation produced, once it is known. Read by whoever is
    /// showing the session when it ends; `nil` while it is still running, and
    /// left `nil` for an ending that speaks for itself.
    private(set) var result: DictationResult?

    /// Set when the user stopped the work in flight themselves.
    ///
    /// Cancelling makes the transcription throw, and that failure must not come
    /// back to the user as one: they know what they did.
    private(set) var didCancelWorkInFlight = false

    /// When the capture began, or nil when this session never took the
    /// microphone. The card's Esc confirmation is measured from it.
    private(set) var recordingStartedAt: Date?

    /// Whether this session holds the microphone right now.
    var isCapturing: Bool { recordingSession != nil }

    /// Whether a transcription is already running, here or in the queue.
    var isTranscriptionBusy: Bool { transcriber.isTranscribing || queue.isProcessing }

    // MARK: - The world

    private let recorder: DictationRecording
    private let transcriber: DictationTranscribing
    private let history: DictationHistory
    private let queue: DictationQueueing
    private let insertion: DictationInserting
    private let asking: DictationAsking
    private let selectionEditor: DictationSelectionEditing
    private let measurement: DictationAudioMeasuring
    private let makeLiveSession: LiveDictationFactory
    /// nil means the production runner, which is built on first use rather
    /// than at every session - it opens a `URLSession` and a picker presenter,
    /// and almost no dictation is a YouTube command.
    private let youTubeRunner: YouTubeCommandRunner?

    // MARK: - What it holds while it runs

    /// The microphone claim this session holds, from the press that took it
    /// until the stop or cancel that gives it back. `nil` means this session
    /// owns no recording - it was refused, or it has already ended - and every
    /// path that reads the recorder is gated on it.
    private var recordingSession: RecordingSession?

    /// The decoder running alongside the recording, or nil when this dictation
    /// takes the whole-file path: the switch is off, the engine is the cloud
    /// one, or the key was not the dictation key (`LiveDictationEligibility`).
    ///
    /// Bound to `recordingSession` - it is made with the claim and ends with
    /// it, by name - and owned here rather than by the recorder because it is
    /// a consumer of the microphone the way the capsule's level meter is, not
    /// a second recorder. The WAV is still written; this only decides how much
    /// of it is left to decode when the key goes up.
    private var liveSession: LiveDictating?
    private var liveSessionCancellable: AnyCancellable?
    private var isDecodingLiveSession = false
    private var cancellables = Set<AnyCancellable>()

    init(
        purpose: DictationPurpose = .dictation,
        dictationTarget: DictationTargetApp? = AppDetector.currentTarget(),
        selectionEdit: SelectedTextCapture? = nil,
        recorder: DictationRecording = AudioRecorder.shared,
        transcriber: DictationTranscribing = TranscriptionService.shared,
        history: DictationHistory = RecordingStore.shared,
        queue: DictationQueueing = TranscriptionQueue.shared,
        insertion: DictationInserting = SystemTextInsertion(),
        asking: DictationAsking = AskPanelPresentation(),
        selectionEditor: DictationSelectionEditing = SelectionEditRewriting(),
        measurement: DictationAudioMeasuring = AudioFileMeasurement(),
        youTubeRunner: YouTubeCommandRunner? = nil,
        makeLiveSession: @escaping LiveDictationFactory = DictationSession.makeLiveDictationSession
    ) {
        self.purpose = purpose
        self.dictationTarget = dictationTarget
        self.selectionEdit = selectionEdit
        self.recorder = recorder
        self.transcriber = transcriber
        self.history = history
        self.queue = queue
        self.insertion = insertion
        self.asking = asking
        self.selectionEditor = selectionEditor
        self.measurement = measurement
        self.youTubeRunner = youTubeRunner
        self.makeLiveSession = makeLiveSession

        // Both sinks describe **this** session and no other, which is what
        // `recordingSession` gates them on. `AudioRecorder` publishes to every
        // subscriber, `@Published` replays its current value to a new one, and
        // the session is built before the press has claimed anything - so a
        // dictation refused because the Ask panel holds the microphone would
        // otherwise be handed that panel's `isRecording` a runloop turn later,
        // repaint itself as a recording it does not own, and let the next press
        // decode the question as a dictation.
        recorder.isConnectingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self, self.recordingSession != nil else { return }
                if isConnecting { self.phase = .connecting }
            }
            .store(in: &cancellables)

        recorder.isRecordingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self, self.recordingSession != nil else { return }
                if isRecording { self.phase = .recording }
            }
            .store(in: &cancellables)

        // The third thing the recorder can say, and the one that used to be
        // said to nobody: this session's microphone never opened. Gated on the
        // session itself rather than on `recordingSession != nil` like the two
        // above, because `@Published` replays and a failure belonging to the
        // Ask panel's capture must not end a dictation. See
        // `AudioRecorder.failedStart`.
        recorder.failedStartPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] failure in
                guard let self, let failure, failure.ends(self.recordingSession) else { return }
                self.recordingDidFailToStart(failure.reason)
            }
            .store(in: &cancellables)
    }

    // MARK: - Starting

    /// Takes the microphone and starts capturing, or refuses and says why.
    func start() {
        if isTranscriptionBusy {
            end(with: .busy(.startRefused))
            return
        }

        guard recorder.hasActiveInput else {
            end(with: .noMicrophone)
            return
        }

        // Claim the microphone before anything is drawn. The Ask panel records
        // on this same `AudioRecorder`, so a dictation started while ⌥A was
        // listening used to delete the question the panel was recording and
        // re-point its file at this session - the mirror image of the seizure
        // `AskPanelWindowController.voiceCaptureRefusal` refuses, and the half
        // nothing guarded. The claim itself is synchronous and costs no
        // CoreAudio HAL round-trip; the recorder still resolves the real state
        // on its own queue and publishes isConnecting/isRecording, which the
        // sinks above translate into `.connecting`/`.recording`.
        guard let claimed = recorder.startRecording() else {
            end(with: .busy(.startRefused))
            return
        }
        recordingSession = claimed
        startLiveSessionIfEligible(for: claimed)

        recordingStartedAt = Date()
        phase = .recording
    }

    /// A voice-edit press that found no selection and no clipboard text.
    ///
    /// Its own entry rather than starting a recording that would have nothing
    /// to rewrite: taking the microphone to say so would be the app holding
    /// hardware for a refusal.
    func reportNothingToEdit() {
        end(with: .commandFailed("Nothing to edit"))
    }

    /// Starts decoding alongside the recording, when this dictation qualifies.
    ///
    /// The settings are resolved now rather than when the key goes up, and the
    /// session keeps them: the utterances are decoded with this prompt, these
    /// terms and this language, and `stop` finishes the joined text with the
    /// same snapshot, so one dictation cannot be decoded under one set of
    /// preferences and post-processed under another.
    private func startLiveSessionIfEligible(for session: RecordingSession) {
        guard let live = makeLiveSession(
            session,
            purpose,
            Settings(
                purpose: purpose,
                dictationTarget: dictationTarget,
                routesSpokenIntents: true,
                correctsSpokenEdits: true))
        else { return }
        liveSession = live
        liveSessionCancellable = live.transcriptPublisher.sink { [weak self] transcript in
            self?.liveTranscript = transcript
        }
        Task { await live.start() }
    }

    /// Ends the live session for `session`, discarding what it holds, and stops
    /// following it. The session is the one that checks the name; this only
    /// stops carrying its line.
    private func endLiveSession(_ session: RecordingSession) {
        liveSession?.cancel(session)
        liveSession = nil
        liveSessionCancellable = nil
        liveTranscript = nil
    }

    /// Ends a session whose microphone never opened.
    ///
    /// The claim is already back - `AudioRecorder.failStart` releases it before
    /// reporting - so this only has to stop standing for a recording that is
    /// not happening and say why.
    private func recordingDidFailToStart(_ reason: FailedRecordingStart.Reason) {
        // The live decoder is a consumer of this microphone, so it goes with
        // the capture that never started - named, like every end of a session.
        if let session = recordingSession {
            endLiveSession(session)
        }
        recordingSession = nil
        recordingStartedAt = nil
        end(with: reason.notice)
    }

    // MARK: - Stopping

    /// The key went up: stop capturing and turn the audio into text.
    ///
    /// Everything after this point is one `Task`, and every way out of it ends
    /// the session exactly once.
    func stop() {
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding while transcription is in flight.
        guard phase == .recording || phase == .connecting else { return }

        guard let session = recordingSession else {
            end(with: nil)
            return
        }
        recordingSession = nil
        var liveSession = self.liveSession
        self.liveSession = nil
        if case .unavailable? = liveSession?.state {
            liveSession = nil
        }
        isDecodingLiveSession = (liveSession != nil)

        // The live path is checked **before** the busy check, and the busy
        // check applies only to the whole-file path. A live session's own
        // utterance decode raises `isTranscribing` exactly like a queue item
        // does, so a dictation that had been decoding itself all along would
        // otherwise be queued as a file at the last moment. Its decodes are its
        // own to wait for, and `finish` waits for them; what the busy rule
        // protects - one transcription per engine at a time - is kept by the
        // frame every decode already runs in.
        if liveSession == nil, isTranscriptionBusy {
            if purpose == .selectionEdit {
                Task { [weak self] in
                    guard let self,
                          let tempURL = await self.recorder.stopRecording(session)
                    else { return }
                    try? FileManager.default.removeItem(at: tempURL)
                }
                end(with: .busy(.startRefused))
                return
            }
            // The engine is busy with another transcription: keep the user's audio
            // and put it into the queue instead of deleting it.
            Task { [weak self] in
                guard let self else { return }
                if let tempURL = await self.recorder.stopRecording(session) {
                    // The queue transcribes and never routes, so a command
                    // capture that lands here is transcribed as text and the
                    // command never runs. History says exactly that rather than
                    // filing it as an ordinary dictation.
                    await self.queue.addFileToQueue(
                        url: tempURL, provenance: .queued(for: self.purpose))
                }
            }
            end(with: .busy(.audioQueued))
            return
        }

        phase = .decoding

        Task { [weak self] in
            guard let self else { return }

            // Both stop after the same tail; neither waits for the other. The
            // live session then decodes what is left while the file is closed.
            async let stopped = self.recorder.stopRecording(session)
            let liveOutcome = await liveSession?.finish(session)

            guard let tempURL = await stopped else {
                print("!!! Not found record url !!!")
                await MainActor.run { self.end(with: nil) }
                return
            }

            // Reading the file back to measure it is the one piece of work
            // on this path whose answer is not needed until a row is
            // written, so it runs alongside the transcription instead of in
            // front of it. Measured at 0.21 ms once AVFoundation is warm and
            // 2.2 ms on the first asset load in a process: small, and there
            // is no reason at all to pay it before the engine can start.
            async let measuredDuration = self.measurement.duration(of: tempURL)
            do {
                print("start decoding...")
                // Resolved once and reused, so the answer to "may this
                // session offer the channel picker" is the same one the
                // pipeline read the allowlist with. A second `Settings`
                // built after the transcription would read preferences the
                // user could have changed while they were speaking.
                // A live session already resolved them at the press, and
                // decoded every utterance with them; the joined text is
                // finished with the same snapshot.
                let settings = liveSession?.settings ?? Settings(
                    purpose: self.purpose,
                    dictationTarget: self.dictationTarget,
                    // Live dictation is the one path where a spoken
                    // command means anything - see `Settings`. A
                    // `.youTubeCommand` capture is not one, and
                    // `Settings` refuses it there whatever is passed.
                    routesSpokenIntents: true,
                    // Live dictation is also the one path where "scratch
                    // that" is a retraction rather than words: a dropped
                    // file is somebody's recording and a ⌥E instruction is
                    // the instruction. `Settings` refuses both.
                    correctsSpokenEdits: true
                )
                let styled = try await self.transcribe(
                    tempURL, liveOutcome: liveOutcome, settings: settings)
                let text = styled.final

                let duration = await measuredDuration

                if text.isEmpty {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.result = .noSpeech
                    print("No speech detected, dictation discarded")
                } else if self.purpose == .selectionEdit {
                    // The spoken words are the instruction. The rewrite of
                    // the captured text is what is stored and pasted, so
                    // this branch must not fall through to the insertion of
                    // the instruction.
                    await self.completeSelectionEdit(
                        instruction: text, audioURL: tempURL, duration: duration)
                    return
                } else if try await self.completeDictation(
                    styled, text: text, audioURL: tempURL, duration: duration, settings: settings)
                {
                    // The branch that ran put its own message up and owns the
                    // end of the session.
                    return
                }
            } catch {
                print("Error transcribing audio: \(error)")

                // A failure the user caused by cancelling is not one to
                // report back to them.
                if !self.didCancelWorkInFlight {
                    self.result = .failed(Self.failureMessage(for: error))
                }

                switch DictationFailureOutcome.forError(error) {
                case .keep(let reason, let notice):
                    let duration = await measuredDuration
                    // Said in two words on screen already, so there is no
                    // outcome left to report: repeating the full sentence when
                    // the session ends would replace the message the user is
                    // in the middle of reading.
                    self.result = nil
                    await MainActor.run {
                        self.history.keepFailedDictation(
                            temporaryURL: tempURL,
                            duration: duration,
                            reason: reason,
                            provenance: .notTranscribed(for: self.purpose, reason: reason)
                        )
                        self.end(with: notice)
                    }
                    return
                case .discard:
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            await MainActor.run { self.end(with: nil) }
        }
    }

    /// Stores one finished dictation and does whatever its words asked for.
    ///
    /// - Returns: whether it put a message on screen and so owns the end of the
    ///   session, the same contract `runOpenLatestVideo` has.
    ///
    /// Throws only what moving the audio into place throws, and deliberately
    /// does not handle it: that is a failed dictation like any other, and
    /// `stop`'s own catch is the one place the keep-or-discard rule is applied.
    private func completeDictation(
        _ styled: StyledTranscript,
        text: String,
        audioURL tempURL: URL,
        duration: TimeInterval,
        settings: Settings
    ) async throws -> Bool {
        let newRecording = Recording.newRow(
            transcription: text,
            duration: duration,
            status: .completed,
            progress: 1.0,
            // What the engine heard, kept only when post-processing changed
            // it. History shows it next to the text the app used, so a rewrite
            // is never the only surviving copy of what was said.
            rawTranscription: styled.originalWorthKeeping,
            // Written with the words rather than after them, so a row is never
            // briefly indistinguishable from an ordinary dictation - and so a
            // quit or a crash between here and the browser leaves a record
            // saying nothing was opened, which is the true thing to have
            // recorded.
            provenance: styled.intent.provenance
        )

        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)

        await MainActor.run {
            self.history.addRecording(newRecording)
        }

        // A spoken question goes to the Ask panel and nowhere else. The
        // recording is still kept and still searchable - the user asked it out
        // loud and may want it back - but nothing is pasted into the app they
        // were typing in, because they did not ask for that.
        if case .openLatestVideo(let command) = styled.intent {
            // Nothing is pasted. The command is run here, beside the Ask panel
            // and for the same reason: the pipeline reads the words, and what
            // is done about them belongs to the session that heard them. The
            // recording is already stored, so the words survive whether or not
            // the video opens.
            //
            // A refusal puts its own message up, so the session ends there
            // rather than falling through to the hide below - the same shape
            // the kept-recording failures take.
            return await runOpenLatestVideo(
                command,
                storedAs: newRecording.id,
                isPickerEnabled: settings.youTubeChannelPicker
            )
        }

        if purpose == .youTubeCommand {
            // Unreachable: a command capture's pipeline produces exactly the
            // outcome above. It is written out anyway because the branch below
            // this one **pastes**, and the one thing this session must never do
            // is fall into it.
            result = nil
            await history.updateProvenance(
                newRecording.id,
                to: .youTubeCommandNotOpened(
                    reason: .notRecognised,
                    message: "That capture was not read as a channel name, so nothing was opened."
                )
            )
            end(with: .commandFailed("That was not a channel name"))
            return true
        }

        if case .ask(let query) = styled.intent {
            asking.present(query: query)
            result = .asked
            print("Ask: \(query)")
            return false
        }

        insertion.insert(text)
        result = .inserted(styleNotice: styled.dictationStyleNotice)
        print("Transcription result: \(text)")
        return false
    }

    /// The transcript for this dictation: the live session's joined text,
    /// finished, when the session stood for the recording; the whole-file
    /// decode of `tempURL` otherwise, exactly as before live decoding existed.
    ///
    /// A fallback is a `print` and nothing else visible - the session has
    /// already taken its line off the capsule, and the whole-file decode puts
    /// its own up.
    ///
    /// A cancel on the live path is a discard, not an interrupt. The frame in
    /// flight when the button is pressed may be a queue item's that this
    /// dictation is waiting behind - the busy check was skipped for it - so
    /// `cancelWorkInFlight` never reaches `cancelTranscription` for a live
    /// session; the tail decode, the finish or the fallback's whole-file decode
    /// runs to its end, and `didCancelWorkInFlight` is read on either side of
    /// it so the result is refused whichever frame, or the gap between two, the
    /// press landed in. The whole-file path is interrupted as it always was,
    /// and throws before the second read.
    private func transcribe(
        _ tempURL: URL, liveOutcome: LiveDictationOutcome?, settings: Settings
    ) async throws -> StyledTranscript {
        guard !didCancelWorkInFlight else { throw TranscriptionError.processingFailed }
        let styled: StyledTranscript
        switch liveOutcome {
        case .committed(let raw):
            styled = try await transcriber.finishTranscribed(raw: raw, settings: settings)
        case .fallback(let reason):
            print("Live dictation fell back to the whole-file decode: \(reason)")
            styled = try await transcriber.transcribeAudio(url: tempURL, settings: settings)
        case nil:
            styled = try await transcriber.transcribeAudio(url: tempURL, settings: settings)
        }
        guard !didCancelWorkInFlight else { throw TranscriptionError.processingFailed }
        return styled
    }

    /// Carries out an "open the latest YouTube video from …" and reports it.
    ///
    /// The work itself is `YouTubeCommandRunner`, which is where the feed, the
    /// browser and the channel picker are tested against stubs; this is the
    /// wiring and the two ways a session can end because of it.
    ///
    /// - Returns: whether it put a message on screen and so owns the end of the
    ///   session, exactly as `DictationFailureOutcome.keep` does.
    private func runOpenLatestVideo(
        _ command: YouTubeCommandResolution,
        storedAs recordingId: UUID,
        isPickerEnabled: Bool
    ) async -> Bool {
        // History is written as each step happens rather than once at the end -
        // the picker can be left on screen for as long as the user likes, and a
        // quit while it is up has to leave a row saying a choice was offered and
        // nothing was opened.
        let outcome = await (youTubeRunner ?? Self.liveYouTubeRunner).run(
            command,
            isPickerEnabled: isPickerEnabled,
            // The transcription has finished; what is left is the user's answer.
            // Leaving the overlay on `.decoding` for as long as the picker is up
            // would show a spinner for work that is over.
            willShowPicker: { [weak self] _ in self?.phase = .awaitingChannelChoice }
        ) { [weak self] provenance in
            await self?.history.updateProvenance(recordingId, to: provenance)
        }
        let report = outcome.report
        // The full sentence, for the users the two-second card cannot reach and
        // for anyone reading the log afterwards.
        YouTubeCommandAccessibility.announce(report)
        print("YouTube command: \(report.spokenSummary)")

        switch report {
        case .opened(let channel, _, _):
            result = .openedVideo(channel: channel)
            return false
        case .refused(_, _, let shortMessage):
            // Said on screen already, so there is no outcome left to report -
            // the same division the kept-recording failures make. Both overlays
            // follow the phase, so one message reaches the card and the capsule.
            result = nil
            end(with: .commandFailed(shortMessage))
            return true
        }
    }

    /// What spoken YouTube commands run through: the real feed fetcher, the real
    /// browser opener and the real channel picker, built once.
    static let liveYouTubeRunner = YouTubeCommandRunner(
        service: .live, chooser: YouTubeChannelPickerPresenter()
    )

    /// The production live decoder, or nil for a dictation that stays on the
    /// whole-file path.
    static let makeLiveDictationSession: LiveDictationFactory = { session, purpose, settings in
        LiveDictationSession.make(
            for: session,
            purpose: purpose,
            settings: settings,
            service: TranscriptionService.shared)
    }

    /// Applies the spoken instruction to the captured text, stores both, and
    /// pastes the rewrite in place of the selection.
    ///
    /// Owns the end of the session the way `runOpenLatestVideo` does: a
    /// rewrite that lands ends it with nothing to add, and a rewrite that is
    /// refused ends it with its own message.
    private func completeSelectionEdit(
        instruction: String, audioURL: URL, duration: TimeInterval
    ) async {
        guard let capture = selectionEdit else {
            try? FileManager.default.removeItem(at: audioURL)
            end(with: .commandFailed("Nothing to edit"))
            return
        }

        let settings = Settings(purpose: .selectionEdit, dictationTarget: dictationTarget)
        let styled = await selectionEditor.rewrite(
            original: capture.text, instruction: instruction, settings: settings)

        let rewritten = styled.final
        let newRecording = Recording.newRow(
            transcription: rewritten,
            duration: duration,
            status: .completed,
            progress: 1.0,
            rawTranscription: capture.text == rewritten ? nil : capture.text,
            provenance: .selectionEdit(instruction: instruction)
        )

        do {
            try recorder.moveTemporaryRecording(from: audioURL, to: newRecording.url)
            try await history.addRecordingSync(newRecording)
        } catch {
            try? FileManager.default.removeItem(at: newRecording.url)
            print("Voice edit: could not save history: \(error)")
            result = nil
            end(with: .commandFailed("Could not save edit"))
            return
        }

        if styled.status.didRewrite, rewritten != capture.text {
            guard await insertion.paste(rewritten, replacing: capture) else {
                result = nil
                end(with: .commandFailed("Target app unavailable"))
                return
            }
            result = .inserted(styleNotice: nil)
            print("Voice edit: \(instruction) -> \(rewritten)")
            await MainActor.run { self.end(with: nil) }
            return
        }

        if styled.status.didRewrite {
            // The model returned the captured text unchanged. Pasting it would
            // replace a rich-text selection with a plain-string copy of itself.
            result = .inserted(styleNotice: nil)
            await MainActor.run { self.end(with: nil) }
            return
        }

        result = nil
        end(with: .commandFailed(Self.shortEditFailure(styled.status)))
    }

    // MARK: - Cancelling

    /// Throws away the recording in flight: nothing is pasted, nothing is kept.
    ///
    /// Deliberately silent about the phase. The user pressed Esc, so there is
    /// nothing to tell them, and the overlay that asked for this is already
    /// taking itself down.
    func cancel() {
        guard let session = recordingSession else { return }
        recordingSession = nil
        // Buffer, committed words and file all go: nothing is pasted, nothing
        // is kept.
        endLiveSession(session)
        recorder.cancelRecording(session)
    }

    /// Stops the transcription the user is currently waiting on, and remembers
    /// that they did.
    ///
    /// The audio goes with it, which is what cancelling means here: the temporary
    /// file is removed by the failure path that follows - the interrupted decode's
    /// own throw on the whole-file path, and `transcribe`'s refusal of the finished
    /// work on the live one, where nothing on the engine is interrupted because
    /// the frame in flight may not be this dictation's.
    func cancelWorkInFlight() {
        guard phase == .decoding else { return }
        didCancelWorkInFlight = true
        if !isDecodingLiveSession {
            transcriber.cancelTranscription()
        }
    }

    /// Lets go of everything this session was following. It is over either way;
    /// this stops it holding subscriptions until it is deallocated.
    func cleanup() {
        recordingStartedAt = nil
        cancellables.removeAll()
        liveSessionCancellable = nil
    }

    // MARK: - Ending

    /// The one way a session finishes: the outcome is already recorded, and this
    /// publishes the phase that says so.
    private func end(with notice: DictationNotice?) {
        phase = .ended(notice)
    }

    // MARK: - Words

    /// One line for the overlay when a voice edit kept the original.
    static func shortEditFailure(_ status: StyleRewriteStatus) -> String {
        switch status {
        case .unavailable: return "Model unavailable"
        case .timedOut: return "Edit timed out"
        case .rejected: return "Kept the original"
        case .transcriptTooLong: return "Text too long"
        case .nothingToRewrite: return "Nothing to edit"
        case .failed: return "Edit failed"
        case .notRequested, .applied: return "Kept the original"
        }
    }

    /// One sentence for a failed dictation, on the surface that has room for one.
    ///
    /// `TranscriptionError` is a `LocalizedError` precisely so this reads as an
    /// instruction rather than "OpenSuperWhisper.TranscriptionError error 2".
    static func failureMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Insertion-stage formatting for the dictation output.
    /// Kept as a delegating wrapper for the existing view-model contract.
    static func applyPostProcessing(_ text: String) -> String {
        TextPostProcessor.prepareForInsertion(text)
    }
}
