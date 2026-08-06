import AppKit
import Combine
import SwiftUI

/// A panel that can be seen but never focused.
///
/// This is load-bearing rather than tidy: the last thing a dictation does is
/// paste into whatever app the user was typing in, so a HUD that took key focus
/// on its way up would change the target of the paste it is reporting on.
/// `.nonactivatingPanel` keeps the *app* from activating; refusing key and main
/// keeps this window from taking focus within it. The cancel button still works -
/// mouse events do not require key status.
private final class CapsuleHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes the frame it was given, unchanged.
    ///
    /// AppKit's default is to pull a window down until it fits inside the screen's
    /// visible frame, and this panel is deliberately taller than the pill it
    /// contains - the extra is transparent margin for the shadow, and the top of
    /// it is *meant* to overlap the menu bar strip. Left constrained, every
    /// placement landed 16 pt lower than it asked for, which is what a HUD sitting
    /// slightly too far down looks like.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the capsule's panel and turns one dictation into the state the capsule
/// draws.
///
/// It is the alternative to `IndicatorWindow`, never an addition to it: both are
/// presentations of the same session, and `IndicatorWindowManager` decides which
/// one a dictation gets, once, when it starts. Nothing here starts, stops or
/// alters a dictation - the single exception is the cancel button, which asks the
/// manager to cancel the work the capsule is currently reporting on.
@MainActor
final class CapsuleHUDWindowController {
    static let shared = CapsuleHUDWindowController()

    /// Whether a dictation starting now is shown as the capsule.
    ///
    /// Read once per session by `IndicatorWindowManager`, so flipping the
    /// preference mid-dictation cannot leave the session with two overlays or
    /// with none.
    static var isEnabled: Bool { AppPreferences.shared.capsuleHUDEnabled }

    /// How long the capsule takes to fade in and out. Short enough to feel
    /// immediate, long enough not to read as a flash.
    static let fadeDuration: TimeInterval = 0.18

    /// The gap between the top of the usable screen and the top of the pill.
    ///
    /// Measured from `visibleFrame`, which already excludes the menu bar on every
    /// display including the notched ones, so one number is right everywhere
    /// instead of a per-Mac inset.
    static let topMargin: CGFloat = 12

    let viewModel: CapsuleHUDViewModel

    private var panel: NSPanel?
    private var sessionCancellables = Set<AnyCancellable>()
    private var stateCancellable: AnyCancellable?

    init() {
        let viewModel = CapsuleHUDViewModel()
        self.viewModel = viewModel
        viewModel.onHide = { [weak self] in self?.hidePanel() }
        // The pill only accepts clicks while it has something to click. A HUD
        // that swallows mouse events for the whole recording would take the top
        // strip of the screen away from the app underneath it.
        stateCancellable = viewModel.$state.sink { [weak self] state in
            self?.panel?.ignoresMouseEvents = !Self.acceptsMouseEvents(in: state)
        }
    }

    private static func acceptsMouseEvents(in state: CapsuleHUDState) -> Bool {
        if case .polishing = state { return true }
        return false
    }

    // MARK: - A session

    /// Starts following a dictation. Shows nothing yet: the panel is ordered on
    /// screen by `present(nearPoint:)`, once it has somewhere to be.
    func beginSession(for indicatorViewModel: IndicatorViewModel) {
        sessionCancellables.removeAll()

        // The chip promises what this dictation will do, so the promise is taken
        // from the preferences as they are now - the same snapshot the pipeline
        // itself takes when the audio stops - and against the same app the
        // session captured, so an app-matched style is named on the chip rather
        // than arriving unannounced.
        let settings = Settings(dictationTarget: indicatorViewModel.dictationTarget)
        viewModel.beginSession(mode: CapsuleHUDMode.forStyleRewrite(settings.styleRewrite))
        viewModel.onCancel = { IndicatorWindowManager.shared.cancelWorkInFlight() }

        // Built now, while the caret position is still being resolved: the panel,
        // its backing store and the blur material cost tens of milliseconds that
        // must not be paid during the appear animation.
        ensurePanel()

        indicatorViewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.viewModel.follow(state)
            }
            .store(in: &sessionCancellables)

        // The Esc confirmation step runs in the session's state machine either
        // way; the capsule mirrors it so the first Esc is visibly acknowledged
        // instead of looking dead.
        indicatorViewModel.$isConfirmingCancel
            .receive(on: RunLoop.main)
            .sink { [weak self] confirming in
                self?.viewModel.setCancelConfirmation(confirming)
            }
            .store(in: &sessionCancellables)

        AudioRecorder.shared.$inputLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.viewModel.pushLevel(level)
            }
            .store(in: &sessionCancellables)

        // Only the transition into rewriting is followed. Its end means the
        // transcription is finished, and the session's own outcome is what says
        // so - stepping back to "Transcribing…" at that point would be a lie in
        // the last half second of the wait.
        //
        // The flag is global - the transcription queue's rewrites raise it too,
        // and a `@Published` even replays a rewrite already in flight at
        // subscription time. The view model is what scopes it to this session:
        // `beginPolishing(.rewriting)` is refused unless the capsule is already
        // showing its own decode.
        StyleRewriteActivity.shared.$isRewriting
            .receive(on: RunLoop.main)
            .sink { [weak self] isRewriting in
                guard isRewriting else { return }
                self?.viewModel.beginPolishing(.rewriting)
            }
            .store(in: &sessionCancellables)

        AudioRecorder.shared.setLevelMonitoring(enabled: true)
    }

    /// Puts the capsule on screen, anchored to the top of the screen the user is
    /// working on.
    ///
    /// `point` is used to pick that screen, not to place the pill: the capsule is
    /// deliberately not caret-anchored - it is one fixed place to look, which is
    /// the whole difference between it and the indicator card.
    func present(nearPoint point: NSPoint?) {
        // The session can already be over: cancelling during the caret lookup is
        // ordinary, and an unpositioned panel ordered front would appear at the
        // bottom-left corner of the primary screen.
        guard viewModel.state != .idle else { return }
        ensurePanel()
        guard let panel, let screen = Self.targetScreen(nearPoint: point) else { return }

        panel.setFrameOrigin(
            Self.origin(
                visibleFrame: screen.visibleFrame,
                screenFrame: screen.frame,
                windowSize: CapsuleHUDView.windowSize
            )
        )

        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The dictation is over. What the capsule does next is decided by what it
    /// produced - a checkmark, a sentence, or nothing at all.
    func endSession(result: DictationResult?) {
        viewModel.finish(result: result)
    }

    /// Takes the capsule away now, whatever it is showing.
    func dismiss() {
        viewModel.dismiss()
    }

    /// Pre-creates the panel so the first dictation of the session does not pay
    /// for the window, its backing store and its blur material mid-animation -
    /// the same warm-up `IndicatorWindowManager` does for the card.
    func warmUp() {
        guard Self.isEnabled, panel == nil else { return }
        ensurePanel()
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFront(nil)
        DispatchQueue.main.async {
            panel.orderOut(nil)
        }
    }

    // MARK: - The panel

    private func hidePanel() {
        AudioRecorder.shared.setLevelMonitoring(enabled: false)
        sessionCancellables.removeAll()

        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A new dictation may have started during the fade; ordering the
            // panel out then would take that fresh capsule off the screen.
            guard let self, self.viewModel.state == .idle else { return }
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel == nil {
            let created = CapsuleHUDPanel(
                contentRect: NSRect(origin: .zero, size: CapsuleHUDView.windowSize),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.level = .floating
            // Over every desktop and alongside full-screen apps: dictation is
            // started from whatever the user is doing, not from this app.
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.backgroundColor = .clear
            created.isOpaque = false
            // The pill draws its own shadow, inside the window. A window shadow
            // would be drawn around the whole transparent panel instead.
            created.hasShadow = false
            created.hidesOnDeactivate = false
            created.ignoresMouseEvents = !Self.acceptsMouseEvents(in: viewModel.state)
            panel = created
        }

        guard let panel else { return }
        if let hostingView = panel.contentView as? NSHostingView<CapsuleHUDView> {
            hostingView.rootView = CapsuleHUDView(viewModel: viewModel)
        } else {
            let hostingView = NSHostingView(rootView: CapsuleHUDView(viewModel: viewModel))
            // SwiftUI's ideal size must never drive this window: a hosting view
            // left to size itself shrinks the panel to the pill, and the window
            // bounds then clip the pill's shadow.
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            panel.contentView = hostingView
        }
        panel.setContentSize(CapsuleHUDView.windowSize)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Which screen the capsule belongs on: the one containing the caret, else the
    /// one with input focus. `NSScreen.main` is not an option - for a background
    /// app it degenerates to the primary screen.
    static func targetScreen(nearPoint point: NSPoint?) -> NSScreen? {
        point.flatMap { FocusUtils.screenContaining(point: $0) }
            ?? FocusUtils.getFocusedWindowScreen()
            ?? NSScreen.screens.first
    }

    /// Top-centre of the screen's usable area, in the window coordinates AppKit
    /// wants: the pill is centred inside a taller panel (margins for its shadow),
    /// so it is the pill that has to land `topMargin` below the top, not the
    /// window.
    ///
    /// Takes the two rectangles rather than the `NSScreen` they came from, so the
    /// arithmetic - which is the part that goes wrong, and did - can be asserted
    /// against a screen the test machine does not have.
    static func origin(visibleFrame visible: CGRect, screenFrame: CGRect, windowSize: CGSize) -> NSPoint {
        let pillTop = visible.maxY - topMargin
        let pillTopInset = (windowSize.height - CapsuleHUDView.capsuleHeight) / 2

        var x = visible.midX - windowSize.width / 2
        // Not clamped from above: the panel's top margin is transparent and is
        // *meant* to sit over the menu bar strip. Clamping the window into the
        // visible frame would push the pill itself 28 pt further down than the
        // margin it was given.
        let y = max(screenFrame.minY, pillTop + pillTopInset - windowSize.height)

        x = max(visible.minX, min(x, visible.maxX - windowSize.width))
        return NSPoint(x: x, y: y)
    }
}
