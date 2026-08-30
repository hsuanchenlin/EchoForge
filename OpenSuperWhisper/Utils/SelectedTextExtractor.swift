import Cocoa

/// Where the text a voice edit will rewrite came from.
///
/// Selection and clipboard are two different things to tell the user, and the
/// HUD names them rather than collapsing them: "Editing Clipboard..." is how
/// somebody learns that nothing was highlighted, which is the one case they
/// can fix on the next press.
enum SelectedTextSource: String, Equatable, Sendable {
    case selection
    case clipboard

    /// The capsule chip. One word: the pill has no room for the gerund.
    var capsuleLabel: String {
        switch self {
        case .selection: return "Selection"
        case .clipboard: return "Clipboard"
        }
    }
}

struct SelectionEditTarget: @unchecked Sendable, Equatable {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement
    let focusedWindow: AXUIElement?
    let selectedRange: CFRange?

    static func == (lhs: SelectionEditTarget, rhs: SelectionEditTarget) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && CFEqual(lhs.focusedElement, rhs.focusedElement)
            && Self.equal(lhs.focusedWindow, rhs.focusedWindow)
            && Self.equal(lhs.selectedRange, rhs.selectedRange)
    }

    private static func equal(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }

    private static func equal(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.location == rhs.location && lhs.length == rhs.length
        default: return false
        }
    }
}

/// The text a voice-edit session will rewrite, and where it was taken from.
struct SelectedTextCapture: Equatable, Sendable {
    let text: String
    let source: SelectedTextSource
    let target: SelectionEditTarget?

    init(
        text: String, source: SelectedTextSource, target: SelectionEditTarget? = nil
    ) {
        self.text = text
        self.source = source
        self.target = target
    }

    /// The card and the capsule while the user is speaking the instruction.
    var hudStatusText: String {
        switch source {
        case .selection: return "Editing Selection..."
        case .clipboard: return "Editing Clipboard..."
        }
    }

    /// The capsule chip. One word: the pill has no room for the gerund.
    var capsuleLabel: String { source.capsuleLabel }
}

/// Captures the text a voice edit will rewrite.
///
/// Three sources, in this order, and the first one that yields usable text
/// wins:
///
/// 1. Accessibility `kAXSelectedTextAttribute` on the focused element.
/// 2. A simulated ⌘C, with the pasteboard restored afterwards so a copy used
///    only as a probe cannot clobber what the user had on the clipboard.
/// 3. The clipboard as it already stood, when nothing was selected.
///
/// The three collaborators are parameters so the cascade is testable without a
/// focused app, a pasteboard or a posted key event. Production passes the real
/// ones. `docs/selection-edit.md` is the whole story.
enum SelectedTextExtractor {

    /// Walks the three sources and returns the first usable capture, or `nil`
    /// when there is nothing to edit.
    static func capture(
        accessibilityText: () -> String? = { FocusUtils.selectedText() },
        copiedSelection: () -> String? = { ClipboardUtil.copySelectedText() },
        clipboardText: () -> String? = { ClipboardUtil.currentString() },
        target: () -> SelectionEditTarget? = { FocusUtils.selectionEditTarget() }
    ) -> SelectedTextCapture? {
        let selectionTarget = target()
        if let text = usable(accessibilityText()) {
            return SelectedTextCapture(
                text: text, source: .selection, target: selectionTarget)
        }
        if let text = usable(copiedSelection()) {
            return SelectedTextCapture(
                text: text, source: .selection, target: selectionTarget)
        }
        if let text = usable(clipboardText()) {
            return SelectedTextCapture(
                text: text, source: .clipboard, target: selectionTarget)
        }
        return nil
    }

    /// Non-whitespace text, or `nil`. Whitespace-only is treated as empty
    /// rather than as something to send to the model: a highlighted space is
    /// not a document.
    static func usable(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
