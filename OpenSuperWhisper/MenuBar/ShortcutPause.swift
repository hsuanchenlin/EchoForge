import Combine
import Foundation

/// Whether Kongweh's global keys are listening.
///
/// **Pausing means the keys, and only the keys.** It does not mute the system
/// microphone, change the input device, or touch anything else the user shares
/// with other applications - a dictation app that silently muted the machine
/// would be doing something to a resource it does not own, and the person who
/// pressed it would find out in their next meeting. The menu says so beside the
/// item, and `MenuBarSnapshot.pausedExplanation` is that sentence.
///
/// What it actually does is stand the triggers down: the six global shortcuts are
/// unregistered and the modifier-key and mouse-button monitors are stopped, so
/// while it is paused ⌥` types a backtick again. Gating the handlers instead
/// would leave the app swallowing keystrokes it had promised to stop listening
/// to, which is a different and worse thing to promise.
///
/// **It is not persisted, deliberately.** A paused install that came back paused
/// after a relaunch is an app that looks broken, and the only clue would be one
/// menu-bar icon a user has no reason to look at. Quitting is therefore also the
/// way out of a pause somebody forgot about. The state is visible in the icon and
/// in the menu's first line for as long as it lasts, which is the session.
@MainActor
final class ShortcutPause: ObservableObject {
    static let shared = ShortcutPause()

    @Published private(set) var isPaused = false

    /// Called whenever the state changes, with the new value. `ShortcutManager`
    /// owns the registration and is the only subscriber; this type owns the
    /// answer to "are the keys live" and nothing else.
    var onChange: ((Bool) -> Void)?

    init() {}

    func toggle() { set(!isPaused) }

    func set(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        onChange?(paused)
    }
}
