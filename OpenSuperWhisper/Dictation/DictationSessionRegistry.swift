import Foundation

/// The dictation that is running, if one is.
///
/// One place to ask, because more than one key can start a dictation and any of
/// them can stop the one in flight: ⌥`, ⌥Y and ⌥E, the modifier-only and
/// mouse-button triggers, the menu bar item, and Esc. They used to ask
/// `ShortcutManager`'s own copy of "the view model that is up", which made the
/// question about an overlay rather than about a dictation - and left the
/// answer somewhere the rest of the app could not see it.
///
/// It holds the session and nothing else: it never starts, stops or cancels
/// one. The microphone itself is still owned by `RecordingSessionClaim`, which
/// is the rule that actually prevents two recordings; this only answers "is
/// there one, and which".
///
/// Deliberately not actor-isolated, for the same reason `ShortcutManager` is
/// not: the hotkey callbacks that read it are delivered on the main thread by
/// Carbon and by the two monitors, and a hop would put "is one already
/// running?" a runloop turn behind the press that asks it - the exact window
/// `RecordingSessionClaim` exists to close.
final class DictationSessionRegistry {
    static let shared = DictationSessionRegistry()

    /// The dictation in flight, or nil when nothing is running.
    private(set) var current: DictationSession?

    init() {}

    /// Records that `session` is now the dictation in flight.
    func adopt(_ session: DictationSession) {
        current = session
    }

    /// Forgets whatever is in flight.
    ///
    /// Unconditional on purpose, matching what it replaced: the callers that
    /// clear it are the ones that just stopped or cancelled the session, and
    /// the notification that a dictation's overlay has gone.
    func clear() {
        current = nil
    }
}
