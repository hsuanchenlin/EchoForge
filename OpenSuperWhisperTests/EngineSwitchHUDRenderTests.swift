import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Renders the engine overlay and reads its pixels back, because the overlay is
/// the only thing this shortcut shows.
///
/// It cannot be screenshotted from outside: it lives for two seconds, over
/// whatever app the user is in, and driving the real thing needs a machine with a
/// display awake and the grants a checkout machine does not have. So the pill is
/// drawn in-process, the same way `UpdateCardRenderTests` draws the update card
/// and for the same reasons - `NSHostingView` in an offscreen, never-shown window,
/// rasterised with `cacheDisplay`, which needs no permission and flashes nothing on
/// screen. Every render is written to `/tmp/EchoForgeEngineSwitchRenders/<name>.png`
/// for a human to open.
///
/// Two things are asserted that no string-level test can reach. The words are read
/// back with OCR, so a pill whose message never made it into the pixels fails here
/// instead of shipping as an empty capsule. And the pill's drawn width is checked
/// against the window that has to contain it, because the message is the one part
/// of this overlay whose length is not under the app's control - an engine name and
/// a provider's model name, side by side - and a pill wider than its panel is a
/// pill with its right end and its shadow cut off.
@MainActor
final class EngineSwitchHUDRenderTests: XCTestCase {

    /// A fixed path rather than a per-run temporary directory, so the comment
    /// above can say where to look and stay true.
    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeEngineSwitchRenders", isDirectory: true)

    func testItDrawsTheEngineItSwitchedTo() throws {
        try assertRenders(
            EngineSwitchMessage.announcement(
                for: .switched(.sensevoice), whisperModelPath: nil, cloudModel: "whisper-1"
            ),
            named: "switched",
            showing: ["Engine", EngineCatalog.entry(for: .sensevoice).displayName]
        )
    }

    /// The cloud engine names the provider's model, which is the case where the
    /// message is longest and least under the app's control.
    func testItDrawsTheCloudModelName() throws {
        try assertRenders(
            EngineSwitchMessage.announcement(
                for: .switched(.cloud), whisperModelPath: nil, cloudModel: "gpt-4o-transcribe"
            ),
            named: "cloud",
            showing: ["Cloud", "gpt-4o-transcribe"]
        )
    }

    /// The longest thing the overlay ever says: the engine with the longest name,
    /// plus the sentence that says the switch waits for this dictation.
    func testItDrawsTheDeferredMessageWithoutOutgrowingItsPanel() throws {
        try assertRenders(
            EngineSwitchMessage.announcement(
                for: .deferred(.paraformer), whisperModelPath: nil, cloudModel: "whisper-1"
            ),
            named: "deferred",
            showing: ["after this dictation"]
        )
    }

    func testItDrawsTheNothingToSwitchToMessage() throws {
        try assertRenders(
            EngineSwitchMessage.announcement(
                for: .onlyOneEngine(.whisper),
                whisperModelPath: "/models/ggml-large-v3-turbo.bin",
                cloudModel: ""
            ),
            named: "only-one",
            showing: ["large-v3-turbo", "only engine ready"]
        )
    }

    // MARK: - Rendering

    private func assertRenders(
        _ announcement: EngineSwitchAnnouncement, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let viewModel = EngineSwitchHUDViewModel(schedule: { _, _ in })
        viewModel.show(announcement)

        let size = EngineSwitchHUDView.windowSize
        // A grey canvas with the light appearance forced: the pill is drawn on
        // `Material.ultraThinMaterial`, which over white is white, and a render
        // nobody can see the capsule in proves less than one they can.
        let pill = EngineSwitchHUDView(viewModel: viewModel)
            .background(Color(white: 0.72))
            .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: pill)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)

        // Never ordered front: `cacheDisplay` draws without the window appearing,
        // so no test flashes a panel or takes focus - which for this overlay would
        // also be the very thing it is designed never to do.
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

        let scale = window.backingScaleFactor
        XCTAssertEqual(image.width, Int(size.width * scale), "width of \(name)", file: file, line: line)

        let pixels = try XCTUnwrap(
            image.dataProvider?.data as Data?, "no pixel data behind \(name)",
            file: file, line: line)
        let first = pixels.first
        XCTAssertTrue(
            pixels.contains { $0 != first }, "the render of \(name) is a blank canvas",
            file: file, line: line)

        try write(image, named: name)

        // The pill sizes itself to its message (`fixedSize`), so this is the check
        // that the longest message still fits inside the panel that clips it.
        let drawn = hosting.fittingSize
        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, size.width,
            "the pill in \(name) is wider than the panel that contains it", file: file, line: line)
        XCTAssertLessThanOrEqual(
            drawn.width, size.width,
            "the \(name) render wants more room than the panel has", file: file, line: line)

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
        // Model names are not prose: language correction turns
        // "gpt-4o-transcribe" into words.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// OCR is trusted for glyphs, not for spacing - the same allowance
    /// `UpdateCardRenderTests` makes.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
