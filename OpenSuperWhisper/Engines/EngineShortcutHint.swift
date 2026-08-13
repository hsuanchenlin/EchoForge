import Foundation

/// What the Models pane says about the engine shortcut.
///
/// The pane where someone changes engine is the one place they are guaranteed to
/// look, and until now it was the only engine surface that never mentioned the
/// shortcut that exists to replace it: ⌥M was named in Settings → Shortcuts, in the
/// release notes and in `docs/engine-shortcut.md`, none of which is where a user
/// stands when they realise they are on the wrong engine. A shortcut nobody finds
/// is a shortcut nobody has.
///
/// The wording is here rather than inline in the view so it can be asserted, the
/// same division `EngineSwitchMessage` makes for the overlay. Two rules carry it:
///
/// - **It shows the binding that is actually in force**, never the literal ⌥M. A
///   user who has moved the shortcut is the user most likely to read this line, and
///   a hint naming a key that does nothing is worse than no hint.
/// - **It only ever reads.** Nothing on this path writes a shortcut, so a pane that
///   is merely opened cannot undo a deliberate choice - including the choice to
///   have no shortcut at all, which is a setting rather than a mistake and is
///   described rather than corrected. `EngineShortcutHintTests` scans for the
///   write.
enum EngineShortcutHint {

    /// The line shown under the engine picker.
    ///
    /// - Parameter shortcut: how the bound shortcut reads - "⌥M" - or `nil` when
    ///   the user has cleared it.
    static func text(shortcut: String?) -> String {
        guard let shortcut, !shortcut.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "No shortcut is set for switching engine. Assign one in the Shortcuts tab to "
                + "change engine from any app, without opening Settings."
        }
        return "Press \(shortcut) in any app to switch to the next ready engine. It names the new "
            + "engine on screen, and during a dictation it waits until that dictation is done. "
            + "Change the key in the Shortcuts tab."
    }
}
