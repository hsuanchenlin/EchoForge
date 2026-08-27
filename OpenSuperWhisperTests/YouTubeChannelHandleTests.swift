import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// How a configured channel is named back to the user.
///
/// The boundary this suite holds is one line: a channel **shown back** is
/// written `@name`, and a spelling the user is meant to **say** is quoted
/// exactly as they stored it. See `YouTubeChannelHandle`.
final class YouTubeChannelHandleTests: XCTestCase {

    func testAConfiguredLabelIsShownAsAHandle() {
        XCTAssertEqual(YouTubeChannelHandle.format("Veritasium"), "@Veritasium")
        XCTAssertEqual(
            YouTubeChannel(displayName: "Veritasium", channelID: "UCHnyfMqiRRG1u-2MsSQLbXA").handle,
            "@Veritasium")
    }

    /// It prefixes and nothing else. Folding "valley 101" into "@valley101"
    /// would look more like a real handle, which is exactly why it must not:
    /// this app never resolves a handle, so anything but the user's own label is
    /// an identity it invented.
    func testItPrefixesAndChangesNothingElse() {
        XCTAssertEqual(YouTubeChannelHandle.format("valley 101"), "@valley 101")
        XCTAssertEqual(YouTubeChannelHandle.format("科技島讀"), "@科技島讀")
        XCTAssertEqual(YouTubeChannelHandle.format("Kurzgesagt – In a Nutshell"),
                       "@Kurzgesagt – In a Nutshell")
    }

    /// A label already written as a handle keeps its single `@`.
    func testALabelAlreadyWrittenAsAHandleIsLeftAlone() {
        XCTAssertEqual(YouTubeChannelHandle.format("@veritasium"), "@veritasium")
        XCTAssertEqual(YouTubeChannelHandle.format("  @veritasium  "), "@veritasium")
    }

    /// A half-finished row has no handle: a bare "@" would read as a channel
    /// with no name rather than as a row that still needs one.
    func testAnEmptyLabelHasNoHandle() {
        XCTAssertEqual(YouTubeChannelHandle.format(""), "")
        XCTAssertEqual(YouTubeChannelHandle.format("   "), "")
        XCTAssertEqual(YouTubeChannel(displayName: "  ", channelID: "").handle, "")
    }

    // MARK: - What it must not touch

    /// Presentation only: what a spoken name is compared against is untouched,
    /// so adding the handle form changed nothing about which channel a phrase
    /// reaches.
    func testTheHandleFormIsNeverWhatASpokenNameIsMatchedAgainst() {
        let channel = YouTubeChannel(
            displayName: "Veritasium", aliases: ["vera tasium"],
            channelID: "UCHnyfMqiRRG1u-2MsSQLbXA")

        XCTAssertEqual(channel.spokenKeys, ["veritasium", "vera tasium"])
        XCTAssertFalse(channel.spokenKeys.contains { $0.contains("@") })
        XCTAssertFalse(channel.compactSpokenKeys.contains { $0.contains("@") })

        // And the phrase still resolves to it, handle or no handle.
        let allowlist = YouTubeChannelAllowlist(channels: [channel])
        guard case .allowlisted(let resolved, _) = allowlist.resolve(spokenName: "vera tasium")
        else { return XCTFail("the alias must still reach the channel") }
        XCTAssertEqual(resolved.channelID, channel.channelID)
    }

    /// The sentence telling the user what to say quotes their own spelling: it
    /// is an instruction to speak, and "@Veritasium" is not something anybody
    /// says out loud.
    func testTheUsageSentenceStillQuotesTheSpokenSpelling() {
        let usage = YouTubeChannelHelpText.usage(exampleChannel: "Veritasium")

        XCTAssertTrue(usage.contains("“Veritasium”"))
        XCTAssertFalse(usage.contains("@Veritasium"))
    }

    // MARK: - The surfaces that name a channel back

    func testThePickerNamesTheChannelsInHandleForm() {
        let request = YouTubeChannelPickerRequest(
            spokenName: "vera tasium",
            cause: .ambiguous(matches: ["Veritasium", "valley 101"]),
            suggestions: [])

        XCTAssertTrue(request.prompt.contains("@Veritasium"))
        XCTAssertTrue(request.prompt.contains("@valley 101"))
        // What was heard is never rewritten: it is the user's own words, and
        // the whole point of showing it is that it is verbatim.
        XCTAssertEqual(request.spokenName, "vera tasium")
    }

    func testARefusalNamesTheCollidingChannelsInHandleForm() throws {
        let report = try XCTUnwrap(
            YouTubeLatestVideoReport.refusal(
                for: .ambiguous(spoken: "vera tasium", matches: ["Veritasium", "Verity"])))

        guard case .refused(let reason, let message, _) = report else {
            return XCTFail("an ambiguous phrase opens nothing")
        }
        XCTAssertEqual(reason, .channelAmbiguous)
        XCTAssertTrue(message.contains("@Veritasium"))
        XCTAssertTrue(message.contains("@Verity"))
        XCTAssertTrue(message.contains("“vera tasium”"))
    }

    func testAnOpenedVideoNamesTheChannelInHandleForm() {
        let report = YouTubeLatestVideoReport.opened(
            channel: "@Veritasium", title: "The newest one", match: .spokenName)

        XCTAssertTrue(report.spokenSummary.contains("from @Veritasium"))
    }

    func testACancelledPickerNamesTheCollidingChannelsInHandleForm() {
        let report = YouTubeLatestVideoReport.pickerCancelled(
            spoken: "vera tasium", cause: .ambiguous(matches: ["Veritasium", "Verity"]))

        guard case .refused(_, let message, _) = report else {
            return XCTFail("a cancelled picker opens nothing")
        }
        XCTAssertTrue(message.contains("@Veritasium"))
        XCTAssertTrue(message.contains("@Verity"))
    }

    /// The History row for the same collision is read after the picker sentence
    /// and about the same channels, so it names them the same way. A handle is a
    /// display label, so the column still carries no id, URL or credential -
    /// which `HistoryProvenancePrivacyTests` is what holds.
    func testTheHistoryRowForAnAmbiguousPickerNamesChannelsInHandleForm() {
        let provenance = RecordingProvenance.pickerShown(
            YouTubeChannelPickerRequest(
                spokenName: "vera tasium",
                cause: .ambiguous(matches: ["Veritasium", "Verity"]),
                suggestions: []))

        guard case .youTubeCommandNotOpened(let reason, let message) = provenance else {
            return XCTFail("a picker on screen has opened nothing")
        }
        XCTAssertEqual(reason, .pickerShown)
        XCTAssertTrue(message.contains("@Veritasium"))
        XCTAssertTrue(message.contains("@Verity"))
        XCTAssertTrue(message.contains("“vera tasium”"))
    }
}

/// Draws the channel picker and reads its pixels back, so the handle form is
/// asserted where the user actually meets it.
///
/// The same offscreen `NSHostingView` technique as
/// `YouTubeChannelsSettingsRenderTests`: no window is shown, nothing is
/// recorded, and no permission is needed.
@MainActor
final class YouTubeChannelPickerHandleRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeYouTubePickerRenders", isDirectory: true)

    func testThePickerDrawsChannelsAsHandlesAndTheHeardPhraseVerbatim() throws {
        let channels = [
            YouTubeChannel(displayName: "Veritasium", channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"),
            YouTubeChannel(
                displayName: "valley101", aliases: ["valley one oh one"],
                channelID: "UCabcdefghijklmnopqrstuv"),
        ]
        let request = YouTubeChannelPickerRequest(
            spokenName: "vera tasium",
            cause: .unknown,
            suggestions: YouTubeChannelSuggestions.rank("vera tasium", among: channels))

        let observed = try render(request, named: "handles")

        XCTAssertTrue(normalized(observed).contains(normalized("@Veritasium")),
                      "the row must name the channel as a handle; OCR read: \(observed)")
        XCTAssertTrue(normalized(observed).contains(normalized("@valley101")),
                      "every row is a channel; OCR read: \(observed)")
        // What was heard is the user's own words and is never rewritten.
        XCTAssertTrue(normalized(observed).contains(normalized("vera tasium")),
                      "OCR read: \(observed)")
        XCTAssertFalse(normalized(observed).contains(normalized("@vera tasium")),
                       "OCR read: \(observed)")
    }

    private func render(_ request: YouTubeChannelPickerRequest, named name: String) throws -> String {
        let viewModel = YouTubeChannelPickerViewModel(request: request)
        let size = YouTubeChannelPickerView.windowSize(rowCount: request.suggestions.count)
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

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)

        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text])
        return (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
