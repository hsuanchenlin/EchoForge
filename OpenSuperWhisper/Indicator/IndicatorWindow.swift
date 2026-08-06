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
        guard EngineConfiguration.isNotConfigured(error) else { return .discard }
        return .keep(reason: EngineConfiguration.unavailableMessage, indicatorState: .noEngine)
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
    
    init(dictationTarget: DictationTargetApp? = AppDetector.currentTarget()) {
        self.dictationTarget = dictationTarget
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared

        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage(_ reason: BusyReason) {
        showAutoDismissingMessage(.busy(reason))
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
        
        // Optimistically assume recording: querying the microphone here costs
        // CoreAudio HAL round-trips on the main thread right before the appear
        // animation. The recorder resolves the real state on its own queue and
        // publishes isConnecting/isRecording, which the sinks above translate
        // into .connecting/.recording.
        state = .recording
        startBlinking()
        recordingStartedAt = Date()
        
        recorder.startRecording()
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
        
        if isTranscriptionBusy {
            // The engine is busy with another transcription: keep the user's audio
            // and put it into the queue instead of deleting it.
            Task { [weak self] in
                guard let self = self else { return }
                if let tempURL = await self.recorder.stopRecording() {
                    await self.transcriptionQueue.addFileToQueue(url: tempURL)
                }
            }
            showBusyMessage(.audioQueued)
            return
        }
        
        state = .decoding
        
        Task { [weak self] in
            guard let self = self else { return }
            
            if let tempURL = await self.recorder.stopRecording() {
                let duration = await AudioUtil.audioDuration(url: tempURL)
                do {
                    print("start decoding...")
                    let styled = try await transcriptionService.transcribeAudio(
                        url: tempURL,
                        settings: Settings(
                            dictationTarget: self.dictationTarget,
                            // Live dictation is the one path where a spoken
                            // command means anything - see `Settings`.
                            routesSpokenIntents: true
                        )
                    )
                    let text = styled.final

                    if text.isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        self.result = .noSpeech
                        print("No speech detected, dictation discarded")
                    } else {
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        let newRecording = Recording(
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

                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)
                        
                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                        }

                        // A spoken question goes to the Ask panel and nowhere
                        // else. The recording is still kept and still searchable
                        // - the user asked it out loud and may want it back -
                        // but nothing is pasted into the app they were typing
                        // in, because they did not ask for that.
                        if case .ask(let query) = styled.intent {
                            AskPanelWindowController.shared.present(query: query)
                            self.result = .asked
                            print("Ask: \(query)")
                        } else {
                            insertText(text)
                            self.result = .inserted(styleNotice: styled.status.explanation)
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
                                reason: reason
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
        recorder.cancelRecording()
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
                        Text("Recording...")
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
