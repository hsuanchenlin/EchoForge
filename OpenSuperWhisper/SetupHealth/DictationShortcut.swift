import Foundation
import KeyboardShortcuts

/// What actually starts a dictation on this Mac right now.
///
/// The app has three mutually exclusive trigger modes and `ShortcutManager`
/// resolves them in a fixed order - a configured mouse button wins over a
/// modifier key, which wins over the ordinary keyboard shortcut. Three surfaces
/// have to say which one is in force (the main window's hint, Setup Health and
/// the menu bar), and before this type each of them re-derived it from the same
/// three preferences. A hint that names a key the app is no longer listening on
/// is worse than no hint at all, so the resolution lives once, here, as a pure
/// function of the three stored values.
enum DictationTrigger: Equatable {
    /// A mouse button. Highest priority, matching `setupRecordingTrigger`.
    case mouseButton(MouseButton)

    /// A modifier key on its own.
    case modifierKey(ModifierKey)

    /// The ordinary global shortcut, as it reads - "⌥`".
    case keyboardShortcut(String)

    /// Nothing is bound. A setting rather than a mistake, and described rather
    /// than corrected - the same rule `EngineShortcutHint` keeps.
    case none

    /// Resolved the way `ShortcutManager.setupRecordingTrigger` resolves it, so
    /// the two cannot disagree about which mode is live.
    static func resolve(
        mouseButton: MouseButton,
        modifierKey: ModifierKey,
        keyboardShortcut: String?
    ) -> DictationTrigger {
        if mouseButton != .none { return .mouseButton(mouseButton) }
        if modifierKey != .none { return .modifierKey(modifierKey) }
        guard let keyboardShortcut, !keyboardShortcut.isEmpty else { return .none }
        return .keyboardShortcut(keyboardShortcut)
    }

    /// The current one, from preferences and the stored binding.
    @MainActor
    static func current(preferences: AppPreferences = .shared) -> DictationTrigger {
        resolve(
            mouseButton: MouseButton(rawValue: preferences.mouseButtonHotkey) ?? .none,
            modifierKey: ModifierKey(rawValue: preferences.modifierOnlyHotkey) ?? .none,
            keyboardShortcut: KeyboardShortcuts.getShortcut(for: .toggleRecord)?.description
        )
    }

    /// The compact form, for a hint beside other text and for a menu item's
    /// trailing label. Empty when nothing is bound, because a menu item cannot
    /// show a sentence.
    var shortDescription: String {
        switch self {
        case .mouseButton(let button): return button.shortSymbol
        case .modifierKey(let key): return key.shortSymbol
        case .keyboardShortcut(let description): return description
        case .none: return ""
        }
    }

    /// The full form, for a status line that has room to be unambiguous - a
    /// mouse button's symbol alone is not something anybody can read.
    var longDescription: String {
        switch self {
        case .mouseButton(let button): return button.displayName
        case .modifierKey(let key): return key.displayName
        case .keyboardShortcut(let description): return description
        case .none: return "Not set"
        }
    }

    var isBound: Bool { self != .none }
}

/// One of this app's global shortcuts, as a value that can be compared with the
/// others.
struct AppShortcutBinding: Equatable, Identifiable {
    /// What the shortcut does, in the user's words - "Start dictation",
    /// "Ask panel". Not the `KeyboardShortcuts.Name`, which is storage.
    let purpose: String

    /// How the binding reads - "⌥A" - or `nil` when the user has cleared it.
    let keys: String?

    var id: String { purpose }
}

/// Two of this app's own shortcuts bound to the same keys.
struct ShortcutConflict: Equatable, Identifiable {
    let keys: String
    /// The purposes that collide, in the order they were listed.
    let purposes: [String]

    var id: String { keys }

    /// The sentence Setup Health shows.
    var message: String {
        "\(keys) is bound to \(purposes.joined(separator: " and ")). Only one of them will run."
    }
}

/// Which of this app's shortcuts collide with each other.
///
/// Deliberately **only this app's own bindings**. macOS exposes no supported way
/// to enumerate every other application's global hotkeys, and the system's own
/// list is not readable either, so a check that claimed to find "conflicts" in
/// general would be claiming something it cannot know. What it can know for
/// certain is that two of Kongweh's six shortcuts are on the same keys - which
/// is a real state, reachable from the Shortcuts pane in two clicks, and one
/// where exactly one of them silently stops working.
enum ShortcutConflicts {

    /// The collisions in `bindings`, one per set of keys, in the order the keys
    /// first appear. Unbound shortcuts collide with nothing.
    static func conflicts(in bindings: [AppShortcutBinding]) -> [ShortcutConflict] {
        var order: [String] = []
        var purposesByKeys: [String: [String]] = [:]

        for binding in bindings {
            guard let keys = binding.keys, !keys.isEmpty else { continue }
            if purposesByKeys[keys] == nil { order.append(keys) }
            purposesByKeys[keys, default: []].append(binding.purpose)
        }

        return order.compactMap { keys in
            guard let purposes = purposesByKeys[keys], purposes.count > 1 else { return nil }
            return ShortcutConflict(keys: keys, purposes: purposes)
        }
    }

    /// Every global shortcut this app registers, with the words the user knows
    /// it by.
    ///
    /// The dictation entry is the **trigger in force**, not the stored keyboard
    /// shortcut: with a mouse button or a modifier key configured, the keyboard
    /// shortcut is disabled (`ShortcutManager.setupRecordingTrigger`), so
    /// reporting it as a conflict would name a collision that cannot happen.
    @MainActor
    static func current(preferences: AppPreferences = .shared) -> [AppShortcutBinding] {
        let trigger = DictationTrigger.current(preferences: preferences)
        return [
            AppShortcutBinding(
                purpose: "Start dictation", keys: trigger.isBound ? trigger.shortDescription : nil),
            AppShortcutBinding(
                purpose: "Ask panel", keys: KeyboardShortcuts.getShortcut(for: .askPanel)?.description),
            AppShortcutBinding(
                purpose: "Ask about the screen",
                keys: KeyboardShortcuts.getShortcut(for: .askAboutScreen)?.description),
            AppShortcutBinding(
                purpose: "Switch engine",
                keys: KeyboardShortcuts.getShortcut(for: .cycleEngine)?.description),
            AppShortcutBinding(
                purpose: "Open latest video",
                keys: KeyboardShortcuts.getShortcut(for: .youTubeCommand)?.description),
            AppShortcutBinding(
                purpose: "Voice edit",
                keys: KeyboardShortcuts.getShortcut(for: .editSelection)?.description),
        ]
    }
}
