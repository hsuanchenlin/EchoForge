import XCTest
@testable import OpenSuperWhisper

/// The three-source cascade a voice-edit press walks, without a focused app or
/// a posted ⌘C.
final class SelectedTextExtractorTests: XCTestCase {

    func testAccessibilitySelectionWinsOverCopyAndClipboard() {
        let capture = SelectedTextExtractor.capture(
            accessibilityText: { "highlighted in Xcode" },
            copiedSelection: { "copied by Cmd+C" },
            clipboardText: { "old clipboard" }
        )

        XCTAssertEqual(
            capture,
            SelectedTextCapture(text: "highlighted in Xcode", source: .selection)
        )
        XCTAssertEqual(capture?.hudStatusText, "Editing Selection...")
    }

    func testSimulatedCopyIsTheFallbackWhenAccessibilityHasNothing() {
        let capture = SelectedTextExtractor.capture(
            accessibilityText: { nil },
            copiedSelection: { "copied from Slack" },
            clipboardText: { "old clipboard" }
        )

        XCTAssertEqual(
            capture,
            SelectedTextCapture(text: "copied from Slack", source: .selection)
        )
    }

    func testClipboardIsUsedWhenNothingIsSelected() {
        let capture = SelectedTextExtractor.capture(
            accessibilityText: { "   " },
            copiedSelection: { nil },
            clipboardText: { "text I copied earlier" }
        )

        XCTAssertEqual(
            capture,
            SelectedTextCapture(text: "text I copied earlier", source: .clipboard)
        )
        XCTAssertEqual(capture?.hudStatusText, "Editing Clipboard...")
        XCTAssertEqual(capture?.capsuleLabel, "Clipboard")
    }

    func testCaptureKeepsTheApplicationThatOwnedTheSelection() {
        let capture = SelectedTextExtractor.capture(
            accessibilityText: { "selected" },
            copiedSelection: { nil },
            clipboardText: { nil },
            targetProcessIdentifier: { 42 }
        )

        XCTAssertEqual(capture?.targetProcessIdentifier, 42)
    }

    func testWhitespaceOnlyIsTreatedAsEmpty() {
        XCTAssertNil(
            SelectedTextExtractor.capture(
                accessibilityText: { " \n\t " },
                copiedSelection: { "" },
                clipboardText: { nil }
            )
        )
    }

    func testNothingToEditWhenEverySourceIsEmpty() {
        XCTAssertNil(
            SelectedTextExtractor.capture(
                accessibilityText: { nil },
                copiedSelection: { nil },
                clipboardText: { nil }
            )
        )
    }
}

/// The ⌘C probe restores the pasteboard, so using copy as a fallback cannot
/// clobber what the user had.
final class ClipboardUtilCopySelectedTextTests: XCTestCase {

    func testSuccessfulCopyRestoresAnOriginallyEmptyPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let copied = ClipboardUtil.copySelectedText(
            pasteboard: pasteboard,
            copy: {
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString("highlighted", forType: .string)
            },
            wait: 0
        )

        XCTAssertEqual(copied, "highlighted")
        XCTAssertTrue(pasteboard.types?.isEmpty ?? true)
        XCTAssertNil(pasteboard.string(forType: .string))
        pasteboard.releaseGlobally()
    }

    func testASuccessfulCopyReturnsTheNewStringAndRestoresTheOriginal() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("original clipboard", forType: .string)

        let copied = ClipboardUtil.copySelectedText(
            pasteboard: pasteboard,
            copy: {
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString("highlighted", forType: .string)
            },
            wait: 0
        )

        XCTAssertEqual(copied, "highlighted")
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
        pasteboard.releaseGlobally()
    }

    func testNoChangeMeansNothingWasSelected() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("original clipboard", forType: .string)

        let copied = ClipboardUtil.copySelectedText(
            pasteboard: pasteboard,
            copy: { },
            wait: 0
        )

        XCTAssertNil(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
        pasteboard.releaseGlobally()
    }

    func testPasteTextIsTheNamedVoiceEditPaste() {
        // `pasteText` is the greppable name the voice-edit path uses. It must
        // keep being `insertText`, which restores the clipboard after the paste.
        XCTAssertTrue(
            sourceMentionsPasteTextAsInsertText(),
            "ClipboardUtil.pasteText must call insertText so a voice edit restores the clipboard"
        )
    }

    private func sourceMentionsPasteTextAsInsertText() -> Bool {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Utils/ClipboardUtil.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pasteText = text.range(of: "static func pasteText")
        else { return false }
        let after = text[pasteText.upperBound...]
        guard let body = after.range(of: "static func") else { return false }
        return after[..<body.lowerBound].contains("insertText(text)")
    }
}
