import AppKit
import XCTest
@testable import OpenSuperWhisper

/// What the Ask shortcut does, and the wiring that carries it there.
///
/// The defect this suite was written against: ⌥A opened the panel and stopped.
/// Every other listening path in the app - the dictation key, the YouTube
/// command key, ⌥S - reaches a call that starts a capture on the same press,
/// and this one reached only `present()`. See `docs/ask-panel.md`.
@MainActor
final class AskVoiceShortcutTests: XCTestCase {

    // MARK: - The press

    /// The whole of what a press decides, stated as the four situations it can
    /// land in. `askByVoice` in three of them is the fix: a press that finds
    /// nothing running starts listening rather than opening an idle card.
    func testAPressStartsListeningUnlessSomethingIsAlreadyRunning() {
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: false, isBusy: false),
            .askByVoice
        )
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: true, isBusy: true),
            .finishVoiceQuestion
        )
        // Transcribing or thinking: the press is neither a second question nor
        // a close, for the same reason ⌥S ignores one.
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: false, isBusy: true),
            .ignore
        )
    }

    /// The recording has stopped, so there is nothing left for a press to
    /// finish. It has to classify as `.ignore` on its own rather than reaching
    /// `finishVoiceFollowUp` and being absorbed by that method's own
    /// `state == .listening` guard - a decision that is only correct because
    /// the thing it decides declines to act is not a decision.
    func testAPressWhileTheQuestionIsBeingTranscribedIsIgnored() {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }
        viewModel.startVoiceFollowUp()
        viewModel.finishVoiceFollowUp()

        XCTAssertEqual(viewModel.state, .transcribing)
        XCTAssertFalse(viewModel.isCapturingVoiceQuestion)
        XCTAssertTrue(viewModel.isBusy)
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: viewModel.isCapturingVoiceQuestion,
                isBusy: viewModel.isBusy),
            .ignore
        )
    }

    /// ⌥S still finishes a screen query that has stopped recording and is being
    /// transcribed - narrowing the voice-question predicate must not narrow
    /// that one, which `toggleScreenQuery` depends on.
    func testNarrowingTheVoicePredicateLeftTheScreenQueryOneAlone() {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }
        viewModel.startScreenQuery()
        viewModel.finishVoiceFollowUp()

        XCTAssertEqual(viewModel.state, .transcribing)
        XCTAssertTrue(viewModel.isCapturingScreenQuery)
        XCTAssertFalse(viewModel.isCapturingVoiceQuestion)
    }

    // MARK: - What Insert still pastes into

    /// The regression the review caught. `present()` is no longer reached only
    /// with the panel hidden: a second ⌥A press re-presents a panel that is up
    /// and key, so the frontmost application is Kongweh itself. Reading it
    /// again would replace the user's editor with nothing, and Insert would
    /// fall back to the clipboard on exactly the follow-up the shortcut exists
    /// to make.
    func testRePresentingAnOpenPanelKeepsTheTargetItOpenedWith() {
        XCTAssertFalse(
            AskPanelWindowController.shouldCaptureInsertionTarget(
                isPanelVisible: true, hasInsertionTarget: true),
            "a re-presentation must not erase the target the panel opened with"
        )
    }

    /// Opening the panel is what reads the frontmost application, and a
    /// presentation holding nothing has nothing to lose by reading again - a
    /// panel opened from Kongweh's own window, or one caught mid-fade-out.
    func testOpeningThePanelStillReadsTheFrontmostApplication() {
        XCTAssertTrue(
            AskPanelWindowController.shouldCaptureInsertionTarget(
                isPanelVisible: false, hasInsertionTarget: false))
        XCTAssertTrue(
            AskPanelWindowController.shouldCaptureInsertionTarget(
                isPanelVisible: false, hasInsertionTarget: true))
        XCTAssertTrue(
            AskPanelWindowController.shouldCaptureInsertionTarget(
                isPanelVisible: true, hasInsertionTarget: false))
    }

    /// And the rule is actually wired into the presentation, not just stated:
    /// `present()` must ask it rather than reading the frontmost application
    /// unconditionally the way it did before the shortcut re-presented panels.
    func testThePresentationAsksBeforeReadingTheFrontmostApplication() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")
        let present = try XCTUnwrap(
            controller.range(of: "func present() {").map { controller[$0.lowerBound...] })
        let body = String(present.prefix(600))

        XCTAssertTrue(
            body.contains("shouldCaptureInsertionTarget"),
            "present() must not capture unconditionally - a re-present would clobber the target"
        )
    }

    /// A screen query in flight belongs to ⌥S: ⌥A must not finish it, because
    /// the two keys ask different questions and only one of them has a
    /// screenshot behind it.
    func testAScreenQueryInFlightIsNotThisKeysToFinish() {
        let viewModel = AskPanelViewModel { _ in .answered("never asked") }
        viewModel.startScreenQuery()

        XCTAssertTrue(viewModel.isCapturingScreenQuery)
        XCTAssertFalse(viewModel.isCapturingVoiceQuestion)
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: viewModel.isCapturingVoiceQuestion,
                isBusy: viewModel.isBusy),
            .ignore
        )
    }

    // MARK: - Shortcut to recording

    /// The transition the captain sees: one press, and the microphone is live.
    func testStartingAVoiceQuestionAsksForACaptureAndListens() {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }
        var captures = 0
        viewModel.onStartVoiceCapture = { captures += 1 }

        viewModel.startVoiceFollowUp()

        XCTAssertEqual(viewModel.state, .listening)
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(viewModel.isScreenQuery)
        XCTAssertTrue(viewModel.isCapturingVoiceQuestion)
    }

    /// The wiring, checked at the source: a press has to reach the call that
    /// starts a capture. A panel that merely appears is the defect this whole
    /// suite exists for, and it is invisible to every assertion above.
    func testTheShortcutReachesTheCallThatStartsACapture() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")
        let action = try XCTUnwrap(
            controller.range(of: "func toggleVoiceQuestion()").map { controller[$0.lowerBound...] }
        )
        let body = String(action.prefix(1200))
        XCTAssertTrue(
            body.contains("startVoiceQuestion()"),
            "The Ask shortcut must start a capture, not only present the panel."
        )

        let shortcuts = try Self.source(of: "OpenSuperWhisper/ShortcutManager.swift")
        XCTAssertTrue(
            shortcuts.contains("AskPanelWindowController.shared.toggleVoiceQuestion()"),
            "The ⌥A binding must run the press that starts a capture."
        )
    }

    /// The panel has to become key, or Esc and every other keystroke go to
    /// whatever the user was working in. A background app's plain `activate()`
    /// is refused - the measurement `YouTubeChannelPickerWindowController`
    /// records - and this panel is opened from a global hotkey or after a
    /// transcription, never from attention this app was just given.
    func testThePanelForcesItsActivationTheWayTheChannelPickerDoes() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")

        XCTAssertTrue(controller.contains("NSApplication.shared.activate(ignoringOtherApps: true)"))
        XCTAssertFalse(
            controller.contains("NSApplication.shared.activate()"),
            "a plain activate() leaves the card on screen but never key"
        )
    }

    // MARK: - Cancelling and failing

    /// Cancelling gives the recording back and costs the user nothing they had
    /// already been given - the same rule the button path follows, because it
    /// is the same path.
    func testCancellingAVoiceQuestionStopsTheRecordingAndKeepsTheLastAnswer() async {
        let viewModel = AskPanelViewModel { _ in .answered("Taipei.") }
        var cancels = 0
        viewModel.onCancelVoiceCapture = { cancels += 1 }

        await viewModel.ask("Where?")
        viewModel.startVoiceFollowUp()
        viewModel.cancelVoiceFollowUp()

        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(viewModel.exchanges.count, 1)
        guard case .answered(let exchange) = viewModel.state else {
            return XCTFail("cancelling must leave the answer that was already given")
        }
        XCTAssertEqual(exchange.answer, "Taipei.")
    }

    /// A capture that cannot start says so on the panel rather than leaving a
    /// card that looks like it is listening.
    func testACaptureThatCannotStartFailsVisibly() {
        let viewModel = AskPanelViewModel { _ in .answered("unused") }
        viewModel.onStartVoiceCapture = { viewModel.voiceCaptureDidFail("No microphone") }

        viewModel.startVoiceFollowUp()

        XCTAssertEqual(viewModel.state, .failed(message: "No microphone", question: nil))
        XCTAssertFalse(viewModel.isBusy)
    }


    // MARK: - What the conversation keeps

    /// A question and the answer it got are one thing, kept together and in the
    /// order they were asked. A spoken question exists nowhere else - the user
    /// never typed it - so the pair is the only record of what was asked.
    func testEveryAnsweredQuestionIsKeptWithItsOwnAnswerInOrder() async {
        let answers = Answers(["Taipei.", "Kaohsiung.", "Taichung."])
        let viewModel = AskPanelViewModel { _ in await answers.next() }

        for question in ["Capital?", "Southern port?", "The one in the middle?"] {
            viewModel.startVoiceFollowUp()
            viewModel.finishVoiceFollowUp()
            await viewModel.voiceCaptureDidProduce(question)
        }

        XCTAssertEqual(
            viewModel.exchanges.map { [$0.question, $0.answer] },
            [
                ["Capital?", "Taipei."],
                ["Southern port?", "Kaohsiung."],
                ["The one in the middle?", "Taichung."],
            ]
        )
        XCTAssertEqual(viewModel.exchanges.count, Set(viewModel.exchanges.map(\.id)).count)
    }

    /// A question that could not be answered is shown with what was asked, and
    /// is **not** written into the conversation: history is pairs, and a failure
    /// has no answer to pair with.
    func testAFailedQuestionIsShownButNeverEntersTheHistory() async {
        let viewModel = AskPanelViewModel { _ in .timedOut }

        viewModel.startVoiceFollowUp()
        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("How tall is Taipei 101?")

        XCTAssertEqual(
            viewModel.state,
            .failed(
                message: AskOutcome.timedOut.explanation ?? "",
                question: "How tall is Taipei 101?"))
        XCTAssertTrue(viewModel.exchanges.isEmpty)
    }

    /// A capture that heard nothing has no question to show, so the card says
    /// only what went wrong.
    func testACaptureThatHeardNothingHasNoQuestionToShow() async {
        let viewModel = AskPanelViewModel { _ in .answered("never asked") }

        viewModel.startVoiceFollowUp()
        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("   ")

        XCTAssertEqual(viewModel.state, .failed(message: "No speech detected", question: nil))
        XCTAssertTrue(viewModel.exchanges.isEmpty)
    }

    /// The follow-up carries the conversation so far, which is what makes "and
    /// in euros?" answerable at all.
    func testASpokenFollowUpIsAskedWithThePairsBeforeIt() async {
        let seen = Requests()
        let viewModel = AskPanelViewModel { request in
            await seen.record(request)
            return .answered("An answer.")
        }

        await viewModel.ask("First?")
        viewModel.startVoiceFollowUp()
        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("And second?")

        let histories = await seen.histories
        XCTAssertEqual(histories.first?.count, 0)
        XCTAssertEqual(histories.last?.map(\.question), ["First?"])
        XCTAssertEqual(histories.last?.map(\.answer), ["An answer."])
    }

    private actor Answers {
        private var remaining: [String]
        init(_ answers: [String]) { remaining = answers }
        func next() -> AskOutcome {
            guard !remaining.isEmpty else { return .empty }
            return .answered(remaining.removeFirst())
        }
    }

    private actor Requests {
        private(set) var histories: [[AskExchange]] = []
        func record(_ request: AskRequest) { histories.append(request.history) }
    }

    // MARK: - Helpers

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
