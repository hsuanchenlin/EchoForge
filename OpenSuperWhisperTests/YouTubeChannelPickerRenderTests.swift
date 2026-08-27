import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the channel picker and reads its pixels back.
///
/// The same technique - and the same reasons - as
/// `YouTubeChannelsSettingsRenderTests` and `AskPanelRenderTests`:
/// `NSHostingView` in an offscreen, never-shown window, rasterised with
/// `cacheDisplay`, which needs no permission, records nothing and flashes
/// nothing on screen. Renders are written to
/// `/tmp/EchoForgeYouTubePickerRenders/<name>.png` for a human to open.
///
/// It is here because `YouTubeChannelHandle` is a **presentation** decision, and
/// the surfaces it changed are the picker's rows and the sentence above them.
/// Every other test of it reads a string; this one reads the card the user
/// actually looks at, which is the only place a row written `@valley101` can be
/// told apart from one that is not.
@MainActor
final class YouTubeChannelPickerRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeYouTubePickerRenders", isDirectory: true)

    private let valley = YouTubeChannel(
        displayName: "valley101", aliases: [], channelID: "UCaaaaaaaaaaaaaaaaaaaaaa")
    private let veritasium = YouTubeChannel(
        displayName: "Veritasium", aliases: ["Verita Zium"],
        channelID: "UCbbbbbbbbbbbbbbbbbbbbbb")
    private let kurzgesagt = YouTubeChannel(
        displayName: "Kurzgesagt", aliases: [], channelID: "UCcccccccccccccccccccccc")

    private var allChannels: [YouTubeChannel] { [valley, veritasium, kurzgesagt] }

    /// The near miss the picker exists for, drawn: the user's own three channels
    /// are on screen, and each row reads as a channel rather than as a word
    /// somebody typed into a box.
    func testEveryRowIsDrawnAsAHandle() throws {
        let request = try request(for: .unknown(spoken: "Vali101"))

        try assertRenders(
            request, named: "near-miss",
            // The phrase that was heard is never rewritten - it is the user's
            // own words, and it carries no `@`.
            showing: ["Heard", "Vali101", "@valley101", "@Veritasium", "@Kurzgesagt"])
    }

    /// The sentence naming the rows an ambiguous phrase collided on writes them
    /// the way the rows below it are written.
    func testTheAmbiguousSentenceNamesTheCollidingChannelsAsHandles() throws {
        let request = try request(
            for: .ambiguous(spoken: "V", matches: ["valley101", "Veritasium"]))

        try assertRenders(
            request, named: "ambiguous",
            showing: ["@valley101", "@Veritasium"])
    }

    /// Typing what a row says finds that row: the filter drops one leading `@`,
    /// so the list narrows to the channel the user is reading off the card.
    func testTypingTheHandleOffTheCardNarrowsToThatRow() throws {
        let request = try request(for: .unknown(spoken: "Vali101"))
        let viewModel = YouTubeChannelPickerViewModel(request: request)
        viewModel.query = "@veritasium"

        XCTAssertEqual(viewModel.rows.map(\.channel), [veritasium])
        try assertRenders(viewModel, named: "filtered-by-handle", showing: ["@Veritasium"])
    }

    // MARK: - Fixtures

    private func request(
        for resolution: YouTubeChannelResolution
    ) throws -> YouTubeChannelPickerRequest {
        let offer = YouTubeChannelPickerOffer.make(
            for: resolution, candidates: allChannels, isEnabled: true)
        guard case .picker(let request) = offer else {
            throw XCTSkip("expected a picker for \(resolution)")
        }
        return request
    }

    // MARK: - Rendering

    private func assertRenders(
        _ request: YouTubeChannelPickerRequest, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertRenders(
            YouTubeChannelPickerViewModel(request: request),
            named: name, showing: fragments, file: file, line: line)
    }

    private func assertRenders(
        _ viewModel: YouTubeChannelPickerViewModel, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // The window is larger than the card because the card draws its own
        // shadow, so the panel's own arithmetic is what sizes the canvas.
        let size = YouTubeChannelPickerView.windowSize(
            rowCount: viewModel.request.suggestions.count)
        let hosting = NSHostingView(
            rootView: YouTubeChannelPickerView(viewModel: viewModel)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)

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
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    /// Case and spacing folded away: OCR is not required to agree with the app
    /// about either, and neither changes whether the words are on screen.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
