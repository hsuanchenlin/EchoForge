import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the YouTube channels section of Settings and reads its pixels back.
///
/// The same technique - and the same reasons - as `EngineSwitchHUDRenderTests`:
/// `NSHostingView` in an offscreen, never-shown window, rasterised with
/// `cacheDisplay`, which needs no permission and flashes nothing on screen.
/// Renders are written to `/tmp/EchoForgeYouTubeSettingsRenders/<name>.png` for a
/// human to open.
///
/// What it is here to catch is the thing a string-level test cannot: a pane that
/// wants more width than the Settings sheet has. This section carries two of the
/// longest strings in Settings - a channel id is 24 characters and sits beside a
/// list of spoken aliases - and the sheet's width is a single decision shared
/// with every other pane (`SettingsSheetLayout`).
final class YouTubeChannelsSettingsRenderTests: IsolatedPreferencesTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeYouTubeSettingsRenders", isDirectory: true)

    /// The width a pane is offered inside the sheet: 680 pt less the sheet's own
    /// padding and the pane's.
    private static let paneWidth: CGFloat = SettingsSheetLayout.preferredSize.width - 64

    /// Taller than the section draws, so nothing is cut off the render. The
    /// section grew a shortcut sentence and a model-fallback disclosure, both of
    /// which wrap.
    private static let canvasHeight: CGFloat = 760

    @MainActor
    func testTheEmptyStateExplainsWhatTheListIsFor() throws {
        try assertRenders(
            named: "empty",
            // The shortcut sentence is on screen in every state: how the command
            // is invoked is the thing a user is most likely to have wrong, and a
            // pane that only explains it once there are rows explains it too
            // late.
            showing: ["No channels yet", "Chrome", "shortcut"]
        )
    }

    @MainActor
    func testThePaneShowsTheModelFallbackAndItsDisclosure() throws {
        try assertRenders(
            named: "model-fallback",
            showing: ["on-device model", "Off by default"]
        )
    }

    @MainActor
    func testAListedChannelShowsItsIDAndItsSpokenNames() throws {
        try YouTubeChannelStore().replaceAll([
            YouTubeChannel(
                displayName: "Veritasium",
                aliases: ["vera tasium"],
                channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
            ),
            YouTubeChannel(
                displayName: "科技島讀",
                channelID: "UCabcdefghijklmnopqrstuv"
            ),
        ])

        try assertRenders(
            named: "listed",
            // The id has to be readable: it is what the user checks when a
            // command did not open what they expected.
            showing: ["Veritasium", "UCHnyfMqiRRG1u-2MsSQLbXA"]
        )
    }

    // MARK: - Rendering

    @MainActor
    private func assertRenders(
        named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let pane = YouTubeChannelsSettingsView()
            .frame(width: Self.paneWidth)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: pane)
        hosting.sizingOptions = []
        // A canvas taller than the section, rather than one measured from
        // `fittingSize`: an `NSHostingView` that is not sizing itself reports a
        // height far short of what it draws, and a canvas shorter than the pane
        // centres the content and cuts the header off the top.
        hosting.frame = CGRect(
            origin: .zero, size: CGSize(width: Self.paneWidth, height: Self.canvasHeight))

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

        // The pane must not lay itself out wider than the sheet offers: a
        // Settings pane wider than the sheet moves the tab bar
        // (`settingsPane()`), and a row wider than the pane loses its right end.
        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, Self.paneWidth,
            "the \(name) render is wider than a Settings pane is offered",
            file: file, line: line)

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
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Case and spacing folded away: OCR is not required to agree with the app
    /// about either, and neither changes whether the words are on screen.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
