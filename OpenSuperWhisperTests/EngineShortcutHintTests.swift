import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper

/// What the Models pane tells a user about the engine shortcut.
///
/// Asserted against the pure wording rather than against the live binding: the
/// shortcut store is `UserDefaults.standard` and not the redirectable
/// `PreferenceStore.defaults`, so a test that wrote one would be writing into the
/// developer's own settings and racing the other host processes the suite runs in.
@MainActor
final class EngineShortcutHintTests: XCTestCase {

    /// The hint names the key that is actually bound. The literal ⌥M in the copy
    /// would be wrong for exactly the user most likely to read it - the one who
    /// moved the shortcut.
    func testItNamesTheBoundShortcut() {
        let text = EngineShortcutHint.text(shortcut: "⌃⌥E")

        XCTAssertTrue(text.contains("⌃⌥E"), text)
        XCTAssertFalse(text.contains("⌥M"), "the default is hard-coded into the hint: \(text)")
    }

    /// The default install's hint, spelled from the default binding rather than
    /// from a second copy of it.
    func testTheDefaultBindingReadsAsOptionM() throws {
        let `default` = try XCTUnwrap(KeyboardShortcuts.Name.cycleEngine.defaultShortcut)

        XCTAssertTrue(
            EngineShortcutHint.text(shortcut: `default`.description).contains(`default`.description)
        )
    }

    /// Having no shortcut is a choice, not a fault: the hint says how to get one
    /// back and nothing offers to restore it.
    func testItSaysSoWhenNoShortcutIsSet() {
        let text = EngineShortcutHint.text(shortcut: nil)

        XCTAssertTrue(text.lowercased().contains("no shortcut"), text)
        XCTAssertTrue(text.contains("Shortcuts tab"), "it has to say where to set one: \(text)")
    }

    /// An empty string is the same state as none - a binding that reads as nothing
    /// would otherwise produce "Press  in any app".
    func testAnEmptyBindingIsTreatedAsNoShortcut() {
        XCTAssertEqual(EngineShortcutHint.text(shortcut: " "), EngineShortcutHint.text(shortcut: nil))
    }

    /// The two things a user must be able to act on: that a press changes engine
    /// from anywhere, and that a press during a dictation waits rather than
    /// cutting into it.
    func testItSaysWhatAPressDoesAndWhatItDoesMidDictation() {
        let text = EngineShortcutHint.text(shortcut: "⌥M")

        XCTAssertTrue(text.contains("next ready engine"), text)
        XCTAssertTrue(text.lowercased().contains("dictation"), text)
    }

    /// A source scan, because the failure guarded against is one added line. The
    /// hint exists to describe a binding; a pane that repaired or re-defaulted one
    /// on its way past would take away a shortcut the user cleared on purpose - or
    /// silently move one they had set.
    func testNothingOnTheHintPathWritesAShortcut() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")

        let writes = ["setShortcut(", "reset(", "removeShortcut("]
        for file in ["Engines/EngineShortcutHint.swift", "Engines/EngineShortcutHintView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for write in writes {
                XCTAssertFalse(
                    text.contains(write),
                    "\(file) calls \(write) - the hint reads the binding and never changes it"
                )
            }
        }
    }
}
