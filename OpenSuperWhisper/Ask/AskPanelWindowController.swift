import AppKit
import KeyboardShortcuts
import SwiftUI

/// The Ask panel's window.
///
/// This HUD **does** take focus - the YouTube channel picker's panel is the
/// only other one that does - and the difference is the text field:
/// `CapsuleHUDPanel` and `IndicatorWindow` exist to be glanced at while the
/// user keeps typing somewhere else, so they refuse key status; a panel with a
/// question box that cannot receive a keystroke is not a panel. A borderless
/// window cannot become key without this override.
///
/// Taking focus is what makes **Insert into Active App** a real problem rather
/// than a trivial one, and it is solved elsewhere: the application the user was
/// working in is captured *before* the panel opens, and brought back before the
/// paste. See `AskPanelWindowController.insert`.
private final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the Ask panel: its window, the question that opened it, and the voice
/// follow-up.
///
/// Everything the panel *decides* is in `AskPanelViewModel`; this type is the
/// half that cannot be tested without a window server - the panel, the
/// pasteboard, the microphone and the app to paste back into.
///
/// `docs/ask-panel.md` is the feature's whole story.
@MainActor
final class AskPanelWindowController {
    static let shared = AskPanelWindowController()

    /// How long the panel takes to fade in and out.
    static let fadeDuration: TimeInterval = 0.14

    /// How far below the top of the usable screen the panel sits. Lower than the
    /// capsule's margin because this is a card to read, not a strip to glance
    /// at, and it must not collide with a capsule reporting the dictation that
    /// opened it.
    static let topMargin: CGFloat = 120

    let viewModel: AskPanelViewModel

    private var panel: NSPanel?

    /// The two halves of a screen query that talk to the system, kept as
    /// properties so the panel can be driven in a test without a window server
    /// or a Screen Recording grant.
    private let screenCapture: ScreenCapturing
    private let screenRecordingAuthorizer: ScreenRecordingAuthorizing

    /// The application that was frontmost when the panel was last presented, and
    /// the one **Insert into Active App** puts the answer into.
    ///
    /// Captured up front rather than read at insertion time: by then the
    /// frontmost application may be this one, because the user has just been
    /// typing into this panel. Only the running application is held - no window,
    /// no document, nothing about what is in it - and only for as long as the
    /// panel is up: hiding it forgets the target, so a later presentation can
    /// never paste into wherever the user was working an hour ago. See
    /// `nextInsertionTarget` for what a re-presentation does with it.
    var insertionTarget: NSRunningApplication?

    /// Which presentation the pending fade-out belongs to. A `present` can land
    /// inside `hide`'s fade, and the stale completion must not order out the
    /// panel it just re-showed.
    private var presentationGeneration = 0

    private init(
        screenCapture: ScreenCapturing = ScreenCaptureService.shared,
        screenRecordingAuthorizer: ScreenRecordingAuthorizing = SystemScreenRecordingAuthorizer()
    ) {
        self.screenCapture = screenCapture
        self.screenRecordingAuthorizer = screenRecordingAuthorizer
        viewModel = AskPanelViewModel()
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onCopy = { ClipboardUtil.copyToClipboard($0) }
        viewModel.onInsert = { [weak self] answer in self?.insert(answer) }
        viewModel.onStartVoiceCapture = { [weak self] in self?.startVoiceCapture() }
        viewModel.onFinishVoiceCapture = { [weak self] in self?.finishVoiceCapture() }
        viewModel.onCancelVoiceCapture = { [weak self] in self?.cancelVoiceCapture() }
    }

    // MARK: - Showing it

    /// What one press of the Ask shortcut means.
    ///
    /// Pure, and separate from carrying it out, so the rule can be asserted
    /// without a window server, a microphone or an on-device model - the same
    /// split `screenRecordingRefusal` and `capturedInsertionTarget` make.
    enum ShortcutAction: Equatable {
        /// Open the panel if it is not up, and start listening.
        case askByVoice
        /// A question is already being spoken: this press ends it.
        case finishVoiceQuestion
        /// Something else holds the one shared recorder - a dictation, or a
        /// YouTube command. The press starts nothing and says so where it can
        /// be seen without disturbing that recording.
        case refuseToSeizeRecorder
        /// Something is running that this press is neither the start nor the end
        /// of - a transcription, an answer, or a ⌥S query that belongs to the
        /// other key.
        case ignore
    }

    /// The press, decided from the three things that matter.
    ///
    /// It is deliberately the same shape as `toggleScreenQuery`'s and **not** a
    /// show/hide toggle any more. A key that closed an open panel could not also
    /// be a key that always starts listening, and starting the capture is what
    /// this shortcut is for: the panel is closed with Esc or the Close button.
    ///
    /// `isRecordingInFlight` is part of the decision rather than a guard bolted
    /// on beside it, because the refusal it produces is a press outcome the user
    /// is owed an answer for - left outside, it was a silent `return` that the
    /// panel's own `dictationInFlight` sentence could never be reached from.
    /// It is asked **after** the finishing case: the panel's own question is
    /// holding that recorder, and this press is what ends it.
    static func shortcutAction(
        isCapturingVoiceQuestion: Bool, isBusy: Bool, isRecordingInFlight: Bool
    ) -> ShortcutAction {
        if isCapturingVoiceQuestion { return .finishVoiceQuestion }
        // A transcription or an answer in flight is what `isBusy` exists to
        // protect, and a screen query in flight belongs to ⌥S.
        guard !isBusy else { return .ignore }
        if isRecordingInFlight { return .refuseToSeizeRecorder }
        return .askByVoice
    }

    /// The ⌥A action: start a spoken question, or finish the one already being
    /// spoken.
    ///
    /// A press begins microphone capture, the way the dictation key, the
    /// YouTube command key and ⌥S all do. It used to only put the panel on
    /// screen, which left the user looking at an idle card and pressing **Ask by
    /// voice** with the mouse - see `docs/ask-panel.md`.
    func toggleVoiceQuestion() {
        switch Self.shortcutAction(
            isCapturingVoiceQuestion: viewModel.isCapturingVoiceQuestion,
            isBusy: viewModel.isBusy,
            isRecordingInFlight: isSharedRecorderInFlight
        ) {
        case .finishVoiceQuestion:
            viewModel.finishVoiceFollowUp()
        case .ignore:
            return
        case .refuseToSeizeRecorder:
            reportRecorderInFlight()
        case .askByVoice:
            startVoiceQuestion()
        }
    }

    /// Says why a press was refused, on a card that is already on screen.
    ///
    /// The panel is deliberately **not** presented to carry the message.
    /// `present()` forces this app forward (`activate(ignoringOtherApps:)`), so
    /// the dictation this press just declined to seize would paste into the
    /// panel's own question field instead of into the user's document - opening
    /// a card to explain the refusal would do the damage the refusal exists to
    /// prevent. With no card up there is nowhere to say it that does not cost
    /// more than the press did, so the press leaves the dictation, and the
    /// screen, exactly as they were.
    private func reportRecorderInFlight() {
        guard panel?.isVisible == true else { return }
        viewModel.shortcutRefused(VoiceCaptureRefusal.dictationInFlight.message)
    }

    /// Opens the panel and starts listening, in that order.
    ///
    /// The same order `startScreenQuery` uses and for the same reason: the panel
    /// has to exist before it can show that it is recording, and the capture
    /// itself is the view model's to request - it reports every reason one
    /// cannot start (`voiceCaptureRefusal`) onto the card rather than leaving
    /// one that looks live.
    private func startVoiceQuestion() {
        present()
        viewModel.startVoiceFollowUp()
    }

    /// Opens the panel with nothing asked yet.
    func present() {
        captureInsertionTarget()
        ensurePanel()
        showPanel()
        // The user is about to wait for the model, and the first request after
        // launch is the slow one. A no-op on a Mac that cannot run it.
        AskModelFactory.prewarmIfAvailable()
    }

    // MARK: - Asking about the screen

    /// The ⌥S action: start a spoken question about the screen, or finish the
    /// one already being spoken.
    ///
    /// A toggle rather than a hold, and the same shape as the recording hotkey:
    /// press to start, press again when you have finished asking.
    func toggleScreenQuery() {
        if viewModel.isCapturingScreenQuery {
            viewModel.finishVoiceFollowUp()
            return
        }
        // Nothing to toggle into while the panel is already working: taking a
        // screenshot the view model would refuse is wasted work, and a second
        // question mid-answer is what `isBusy` exists to prevent.
        guard !viewModel.isBusy else { return }
        guard !isSharedRecorderInFlight else {
            reportRecorderInFlight()
            return
        }
        startScreenQuery()
    }

    /// Takes the screenshot, opens the panel, and starts listening.
    ///
    /// The order is the feature. The frontmost application is read **first**,
    /// while it is still the user's own - opening this panel activates Kongweh
    /// - and the capture is started before the panel is shown so the shot is of
    /// what they were looking at rather than of the card that just appeared over
    /// it. Screen Recording is checked here and nowhere else: a Mac that has
    /// never granted it dictates exactly as it always did.
    private func startScreenQuery() {
        let frontmost = NSWorkspace.shared.frontmostApplication

        if !screenRecordingAuthorizer.isScreenRecordingGranted() {
            let previouslyAsked = AppPreferences.shared.screenRecordingAccessRequested
            guard screenRecordingAuthorizer.requestScreenRecordingAccess() else {
                // `screenRecordingRefusal` decides what else the user sees: on
                // the first press the OS dialog is already up and is the one
                // thing to act on; every later press has no dialog left, so
                // System Settings is opened instead.
                let refusal = Self.screenRecordingRefusal(previouslyAsked: previouslyAsked)
                present()
                viewModel.screenQueryRefused(refusal.message)
                if refusal.opensSystemSettings {
                    PermissionsManager.openSystemSettings(for: .screenRecording)
                }
                return
            }
        }

        let capture = Task { [screenCapture] in
            try await screenCapture.captureScreen(ofProcess: frontmost?.processIdentifier)
        }

        present()
        guard let token = viewModel.startScreenQuery() else {
            capture.cancel()
            return
        }

        Task { [weak self] in
            do {
                let observation = try await capture.value
                self?.viewModel.attachScreen(observation, token: token)
            } catch let error as ScreenCaptureError {
                self?.viewModel.screenCaptureDidFail(error.message, token: token)
            } catch {
                self?.viewModel.screenCaptureDidFail(
                    ScreenCaptureError.captureFailed(error.localizedDescription).message,
                    token: token
                )
            }
        }
    }

    /// What a refused Screen Recording check puts on the panel, and whether it
    /// also opens System Settings.
    ///
    /// macOS shows its own permission dialog exactly once per app, and the
    /// first ⌥S without a grant is that once: the dialog is already on screen
    /// when the request returns false, so the panel explains and nothing else
    /// opens - jumping to System Settings as well would bury the dialog that
    /// matters under a third surface. Every later refusal has no dialog left to
    /// show (`screenRecordingAccessRequested` is how the app knows), so the
    /// panel's sentence points at System Settings and the pane is opened.
    struct ScreenRecordingRefusal: Equatable {
        let message: String
        let opensSystemSettings: Bool
    }

    static func screenRecordingRefusal(previouslyAsked: Bool) -> ScreenRecordingRefusal {
        if previouslyAsked {
            return ScreenRecordingRefusal(
                message: ScreenCaptureError.permissionDenied.message,
                opensSystemSettings: true
            )
        }
        return ScreenRecordingRefusal(
            message: "Kongweh just asked macOS for Screen Recording permission. "
                + "Grant it in the dialog that appeared, then try again.",
            opensSystemSettings: false
        )
    }

    /// Opens the panel on a question, which is how a spoken `Ask: …` arrives.
    ///
    /// The insertion target is deliberately captured the same way as for the
    /// shortcut: the user was dictating into some application a moment ago, and
    /// that application is still frontmost when this runs.
    func present(query: String) {
        present()
        Task { await viewModel.ask(query) }
    }

    func hide() {
        stopVoiceCaptureIfRunning()
        let target = insertionTarget
        insertionTarget = nil
        guard let panel, panel.isVisible else { return }
        // Opening the panel took keyboard focus, so closing it hands focus back
        // - the same hand-back `insert` does - or the user's next keystrokes go
        // nowhere until they click. Only while this app still holds focus: if
        // the user already clicked into another app, yanking it back from there
        // would be worse than leaving it.
        if NSApplication.shared.isActive {
            target?.activate()
        }
        presentationGeneration += 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            panel.orderOut(nil)
        }
    }

    private func showPanel() {
        guard let panel else { return }
        presentationGeneration += 1
        if let screen = CapsuleHUDWindowController.targetScreen(nearPoint: nil) {
            panel.setFrameOrigin(
                Self.origin(visibleFrame: screen.visibleFrame, windowSize: AskPanelView.windowSize)
            )
        }
        // The app has to come forward for the question field to receive a
        // keystroke at all: keyboard input goes to the active application, and
        // this one spends its life in the background. It is why the insertion
        // target is captured first - by the time the user presses Insert, the
        // frontmost application is this one.
        //
        // `ignoringOtherApps` for the reason `YouTubeChannelPickerWindowController`
        // measured: macOS grants a background process the right to activate only
        // just after the user has given it attention, and this app is given none
        // - a global hotkey press goes to the system rather than into this app's
        // event stream, and a spoken "Ask: …" opens the panel later still, after
        // a recording and a transcription. Without it the card appeared over the
        // frontmost app, never became key, and Esc and every keystroke went to
        // that app instead. It is the same trade the picker makes and tolerable
        // for the same reason: the panel is only ever here because the user
        // pressed a key of their own or said so.
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard !panel.isVisible || panel.alphaValue < 1 else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Top-centre of the screen's usable area, in the window coordinates AppKit
    /// wants.
    ///
    /// Takes the rectangle rather than the `NSScreen` it came from so the
    /// arithmetic can be asserted against a screen the test machine does not
    /// have - the same reason `CapsuleHUDWindowController.origin` does.
    static func origin(visibleFrame visible: CGRect, windowSize: CGSize) -> NSPoint {
        let cardTop = visible.maxY - topMargin
        let cardTopInset = (windowSize.height - AskPanelView.cardSize.height) / 2
        var x = visible.midX - windowSize.width / 2
        x = max(visible.minX, min(x, visible.maxX - windowSize.width))
        let y = max(visible.minY, cardTop + cardTopInset - windowSize.height)
        return NSPoint(x: x, y: y)
    }

    private func ensurePanel() {
        if panel == nil {
            let created = AskPanel(
                contentRect: NSRect(origin: .zero, size: AskPanelView.windowSize),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.backgroundColor = .clear
            created.isOpaque = false
            // The card draws its own shadow, inside the window. A window shadow
            // would be drawn around the whole transparent panel instead.
            created.hasShadow = false
            created.hidesOnDeactivate = false
            panel = created
        }

        guard let panel else { return }
        if let hostingView = panel.contentView as? NSHostingView<AskPanelView> {
            hostingView.rootView = AskPanelView(viewModel: viewModel)
        } else {
            let hostingView = NSHostingView(rootView: AskPanelView(viewModel: viewModel))
            // SwiftUI's ideal size must never drive this window: a hosting view
            // left to size itself shrinks the panel to the card, and the window
            // bounds then clip the card's shadow.
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            panel.contentView = hostingView
        }
        panel.setContentSize(AskPanelView.windowSize)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - What the answer does next

    private func captureInsertionTarget() {
        insertionTarget = Self.nextInsertionTarget(
            frontmost: NSWorkspace.shared.frontmostApplication,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            held: insertionTarget
        )
    }

    /// The target a presentation leaves the panel holding: whoever is frontmost
    /// now, and otherwise whoever it was already holding.
    ///
    /// Both halves are load-bearing, because `present()` is no longer reached
    /// only with the panel hidden. A second ⌥A press - the follow-up the
    /// shortcut exists to make - re-presents a panel that is already up and
    /// already key, so the frontmost application is Kongweh itself,
    /// `capturedInsertionTarget` refuses this app, and a plain capture would
    /// replace the target the panel opened with (the user's editor) with
    /// nothing: **Insert into Active App** would then fall back to the clipboard
    /// on exactly the question they asked while looking at the document they
    /// wanted it in.
    ///
    /// Keeping the held target across every re-presentation is the opposite
    /// mistake and the worse one. The panel is `.floating` and does not hide on
    /// deactivate, so it survives a switch to another application, and a press
    /// made *there* would paste the answer into the application the user left.
    /// Reading first and falling back second is what tells the two apart: the
    /// read refuses this app and only this app, and only this app is not a move.
    static func nextInsertionTarget(
        frontmost: NSRunningApplication?,
        ownBundleIdentifier: String?,
        held: NSRunningApplication?
    ) -> NSRunningApplication? {
        capturedInsertionTarget(frontmost: frontmost, ownBundleIdentifier: ownBundleIdentifier)
            ?? held
    }

    /// The application **Insert into Active App** would paste into, given who
    /// was frontmost when the panel opened.
    ///
    /// This app itself is never a target: a panel opened from Kongweh's own
    /// window remembers nothing, and the answer then goes to the clipboard and
    /// nowhere else.
    static func capturedInsertionTarget(
        frontmost: NSRunningApplication?, ownBundleIdentifier: String?
    ) -> NSRunningApplication? {
        guard let frontmost, frontmost.bundleIdentifier != ownBundleIdentifier else { return nil }
        return frontmost
    }

    /// Puts the answer into the application the user was working in.
    ///
    /// This app holds keyboard focus while the panel is open, so the target has
    /// to be brought back before the paste - a synthesized Cmd+V goes wherever
    /// the keyboard is pointing, and if that were still this panel the answer
    /// would be pasted into the question field. The clipboard is left holding
    /// the answer rather than restored, because a user who pressed Insert wants
    /// the text and having it on the clipboard as well costs them nothing.
    ///
    /// Without a remembered target - the panel was opened from Kongweh's own
    /// window, or the frontmost application could not be read - the answer goes
    /// to the clipboard and nowhere else. Guessing where to paste is the one
    /// thing this must not do, which is also why a target that cannot come
    /// forward - quit while the panel was open - degrades to the clipboard
    /// rather than to a paste into whatever happens to be frontmost.
    private func insert(_ answer: String) {
        let target = insertionTarget
        hide()
        guard let target, target.activate() else {
            ClipboardUtil.copyToClipboard(answer)
            return
        }
        // One runloop turn is not enough for another application to take
        // keyboard focus; the paste has to wait for the activation to land or
        // it is delivered to whoever still has it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDelay) {
            ClipboardUtil.insertTextAndKeepInClipboard(answer)
        }
    }

    /// How long to wait for the target application to come forward before
    /// synthesizing the paste. Measured against the same activation the update
    /// installer relies on; shorter than this and the keystroke arrives while
    /// this panel still has focus.
    static let activationDelay: TimeInterval = 0.15

    // MARK: - Voice follow-up

    /// The follow-up records and transcribes through the ordinary services, but
    /// deliberately not through `IndicatorWindowManager`: that machinery exists
    /// to paste into another app, and this recording is a question for the panel
    /// that is already on screen. The panel shows its own listening state.
    private var isCapturing = false

    /// Why a capture cannot start, and what the card says instead.
    ///
    /// Pure and separate from starting one, the same split `shortcutAction`
    /// makes, because the case that matters most cannot be reached from a test
    /// at all: `AudioRecorder.shared` is a singleton wired to real hardware.
    enum VoiceCaptureRefusal: Equatable {
        case noMicrophone
        case dictationInFlight
        case busy

        var message: String {
            switch self {
            case .noMicrophone: return "No microphone"
            case .dictationInFlight: return "Recording a dictation - finish that first"
            case .busy: return "Busy - try again in a moment"
            }
        }
    }

    /// A recording already in flight refuses the press rather than taking it
    /// over.
    ///
    /// There is one `AudioRecorder` and the dictation keys hold the same
    /// instance, and starting a second recording on it **discards the first**:
    /// the dictation's audio is deleted and its file re-pointed at this
    /// question, so the ⌥` that ends the dictation hands the user's document the
    /// question they asked the panel while the panel reports hearing nothing.
    /// Refusing is the only answer that leaves the dictation entirely alone -
    /// deferring the press the way `EngineSwitcher` does would start listening
    /// at a moment the user has stopped speaking to the panel.
    ///
    /// This is the **sentence**, not the enforcement: `AudioRecorder` refuses
    /// the second claim itself (`hasSessionInFlight`), which is what makes the
    /// rule hold in the other direction too - a dictation started while this
    /// panel is listening is refused by the same claim, and used to seize the
    /// question instead. This function only decides what the card then says.
    ///
    /// A microphone that has to wake up counts as in flight: it is recording to
    /// its file already, and the window before the first samples arrive is
    /// exactly where a second press would land.
    static func voiceCaptureRefusal(
        hasMicrophone: Bool, isRecordingInFlight: Bool, isTranscribing: Bool
    ) -> VoiceCaptureRefusal? {
        guard hasMicrophone else { return .noMicrophone }
        if isRecordingInFlight { return .dictationInFlight }
        if isTranscribing { return .busy }
        return nil
    }

    /// Whether something already holds the one shared `AudioRecorder`.
    ///
    /// `hasSessionInFlight` rather than the published `isRecording` and
    /// `isConnecting`: those are set on the main queue *after* the recorder's
    /// work queue has paid its CoreAudio round-trips, so a press landing in that
    /// window read an idle recorder and started a second capture on it - the
    /// very seizure this predicate exists to refuse.
    private var isSharedRecorderInFlight: Bool {
        AudioRecorder.shared.hasSessionInFlight
    }

    private func startVoiceCapture() {
        guard !isCapturing else { return }
        if let refusal = Self.voiceCaptureRefusal(
            hasMicrophone: MicrophoneService.shared.getActiveMicrophone() != nil,
            isRecordingInFlight: isSharedRecorderInFlight,
            isTranscribing: TranscriptionService.shared.isTranscribing
        ) {
            viewModel.voiceCaptureDidFail(refusal.message)
            return
        }
        // The recorder's own claim is what actually decides, and it is atomic:
        // the read above can go stale between here and the next line, and the
        // panel must never be left showing "Listening…" over a capture that was
        // refused - or, worse, over a dictation it has just taken.
        guard AudioRecorder.shared.startRecording() else {
            viewModel.voiceCaptureDidFail(VoiceCaptureRefusal.dictationInFlight.message)
            return
        }
        isCapturing = true
    }

    private func finishVoiceCapture() {
        guard isCapturing else { return }
        isCapturing = false

        Task { [weak self] in
            guard let self else { return }
            guard let url = await AudioRecorder.shared.stopRecording() else {
                self.viewModel.voiceCaptureDidFail("No speech detected")
                return
            }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let styled = try await TranscriptionService.shared.transcribeAudio(
                    url: url, settings: Self.followUpTranscriptionSettings()
                )
                await self.viewModel.voiceCaptureDidProduce(styled.final)
            } catch {
                self.viewModel.voiceCaptureDidFail(
                    IndicatorViewModel.failureMessage(for: error)
                )
            }
        }
    }

    /// The settings a voice follow-up is transcribed with.
    ///
    /// `routesSpokenIntents` stays off: a follow-up that began "Ask: …" must
    /// not be routed back into the panel it came from. And the style rewrite is
    /// pinned off whatever the user's preference says: a question is not a
    /// dictation to restyle, and restyling it on its way to the model that is
    /// about to answer it changes what was asked. The deterministic stages -
    /// personal terms, CJK spacing - still run.
    static func followUpTranscriptionSettings() -> Settings {
        var settings = Settings()
        settings.styleRewrite = .disabled
        return settings
    }

    private func cancelVoiceCapture() {
        guard isCapturing else { return }
        isCapturing = false
        AudioRecorder.shared.cancelRecording()
    }

    private func stopVoiceCaptureIfRunning() {
        guard isCapturing else { return }
        isCapturing = false
        AudioRecorder.shared.cancelRecording()
    }
}
