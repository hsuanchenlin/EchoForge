import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the Ask panel and reads its pixels back.
///
/// The same technique - and the same reasons - as
/// `YouTubeChannelsSettingsRenderTests`: `NSHostingView` in an offscreen,
/// never-shown window, rasterised with `cacheDisplay`, which needs no
/// permission, records nothing and flashes nothing on screen. Renders are
/// written to `/tmp/EchoForgeAskRenders/<name>.png` for a human to open.
///
/// It is here because the defect that produced this suite was only ever visible
/// as pixels: the shortcut opened a card offering an **Ask by voice** button,
/// and every state assertion in the app agreed that the panel was fine.
@MainActor
final class AskPanelRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeAskRenders", isDirectory: true)

    /// The card with nothing asked yet tells the user what the shortcut now
    /// does. It used to say "hold your shortcut and say \"Ask: …\"", which was
    /// the only instruction on screen for a key that had merely opened this
    /// card - the sentence and the key have to agree.
    func testTheEmptyCardSaysThatTheShortcutStartsTalking() throws {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }

        try assertRenders(
            viewModel, named: "idle",
            showing: ["Ask a question", "Press your Ask shortcut and start talking"])
    }

    /// The captain's press: the card says it is listening, and there is a Stop
    /// on it rather than a button they still have to find.
    func testTheShortcutPutsAListeningCardOnScreen() throws {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }
        viewModel.startVoiceFollowUp()

        try assertRenders(viewModel, named: "listening", showing: ["Listening", "Stop"])
    }

    /// The recognized question is on the card while the model works on it.
    func testTheQuestionIsOnScreenWhileItIsBeingAnswered() async throws {
        let gate = Gate()
        let viewModel = AskPanelViewModel { _ in await gate.wait() }
        let asking = Task { await viewModel.ask("How tall is Taipei 101?") }
        await Self.yieldUntil(viewModel, reaches: .thinking(question: "How tall is Taipei 101?"))

        try assertRenders(
            viewModel, named: "thinking", showing: ["How tall is Taipei 101", "Thinking"])

        await gate.release(.answered("508 metres."))
        await asking.value
    }

    /// The pair, drawn together: what was asked and what came back.
    func testTheQuestionAndItsAnswerAreDrawnTogether() async throws {
        let viewModel = AskPanelViewModel { _ in .answered("508 metres to the tip.") }

        await viewModel.ask("How tall is Taipei 101?")

        try assertRenders(
            viewModel, named: "answered",
            showing: ["How tall is Taipei 101", "508 metres to the tip"])
    }

    /// A question that failed keeps its question on the card. A spoken one
    /// exists nowhere else, and a bare sentence leaves the user unable to tell a
    /// misheard question from a model that could not run.
    func testAFailedQuestionIsStillShownAboveTheReason() async throws {
        let viewModel = AskPanelViewModel { _ in .timedOut }

        await viewModel.ask("How tall is Taipei 101?")

        try assertRenders(
            viewModel, named: "failed",
            showing: ["How tall is Taipei 101", "took too long"])
    }

    /// Older pairs stay on the card, oldest first, under the newest one.
    func testEarlierPairsStayOnTheCardInTheOrderTheyWereAsked() async throws {
        let answers = Answers(["Taipei.", "Kaohsiung."])
        let viewModel = AskPanelViewModel { _ in await answers.next() }

        await viewModel.ask("Capital of Taiwan?")
        await viewModel.ask("And the southern port?")

        XCTAssertEqual(viewModel.exchanges.map(\.question),
                       ["Capital of Taiwan?", "And the southern port?"])
        try assertRenders(
            viewModel, named: "conversation",
            showing: ["Capital of Taiwan", "Taipei.", "And the southern port", "Kaohsiung."])
    }

    // MARK: - Stubs

    private actor Gate {
        private var waiting: CheckedContinuation<AskOutcome, Never>?
        func wait() async -> AskOutcome {
            await withCheckedContinuation { self.waiting = $0 }
        }
        func release(_ outcome: AskOutcome) {
            waiting?.resume(returning: outcome)
            waiting = nil
        }
    }

    private actor Answers {
        private var remaining: [String]
        init(_ answers: [String]) { remaining = answers }
        func next() -> AskOutcome {
            guard !remaining.isEmpty else { return .empty }
            return .answered(remaining.removeFirst())
        }
    }

    private static func yieldUntil(
        _ viewModel: AskPanelViewModel, reaches state: AskPanelState
    ) async {
        for _ in 0 ..< 2000 {
            if viewModel.state == state { return }
            await Task.yield()
        }
        XCTFail("never reached \(state)")
    }

    // MARK: - Rendering

    private func assertRenders(
        _ viewModel: AskPanelViewModel, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hosting = NSHostingView(
            rootView: AskPanelView(viewModel: viewModel)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: AskPanelView.windowSize)

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
