import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the two cards Phase 2 added to Settings → Dictionary & Snippets and
/// reads their pixels back.
///
/// The same technique and the same reasons as `YouTubeChannelsSettingsRenderTests`:
/// `NSHostingView` in an offscreen, never-shown window, rasterised with
/// `cacheDisplay`, which needs no permission and flashes nothing on screen.
/// Renders are written to `/tmp/EchoForgeDictionaryPaneRenders/<name>.png` for a
/// human to open.
///
/// What it is here to catch is what a string test cannot. Both cards carry long
/// explanatory copy and a wrapping list of phrase chips, and the Settings sheet's
/// width is one decision shared by every pane (`SettingsSheetLayout`) - a card
/// that lays itself out wider than the pane it is offered loses its right edge.
/// Both appearances are drawn, because a chip whose fill is only visible in one
/// of them is a chip nobody can read in the other.
final class DictionaryPaneRenderTests: IsolatedPreferencesTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeDictionaryPaneRenders", isDirectory: true)

    /// The width a pane is offered inside the sheet: the sheet's width less its
    /// own padding and the pane's.
    private static let paneWidth: CGFloat = SettingsSheetLayout.preferredSize.width - 64

    private static let canvasHeight: CGFloat = 900

    // MARK: - Spoken corrections

    @MainActor
    func testTheCorrectionsCardExplainsTheClauseRuleBeforeItIsSwitchedOn() throws {
        try assertRenders(
            SpokenCorrectionsSettingsView(),
            named: "corrections-off",
            appearance: .aqua,
            // The false-positive rule is the one thing a user has to believe
            // before switching this on, so it is on screen in every state.
            showing: ["Spoken Corrections", "scratch that", "on-device"]
        )
    }

    @MainActor
    func testTheCorrectionsCardListsEveryPhraseItActsOn() throws {
        AppPreferences.shared.spokenCorrectionsEnabled = true
        AppPreferences.shared.fillerWordRemovalEnabled = true

        try assertRenders(
            SpokenCorrectionsSettingsView(isShowingPhrases: true),
            named: "corrections-phrases",
            appearance: .aqua,
            showing: ["Drop what you just said", "delete the last sentence", "start over"]
        )
    }

    @MainActor
    func testTheCorrectionsCardIsReadableInTheDark() throws {
        try assertRenders(
            SpokenCorrectionsSettingsView(isShowingPhrases: true),
            named: "corrections-dark",
            appearance: .darkAqua,
            showing: ["Spoken Corrections", "scratch that"]
        )
    }

    // MARK: - App vocabulary

    @MainActor
    func testTheVocabularyCardSaysWhatItReadsBeforeItIsSwitchedOn() throws {
        try assertRenders(
            AppVocabularySettingsView(),
            named: "vocabulary-off",
            appearance: .aqua,
            // The privacy sentence and the engine caveat are the two facts a
            // user needs before deciding, so neither waits for the toggle.
            showing: ["App Vocabulary", "identifier", "Whisper"]
        )
    }

    @MainActor
    func testTheVocabularyCardShowsTheProfilesOnceItIsOn() throws {
        AppVocabularyStore(isEnabled: true).save()

        try assertRenders(
            AppVocabularySettingsView(),
            named: "vocabulary-on",
            appearance: .aqua,
            showing: ["Code & terminals", "Mail", "Documents & notes"]
        )
    }

    /// The exact list is one click away, and it is the point of the pane: a user
    /// is being asked to let this app add words to what their recognizer is
    /// primed with, and "what exactly?" has to be answerable on screen.
    @MainActor
    func testAProfilesExactWordsAndPassageCanBeRead() throws {
        AppVocabularyStore(isEnabled: true).save()

        try assertRenders(
            AppVocabularySettingsView(expandedProfiles: ["developerTools"]),
            named: "vocabulary-expanded",
            appearance: .aqua,
            showing: ["Sample passage", "camelCase", "snake_case"]
        )
    }

    @MainActor
    func testTheVocabularyCardIsReadableInTheDark() throws {
        AppVocabularyStore(isEnabled: true).save()

        try assertRenders(
            AppVocabularySettingsView(),
            named: "vocabulary-dark",
            appearance: .darkAqua,
            showing: ["App Vocabulary", "Code & terminals"]
        )
    }

    // MARK: - Rendering

    @MainActor
    private func assertRenders<Pane: View>(
        _ pane: Pane,
        named name: String,
        appearance: NSAppearance.Name,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hosted = pane
            .frame(width: Self.paneWidth)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let hosting = NSHostingView(rootView: hosted)
        hosting.sizingOptions = []
        hosting.frame = CGRect(
            origin: .zero, size: CGSize(width: Self.paneWidth, height: Self.canvasHeight))

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
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

        // A Settings card wider than the pane it is offered loses its right end,
        // and a pane wider than the sheet moves the tab bar (`settingsPane()`).
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
