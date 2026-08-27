import AppKit
import SwiftUI

/// The picker's window.
///
/// Like the Ask panel and unlike every other HUD in this app, it **takes focus**
/// - and for the same reason: a panel the user is meant to type into and arrow
/// through cannot receive a keystroke otherwise. It is also why the picker is a
/// switch (`youTubeChannelPickerEnabled`): it is the one part of this feature
/// that appears in front of whatever somebody was doing.
///
/// Nothing is inserted anywhere by this panel, so unlike the Ask panel it holds
/// no insertion target and captures no frontmost application. What it produces
/// is one channel from a fixed list, or nothing.
private final class YouTubeChannelPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Puts the channel picker on screen and waits for the user.
///
/// The whole of what it decides is in `YouTubeChannelPickerViewModel`; this is
/// the half that cannot exist without a window server - the panel, the focus,
/// and the key events.
@MainActor
final class YouTubeChannelPickerWindowController {
    static let shared = YouTubeChannelPickerWindowController()

    static let fadeDuration: TimeInterval = 0.12

    /// How far below the top of the usable screen the card sits. Lower than the
    /// capsule so a picker never covers the overlay that reported the dictation
    /// which raised it.
    static let topMargin: CGFloat = 140

    private var panel: NSPanel?
    private var viewModel: YouTubeChannelPickerViewModel?
    private var keyMonitor: Any?
    /// The application that was frontmost when the picker opened, so closing it
    /// hands focus back rather than leaving the user's next keystrokes nowhere.
    private var previousApplication: NSRunningApplication?
    /// Which presentation the pending fade-out belongs to. A `present` can land
    /// inside a `dismiss`'s fade - a second command press while a picker is up
    /// is exactly that - and the stale completion must not order out the panel
    /// the newer presentation has just re-shown.
    private var presentationGeneration = 0

    private init() {}

    /// Shows the picker and resolves when the user has answered it.
    ///
    /// One presentation at a time: a second call while a picker is up cancels
    /// the first, because two panels asking "which channel did you mean" about
    /// two different utterances is a question nobody can answer.
    func choose(_ request: YouTubeChannelPickerRequest) async -> YouTubeChannel? {
        // The hand-back target is read *before* a picker already up is
        // cancelled, and kept across the replacement: by the time a second
        // picker opens this app is the frontmost one, and capturing then would
        // aim the eventual hand-back at Kongweh itself.
        let handBack = previousApplication
        if viewModel != nil { finish(nil) }

        let model = YouTubeChannelPickerViewModel(request: request)
        viewModel = model
        previousApplication = handBack ?? NSWorkspace.shared.frontmostApplication
        present(model)

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            model.onFinish = { [weak self] channel in
                // `finish` is reachable from the view, from the key monitor and
                // from a second presentation, and the continuation may be
                // resumed exactly once.
                guard !hasResumed else { return }
                hasResumed = true
                self?.dismiss()
                continuation.resume(returning: channel)
            }
        }
    }

    /// Ends the presentation from outside the panel - a second command arriving,
    /// or the app shutting down.
    func finish(_ channel: YouTubeChannel?) {
        guard let viewModel else { return }
        guard let channel else { return viewModel.cancel() }
        viewModel.choose(channel)
    }

    // MARK: - The window

    private func present(_ model: YouTubeChannelPickerViewModel) {
        presentationGeneration += 1
        let created = panel ?? makePanel()
        panel = created

        if let hostingView = created.contentView as? NSHostingView<YouTubeChannelPickerView> {
            hostingView.rootView = YouTubeChannelPickerView(viewModel: model)
        } else {
            let hostingView = NSHostingView(rootView: YouTubeChannelPickerView(viewModel: model))
            // SwiftUI's ideal size must never drive this window: a hosting view
            // left to size itself shrinks the panel to the card and the window
            // bounds then clip the card's shadow.
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            created.contentView = hostingView
        }
        // Sized to how many channels this user has - see `YouTubeChannelPickerView`
        // - so a list of two does not arrive in a card built for eight.
        let windowSize = YouTubeChannelPickerView.windowSize(
            rowCount: model.request.suggestions.count)
        created.setContentSize(windowSize)
        created.contentView?.layoutSubtreeIfNeeded()

        if let screen = CapsuleHUDWindowController.targetScreen(nearPoint: nil) {
            created.setFrameOrigin(
                Self.origin(
                    visibleFrame: screen.visibleFrame,
                    windowSize: windowSize,
                    cardHeight: YouTubeChannelPickerView.cardSize(
                        rowCount: model.request.suggestions.count).height
                )
            )
        }

        // Keyboard input goes to the active application, and this one spends its
        // life in the background: without this the filter field never receives a
        // character and the arrow keys reach nothing.
        //
        // `ignoringOtherApps` is the measured half. macOS grants a background
        // process the right to activate only just after the user has given it
        // attention, and the plain `activate()` the Ask panel uses is refused
        // once that has lapsed - which is exactly this panel's situation, since
        // it opens *after* a recording and a transcription rather than on the
        // key press. Measured on macOS 26: with `activate()` the card appeared
        // over the frontmost app, never became key, and every keystroke went to
        // that app instead. Forcing is right here for the same reason it is
        // tolerable: the panel exists only because the user just spoke a command
        // into a key of their own, and it is the switch
        // `youTubeChannelPickerEnabled` turns off.
        NSApplication.shared.activate(ignoringOtherApps: true)
        created.alphaValue = 0
        created.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            created.animator().alphaValue = 1
        }

        installKeyMonitor(for: model)
    }

    private func makePanel() -> NSPanel {
        let created = YouTubeChannelPickerPanel(
            contentRect: NSRect(
                origin: .zero, size: YouTubeChannelPickerView.windowSize(rowCount: 1)),
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
        return created
    }

    private func dismiss() {
        removeKeyMonitor()
        viewModel = nil
        let previous = previousApplication
        previousApplication = nil
        guard let panel, panel.isVisible else { return }
        // Opening the panel took keyboard focus, so closing it hands focus back
        // - the same hand-back the Ask panel makes - or the user's next
        // keystrokes go nowhere until they click. Only while this app still
        // holds focus: if they have already clicked into another app, yanking it
        // back from there would be worse than leaving it.
        if NSApplication.shared.isActive { previous?.activate() }
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

    // MARK: - Keys

    /// Arrow keys, Return and Escape, taken before the filter field sees them.
    ///
    /// A local monitor rather than `onKeyPress` or a first responder chain,
    /// because the focus is deliberately in a text field: AppKit's field editor
    /// answers Up and Down itself by moving the caret to the ends of the line,
    /// so a list that read them from the responder chain would never receive
    /// one. Every other key falls through untouched, which is what leaves
    /// type-to-filter working.
    private func installKeyMonitor(for model: YouTubeChannelPickerViewModel) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak model] event in
            guard let self, let model, self.panel?.isKeyWindow == true else { return event }
            return Self.handle(event, with: model, isComposing: self.isComposing) ? nil : event
        }
    }

    /// Whether an input method is part-way through composing a word in the
    /// filter field.
    ///
    /// This app's own users type Chinese, so it is not an edge case: with a
    /// Zhuyin or Pinyin source active, the letters typed into the field are
    /// **marked text** the input method still owns, and Return, Escape and the
    /// arrow keys belong to *it* until the word is committed. A picker that took
    /// them first would make Return finish the command on a half-typed word and
    /// Escape close the panel instead of the candidate list.
    private var isComposing: Bool {
        guard let editor = panel?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    /// Whether this key belonged to the picker. Separated from the monitor so
    /// the mapping itself is a pure function of a key code and two flags.
    ///
    /// - Returns: true when the event was consumed and must not reach the field.
    static func handle(
        _ event: NSEvent, with model: YouTubeChannelPickerViewModel, isComposing: Bool = false
    ) -> Bool {
        // While an input method is composing, every key here is its key.
        guard !isComposing else { return false }
        // A modifier means the user is doing something else - ⌘A in the filter
        // field, or a system shortcut - and the picker must not swallow it.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.subtracting([.function, .numericPad, .capsLock]).isEmpty else {
            return false
        }
        switch KeyCode(rawValue: event.keyCode) {
        case .downArrow:
            model.highlightNext()
            return true
        case .upArrow:
            model.highlightPrevious()
            return true
        case .return, .keypadEnter:
            model.commit()
            return true
        case .escape:
            model.cancel()
            return true
        case nil:
            return false
        }
    }

    /// The four keys this panel answers to, named rather than spelled as
    /// numbers at the point of use.
    enum KeyCode: UInt16 {
        case `return` = 36
        case keypadEnter = 76
        case escape = 53
        case upArrow = 126
        case downArrow = 125
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Top-centre of the screen's usable area, in the window coordinates AppKit
    /// wants.
    ///
    /// Takes the rectangle rather than the `NSScreen` it came from so the
    /// arithmetic can be asserted against a screen the test machine does not
    /// have - the same reason `AskPanelWindowController.origin` does.
    static func origin(
        visibleFrame visible: CGRect, windowSize: CGSize, cardHeight: CGFloat
    ) -> NSPoint {
        let cardTop = visible.maxY - topMargin
        let cardTopInset = (windowSize.height - cardHeight) / 2
        var x = visible.midX - windowSize.width / 2
        x = max(visible.minX, min(x, visible.maxX - windowSize.width))
        let y = max(visible.minY, cardTop + cardTopInset - windowSize.height)
        return NSPoint(x: x, y: y)
    }
}

/// The production chooser: the real panel, on the real screen.
///
/// A separate type from the controller so `YouTubeCommandRunner` depends on the
/// protocol and nothing else - the same shape `ChromeBrowserOpener` takes beside
/// `BrowserOpening`.
struct YouTubeChannelPickerPresenter: YouTubeChannelChoosing {
    @MainActor
    func chooseChannel(_ request: YouTubeChannelPickerRequest) async -> YouTubeChannel? {
        await YouTubeChannelPickerWindowController.shared.choose(request)
    }
}
