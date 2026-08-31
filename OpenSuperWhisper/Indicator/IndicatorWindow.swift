import Cocoa
import Combine
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding

    /// Another transcription is still running. The reason says what became of
    /// this dictation because of it, so an overlay can be honest about whether
    /// the user's words are coming later.
    case busy(BusyReason)
    case noMicrophone

    /// Reached when a recording decoded with no engine set up. The card states
    /// it in the fewest words that fit; the sentence the user can act on is in
    /// the main window's banner and on the kept recording.
    case noEngine

    /// A cloud transcription that never produced a transcript: no network, a
    /// refused key, a rate limit, a provider outage.
    ///
    /// Its own case rather than `noEngine` because they need different words. An
    /// engine that is not set up is a settings problem the user fixes once; a
    /// provider that timed out is usually nothing they did, and telling them "no
    /// engine set up" would send them to a pane where everything is correct. The
    /// short reason is carried because there are seven of them
    /// (`CloudRequestError.shortMessage`) and the full sentence is on the
    /// recording that was kept.
    case cloudFailed(String)

    /// A dictation the engine could not transcribe because it was not in a
    /// language that engine can do - Paraformer, which answers non-Mandarin with
    /// tokeniser fragments rather than refusing it (`ParaformerLanguageGuard`).
    ///
    /// Separate from `.noEngine` for the same reason `.cloudFailed` is: nothing
    /// is wrong with the setup. Sending this user to a pane where every setting
    /// is correct would be the app misdirecting them; the words they need are
    /// "that was not Mandarin", and the fix is another engine.
    case wrongLanguage(String)

    /// A spoken command that was understood and could not be carried out: an
    /// unknown channel, a feed that could not be read, a browser that is not
    /// installed. Nothing was inserted and nothing was opened, which is why it
    /// needs a message of its own - the card would otherwise simply vanish and
    /// leave the user wondering whether the words went somewhere.
    ///
    /// The reason is short by construction (`YouTubeLatestVideoReport`
    /// carries a matching sentence for the surfaces with room, and posts it as a
    /// VoiceOver announcement).
    case commandFailed(String)

    /// A command whose spoken channel name nothing could place, with the channel
    /// picker now on screen waiting for the user.
    ///
    /// It exists because the card would otherwise sit on `.decoding` for as long
    /// as the picker is up - a spinner that has in fact finished, in front of a
    /// panel that is waiting on the user - and a spinner that never resolves is
    /// how a working feature looks broken. Unlike every other message here it
    /// carries no timer: the picker ends it, and until then this is what the
    /// session is doing. See `YouTubeChannelPickerOffer`.
    case awaitingChannelChoice
}

/// What became of a dictation that arrived while the engine was busy.
///
/// The two paths end in the same waiting, but only one of them kept the user's
/// audio, and a message that says "queued" for the other is promising words that
/// are never going to arrive.
enum BusyReason: Equatable {
    /// The start was refused: nothing was captured and nothing is queued.
    case startRefused
    /// The audio was captured and queued behind the transcription in flight.
    case audioQueued
}

/// What a dictation that failed to transcribe does with the user's audio.
///
/// One rule for both places a dictation can be started - the mini indicator and
/// the main window - so a failure the user can fix cannot keep the recording in
/// one of them and delete it in the other.
enum DictationFailureOutcome: Equatable {
    /// Delete the temporary audio, as every failure did before: there is nothing
    /// the user could do with it that would go any better.
    case discard

    /// Keep the audio and say why it has no transcript yet. The reason is stored
    /// on the recording, so it is still there after the indicator has gone, and
    /// the regenerate button transcribes it once the reason is dealt with.
    case keep(reason: String, indicatorState: RecordingState)

    static func forError(_ error: Error) -> DictationFailureOutcome {
        if EngineConfiguration.isNotConfigured(error) {
            return .keep(reason: EngineConfiguration.unavailableMessage, indicatorState: .noEngine)
        }
        // Every way a cloud request can fail is either transient or something
        // the user can fix, and the audio transcribes perfectly well afterwards -
        // on the provider once the key is right, or on a local engine. Deleting
        // it because a network call failed would be the app throwing away work it
        // never even attempted.
        if let cloud = error as? CloudRequestError, cloud.keepsTheRecording {
            return .keep(
                reason: cloud.errorDescription ?? cloud.shortMessage,
                indicatorState: .cloudFailed(cloud.shortMessage)
            )
        }
        // The audio is good and a different engine transcribes it, so deleting
        // it would throw away work over a choice the user can change in one
        // press. The engine that refused supplies both strings.
        if let transcription = error as? TranscriptionError,
            case .unsupportedSpokenLanguage(let message, let shortMessage) = transcription
        {
            return .keep(reason: message, indicatorState: .wrongLanguage(shortMessage))
        }
        return .discard
    }
}

/// What a dictation that ran to its end actually produced.
///
/// The indicator card never needed this - it decodes, hides, and says nothing
/// either way - but a HUD that ends every dictation on a success badge would show
/// a checkmark for a recording that was silent or a transcription that failed.
/// So the outcome is recorded rather than inferred, and `nil` means "the session
/// ended with nothing to add": cancelled, or already showing why it stopped.
enum DictationResult: Equatable {
    /// Text was produced and handed to whatever the user was typing in.
    ///
    /// `styleNotice` is `StyleRewriteStatus.explanation` when a rewrite was
    /// expected but the deterministic transcript was kept instead - refused by
    /// the guard, timed out, failed - and nil for a plain success. The text is
    /// inserted and stored identically either way; the notice only changes what
    /// the badge says.
    case inserted(styleNotice: String?)
    /// The words were a spoken question and went to the Ask panel instead of
    /// into another app. Nothing was inserted, and that is the point.
    case asked
    /// The words asked for a channel's latest video and it is open in the
    /// browser. Nothing was inserted, for the same reason `asked` inserts
    /// nothing.
    case openedVideo(channel: String)
    /// The recording decoded to nothing. The audio is discarded, as it always was.
    case noSpeech
    /// It failed for a reason worth telling the user.
    case failed(String)
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {

    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0
    
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false
    @Published var recorder: AudioRecorder = .shared
    
    var recordingStartedAt: Date?

    /// The app this dictation is going into, read once when the session starts.
    ///
    /// Once, and not again: the text is on its way into whatever the user was
    /// typing in when they pressed the shortcut, and by the time it is decoded
    /// the frontmost app may be something they alt-tabbed to while speaking. It
    /// is also the value the capsule's chip is resolved from, so what the chip
    /// promised and what the pipeline did cannot disagree.
    let dictationTarget: DictationTargetApp?

    /// What the key that started this session captures.
    ///
    /// Read once, at the start, for the same reason `dictationTarget` is: what
    /// happens to the words has to be decided by the press that captured them.
    /// A `.youTubeCommand` session never inserts anything into
    /// `dictationTarget`; the app is still captured because the session's other
    /// machinery is shared, and it is simply not used. A `.selectionEdit`
    /// session pastes into it, but the words it pastes are the rewrite of the
    /// captured text, not the spoken instruction.
    let purpose: DictationPurpose

    /// The text a voice-edit session will rewrite, captured before recording
    /// started. Nil on every other purpose, and nil on a voice-edit press that
    /// found nothing to edit (those never take the microphone).
    private(set) var selectionEdit: SelectedTextCapture?

    /// What this dictation produced, once it is known. Read by whoever is showing
    /// the session when it ends; `nil` while it is still running, and left `nil`
    /// for an ending that speaks for itself.
    private(set) var result: DictationResult?

    /// Set when the user stopped the work in flight themselves.
    ///
    /// Cancelling makes the transcription throw, and that failure must not come
    /// back to the user as one: they know what they did.
    private(set) var didCancelWorkInFlight = false

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    
    init(
        purpose: DictationPurpose = .dictation,
        dictationTarget: DictationTargetApp? = AppDetector.currentTarget(),
        selectionEdit: SelectedTextCapture? = nil
    ) {
        self.purpose = purpose
        self.dictationTarget = dictationTarget
        self.selectionEdit = selectionEdit
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared

        // Both sinks describe **this** session and no other, which is what
        // `recordingSession` gates them on. `AudioRecorder` publishes to every
        // subscriber, `@Published` replays its current value to a new one, and
        // `prepare()` builds this view model before the press has claimed
        // anything - so a dictation refused because the Ask panel holds the
        // microphone would otherwise be handed that panel's `isRecording` a
        // runloop turn later, repaint itself as a blinking recording it does not
        // own, and let the next press decode the question as a dictation.
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self, self.recordingSession != nil else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)

        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self, self.recordingSession != nil else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }

    /// The microphone claim this session holds, from the press that took it
    /// until the stop or cancel that gives it back. `nil` means this view model
    /// owns no recording - it was refused, or it has already ended - and every
    /// path that reads the recorder is gated on it.
    private var recordingSession: RecordingSession?
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage(_ reason: BusyReason) {
        showAutoDismissingMessage(.busy(reason))
    }

    /// A voice-edit press that found no selection and no clipboard text.
    ///
    /// Its own entry rather than starting a recording that would have nothing
    /// to rewrite: taking the microphone to say so would be the app holding
    /// hardware for a refusal.
    func showNothingToEdit() {
        showAutoDismissingMessage(.commandFailed("Nothing to edit"))
    }

    /// The line the card shows while capturing, so a voice edit is not drawn
    /// as an ordinary dictation.
    var recordingHeadline: String {
        if isConfirmingCancel { return "Press Esc to cancel" }
        return selectionEdit?.hudStatusText ?? "Recording..."
    }

    private func showAutoDismissingMessage(_ message: RecordingState) {
        state = message

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    func startRecording() {
        if isTranscriptionBusy {
            showBusyMessage(.startRefused)
            return
        }

        // getActiveMicrophone() only reads the cached currentMicrophone, so
        // this guard costs no CoreAudio HAL round-trip on the main thread.
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showAutoDismissingMessage(.noMicrophone)
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
        // sinks above translate into .connecting/.recording.
        guard let claimed = recorder.startRecording() else {
            showBusyMessage(.startRefused)
            return
        }
        recordingSession = claimed

        state = .recording
        startBlinking()
        recordingStartedAt = Date()
    }
    
    func handleCancelRequest() -> Bool {
        guard state == .recording,
              !AppPreferences.shared.escCancelWithoutConfirmation,
              !isConfirmingCancel,
              let startedAt = recordingStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.cancelConfirmationThreshold
        else {
            return true
        }
        
        isConfirmingCancel = true
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelConfirmationWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetCancelConfirmation()
            }
        }
        return false
    }
    
    private func resetCancelConfirmation() {
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = nil
        isConfirmingCancel = false
    }
    
    func startDecoding() {
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding or hide the window while transcription is in flight.
        guard state == .recording || state == .connecting else { return }

        resetCancelConfirmation()
        stopBlinking()

        guard let session = recordingSession else {
            delegate?.didFinishDecoding()
            return
        }
        recordingSession = nil

        if isTranscriptionBusy {
            if purpose == .selectionEdit {
                Task { [weak self] in
                    guard let self,
                          let tempURL = await self.recorder.stopRecording(session)
                    else { return }
                    try? FileManager.default.removeItem(at: tempURL)
                }
                showBusyMessage(.startRefused)
                return
            }
            // The engine is busy with another transcription: keep the user's audio
            // and put it into the queue instead of deleting it.
            Task { [weak self] in
                guard let self = self else { return }
                if let tempURL = await self.recorder.stopRecording(session) {
                    // The queue transcribes and never routes, so a command
                    // capture that lands here is transcribed as text and the
                    // command never runs. History says exactly that rather than
                    // filing it as an ordinary dictation.
                    await self.transcriptionQueue.addFileToQueue(
                        url: tempURL, provenance: .queued(for: self.purpose))
                }
            }
            showBusyMessage(.audioQueued)
            return
        }
        
        state = .decoding
        
        Task { [weak self] in
            guard let self = self else { return }

            if let tempURL = await self.recorder.stopRecording(session) {
                let duration = await AudioUtil.audioDuration(url: tempURL)
                do {
                    print("start decoding...")
                    // Resolved once and reused, so the answer to "may this
                    // session offer the channel picker" is the same one the
                    // pipeline read the allowlist with. A second `Settings`
                    // built after the transcription would read preferences the
                    // user could have changed while they were speaking.
                    let settings = Settings(
                        purpose: self.purpose,
                        dictationTarget: self.dictationTarget,
                        // Live dictation is the one path where a spoken
                        // command means anything - see `Settings`. A
                        // `.youTubeCommand` capture is not one, and
                        // `Settings` refuses it there whatever is passed.
                        routesSpokenIntents: true
                    )
                    let styled = try await transcriptionService.transcribeAudio(
                        url: tempURL, settings: settings)
                    let text = styled.final

                    if text.isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        self.result = .noSpeech
                        print("No speech detected, dictation discarded")
                    } else if self.purpose == .selectionEdit {
                        // The spoken words are the instruction. The rewrite of
                        // the captured text is what is stored and pasted, so
                        // this branch must not fall through to `insertText` of
                        // the instruction.
                        await self.completeSelectionEdit(
                            instruction: text, audioURL: tempURL, duration: duration)
                        return
                    } else {
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        var newRecording = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: duration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil,
                            // What the engine heard, kept only when
                            // post-processing changed it. History shows it next
                            // to the text the app used, so a rewrite is never
                            // the only surviving copy of what was said.
                            rawTranscription: styled.originalWorthKeeping
                        )
                        // Written with the words rather than after them, so a
                        // row is never briefly indistinguishable from an
                        // ordinary dictation - and so a quit or a crash between
                        // here and the browser leaves a record saying nothing
                        // was opened, which is the true thing to have recorded.
                        newRecording.provenance = styled.intent.provenance

                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)
                        
                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                        }

                        // A spoken question goes to the Ask panel and nowhere
                        // else. The recording is still kept and still searchable
                        // - the user asked it out loud and may want it back -
                        // but nothing is pasted into the app they were typing
                        // in, because they did not ask for that.
                        if case .openLatestVideo(let command) = styled.intent {
                            // Nothing is pasted. The command is run here, beside
                            // the Ask panel and for the same reason: the pipeline
                            // reads the words, and what is done about them
                            // belongs to the session that heard them. The
                            // recording is already stored, so the words survive
                            // whether or not the video opens.
                            //
                            // A refusal puts its own message up on its own
                            // timer, so the session ends there rather than
                            // falling through to the hide below - the same shape
                            // the kept-recording failures take.
                            if await self.runOpenLatestVideo(
                                command,
                                storedAs: recordingId,
                                isPickerEnabled: settings.youTubeChannelPicker
                            ) {
                                return
                            }
                        } else if self.purpose == .youTubeCommand {
                            // Unreachable: a command capture's pipeline produces
                            // exactly the outcome above. It is written out anyway
                            // because the branch below this one **pastes**, and
                            // the one thing this session must never do is fall
                            // into it.
                            self.result = nil
                            await self.recordingStore.updateProvenance(
                                recordingId,
                                to: .youTubeCommandNotOpened(
                                    reason: .notRecognised,
                                    message: "That capture was not read as a channel name, so nothing was opened."
                                )
                            )
                            self.showAutoDismissingMessage(
                                .commandFailed("That was not a channel name"))
                            return
                        } else if case .ask(let query) = styled.intent {
                            AskPanelWindowController.shared.present(query: query)
                            self.result = .asked
                            print("Ask: \(query)")
                        } else {
                            insertText(text)
                            self.result = .inserted(styleNotice: styled.statusExplanation)
                            print("Transcription result: \(text)")
                        }
                    }
                } catch {
                    print("Error transcribing audio: \(error)")

                    // A failure the user caused by cancelling is not one to
                    // report back to them.
                    if !self.didCancelWorkInFlight {
                        self.result = .failed(Self.failureMessage(for: error))
                    }

                    switch DictationFailureOutcome.forError(error) {
                    case .keep(let reason, let indicatorState):
                        // Said in two words on screen already, so there is no
                        // outcome left to report: repeating the full sentence when
                        // the session ends would replace the message the user is
                        // in the middle of reading.
                        self.result = nil
                        // The message's own timer hides the window, which is why
                        // this does not fall through to `didFinishDecoding()`.
                        await MainActor.run {
                            self.recordingStore.keepFailedDictation(
                                temporaryURL: tempURL,
                                duration: duration,
                                reason: reason,
                                provenance: .notTranscribed(for: self.purpose, reason: reason)
                            )
                            self.showAutoDismissingMessage(indicatorState)
                        }
                        return
                    case .discard:
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                }

                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            } else {
                print("!!! Not found record url !!!")
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        }
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
        let outcome = await Self.youTubeRunner.run(
            command,
            isPickerEnabled: isPickerEnabled,
            // The transcription has finished; what is left is the user's answer.
            // Leaving the card on `.decoding` for as long as the picker is up
            // would show a spinner for work that is over.
            willShowPicker: { [weak self] _ in self?.state = .awaitingChannelChoice }
        ) { [weak self] provenance in
            await self?.recordingStore.updateProvenance(recordingId, to: provenance)
        }
        let report = outcome.report
        // The full sentence, for the users the two-second card cannot reach and
        // for anyone reading the log afterwards.
        YouTubeCommandAccessibility.announce(report)
        print("YouTube command: \(report.spokenSummary)")

        switch report {
        case .opened(let channel, _, _):
            self.result = .openedVideo(channel: channel)
            return false
        case .refused(_, _, let shortMessage):
            // Said on screen already, so there is no outcome left to report -
            // the same division the kept-recording failures make. Both overlays
            // follow `state`, so one message reaches the card and the capsule.
            self.result = nil
            self.showAutoDismissingMessage(.commandFailed(shortMessage))
            return true
        }
    }

    /// What spoken YouTube commands run through: the real feed fetcher, the real
    /// browser opener and the real channel picker, built once.
    private static let youTubeRunner = YouTubeCommandRunner(
        service: .live, chooser: YouTubeChannelPickerPresenter()
    )

    /// Applies the spoken instruction to the captured text, stores both, and
    /// pastes the rewrite in place of the selection.
    ///
    /// Owns the end of the session the way `runOpenLatestVideo` does: a
    /// rewrite that lands hides through `didFinishDecoding`, and a rewrite
    /// that is refused puts its own message up on its own timer.
    private func completeSelectionEdit(
        instruction: String, audioURL: URL, duration: TimeInterval
    ) async {
        guard let capture = selectionEdit else {
            try? FileManager.default.removeItem(at: audioURL)
            showAutoDismissingMessage(.commandFailed("Nothing to edit"))
            return
        }

        let settings = Settings(purpose: .selectionEdit, dictationTarget: dictationTarget)
        let styled = await SelectionEditRewrite.apply(
            original: capture.text,
            instruction: instruction,
            settings: settings,
            terms: PersonalTermsStore.shared.activeTerms
        )

        let timestamp = Date()
        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
        let recordingId = UUID()
        let rewritten = styled.final
        var newRecording = Recording(
            id: recordingId,
            timestamp: timestamp,
            fileName: fileName,
            transcription: rewritten,
            duration: duration,
            status: .completed,
            progress: 1.0,
            sourceFileURL: nil,
            rawTranscription: capture.text == rewritten ? nil : capture.text
        )
        newRecording.provenance = .selectionEdit(instruction: instruction)

        do {
            try recorder.moveTemporaryRecording(from: audioURL, to: newRecording.url)
            try await recordingStore.addRecordingSync(newRecording)
        } catch {
            try? FileManager.default.removeItem(at: newRecording.url)
            print("Voice edit: could not save history: \(error)")
            self.result = nil
            showAutoDismissingMessage(.commandFailed("Could not save edit"))
            return
        }

        if styled.status.didRewrite, rewritten != capture.text {
            guard await ClipboardUtil.pasteText(
                rewritten, replacing: capture)
            else {
                self.result = nil
                showAutoDismissingMessage(.commandFailed("Target app unavailable"))
                return
            }
            self.result = .inserted(styleNotice: nil)
            print("Voice edit: \(instruction) -> \(rewritten)")
            await MainActor.run {
                self.delegate?.didFinishDecoding()
            }
            return
        }

        if styled.status.didRewrite {
            // The model returned the captured text unchanged. Pasting it would
            // replace a rich-text selection with a plain-string copy of itself.
            self.result = .inserted(styleNotice: nil)
            await MainActor.run {
                self.delegate?.didFinishDecoding()
            }
            return
        }

        self.result = nil
        showAutoDismissingMessage(.commandFailed(Self.shortEditFailure(styled.status)))
    }

    /// One line for the card when a voice edit kept the original.
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

    /// Stops the transcription the user is currently waiting on, and remembers
    /// that they did.
    ///
    /// The audio goes with it, which is what cancelling means here: the temporary
    /// file is removed by the failure path the cancellation triggers.
    func cancelWorkInFlight() {
        guard state == .decoding else { return }
        didCancelWorkInFlight = true
        transcriptionService.cancelTranscription()
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        if prefs.autoPasteTranscription {
            if prefs.autoCopyToClipboard {
                // Paste and keep in clipboard
                ClipboardUtil.insertTextAndKeepInClipboard(finalText)
            } else {
                // Paste but restore original clipboard (legacy behavior)
                ClipboardUtil.insertText(finalText)
            }
        } else if prefs.autoCopyToClipboard {
            // Only copy to clipboard, don't paste
            ClipboardUtil.copyToClipboard(finalText)
        }
        // If both are false, do nothing

    }
    
    /// Insertion-stage formatting for the live dictation output.
    /// Kept as a delegating wrapper for the existing view-model contract.
    static func applyPostProcessing(_ text: String) -> String {
        TextPostProcessor.prepareForInsertion(text)
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        resetCancelConfirmation()
        recordingStartedAt = nil
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let session = recordingSession else { return }
        recordingSession = nil
        recorder.cancelRecording(session)
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool
    
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1
    
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.orange)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .onAppear {
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

struct IndicatorWindow: View {
    /// Geometry shared with IndicatorWindowManager. The panel must be larger
    /// than the card: everything drawn outside the window bounds is cut off,
    /// so the appear offset (moves the card down) and the spring overshoot
    /// need margins, otherwise the card edges are visibly clipped mid-animation.
    static let cardSize = CGSize(width: 200, height: 36)
    static let windowSize = CGSize(width: 256, height: 96)
    static let appearOffset: CGFloat = 20
    static let appearInitialScale: CGFloat = 0.5
    
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }
    
    var body: some View {

        let rect = RoundedRectangle(cornerRadius: 24)
        
        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    
                    if viewModel.isConfirmingCancel {
                        Text("Press Esc to cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .transition(.opacity)
                    } else {
                        Text(viewModel.recordingHeadline)
                            .font(.system(size: 13, weight: .semibold))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
                
            case .decoding:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .noMicrophone:
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("No microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .noEngine:
                HStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    // Two words shorter than "No microphone" is as much as this
                    // 200 pt card holds on one line at this weight, and the
                    // recording it just kept carries the full sentence.
                    Text("No engine set up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .cloudFailed(let reason):
                HStack(spacing: 8) {
                    Image(systemName: "cloud.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    // Kept to the same one line as the case above; the sentence
                    // naming the fix is on the recording that was just kept.
                    Text(reason)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .wrongLanguage(let reason):
                HStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    // Same one line, same division: two words here, the sentence
                    // naming the fix on the recording that was just kept.
                    Text(reason)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .commandFailed(let reason):
                HStack(spacing: 8) {
                    Image(systemName: "play.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    // The same one line as the cases above; the whole sentence
                    // is spoken as an accessibility announcement and printed to
                    // the log, and the pane that fixes it is named there.
                    Text(reason)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .awaitingChannelChoice:
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    Text("Choose a channel")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: Self.cardSize.height)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isConfirmingCancel {
                CancelConfirmationBar()
            }
        }
        .clipShape(rect)
        .frame(width: Self.cardSize.width)
        // The ideal size of the root view must match the panel: NSHostingView
        // resizes the window down to SwiftUI's ideal size, and a window sized
        // to the bare card clips the appear offset, bounce overshoot and shadow.
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // The appear/hide animation is NOT done in SwiftUI on purpose:
        // animating scaleEffect/offset/opacity re-rasterizes the card (material
        // + gradients + shadow) on the CPU every frame and stalls the main
        // thread in CABackingStoreUpdate/wait_for_synchronize (20-60 ms per
        // frame in traces). IndicatorWindowManager animates the hosting view's
        // layer with CASpringAnimation instead: content is drawn once and the
        // spring runs entirely in the render server on the GPU.
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.state = .decoding
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
