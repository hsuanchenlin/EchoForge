import Combine
import Foundation

/// What `DictationSession` needs from the world, stated as narrow ports.
///
/// Each one is the *part* of a collaborator one dictation actually uses, not
/// the collaborator: the microphone it claims and gives back, the engine it
/// decodes on, the history it writes one row to, the queue it hands refused
/// audio to, the place the finished words go. The production conformances below
/// are one line each and forward to the singletons that already existed, so
/// nothing about the app's wiring changes - what changes is that the
/// orchestration can be stated against a recorder that never opens a microphone
/// and an engine that throws on cue, which is what `DictationSessionTests`
/// does.
///
/// Most are `@MainActor`, because `DictationSession` is and every call happens
/// there. `DictationRecording` is the exception: `AudioRecorder` does its work
/// on its own queue and is not isolated, so the port that describes it cannot
/// be either.

// MARK: - The microphone

/// The microphone, as one dictation uses it: claim it, give it back with the
/// audio, or throw the audio away.
protocol DictationRecording: AnyObject {
    /// Whether there is an input device to record with.
    ///
    /// Answered from the cached device list, so asking costs no CoreAudio
    /// round-trip on the main thread.
    var hasActiveInput: Bool { get }

    /// Claims the microphone for one session, or refuses because something
    /// already holds it. See `RecordingSessionClaim`.
    func startRecording() -> RecordingSession?

    /// Ends `session` and hands back its audio, or nil when that session is no
    /// longer the one in flight.
    func stopRecording(_ session: RecordingSession) async -> URL?

    /// Throws `session`'s audio away.
    func cancelRecording(_ session: RecordingSession)

    /// Moves a temporary capture under the name history gave it.
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws

    /// The recorder is reaching a device that takes a moment to open.
    var isConnectingPublisher: AnyPublisher<Bool, Never> { get }

    /// The recorder is capturing.
    var isRecordingPublisher: AnyPublisher<Bool, Never> { get }

    /// A start that was accepted and then failed on the work queue. It names
    /// the session it belongs to, because five keys share one recorder - see
    /// `AudioRecorder.failedStart`.
    var failedStartPublisher: AnyPublisher<FailedRecordingStart?, Never> { get }
}

extension AudioRecorder: DictationRecording {
    var hasActiveInput: Bool { MicrophoneService.shared.getActiveMicrophone() != nil }
    var isConnectingPublisher: AnyPublisher<Bool, Never> { $isConnecting.eraseToAnyPublisher() }
    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var failedStartPublisher: AnyPublisher<FailedRecordingStart?, Never> {
        $failedStart.eraseToAnyPublisher()
    }
}

// MARK: - The engine

/// The engine, as one dictation uses it: decode this file, or finish what the
/// live session already decoded.
@MainActor
protocol DictationTranscribing: AnyObject {
    /// Whether a transcription is running right now, anywhere in the app.
    var isTranscribing: Bool { get }
    func transcribeAudio(url: URL, settings: Settings) async throws -> StyledTranscript
    func finishTranscribed(raw: String, settings: Settings) async throws -> StyledTranscript
    /// Stops the transcription in flight. Never reached for a live session -
    /// see `DictationSession.cancelWorkInFlight`.
    func cancelTranscription()
}

extension TranscriptionService: DictationTranscribing {}

/// The decoder that runs alongside the recording, as the session uses it.
///
/// A protocol rather than `LiveDictationSession` itself so the two ends of the
/// live path - a session that commits and one that falls back - can be stated
/// without a microphone. `LiveDictationSession` is still the only production
/// implementation, and `docs/live-dictation.md` is its story.
@MainActor
protocol LiveDictating: AnyObject {
    /// The settings every utterance was decoded with, which the joined text is
    /// finished with and the WAV is decoded with on a fallback.
    var settings: Settings { get }
    var state: LiveDictationState { get }
    /// What has been committed so far, for the overlay to draw.
    var transcriptPublisher: AnyPublisher<PartialTranscript?, Never> { get }
    func start() async
    func finish(_ session: RecordingSession) async -> LiveDictationOutcome
    func cancel(_ session: RecordingSession)
}

extension LiveDictationSession: LiveDictating {
    var transcriptPublisher: AnyPublisher<PartialTranscript?, Never> {
        $transcript.eraseToAnyPublisher()
    }
}

/// Makes the live decoder for a dictation that qualifies, or answers nil for
/// one that stays on the whole-file path (`LiveDictationEligibility`).
typealias LiveDictationFactory =
    @MainActor (RecordingSession, DictationPurpose, Settings) -> LiveDictating?

// MARK: - History

/// History, as one dictation writes to it.
@MainActor
protocol DictationHistory: AnyObject {
    func addRecording(_ recording: Recording)
    func addRecordingSync(_ recording: Recording) async throws
    /// Keeps a dictation the app was unable to transcribe, with the reason.
    @discardableResult
    func keepFailedDictation(
        temporaryURL: URL, duration: TimeInterval, reason: String,
        provenance: RecordingProvenance
    ) -> Recording?
    func updateProvenance(_ id: UUID, to provenance: RecordingProvenance) async
}

extension RecordingStore: DictationHistory {}

/// The file transcription queue, as a refused dictation uses it.
@MainActor
protocol DictationQueueing: AnyObject {
    var isProcessing: Bool { get }
    func addFileToQueue(url: URL, provenance: RecordingProvenance) async
}

extension TranscriptionQueue: DictationQueueing {}

// MARK: - Where the words go

/// The last step: the finished text on its way into whatever the user was
/// typing in.
@MainActor
protocol DictationInserting {
    /// Puts `text` where the user's preferences say it goes - pasted, copied,
    /// both, or neither.
    func insert(_ text: String)
    /// Replaces a captured selection with the rewritten text.
    /// - Returns: whether the target app was still there to paste into.
    func paste(_ text: String, replacing capture: SelectedTextCapture) async -> Bool
}

/// The real clipboard and the real keystrokes.
struct SystemTextInsertion: DictationInserting {
    /// Nonisolated so it can be a default argument, which is evaluated outside
    /// any actor. It holds nothing; only its two calls are on the main actor.
    nonisolated init() {}

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let finalText = DictationSession.applyPostProcessing(text)
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

    func paste(_ text: String, replacing capture: SelectedTextCapture) async -> Bool {
        await ClipboardUtil.pasteText(text, replacing: capture)
    }
}

/// The Ask panel, as a spoken question reaches it.
@MainActor
protocol DictationAsking {
    func present(query: String)
}

struct AskPanelPresentation: DictationAsking {
    /// Nonisolated for the same reason `SystemTextInsertion.init` is.
    nonisolated init() {}

    func present(query: String) {
        AskPanelWindowController.shared.present(query: query)
    }
}

/// The voice-edit rewrite stage, as the session runs it.
protocol DictationSelectionEditing {
    func rewrite(original: String, instruction: String, settings: Settings) async -> StyledTranscript
}

struct SelectionEditRewriting: DictationSelectionEditing {
    func rewrite(
        original: String, instruction: String, settings: Settings
    ) async -> StyledTranscript {
        await SelectionEditRewrite.apply(
            original: original,
            instruction: instruction,
            settings: settings,
            terms: PersonalTermsStore.shared.activeTerms
        )
    }
}

/// How long a capture turned out to be.
///
/// Its own port because the answer is read back off the file, which a test
/// driving the session with a file that holds no audio cannot do.
protocol DictationAudioMeasuring {
    func duration(of url: URL) async -> TimeInterval
}

struct AudioFileMeasurement: DictationAudioMeasuring {
    func duration(of url: URL) async -> TimeInterval {
        await AudioUtil.audioDuration(url: url)
    }
}
