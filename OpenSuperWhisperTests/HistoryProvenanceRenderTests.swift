import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws history rows and reads their pixels back.
///
/// The same technique - and the same reasons - as
/// `YouTubeChannelsSettingsRenderTests`: `NSHostingView` in an offscreen, never
/// shown window, rasterised with `cacheDisplay`, which needs no permission and
/// flashes nothing on screen. Renders are written to
/// `/tmp/EchoForgeHistoryRenders/<name>.png` for a human to open.
///
/// What it is here to catch is the thing a string-level test cannot: a label
/// that is on the row in principle and not readable in practice. The whole
/// change is worth nothing if the sentence explaining a failed command is
/// clipped, truncated to one line, or off the edge of a 450 pt window.
final class HistoryProvenanceRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeHistoryRenders", isDirectory: true)

    /// The width a row is offered in the narrowest history window the app
    /// allows (`ContentView` pins `minWidth: 400`), less the list's padding.
    private static let rowWidth: CGFloat = 400 - 32

    // MARK: - The four labels

    @MainActor
    func testAnOrdinaryDictationIsLabelledAsOne() throws {
        try assertRow(
            named: "dictation",
            transcription: "the sentence I typed into an editor",
            provenance: .dictation,
            showing: ["Dictation"]
        )
    }

    @MainActor
    func testAQuestionIsLabelledAsAsk() throws {
        try assertRow(
            named: "ask",
            transcription: "what is the capital of France?",
            provenance: .ask,
            showing: ["Ask"]
        )
    }

    @MainActor
    func testAnOpenedCommandSaysWhatItOpened() throws {
        try assertRow(
            named: "command-opened",
            transcription: "Open YouTube channel Valley 101",
            provenance: .command(
                .opened(channel: "valley101", title: "The newest one", match: .spacing)),
            showing: ["YouTube command", "opened", "valley101", "Chrome"]
        )
    }

    /// The row this whole change exists for. The label, the spelling that was
    /// heard, and what to do about it all have to be readable without a click.
    @MainActor
    func testARefusedCommandShowsTheReasonWithoutAClick() throws {
        try assertRow(
            named: "command-not-opened",
            transcription: "Open YouTube channel Vali101",
            provenance: .command(
                .refused(
                    reason: .channelUnknown,
                    message: "No allowlisted YouTube channel answers to “Vali101”. Add it in Settings → Dictionary & Snippets → YouTube Channels, or add that spelling as a spoken name on the channel you meant.",
                    shortMessage: "Channel not in your list"),
                modelMatch: .off),
            showing: ["YouTube command", "not opened", "Vali101", "spoken name", "switched off"]
        )
    }

    /// Every row made before this existed. It must say it does not know, not
    /// pick one of the other four.
    @MainActor
    func testARecordingFromBeforeProvenanceSaysSo() throws {
        try assertRow(
            named: "legacy",
            transcription: "something said last month",
            provenance: .unknown,
            showing: ["Older recording"]
        )
    }

    // MARK: - The filter

    @MainActor
    func testTheFilterNamesTheKindItIsShowing() throws {
        let menu = HistoryProvenanceFilterMenu(
            selection: .constant(.youTubeCommandNotOpened))
        try assertRenders(
            menu.padding(8), named: "filter-menu", width: 260,
            height: 44, showing: ["Not opened"])
    }

    /// The control is a menu, and it is not the width of the window: a filter
    /// that pushed the search field off the row would be worse than no filter.
    @MainActor
    func testTheFilterFitsBesideTheSearchField() throws {
        for filter in HistoryProvenanceFilter.allCases {
            let hosting = NSHostingView(
                rootView: HistoryProvenanceFilterMenu(selection: .constant(filter)))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(
                hosting.fittingSize.width, 120,
                "the “\(filter.menuLabel)” filter is too wide to sit beside the search field")
        }
    }

    // MARK: - Rendering

    @MainActor
    private func assertRow(
        named name: String,
        transcription: String,
        provenance: RecordingProvenance,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var recording = Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000.wav",
            transcription: transcription,
            duration: 5.5,
            status: .completed,
            progress: 1.0,
            sourceFileURL: nil
        )
        recording.provenance = provenance

        try assertRenders(
            RecordingRow(
                recording: recording, searchQuery: "", onDelete: {}, onRegenerate: {}),
            named: name, width: Self.rowWidth, height: 320,
            showing: fragments, file: file, line: line)
    }

    @MainActor
    private func assertRenders<Content: View>(
        _ content: Content, named name: String, width: CGFloat, height: CGFloat,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = content
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))

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

        // Nothing may lay itself out wider than the window offers, or the right
        // end of the reason is simply gone.
        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, width,
            "the \(name) render is wider than the window offers", file: file, line: line)

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
