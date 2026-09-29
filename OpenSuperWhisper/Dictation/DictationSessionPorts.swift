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

/// The microphone, as one dictation uses it: claim a capture, whose handle
/// is the stop, the cancel and the start's own result.
protocol DictationRecording: AnyObject {
    /// Whether there is an input device to record with.
    ///
    /// Answered from the cached device list, so asking costs no CoreAudio
    /// round-trip on the main thread.
    var hasActiveInput: Bool { get }

    /// Claims the microphone for one capture, or refuses because something
    /// already holds it. See `RecordingCapture`.
    func startRecording() -> RecordingCapture?

    /// Moves a temporary capture under the name history gave it.
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws
}

extension AudioRecorder: DictationRecording {
    var hasActiveInput: Bool { MicrophoneService.shared.getActiveMicrophone() != nil }
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

/// Where a dictation's finished words go, once they are known.
///
/// The hotkey path pastes into whatever the user was typing in and reads the
/// words for a spoken command or correction. Two more surfaces used to run a
/// smaller copy of the same orchestration to reach two different endings:
/// the main window's record button only ever wanted the words in history, and
/// the Ask panel's own voice follow-up only ever wanted them handed back as
/// the next question. Both now ask for the ending they want instead of
/// keeping their own copy of everything that leads up to it.
enum DictationDelivery {
    /// The ordinary hotkey path: paste into the target app, and read the
    /// words for a spoken command or correction.
    case insertion
    /// The main window's record button: add to history, and nothing else -
    /// never pasted, never read for a command or a correction.
    case historyOnly
    /// The Ask panel's own voice follow-up: hand the words to `receiver`
    /// instead of pasting or storing them. Never kept in history even on
    /// failure - there is no regenerate button on a question, only the card
    /// telling the user to try again.
    case toPanel(receiver: DictationPanelReceiving)
}

/// Where a `.toPanel` dictation's finished words - or its failure - land.
///
/// `AskPanelViewModel` already has exactly this shape from the follow-up it
/// used to drive by hand, so it conforms with nothing added.
@MainActor
protocol DictationPanelReceiving: AnyObject {
    func voiceCaptureDidProduce(_ text: String) async
    func voiceCaptureDidFail(_ message: String)
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
