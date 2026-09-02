import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the Model pane's bilingual hint and reads it back, because the whole
/// point of a hint is that a user's eye lands on it and can read it.
///
/// The same tactic and the same reason as `EngineShortcutHintRenderTests`: a
/// string test proves the sentence exists, not that it survived into a row of the
/// right width, wrapped rather than truncated, and legible. Renders go to
/// `/tmp/EchoForgeBilingualHintRenders/` for a human to open.
@MainActor
final class BilingualEngineHintRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeBilingualHintRenders", isDirectory: true)

    /// The width the row sits at inside the Model pane, so what is drawn is the
    /// shape the user gets rather than one that happens to fit.
    private static let rowWidth: CGFloat = 520

    /// The engine name and the reason are both load-bearing, and the reason is
    /// the longer of the two - so it is the half most likely to be clipped by a
    /// row that has stopped growing with its text.
    func testItDrawsTheEngineNameAndWhyTheOthersAreNotTheAnswer() throws {
        try assertRenders(
            named: "bilingual-hint",
            showing: ["Mixed English and Chinese", "SenseVoice", "Whisper", "Parakeet", "Paraformer"]
        )
    }

    // MARK: - Rendering

    private func assertRenders(
        named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let row = BilingualEngineHintRow()
            .frame(width: Self.rowWidth)
            .background(Color(white: 0.95))
            .environment(\.colorScheme, .light)

        // Measured before the sizing is frozen: the row's height is whatever its
        // two sentences wrap to at this width, which is the thing being checked.
        let hosting = NSHostingView(rootView: row)
        let height = hosting.fittingSize.height
        XCTAssertGreaterThan(height, 0, "the hint drew nothing", file: file, line: line)
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: Self.rowWidth, height: height)

        // Never ordered front: no test may put a window on a developer's screen
        // or take their focus.
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

    /// OCR is trusted for glyphs, not for spacing - the same allowance the other
    /// render tests make.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
