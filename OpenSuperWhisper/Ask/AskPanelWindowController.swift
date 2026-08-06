import AppKit
import KeyboardShortcuts
import SwiftUI

/// The Ask panel's window.
///
/// This is the one HUD in the app that **does** take focus, and the difference
/// is the text field: `CapsuleHUDPanel` and `IndicatorWindow` exist to be
/// glanced at while the user keeps typing somewhere else, so they refuse key
/// status; a panel with a question box that cannot receive a keystroke is not a
/// panel. A borderless window cannot become key without this override.
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

    /// The application that was frontmost when the panel opened, and the one
    /// **Insert into Active App** puts the answer into.
    ///
    /// Captured up front rather than read at insertion time: by then the
    /// frontmost application may be this one, because the user has just been
    /// typing into this panel. Only the running application is held - no window,
    /// no document, nothing about what is in it.
    private var insertionTarget: NSRunningApplication?

    private init() {
        viewModel = AskPanelViewModel()
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onCopy = { ClipboardUtil.copyToClipboard($0) }
        viewModel.onInsert = { [weak self] answer in self?.insert(answer) }
        viewModel.onStartVoiceCapture = { [weak self] in self?.startVoiceCapture() }
        viewModel.onFinishVoiceCapture = { [weak self] in self?.finishVoiceCapture() }
        viewModel.onCancelVoiceCapture = { [weak self] in self?.cancelVoiceCapture() }
    }

    // MARK: - Showing it

    /// The shortcut's action: open the panel, or close it if it is already up.
    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            present()
        }
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
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func showPanel() {
        guard let panel else { return }
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
        NSApplication.shared.activate()

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
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        insertionTarget = frontmost
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
    /// Without a remembered target - the panel was opened from EchoForge's own
    /// window, or the frontmost application could not be read - the answer goes
    /// to the clipboard and nowhere else. Guessing where to paste is the one
    /// thing this must not do.
    private func insert(_ answer: String) {
        hide()
        guard let insertionTarget else {
            ClipboardUtil.copyToClipboard(answer)
            return
        }
        _ = insertionTarget.activate()
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

    private func startVoiceCapture() {
        guard !isCapturing else { return }
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            viewModel.voiceCaptureDidFail("No microphone")
            return
        }
        guard !TranscriptionService.shared.isTranscribing else {
            viewModel.voiceCaptureDidFail("Busy - try again in a moment")
            return
        }
        isCapturing = true
        AudioRecorder.shared.startRecording()
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
                // `routesSpokenIntents` is left off on purpose: a follow-up that
                // began "Ask: …" must not be routed back into this panel, and a
                // question is not a dictation to restyle either.
                let styled = try await TranscriptionService.shared.transcribeAudio(
                    url: url, settings: Settings()
                )
                await self.viewModel.voiceCaptureDidProduce(styled.final)
            } catch {
                self.viewModel.voiceCaptureDidFail(
                    IndicatorViewModel.failureMessage(for: error)
                )
            }
        }
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
