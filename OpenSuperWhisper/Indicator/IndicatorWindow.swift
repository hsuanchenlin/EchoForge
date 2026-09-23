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

    /// The microphone never opened for this session.
    ///
    /// Its own case rather than `.noMicrophone` because it is reached from a
    /// different place and means something different: `.noMicrophone` is the
    /// synchronous refusal before anything was claimed, while this is a start
    /// that was accepted, drawn as a recording, and then failed on the
    /// recorder's work queue (`AudioRecorder.failedStart`). Until it existed the
    /// card blinked "Recording..." over a microphone that never started and then
    /// vanished without a word. The reason is short by construction - it is
    /// written for this 200 pt card and for the capsule pill.
    case recordingFailed(String)

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


extension RecordingState {
    /// What the card shows for one of the session's notices.
    ///
    /// The derivation is one-to-one and deliberately dull: `DictationNotice` is
    /// what a dictation has to say, `RecordingState` is what this card draws,
    /// and they are separate types because the second is on its way out - the
    /// capsule already follows the session's own vocabulary through it. Until
    /// the card follows the phase directly, this is the single place the two
    /// are mapped.
    init(_ notice: DictationNotice) {
        switch notice {
        case .busy(let reason): self = .busy(reason)
        case .noMicrophone: self = .noMicrophone
        case .recordingFailed(let reason): self = .recordingFailed(reason)
        case .noEngine: self = .noEngine
        case .cloudFailed(let reason): self = .cloudFailed(reason)
        case .wrongLanguage(let reason): self = .wrongLanguage(reason)
        case .commandFailed(let reason): self = .commandFailed(reason)
        }
    }
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {

    func didFinishDecoding()
}

/// The dictation card's view model: what is on screen, and for how long.
///
/// It owns no dictation. `DictationSession` does the work and publishes a
/// `DictationPhase`; this follows that phase, turns it into the `RecordingState`
/// the card draws, and runs the three timers that are properties of an overlay
/// rather than of a recording - the blink, the two seconds a message stays up,
/// and the Esc confirmation window. When the session is over and its last
/// message has been read, it tells the delegate to take the window away.
///
/// The capsule follows the same two published values through this object
/// (`CapsuleHUDWindowController.beginSession`), so a dictation is drawn from one
/// account of itself whichever overlay the user has chosen.
@MainActor
class IndicatorViewModel: ObservableObject {
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0

    /// What the card draws, derived from the session's phase.
    ///
    /// Settable so a test can put the card in a state without a microphone; the
    /// session is what writes it in production.
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false

    /// The dictation this card is showing.
    let session: DictationSession

    /// When the capture began, for the Esc confirmation threshold. Copied from
    /// the session at the press rather than read through it, so a test can date
    /// a recording that never happened.
    var recordingStartedAt: Date?

    /// Republished from the session so the capsule can follow it here, beside
    /// the phase, rather than reaching past this object into the session.
    @Published private(set) var liveTranscript: PartialTranscript?

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    convenience init(
        purpose: DictationPurpose = .dictation,
        dictationTarget: DictationTargetApp? = AppDetector.currentTarget(),
        selectionEdit: SelectedTextCapture? = nil
    ) {
        self.init(
            session: DictationSession(
                purpose: purpose,
                dictationTarget: dictationTarget,
                selectionEdit: selectionEdit))
    }

    init(session: DictationSession) {
        self.session = session

        // Followed without a scheduler hop on purpose: the session is on this
        // actor and publishes from it, and the card's answer to a refused start
        // has to be on screen in the same turn the press is handled - a hop
        // would leave the window up with nothing drawn in it.
        session.$phase
            .sink { [weak self] phase in self?.follow(phase) }
            .store(in: &cancellables)

        session.$liveTranscript
            .sink { [weak self] transcript in self?.liveTranscript = transcript }
            .store(in: &cancellables)
    }

    // MARK: - What the session says

    /// Turns one phase into what the card is showing and which timers run.
    private func follow(_ phase: DictationPhase) {
        switch phase {
        case .idle:
            state = .idle
        case .connecting:
            state = .connecting
            stopBlinking()
        case .recording:
            state = .recording
            startBlinking()
        case .decoding:
            resetCancelConfirmation()
            stopBlinking()
            state = .decoding
        case .awaitingChannelChoice:
            state = .awaitingChannelChoice
        case .ended(let notice):
            resetCancelConfirmation()
            stopBlinking()
            recordingStartedAt = nil
            guard let notice else {
                delegate?.didFinishDecoding()
                return
            }
            showAutoDismissingMessage(RecordingState(notice))
        }
    }

    /// Leaves a message up long enough to read, then takes the window away.
    ///
    /// Two seconds, and the same two seconds for every message: the card holds
    /// one short line and there is nothing on it to act on, so a per-message
    /// duration would only make the overlay's behaviour harder to predict.
    private func showAutoDismissingMessage(_ message: RecordingState) {
        state = message

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    // MARK: - What the session is

    /// What the key that started this session captures. Read by the capsule to
    /// decide what its chip promises.
    var purpose: DictationPurpose { session.purpose }

    /// The app this dictation is going into. Read by the capsule for the same
    /// reason `purpose` is.
    var dictationTarget: DictationTargetApp? { session.dictationTarget }

    /// The text a voice edit is rewriting, or nil on every other purpose.
    var selectionEdit: SelectedTextCapture? { session.selectionEdit }

    /// What this dictation produced, once the session knows.
    var result: DictationResult? { session.result }

    /// The line the card shows while capturing, so a voice edit is not drawn
    /// as an ordinary dictation.
    var recordingHeadline: String {
        if isConfirmingCancel { return "Press Esc to cancel" }
        return selectionEdit?.hudStatusText ?? "Recording..."
    }

    // MARK: - Driving the session

    func startRecording() {
        session.start()
        // Dated from the press, not from the moment the microphone opens: a
        // headset that takes two seconds to connect is two seconds the user
        // has been holding the key, and the Esc confirmation threshold is
        // about how long they have been waiting.
        if session.isCapturing {
            recordingStartedAt = Date()
        }
    }

    /// A voice-edit press that found nothing to edit.
    func showNothingToEdit() {
        session.reportNothingToEdit()
    }

    func startDecoding() {
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding or hide the window while transcription is in flight.
        guard state == .recording || state == .connecting else { return }

        session.stop()
    }

    func cancelWorkInFlight() {
        session.cancelWorkInFlight()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        session.cancel()
    }

    // MARK: - The Esc confirmation

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

    // MARK: - Timers

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
        session.cleanup()
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

            case .recordingFailed(let reason):
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text(reason)
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
