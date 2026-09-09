import XCTest

@testable import OpenSuperWhisper

/// The menu bar's Pause stands the triggers down; these tests hold the two
/// halves of that promise that can break without any hardware being involved.
@MainActor
final class ShortcutPauseGateTests: XCTestCase {

    func testThePauseBroadcastsOnlyRealChanges() {
        let pause = ShortcutPause()
        var broadcasts: [Bool] = []
        pause.onChange = { broadcasts.append($0) }

        pause.set(true)
        pause.set(true)
        pause.set(false)

        XCTAssertEqual(broadcasts, [true, false])
        XCTAssertFalse(pause.isPaused)
    }

    func testToggleFlipsTheState() {
        let pause = ShortcutPause()
        pause.toggle()
        XCTAssertTrue(pause.isPaused)
        pause.toggle()
        XCTAssertFalse(pause.isPaused)
    }

    /// A binding change re-runs `setupRecordingTrigger`, which restarts the
    /// monitors and re-enables the dictation shortcut. While the pause is up
    /// that would unpause in everything but name: the menu and the icon would
    /// still say paused while the app swallowed the keystroke again.
    ///
    /// `ShortcutManager` cannot be instantiated in a test - its init starts
    /// real event monitors - so the guard is scanned for instead. Deleting it
    /// fails here rather than shipping a pause that Settings can silently undo.
    func testAHotkeySettingsChangeDefersToThePause() throws {
        let text = try shortcutManagerSource()

        XCTAssertTrue(
            gateBody(in: text)?.contains("ShortcutPause.shared.isPaused") == true,
            "the binding-change gate re-arms the triggers without asking the pause first")
        XCTAssertTrue(
            gateBody(in: text)?.contains("applyPause(true)") == true,
            "a binding change while paused must re-assert the pause, not just skip the rebuild")
        XCTAssertTrue(
            handlerBody(named: "func hotkeySettingsChanged", in: text)?.contains("reconfigureTriggersRespectingPause") == true,
            "hotkeySettingsChanged must go through the pause gate")
    }

    /// The Settings Recorders are the second door into the same hole: a rebind
    /// calls `KeyboardShortcuts.register` unconditionally and posts the
    /// package's own `shortcutByNameDidChange`, which no app-level signal
    /// covers. The manager has to observe it and route it through the same
    /// gate, or rebinding a shortcut while paused re-arms it behind the
    /// paused indicator.
    func testARecorderRebindDefersToThePause() throws {
        let text = try shortcutManagerSource()

        XCTAssertTrue(
            text.contains("KeyboardShortcuts_shortcutByNameDidChange"),
            "ShortcutManager must observe KeyboardShortcuts' own binding-change broadcast")
        XCTAssertTrue(
            handlerBody(named: "func shortcutBindingDidChange", in: text)?.contains("reconfigureTriggersRespectingPause") == true,
            "a Recorder rebind must go through the pause gate")
    }

    private func shortcutManagerSource() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/ShortcutManager.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("Sources are not beside the tests: \(source.path)")
        }
        return text
    }

    private func gateBody(in text: String) -> Substring? {
        handlerBody(named: "func reconfigureTriggersRespectingPause", in: text)
    }

    private func handlerBody(named signature: String, in text: String) -> Substring? {
        guard let start = text.range(of: signature),
              let end = text.range(of: "\n    }", range: start.upperBound..<text.endIndex)
        else { return nil }
        return text[start.upperBound..<end.lowerBound]
    }
}
