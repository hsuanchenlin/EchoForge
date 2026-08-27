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
                isCapturingVoiceQuestion: false, isBusy: false, isRecordingInFlight: false),
            .askByVoice
        )
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: true, isBusy: true, isRecordingInFlight: true),
            .finishVoiceQuestion
        )
        // Transcribing or thinking: the press is neither a second question nor
        // a close, for the same reason ⌥S ignores one.
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: false, isBusy: true, isRecordingInFlight: false),
            .ignore
        )
    }

    /// A dictation holding the microphone is its **own** outcome, not `.ignore`.
    /// It was a bare `return` beside the switch for one commit, which made the
    /// press a silent no-op and left `dictationInFlight`'s sentence with no way
    /// to be reached from either shortcut.
    func testAPressIsRefusedRatherThanIgnoredWhileSomethingElseIsRecording() {
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: false, isBusy: false, isRecordingInFlight: true),
            .refuseToSeizeRecorder
        )
        // The panel's own question holds that same recorder, and this press is
        // what ends it - so finishing is asked first and wins.
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: true, isBusy: true, isRecordingInFlight: true),
            .finishVoiceQuestion
        )
        // And a panel that is only thinking has no recorder to seize, so naming
        // one would be a lie: that press stays `.ignore`.
        XCTAssertEqual(
            AskPanelWindowController.shortcutAction(
                isCapturingVoiceQuestion: false, isBusy: true, isRecordingInFlight: false),
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
                isBusy: viewModel.isBusy,
                isRecordingInFlight: false),
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
    /// plainly would replace the user's editor with nothing, and Insert would
    /// fall back to the clipboard on exactly the follow-up the shortcut exists
    /// to make.
    func testRePresentingWhileThisAppIsFrontmostKeepsTheTargetItOpenedWith() {
        let editor = NSRunningApplication.current

        XCTAssertEqual(
            AskPanelWindowController.nextInsertionTarget(
                frontmost: editor,
                ownBundleIdentifier: editor.bundleIdentifier,
                held: editor
            ),
            editor,
            "a re-presentation over this app's own panel must not erase the target"
        )
    }

    /// And the other half, which keeping the target unconditionally got wrong:
    /// the panel is floating and survives a switch to another application, so a
    /// press made *there* has to re-target. Otherwise Insert pastes the answer
    /// into the application the user left.
    func testAPressFromAnotherApplicationRetargetsTheHeldOne() throws {
        let left = NSRunningApplication.current
        let movedTo = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier != nil && $0 != left
            },
            "the app-switch case needs a second running application to move to"
        )

        XCTAssertEqual(
            AskPanelWindowController.nextInsertionTarget(
                frontmost: movedTo,
                ownBundleIdentifier: "kongweh.itself",
                held: left
            ),
            movedTo
        )
    }

    /// Only a read that **refuses** falls back - this app itself, or a frontmost
    /// application that could not be read at all. A presentation holding nothing
    /// then still ends up holding nothing, which is the clipboard-only case.
    func testOnlyARefusedReadFallsBackToWhatIsHeld() {
        let editor = NSRunningApplication.current

        XCTAssertEqual(
            AskPanelWindowController.nextInsertionTarget(
                frontmost: nil, ownBundleIdentifier: "kongweh.itself", held: editor
            ),
            editor
        )
        XCTAssertNil(
            AskPanelWindowController.nextInsertionTarget(
                frontmost: editor, ownBundleIdentifier: editor.bundleIdentifier, held: nil
            )
        )
    }

    /// And the rule is actually wired into the presentation, not just stated:
    /// `present()` reads the frontmost application on every presentation, and
    /// what it holds is only ever a fallback.
    func testThePresentationReadsTheFrontmostApplicationEveryTime() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")
        let present = try XCTUnwrap(
            controller.range(of: "func present() {").map { controller[$0.lowerBound...] })
        let body = String(present.prefix(600))

        XCTAssertTrue(
            body.contains("captureInsertionTarget()"),
            "present() must read the frontmost app - a kept target would paste into the app the user left"
        )
        let capture = try XCTUnwrap(
            controller.range(of: "private func captureInsertionTarget() {")
                .map { controller[$0.lowerBound...] })
        XCTAssertTrue(
            String(capture.prefix(400)).contains("held: insertionTarget"),
            "the read must fall back to the held target, or a follow-up clobbers it with nil"
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
                isBusy: viewModel.isBusy,
                isRecordingInFlight: true),
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

    /// The press must never take the recorder away from a dictation. There is
    /// one `AudioRecorder`, and starting a second recording on it discards the
    /// first: the dictation's audio is deleted and its file re-pointed at this
    /// question, so ⌥` then pastes the spoken question into the user's document
    /// while the panel reports hearing nothing.
    func testACaptureIsRefusedWhileARecordingIsAlreadyRunning() {
        XCTAssertEqual(
            AskPanelWindowController.voiceCaptureRefusal(
                hasMicrophone: true, isRecordingInFlight: true, isTranscribing: false),
            .dictationInFlight
        )
        // A recording in flight is named ahead of anything else that is busy,
        // because it is the one the press would have destroyed.
        XCTAssertEqual(
            AskPanelWindowController.voiceCaptureRefusal(
                hasMicrophone: true, isRecordingInFlight: true, isTranscribing: true),
            .dictationInFlight
        )
        XCTAssertNil(
            AskPanelWindowController.voiceCaptureRefusal(
                hasMicrophone: true, isRecordingInFlight: false, isTranscribing: false)
        )
        XCTAssertEqual(
            AskPanelWindowController.voiceCaptureRefusal(
                hasMicrophone: false, isRecordingInFlight: false, isTranscribing: false),
            .noMicrophone
        )
        XCTAssertEqual(
            AskPanelWindowController.voiceCaptureRefusal(
                hasMicrophone: true, isRecordingInFlight: false, isTranscribing: true),
            .busy
        )
    }

    /// And the guard is wired in, which no assertion above can see: the shared
    /// recorder is a singleton on real hardware, so the only way to know
    /// `startVoiceCapture` consults it is to read the source. It covers ⌥S and
    /// the **Ask by voice** button too, since all three reach that call.
    func testStartingACaptureConsultsTheSharedRecorder() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")
        let body = try Self.body(of: "private func startVoiceCapture() {", in: controller)

        XCTAssertTrue(body.contains("voiceCaptureRefusal("))
        XCTAssertTrue(body.contains("isRecordingInFlight: isSharedRecorderInFlight"))
        XCTAssertTrue(
            body.contains("guard AudioRecorder.shared.startRecording() else"),
            "the read can go stale, so the recorder's own claim has to be what decides"
        )
        XCTAssertTrue(
            controller.contains("AudioRecorder.shared.hasSessionInFlight"),
            "a press must not seize a dictation that is already recording"
        )
        XCTAssertFalse(
            controller.contains("AudioRecorder.shared.isRecording || AudioRecorder.shared.isConnecting"),
            "those two are published a main-queue hop after the start, so a press lands inside the window they leave open"
        )
    }

    /// The claim belongs to the recorder, not to whoever happens to reach it.
    ///
    /// This is the half the first fix missed. The Ask panel guarded itself and
    /// the dictation keys guarded nothing, so ⌥` pressed while the panel was
    /// listening ran straight into `performStart`, which deletes the recording
    /// in flight and re-points the file - the panel's question destroyed, the
    /// card still saying "Listening…". A rule every caller has to remember is a
    /// rule one of them forgets.
    func testTheRecorderRefusesASecondSessionSoNeitherKeyCanSeizeTheOther() throws {
        let recorder = try Self.source(of: "OpenSuperWhisper/AudioRecorder.swift")
        XCTAssertTrue(
            recorder.contains("func startRecording() -> Bool"),
            "a start that cannot refuse cannot be asked to"
        )
        XCTAssertTrue(try Self.body(of: "func startRecording() -> Bool {", in: recorder)
            .contains("guard claimSession() else"))
        XCTAssertTrue(recorder.contains("var hasSessionInFlight: Bool"))

        let indicator = try Self.source(of: "OpenSuperWhisper/Indicator/IndicatorWindow.swift")
        XCTAssertTrue(
            try Self.body(of: "func startRecording() {", in: indicator)
                .contains("guard recorder.startRecording() else"),
            "a dictation must not start on a recorder the Ask panel is already holding"
        )

        let main = try Self.source(of: "OpenSuperWhisper/ContentView.swift")
        XCTAssertTrue(
            try Self.body(of: "func startRecording() {", in: main)
                .contains("guard recorder.startRecording() else"),
            "the main window's record button reaches the same one recorder"
        )
    }

    func testShortcutRefusesAnActiveDictationBeforePresentingOrCapturingTheScreen() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")

        let voiceBody = try Self.body(of: "func toggleVoiceQuestion() {", in: controller)
        let voiceGuard = try XCTUnwrap(voiceBody.range(of: "isRecordingInFlight: isSharedRecorderInFlight"))
        let voicePresentation = try XCTUnwrap(voiceBody.range(of: "startVoiceQuestion()"))
        XCTAssertLessThan(voiceGuard.lowerBound, voicePresentation.lowerBound)

        let screenBody = try Self.body(of: "func toggleScreenQuery() {", in: controller)
        let screenGuard = try XCTUnwrap(screenBody.range(of: "guard !isSharedRecorderInFlight"))
        let screenCapture = try XCTUnwrap(screenBody.range(of: "startScreenQuery()"))
        XCTAssertLessThan(screenGuard.lowerBound, screenCapture.lowerBound)
    }

    /// A refused press says so - and says it without opening anything.
    ///
    /// Presenting the panel to carry the message would activate this app, and
    /// the dictation the press just declined to seize would then paste into the
    /// panel's own question field: the refusal would cause exactly the damage it
    /// exists to prevent. So a press with no card on screen is a deliberate
    /// no-op, and that is the whole of what this key may do while somebody else
    /// holds the microphone.
    func testARefusedPressReportsOnAnOpenCardAndNeverOpensOne() throws {
        let controller = try Self.source(of: "OpenSuperWhisper/Ask/AskPanelWindowController.swift")
        let body = try Self.body(of: "private func reportRecorderInFlight() {", in: controller)

        XCTAssertTrue(body.contains("shortcutRefused("))
        XCTAssertTrue(body.contains("panel?.isVisible == true"))
        XCTAssertFalse(
            body.contains("present()"),
            "opening a card mid-dictation is the damage the refusal exists to prevent"
        )
    }

    /// And the sentence actually lands, from any state a refused press can find
    /// the panel in - which `voiceCaptureDidFail` cannot do, because it is
    /// guarded on a capture having already begun.
    func testARefusedPressSaysSoWithoutEndingWorkAlreadyInFlight() async {
        let viewModel = AskPanelViewModel { _ in .answered("Taipei.") }
        await viewModel.ask("Where?")

        viewModel.shortcutRefused(
            AskPanelWindowController.VoiceCaptureRefusal.dictationInFlight.message)

        XCTAssertEqual(
            viewModel.state,
            .failed(
                message: "Recording a dictation - finish that first", question: nil))
        XCTAssertEqual(
            viewModel.exchanges.count, 1,
            "the conversation is kept, so the answer is still on the card above the badge")

        // A question the panel is already listening to or thinking about is
        // never ended by a refusal: the press started nothing, and saying so
        // must not cost the user what is running.
        viewModel.startVoiceFollowUp()
        viewModel.shortcutRefused("Recording a dictation - finish that first")
        XCTAssertEqual(viewModel.state, .listening)
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

    /// One function's body, from its signature to the line that closes it.
    ///
    /// Bounded rather than a fixed `prefix`, because these assertions are about
    /// what a *particular* function does: a prefix that overruns into the next
    /// one turns "this guard is here" into "this guard is somewhere nearby",
    /// and the negative assertions - that a refusal never presents the panel -
    /// would be answered by whatever happens to follow it.
    private static func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature), "no function \(signature) to read")
        let rest = source[start.upperBound...]
        // Every function read here is a method, so the line that closes it is
        // the first `}` at one level of indentation.
        let end = rest.range(of: "\n    }\n")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
