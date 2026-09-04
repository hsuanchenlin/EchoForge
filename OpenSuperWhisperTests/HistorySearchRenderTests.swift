import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the two surfaces history search owns and reads them back.
///
/// The same offscreen technique as `HistoryRowRenderTests` - an `NSHostingView`
/// in a window that is never shown, rasterised with `cacheDisplay`, needing no
/// permission and flashing nothing on screen. Renders land in
/// `/tmp/EchoForgeHistoryRenders/` for a human to open.
///
/// It exists because the alternative is nobody looking. Both of these sit inside
/// `ContentView`, behind a microphone and an Accessibility grant, so a truncated
/// placeholder or a no-results panel that says the wrong thing would only be
/// found by launching a fully permitted build and typing into it.
final class HistorySearchRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeHistoryRenders", isDirectory: true)

    /// The bar less the list's own horizontal padding, at the narrowest window
    /// `ContentView` allows and at a width the user has dragged out to.
    private static let compactWidth: CGFloat = 400 - 32
    private static let regularWidth: CGFloat = 820 - 32

    // MARK: - The bar

    /// The field, the filter, and the placeholder that has to fit between them.
    ///
    /// The 450 pt window is where this is tightest: the placeholder names three
    /// things the search reaches, and a user who only ever sees the first word
    /// of it has a word search and a filter and nothing between them.
    @MainActor
    func testTheBarStatesWhatItSearchesAtBothWidths() throws {
        for (name, width) in [("compact", Self.compactWidth), ("regular", Self.regularWidth)] {
            try assert(
                bar(),
                named: "search-bar-\(name)",
                width: width,
                showing: ["Search", "transcripts", "All"])
        }
    }

    /// A phrase replaces the placeholder rather than sitting beside it, and the
    /// bar still fits everything on one line with the ⓧ that appears next to it.
    ///
    /// The clear button is a glyph, so OCR cannot see it; what this holds is the
    /// half that can be read - the field says what was typed and stops
    /// advertising what it searches - and both renders are written for a human
    /// to look at. The button's own condition is one line in `HistorySearchBar`.
    @MainActor
    func testATypedPhraseReplacesThePlaceholder() throws {
        let empty = try render(bar(text: ""), width: Self.regularWidth)
        let typed = try render(bar(text: "voice edit"), width: Self.regularWidth)
        try write(empty, named: "search-bar-empty")
        try write(typed, named: "search-bar-typed")

        XCTAssertTrue(
            normalized(try recognizedText(in: empty)).contains(
                normalized(HistorySearchBar.placeholder)),
            "the empty field does not say what it searches")

        let typedText = normalized(try recognizedText(in: typed))
        XCTAssertTrue(typedText.contains(normalized("voice edit")), "the phrase is not on the bar")
        XCTAssertFalse(
            typedText.contains(normalized(HistorySearchBar.placeholder)),
            "the placeholder is still drawn over a field that has a phrase in it")
    }

    @MainActor
    func testTheBarDrawsInDarkModeToo() throws {
        try assert(
            bar(),
            named: "search-bar-dark",
            width: Self.regularWidth,
            scheme: .dark,
            showing: ["Search", "transcripts"])
    }

    /// A chosen filter is stated on the collapsed control, or the user cannot
    /// see that the list in front of them is narrowed.
    @MainActor
    func testTheChosenFilterIsNamedOnTheBar() throws {
        try assert(
            bar(filter: .selectionEdit),
            named: "search-bar-filtered",
            width: Self.regularWidth,
            showing: ["Voice edit"])
    }

    // MARK: - No results

    /// A search that found nothing says what was searched for, says what else a
    /// phrase can be, and offers the one action out.
    @MainActor
    func testAnEmptySearchExplainsItselfAndOffersTheWayBack() throws {
        for (name, width) in [("compact", Self.compactWidth), ("regular", Self.regularWidth)] {
            try assert(
                HistoryNoResultsView(query: "quarterly", filter: .all, clear: {}),
                named: "search-empty-\(name)",
                width: width,
                showing: ["No results found", "quarterly", "Clear search"])
        }
    }

    /// A filtered list that is empty must say it is *filtered*. "No recordings
    /// yet" over a history full of recordings is the app telling the user
    /// something untrue - and this panel is the half that stops that happening.
    @MainActor
    func testAFilteredEmptyListNamesTheFilterAndHowToLeaveIt() throws {
        try assert(
            HistoryNoResultsView(query: "", filter: .youTubeCommandNotOpened, clear: {}),
            named: "search-empty-filtered",
            width: Self.regularWidth,
            showing: ["No results found", "YouTube command", "Choose All"])
    }

    /// With no phrase there is no search to clear, so the action is not offered
    /// - the filter control is where that list is widened.
    @MainActor
    func testThereIsNoClearActionWhenNothingWasTyped() throws {
        let text = try recognizedText(
            in: try render(
                HistoryNoResultsView(query: "", filter: .ask, clear: {}),
                width: Self.regularWidth))
        XCTAssertFalse(
            normalized(text).contains(normalized("Clear search")),
            "there is no search to clear")
    }

    // MARK: - The sentence, as a decision

    func testTheMessageNamesWhicheverThingIsNarrowingTheList() {
        let searched = HistoryNoResultsView.message(query: "quarterly", filter: .all)
        XCTAssertTrue(searched.contains("quarterly"))
        XCTAssertTrue(searched.contains("Voice edit"), "it must say a kind is searchable")
        XCTAssertTrue(searched.contains("2026-09-04"), "it must say a date is searchable")

        let filtered = HistoryNoResultsView.message(query: "", filter: .ask)
        XCTAssertTrue(filtered.contains("Ask"))
        XCTAssertTrue(filtered.contains("Choose All"))
        XCTAssertFalse(filtered.contains("match that search"), "nothing was searched for")

        let both = HistoryNoResultsView.message(query: "quarterly", filter: .ask)
        XCTAssertTrue(both.contains("Ask"))
        XCTAssertTrue(both.contains("match that search"))
    }

    /// The placeholder and the labels are the same promise in three places, and
    /// a VoiceOver user gets the more specific one because they cannot see the
    /// list change as they type.
    func testTheFieldNamesItselfForAReaderWhoCannotSeeIt() {
        XCTAssertFalse(HistorySearchBar.accessibilityLabel.isEmpty)
        XCTAssertTrue(HistorySearchBar.accessibilityHint.contains("Voice edit"))
        XCTAssertTrue(HistorySearchBar.accessibilityHint.contains("2026-09-04"))
        XCTAssertTrue(HistorySearchBar.help.contains("⌘F"), "the shortcut has no menu item")
        XCTAssertFalse(HistorySearchBar.clearLabel.isEmpty)

        // The placeholder promises the three things the search actually reaches.
        for word in ["transcripts", "dates", "kinds"] {
            XCTAssertTrue(
                HistorySearchBar.placeholder.lowercased().contains(word),
                "the placeholder does not mention \(word)")
        }
    }

    // MARK: - Fixtures

    @MainActor
    private func bar(
        text: String = "", filter: HistoryProvenanceFilter = .all
    ) -> some View {
        HistorySearchBarHarness(text: text, filter: filter)
    }

    /// A host for the bar, because `HistorySearchBar` takes a `FocusState`
    /// binding and only a view can own one.
    private struct HistorySearchBarHarness: View {
        @State var text: String
        @State var filter: HistoryProvenanceFilter
        @FocusState private var focus: Bool

        var body: some View {
            HistorySearchBar(
                text: $text, filter: $filter, clear: { text = "" }, focus: $focus)
        }
    }

    // MARK: - Rendering

    @MainActor
    private func assert<Content: View>(
        _ content: Content,
        named name: String,
        width: CGFloat,
        scheme: ColorScheme = .light,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let image = try render(content, width: width, scheme: scheme)
        try write(image, named: name)

        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    @MainActor
    private func image(of hosting: NSHostingView<AnyView>) throws -> CGImage {
        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "no bitmap to draw into")
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try XCTUnwrap(rep.cgImage, "no image behind the render")
    }

    @MainActor
    private func render<Content: View>(
        _ content: Content, width: CGFloat, scheme: ColorScheme = .light
    ) throws -> CGImage {
        let hosting = try host(content, width: width, scheme: scheme)
        let image = try self.image(of: hosting)

        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?, "no pixel data")
        let first = pixels.first
        XCTAssertTrue(pixels.contains { $0 != first }, "the render is a blank canvas")

        // Nothing may lay itself out wider than it was offered.
        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, width + 32,
            "the render is wider than it was offered")
        return image
    }

    /// Lays a view out in a window that is never shown.
    @MainActor
    private func host<Content: View>(
        _ content: Content, width: CGFloat, scheme: ColorScheme
    ) throws -> NSHostingView<AnyView> {
        let root = AnyView(
            content
                .frame(width: width)
                .padding(16)
                .background(ThemePalette.windowBackground(scheme))
                .environment(\.colorScheme, scheme))

        let hosting = NSHostingView(rootView: root)
        let height = hosting.fittingSize.height
        hosting.frame = CGRect(
            origin: .zero, size: CGSize(width: width + 32, height: max(height, 60)))

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
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
