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

    /// A hotkey-settings change re-runs `setupRecordingTrigger`, which restarts
    /// the monitors and re-enables the dictation shortcut. While the pause is
    /// up that would unpause in everything but name: the menu and the icon
    /// would still say paused while the app swallowed the keystroke again.
    ///
    /// `ShortcutManager` cannot be instantiated in a test - its init starts
    /// real event monitors - so the guard is scanned for instead. Deleting it
    /// fails here rather than shipping a pause that Settings can silently undo.
    func testAHotkeySettingsChangeDefersToThePause() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/ShortcutManager.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("Sources are not beside the tests: \(source.path)")
        }

        guard let start = text.range(of: "func hotkeySettingsChanged"),
              let end = text.range(of: "\n    }", range: start.upperBound..<text.endIndex)
        else {
            XCTFail("hotkeySettingsChanged is gone, and this scan needs re-pointing")
            return
        }

        XCTAssertTrue(
            text[start.upperBound..<end.lowerBound].contains("ShortcutPause.shared.isPaused"),
            "hotkeySettingsChanged re-arms the triggers without asking the pause first")
    }
}
