import Foundation

/// What the capsule is showing.
///
/// It mirrors the stages of one dictation and nothing else: the capsule has no
/// state of its own to get out of step with the session, and `.idle` means there
/// is nothing on screen. `CapsuleHUDWindowController` owns the panel and derives
/// its visibility from this, so a transition here is the only way the HUD appears
/// or goes away.
enum CapsuleHUDState: Equatable {
    /// Nothing on screen.
    case idle
    /// The microphone is being reached - a Bluetooth headset takes a moment - so
    /// no audio is being captured yet and the timer has not started.
    case connecting
    /// Capturing. The level meter and the duration are live.
    case recording
    /// The audio has stopped and the app is turning it into text.
    case polishing(CapsuleHUDWork)
    /// The text was produced and handed to whatever the user was typing in.
    case complete
    /// Something the user should know before the capsule goes: nothing was heard,
    /// no engine is set up, the rewrite was refused. Carries what to say.
    case error(String)

    /// Whether this state goes away on its own.
    ///
    /// The distinction matters when a session ends while one of these is on
    /// screen: its own timer owns the rest of its life, and cutting it short
    /// would take the message away before it was read.
    var isTerminalBadge: Bool {
        switch self {
        case .complete, .error: return true
        case .idle, .connecting, .recording, .polishing: return false
        }
    }
}

/// The work between the audio stopping and the text arriving.
///
/// Two cases rather than one label because they are two different waits with two
/// different causes, and only one of them is affected by the Style pane.
enum CapsuleHUDWork: Equatable {
    /// The speech engine is decoding.
    case transcribing
    /// The on-device model is rewriting the transcript into the chosen style.
    case rewriting

    var label: String {
        switch self {
        case .transcribing: return "Transcribing…"
        case .rewriting: return "Polishing…"
        }
    }
}

/// What the chip on the capsule says this dictation is going to do.
///
/// EchoForge dictates; it does not translate or answer questions, so the chip
/// names what this app actually has - plain dictation, or the style the
/// transcript is about to be rewritten into. The label comes from
/// `StyleRewriteCatalog`, which owns every user-facing word about a style.
struct CapsuleHUDMode: Equatable {
    let label: String

    /// Nothing will touch the words but the deterministic stages.
    static let dictate = CapsuleHUDMode(label: "Dictate")

    /// The chip for a configuration, read the same way the pipeline reads it:
    /// `isRunnable` is false for rewriting that is switched off *and* for a
    /// custom style with no prompt written yet, and in both cases no rewrite is
    /// going to happen, so the chip must not promise one.
    static func forStyleRewrite(_ configuration: StyleRewriteConfiguration) -> CapsuleHUDMode {
        guard configuration.isRunnable else { return .dictate }
        return CapsuleHUDMode(label: configuration.style.shortName)
    }
}

/// The capsule's state machine, and the only thing that decides what it shows.
///
/// It is deliberately free of AppKit, of the panel and of the dictation itself:
/// `CapsuleHUDWindowController` translates one session's events into the calls
/// below and draws whatever comes out, so every transition - including the
/// auto-hide timings, which are the part most easily got wrong - is testable
/// without a window server, a microphone or a real 1.5 second wait.
/// See `CapsuleHUDViewModelTests`.
@MainActor
final class CapsuleHUDViewModel: ObservableObject {

    /// How long the success badge stays before the capsule fades out. Long
    /// enough to be seen, short enough not to outlive the paste it is about.
    static let completeVisibleDuration: TimeInterval = 1.5

    /// Longer than the success badge, because this one carries a sentence to
    /// read rather than a checkmark to notice.
    static let errorVisibleDuration: TimeInterval = 3.0

    /// How many samples the waveform holds. At `AudioRecorder.levelSampleInterval`
    /// that is the last ~1.4 seconds of the user's voice.
    static let waveformSampleCount = 28

    @Published private(set) var state: CapsuleHUDState = .idle
    @Published private(set) var mode: CapsuleHUDMode = .dictate

    /// When the capture actually started, which is not when the session did -
    /// reaching a Bluetooth microphone can take a second, and a timer started
    /// before the first sample counts time that is not in the recording.
    @Published private(set) var recordingStartedAt: Date?

    /// Recent microphone levels, oldest first, each 0…1. The waveform draws these
    /// directly.
    @Published private(set) var levels: [Float] = []

    /// Whether the first Esc press is being visibly acknowledged.
    ///
    /// The session's own state machine (`IndicatorViewModel.isConfirmingCancel`)
    /// decides; the capsule only mirrors it, so the pill can show the same
    /// "Press Esc to cancel" step the card shows instead of letting the first
    /// Esc look dead.
    @Published private(set) var isConfirmingCancel = false

    /// What the cancel button does. Set by whoever owns the dictation; the view
    /// model neither knows nor cares what cancelling involves.
    var onCancel: (() -> Void)?

    /// Called once whenever the capsule has finished with the screen, so the
    /// controller can fade the panel out and put the level meter back.
    var onHide: (() -> Void)?

    // Both seams stay on the main actor, like everything else here: dropping the
    // annotation makes the default arguments below lose their isolation, which is
    // an error under the Swift 6 language mode.
    private let now: @MainActor () -> Date
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Which visible state a pending auto-hide belongs to.
    ///
    /// A scheduled hide cannot simply run: 1.5 seconds is long enough for the
    /// user to start their next dictation, and a hide left over from the previous
    /// one would take that fresh capsule off the screen. Every transition
    /// invalidates whatever was scheduled by moving this on.
    private var generation = 0

    init(
        now: @escaping @MainActor () -> Date = Date.init,
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
            = CapsuleHUDViewModel.scheduleOnMainQueue
    ) {
        self.now = now
        self.schedule = schedule
    }

    /// The production timer. A test injects its own so the suite does not spend
    /// the badge durations waiting for them.
    static func scheduleOnMainQueue(after delay: TimeInterval, work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    // MARK: - Session

    /// Starts a session, before it is known whether the microphone is ready.
    ///
    /// The mode is taken once, here, rather than read while the capsule is on
    /// screen: what the chip promises must be what the pipeline is about to do
    /// with these words, and Settings can be changed mid-dictation.
    func beginSession(mode: CapsuleHUDMode) {
        generation += 1
        self.mode = mode
        recordingStartedAt = nil
        levels = []
        isConfirmingCancel = false
        state = .connecting
    }

    func beginConnecting() {
        guard state != .connecting else { return }
        generation += 1
        state = .connecting
    }

    func beginRecording() {
        guard state != .recording else { return }
        generation += 1
        if recordingStartedAt == nil {
            recordingStartedAt = now()
        }
        state = .recording
    }

    func beginPolishing(_ work: CapsuleHUDWork) {
        guard state != .polishing(work) else { return }
        // Nothing to polish once a badge is up: a late rewrite notification
        // arriving after the session ended must not reopen the capsule.
        guard !state.isTerminalBadge, state != .idle else { return }
        // The two waits happen in order, so the label only ever moves forwards.
        // A repeated decoding notification arriving after the rewrite started
        // must not tell the user the engine is still going.
        guard !(state == .polishing(.rewriting) && work == .transcribing) else { return }
        // A rewrite can only follow this session's own decode.
        // `StyleRewriteActivity` is global and every transcription flow passes
        // through it, so a queue item's rewrite - file drop, open-with, history
        // regenerate - would otherwise hijack a capsule that is still recording.
        guard !(work == .rewriting && state != .polishing(.transcribing)) else { return }
        generation += 1
        state = .polishing(work)
    }

    /// The dictation produced text and the app used it.
    ///
    /// Ignored unless a session is actually in flight, which is what keeps a
    /// cancelled dictation - or one already showing why it failed - from ending
    /// on a checkmark.
    func complete() {
        switch state {
        case .connecting, .recording, .polishing:
            break
        case .idle, .complete, .error:
            return
        }
        generation += 1
        state = .complete
        scheduleHide(after: Self.completeVisibleDuration)
    }

    /// Something the user should know. Replaces whatever is on screen, including
    /// an earlier message: the newest reason is the one that still applies.
    func fail(_ message: String) {
        guard state != .idle else { return }
        generation += 1
        state = .error(message)
        scheduleHide(after: Self.errorVisibleDuration)
    }

    /// The session ended with nothing more to say - it was cancelled, or the
    /// message explaining it is already up.
    ///
    /// A badge already on screen is left to its own timer; anything else goes
    /// immediately, because a capsule that keeps saying "Recording…" after the
    /// recording stopped is worse than no capsule.
    func endWithoutBadge() {
        guard !state.isTerminalBadge else { return }
        guard state != .idle else { return }
        dismiss()
    }

    /// The user pressed the capsule's cancel button.
    ///
    /// The capsule goes at once rather than waiting for the work to unwind: the
    /// user asked for it to stop, and the failure that cancelling causes is not a
    /// failure to report back to them.
    func cancel() {
        guard case .polishing = state else { return }
        let cancelWork = onCancel
        dismiss()
        cancelWork?()
    }

    /// Takes the capsule off the screen now.
    func dismiss() {
        guard state != .idle else { return }
        generation += 1
        state = .idle
        recordingStartedAt = nil
        levels = []
        isConfirmingCancel = false
        onHide?()
    }

    /// Mirrors the session's cancel-confirmation step, which only exists while
    /// the recording it belongs to is on screen - a confirmation raised for
    /// some other state has nothing here to confirm.
    func setCancelConfirmation(_ confirming: Bool) {
        guard !confirming || state == .recording else { return }
        isConfirmingCancel = confirming
    }

    private func scheduleHide(after delay: TimeInterval) {
        let scheduledGeneration = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.dismiss()
        }
    }

    // MARK: - Driving it from a dictation

    /// Follows the indicator's own state, which is the app's single account of
    /// where a dictation has got to.
    ///
    /// Mapped rather than mirrored: `.busy`, `.noMicrophone` and `.noEngine` are
    /// three different sentences the user needs and the card already shows all
    /// three in the same warning styling, so the capsule shows them the same way.
    func follow(_ recordingState: RecordingState) {
        switch recordingState {
        case .idle:
            break
        case .connecting:
            beginConnecting()
        case .recording:
            beginRecording()
        case .decoding:
            beginPolishing(.transcribing)
        // The two busy paths look alike but only one kept the audio: a stop
        // while busy queues the recording, a start while busy refuses it, and
        // "queued" for the refused start would promise words that are never
        // going to arrive.
        case .busy(.audioQueued):
            fail("Still transcribing - queued")
        case .busy(.startRefused):
            fail("Busy - try again in a moment")
        case .noMicrophone:
            fail("No microphone")
        case .noEngine:
            fail(CapsuleHUDViewModel.noEngineMessage)
        }
    }

    /// Kept to the two words the pill has room for. The sentence the user can act
    /// on is on the recording that was kept and in the main window's banner - the
    /// same division the indicator card makes.
    static let noEngineMessage = "No engine set up"

    /// How a finished session ends on screen.
    func finish(result: DictationResult?) {
        switch result {
        case .none:
            endWithoutBadge()
        case .inserted(styleNotice: nil):
            complete()
        // The text went in exactly as a plain success does; the badge is the
        // only place the kept-the-original story is told, and the notice is the
        // stage's own sentence for it.
        case .inserted(styleNotice: let notice?):
            fail(notice)
        case .noSpeech:
            fail("No speech detected")
        case .failed(let reason):
            fail(reason)
        }
    }

    // MARK: - Level meter

    /// Adds one microphone sample, dropping the oldest once the window is full.
    func pushLevel(_ level: Float) {
        guard case .recording = state else { return }
        levels.append(min(1, max(0, level)))
        if levels.count > Self.waveformSampleCount {
            levels.removeFirst(levels.count - Self.waveformSampleCount)
        }
    }

    // MARK: - Duration

    /// How long the capture has been running at `date`.
    func elapsed(at date: Date) -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return max(0, date.timeIntervalSince(recordingStartedAt))
    }

    /// The duration as the capsule shows it: `m:ss`, growing an hours field only
    /// if a dictation ever needs one.
    ///
    /// Not `TextUtil.formatDuration`, which writes "1m 5s" - that is right for a
    /// row in history and wrong for a counter that has to hold still while it
    /// runs, where a fixed `0:00` shape is what stops the capsule twitching wider
    /// every ten seconds.
    static func durationText(for duration: TimeInterval) -> String {
        let total = Int(max(0, duration))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
