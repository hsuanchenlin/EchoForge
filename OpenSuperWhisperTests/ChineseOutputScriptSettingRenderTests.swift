import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the Chinese output script control and reads its pixels back.
///
/// A string test cannot reach what matters about this one control. Its two
/// labels are named *in the scripts they select*, so the glyphs are the meaning:
/// a "Traditional" option drawn as 繁体 would be a control contradicting itself
/// while every assertion about its strings still passed. And the row has to fit
/// the Settings sheet, which is the width the whole pane is squeezed into.
///
/// Drawn the same way `EngineSwitchHUDRenderTests` draws the engine pill -
/// `NSHostingView` in an offscreen, never-shown window, rasterised with
/// `cacheDisplay` - so it needs no permission and shows nothing on screen. Every
/// render is written to `/tmp/EchoForgeChineseScriptRenders/<name>.png` for a
/// human to open.
@MainActor
final class ChineseOutputScriptSettingRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeChineseScriptRenders", isDirectory: true)

    /// The room a pane actually has: the sheet, less the padding
    /// `transcriptionSettings` puts around its cards and the card's own.
    private let paneWidth = SettingsSheetLayout.preferredSize.width - 80

    func testItDrawsBothScriptsInTheirOwnScript() throws {
        let render = try render(selecting: .traditional, named: "traditional")

        // 繁 and 體 are Traditional-only; 简 and 体 are Simplified-only. Each
        // label has to be drawn in the script it names, or the control is
        // telling the user the opposite of what it does.
        for glyph in ["繁", "體", "简", "体"] {
            XCTAssertTrue(
                render.text.contains(glyph),
                "the control never drew \(glyph); OCR read: \(render.text)"
            )
        }
        // "simpli", not "simplified": with language correction off, OCR reads the
        // "fi" ligature the system font draws as "ti". The glyphs above are what
        // this test is for; the English words only have to be there.
        XCTAssertTrue(
            normalized(render.text).contains("traditional")
                && normalized(render.text).contains("simpli"),
            "both options must be readable: \(render.text)"
        )
    }

    /// The explanation is the sentence that keeps this from reading as a switch
    /// that changes what the app listens for, so it has to survive to the
    /// pixels rather than being clipped away.
    func testItDrawsTheSentenceThatSaysWhatIsNotAffected() throws {
        let render = try render(selecting: .traditional, named: "traditional")
        let read = normalized(render.text)

        XCTAssertTrue(read.contains("otherlanguages"), render.text)
        XCTAssertTrue(read.contains("history"), render.text)
    }

    /// Nothing here may push the pane wider than the sheet: a Settings pane that
    /// speaks for the sheet is the defect `SettingsTabBarFitTests` exists for.
    func testItFitsTheWidthAPaneIsGiven() throws {
        for script in [ChineseScriptVariant.traditional, .simplified] {
            let hosting = NSHostingView(
                rootView: ChineseOutputScriptSetting(script: .constant(script))
            )
            hosting.sizingOptions = []
            hosting.frame = CGRect(x: 0, y: 0, width: paneWidth, height: 120)
            hosting.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(
                hosting.fittingSize.width, paneWidth,
                "the \(script.rawValue) state wants \(hosting.fittingSize.width) pt of \(paneWidth)"
            )
        }
    }

    /// Both states render, and differ: a segmented control drawn with neither
    /// segment selected would look the same in both and say nothing about which
    /// script the user is getting.
    func testTheSelectedScriptIsVisiblyDifferent() throws {
        let traditional = try render(selecting: .traditional, named: "traditional")
        let simplified = try render(selecting: .simplified, named: "simplified")

        XCTAssertNotEqual(
            traditional.pixels, simplified.pixels,
            "the two selections drew identical pixels, so the selection is not visible"
        )
    }

    // MARK: - Rendering

    private struct Render {
        let text: String
        let pixels: Data
    }

    private func render(
        selecting script: ChineseScriptVariant,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Render {
        let view = ChineseOutputScriptSetting(script: .constant(script))
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: paneWidth, height: 130)

        // Never ordered front: `cacheDisplay` draws without the window ever
        // appearing, so this test flashes nothing and takes no focus.
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

        let pixels = try XCTUnwrap(
            image.dataProvider?.data as Data?, "no pixel data behind \(name)",
            file: file, line: line)
        let first = pixels.first
        XCTAssertTrue(
            pixels.contains { $0 != first }, "the render of \(name) is a blank canvas",
            file: file, line: line)

        try write(image, named: name)

        return Render(text: try recognizedText(in: image), pixels: pixels)
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
        // Both scripts, and no language correction: a corrector that "fixes"
        // 简体 into 簡體 would hide exactly the defect this file looks for.
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
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
