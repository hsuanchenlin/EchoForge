import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the Models pane's shortcut hint and reads it back, because the whole
/// point of the hint is that a user's eye lands on it.
///
/// The same tactic as `EngineSwitchHUDRenderTests` and for a related reason: a
/// string test proves the sentence exists, not that it survived into a row that is
/// the right width, wraps rather than truncates, and can be read. Renders go to
/// `/tmp/EchoForgeEngineSwitchRenders/` beside the overlay's, for a human to open.
@MainActor
final class EngineShortcutHintRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeEngineSwitchRenders", isDirectory: true)

    /// The pane width the hint sits in, so what is rendered is the shape the user
    /// gets rather than one that happens to fit.
    private static let rowWidth: CGFloat = 520

    func testItDrawsTheBoundShortcutAndWhatAPressDoes() throws {
        try assertRenders(
            shortcut: "⌥M",
            named: "hint-bound",
            showing: ["in any app", "next ready engine"]
        )
    }

    /// The state a user reaches by clearing the recorder, which is exactly when a
    /// hint that still said "press ⌥M" would be a lie.
    func testItDrawsTheNoShortcutState() throws {
        try assertRenders(
            shortcut: nil,
            named: "hint-unassigned",
            showing: ["No shortcut is set", "Shortcuts tab"]
        )
    }

    // MARK: - Rendering

    private func assertRenders(
        shortcut: String?, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let row = EngineShortcutHintRow(shortcut: shortcut)
            .frame(width: Self.rowWidth)
            .background(Color(white: 0.95))
            .environment(\.colorScheme, .light)

        // Measured before the sizing is frozen: the row's height is whatever its
        // sentence wraps to at this width, which is the thing being checked. A
        // hosting view with `sizingOptions` already cleared reports nothing to
        // measure.
        let hosting = NSHostingView(rootView: row)
        let height = hosting.fittingSize.height
        XCTAssertGreaterThan(height, 0, "the hint drew nothing", file: file, line: line)
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: Self.rowWidth, height: height)

        // Never ordered front, the same as the overlay's renders: no test may put a
        // window on a developer's screen or take their focus.
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            "no bitmap to draw \(name) into", file: file, line: line)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, "no image behind \(name)", file: file, line: line)

        try write(image, named: name)

        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    private func write(_ image: CGImage, named name: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// OCR is trusted for glyphs, not for spacing - the same allowance the
    /// overlay's render tests make.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
