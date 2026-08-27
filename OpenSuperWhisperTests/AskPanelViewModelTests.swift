import AppKit
import XCTest
@testable import OpenSuperWhisper

/// The Ask panel's state machine, driven the way the panel drives it.
///
/// The model is injected, so every outcome the real one can produce - including
/// the ones that cannot be requested from a real model, like a timeout - is a
/// plain test case, and the suite runs identically on a Mac with no on-device
/// model at all.
@MainActor
final class AskPanelViewModelTests: XCTestCase {

    /// A model that answers whatever it is told to, and remembers what it was
    /// asked.
    ///
    /// The lock is not decoration: the view model awaits this from the main
    /// actor, so the call itself runs off it.
    private final class StubAnswerer: @unchecked Sendable {
        private let lock = NSLock()
        private let outcomes: [AskOutcome]
        private var received: [AskRequest] = []
        private var index = 0

        init(_ outcomes: [AskOutcome]) {
            self.outcomes = outcomes
        }

        var requests: [AskRequest] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        func answer(_ request: AskRequest) async -> AskOutcome {
            lock.lock()
            defer { lock.unlock() }
            received.append(request)
            defer { index += 1 }
            return outcomes[min(index, outcomes.count - 1)]
        }
    }

    /// A model that does not answer until the test says so, which is the only
    /// way to hold the view model in `.thinking` and see what it does there.
    private final class GatedAnswerer: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var isReleased = false
        private var received = 0

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        func answer(_ request: AskRequest) async -> AskOutcome {
            lock.lock()
            received += 1
            lock.unlock()

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isReleased {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
            return .answered("gated")
        }

        func release() {
            lock.lock()
            isReleased = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private func makeViewModel(_ outcomes: [AskOutcome]) -> (AskPanelViewModel, StubAnswerer) {
        let stub = StubAnswerer(outcomes)
        return (AskPanelViewModel { await stub.answer($0) }, stub)
    }

    // MARK: - The happy path

    func testAskingProducesAnAnswerAndKeepsTheExchange() async {
        let (viewModel, _) = makeViewModel([.answered("Paris.")])
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertFalse(viewModel.canUseAnswer)

        await viewModel.ask("What is the capital of France?")

        XCTAssertEqual(viewModel.answer, "Paris.")
        XCTAssertEqual(viewModel.exchanges.count, 1)
        XCTAssertEqual(viewModel.exchanges.first?.question, "What is the capital of France?")
        XCTAssertEqual(viewModel.exchanges.first?.answer, "Paris.")
        XCTAssertEqual(viewModel.state, .answered(viewModel.exchanges[0]))
        XCTAssertTrue(viewModel.canUseAnswer)
        XCTAssertFalse(viewModel.isBusy)
    }

    func testSubmittingSendsTheDraftAndClearsTheField() async {
        let (viewModel, stub) = makeViewModel([.answered("28 grams.")])
        viewModel.draft = "  How many grams in an ounce?  "
        XCTAssertTrue(viewModel.canSubmitDraft)

        await viewModel.submit()

        XCTAssertEqual(stub.requests.first?.question, "How many grams in an ounce?")
        XCTAssertEqual(viewModel.draft, "")
        XCTAssertFalse(viewModel.canSubmitDraft)
    }

    /// A follow-up is only a follow-up if the model is told what came before.
    func testAFollowUpCarriesTheConversationSoFar() async {
        let (viewModel, stub) = makeViewModel([.answered("Paris."), .answered("2.1 million.")])

        await viewModel.ask("What is the capital of France?")
        await viewModel.ask("And how many people live there?")

        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertTrue(stub.requests[0].history.isEmpty)
        XCTAssertEqual(stub.requests[1].history.count, 1)
        XCTAssertEqual(stub.requests[1].history.first?.answer, "Paris.")
        XCTAssertEqual(viewModel.exchanges.count, 2)
    }

    // MARK: - Which language it is asked in

    /// The question decides, not the app's dictation language - the same
    /// measurement `StyleRewriteLanguage` documents, applied to the other
    /// direction: the model answers in the language it was addressed in.
    func testTheQuestionDecidesWhichLanguageTheModelIsAskedIn() async {
        let (viewModel, stub) = makeViewModel([.answered("好"), .answered("好"), .answered("ok")])

        await viewModel.ask("台北今天天氣如何？")
        await viewModel.ask("上海今天天气如何？")
        await viewModel.ask("What is the weather in Taipei?")

        XCTAssertEqual(stub.requests[0].language, .chinese(.traditional))
        XCTAssertEqual(stub.requests[1].language, .chinese(.simplified))
        XCTAssertEqual(stub.requests[2].language, .other)
    }

    // MARK: - Every way it can fail

    func testAnUnavailableModelIsExplainedRatherThanSwallowed() async {
        let (viewModel, _) = makeViewModel([.unavailable(.appleIntelligenceOff)])

        await viewModel.ask("Anything")

        // Named for the panel the user is looking at, not for rewriting: they
        // pressed ⌥A and rewriting is not what they were trying to use.
        XCTAssertEqual(
            viewModel.state,
            .failed(
                message: StyleRewriteAvailability.appleIntelligenceOff.explanation(for: .ask),
                question: "Anything"
            )
        )
        XCTAssertTrue(
            StyleRewriteAvailability.appleIntelligenceOff.explanation(for: .ask)
                .contains("the Ask panel")
        )
        XCTAssertNil(viewModel.answer)
        XCTAssertFalse(viewModel.canUseAnswer)
        XCTAssertTrue(viewModel.exchanges.isEmpty)
    }

    func testEveryOtherOutcomeReachesTheUserAsASentence() async {
        for outcome in [AskOutcome.timedOut, .empty, .questionTooLong, .failed("model exploded")] {
            let (viewModel, _) = makeViewModel([outcome])
            await viewModel.ask("Anything")
            XCTAssertEqual(
                viewModel.state,
                .failed(message: outcome.explanation ?? "", question: "Anything"),
                "\(outcome)")
            XCTAssertTrue(viewModel.exchanges.isEmpty, "\(outcome)")
        }
    }

    /// A blank question is refused rather than sent: an empty prompt does not
    /// get a neutral answer from a language model, it gets an arbitrary one.
    func testABlankQuestionIsNeverSentToTheModel() async {
        let (viewModel, stub) = makeViewModel([.answered("should not happen")])

        await viewModel.ask("   \n ")

        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(
            viewModel.state,
            .failed(message: AskOutcome.nothingAsked.explanation ?? "", question: nil))
    }

    func testASecondQuestionIsRefusedWhileOneIsInFlight() async {
        let gate = GatedAnswerer()
        let viewModel = AskPanelViewModel { await gate.answer($0) }
        let asking = Task { await viewModel.ask("first") }
        await waitUntilBusy(viewModel)
        XCTAssertEqual(viewModel.state, .thinking(question: "first"))

        await viewModel.ask("second")
        XCTAssertEqual(viewModel.state, .thinking(question: "first"))

        gate.release()
        await asking.value

        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertEqual(viewModel.exchanges.map(\.question), ["first"])
    }

    // MARK: - The answer belongs to the question that asked for it

    /// The panel can be closed or reset while the model is still working, and a
    /// late answer must not land on top of whatever replaced it.
    func testAnAnswerArrivingAfterAResetIsDropped() async {
        let gate = GatedAnswerer()
        let viewModel = AskPanelViewModel { await gate.answer($0) }
        let asking = Task { await viewModel.ask("What is the capital of France?") }
        await waitUntilBusy(viewModel)

        viewModel.reset()
        gate.release()
        await asking.value

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.exchanges.isEmpty)
        XCTAssertNil(viewModel.answer)
    }

    /// `ask` moves into `.thinking` before it awaits the model, so yielding
    /// until the view model is busy is enough to be sure the request is away.
    private func waitUntilBusy(
        _ viewModel: AskPanelViewModel, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0 ..< 1000 where !viewModel.isBusy {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isBusy, "the view model never started working", file: file, line: line)
    }

    func testClosingClearsTheConversationAndTellsTheController() async {
        let (viewModel, _) = makeViewModel([.answered("Paris.")])
        var closed = false
        viewModel.onClose = { closed = true }

        await viewModel.ask("What is the capital of France?")
        viewModel.draft = "half typed"
        viewModel.close()

        XCTAssertTrue(closed)
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.draft, "")
        XCTAssertTrue(viewModel.exchanges.isEmpty)
    }

    // MARK: - Copy and insert

    func testCopyAndInsertHandOutExactlyTheAnswerOnScreen() async {
        let (viewModel, _) = makeViewModel([.answered("Paris.")])
        var copied: String?
        var inserted: String?
        viewModel.onCopy = { copied = $0 }
        viewModel.onInsert = { inserted = $0 }

        await viewModel.ask("What is the capital of France?")
        viewModel.copyAnswer()
        viewModel.insertAnswer()

        XCTAssertEqual(copied, "Paris.")
        XCTAssertEqual(inserted, "Paris.")
    }

    /// Nothing leaves the panel when there is nothing to send. Both actions are
    /// disabled in the UI on `canUseAnswer`; this is the rule underneath it.
    func testCopyAndInsertDoNothingWithoutAnAnswer() async {
        let (viewModel, _) = makeViewModel([.timedOut])
        var handedOut: [String] = []
        viewModel.onCopy = { handedOut.append($0) }
        viewModel.onInsert = { handedOut.append($0) }

        viewModel.copyAnswer()
        viewModel.insertAnswer()
        await viewModel.ask("Anything")
        viewModel.copyAnswer()
        viewModel.insertAnswer()

        XCTAssertTrue(handedOut.isEmpty)
    }

    // MARK: - Voice follow-up

    func testAVoiceFollowUpRunsThroughToAnAnswer() async {
        let (viewModel, stub) = makeViewModel([.answered("Sunny.")])
        var started = 0
        var finished = 0
        viewModel.onStartVoiceCapture = { started += 1 }
        viewModel.onFinishVoiceCapture = { finished += 1 }

        viewModel.startVoiceFollowUp()
        XCTAssertEqual(viewModel.state, .listening)
        XCTAssertEqual(started, 1)
        XCTAssertTrue(viewModel.isBusy)

        viewModel.finishVoiceFollowUp()
        XCTAssertEqual(viewModel.state, .transcribing)
        XCTAssertEqual(finished, 1)

        await viewModel.voiceCaptureDidProduce("What is the weather like?")

        XCTAssertEqual(stub.requests.first?.question, "What is the weather like?")
        XCTAssertEqual(viewModel.answer, "Sunny.")
    }

    /// "Say that again" and "this Mac cannot answer" are different things to be
    /// told, so a silent recording is its own message rather than an empty
    /// question.
    func testASilentFollowUpSaysSoAndAsksNothing() async {
        let (viewModel, stub) = makeViewModel([.answered("should not happen")])

        viewModel.startVoiceFollowUp()
        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("   ")

        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(viewModel.state, .failed(message: "No speech detected", question: nil))
    }

    func testCancellingAFollowUpKeepsTheAnswerAlreadyOnScreen() async {
        let (viewModel, _) = makeViewModel([.answered("Paris.")])
        var cancelled = 0
        viewModel.onCancelVoiceCapture = { cancelled += 1 }

        await viewModel.ask("What is the capital of France?")
        viewModel.startVoiceFollowUp()
        viewModel.cancelVoiceFollowUp()

        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(viewModel.state, .answered(viewModel.exchanges[0]))
        XCTAssertEqual(viewModel.answer, "Paris.")
    }

    func testCancellingAFollowUpFromAnEmptyPanelGoesBackToIdle() {
        let (viewModel, _) = makeViewModel([.answered("unused")])

        viewModel.startVoiceFollowUp()
        viewModel.cancelVoiceFollowUp()

        XCTAssertEqual(viewModel.state, .idle)
    }

    /// A capture the user has already thrown away must not reopen the spinner
    /// when its late result arrives.
    func testAFollowUpResultArrivingAfterCancellationIsIgnored() async {
        let (viewModel, stub) = makeViewModel([.answered("should not happen")])

        viewModel.startVoiceFollowUp()
        viewModel.cancelVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("late transcript")
        viewModel.voiceCaptureDidFail("late failure")

        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testAFollowUpIsRefusedWhileTheModelIsWorking() async {
        let gate = GatedAnswerer()
        let viewModel = AskPanelViewModel { await gate.answer($0) }
        var started = 0
        viewModel.onStartVoiceCapture = { started += 1 }

        let asking = Task { await viewModel.ask("in flight") }
        await waitUntilBusy(viewModel)
        viewModel.startVoiceFollowUp()

        XCTAssertEqual(started, 0)
        XCTAssertEqual(viewModel.state, .thinking(question: "in flight"))

        gate.release()
        await asking.value
    }

    func testASecondFollowUpIsRefusedWhileOneIsRecording() {
        let (viewModel, _) = makeViewModel([.answered("unused")])
        var started = 0
        viewModel.onStartVoiceCapture = { started += 1 }

        viewModel.startVoiceFollowUp()
        viewModel.startVoiceFollowUp()

        XCTAssertEqual(started, 1)
        XCTAssertEqual(viewModel.state, .listening)
    }

    func testAFailedCaptureIsExplained() {
        let (viewModel, _) = makeViewModel([.answered("unused")])

        viewModel.startVoiceFollowUp()
        viewModel.voiceCaptureDidFail("No microphone")

        XCTAssertEqual(viewModel.state, .failed(message: "No microphone", question: nil))
        XCTAssertFalse(viewModel.isBusy)
    }

    // MARK: - The service's own rules

    func testTheServiceRefusesToAskWithoutAModel() async {
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"),
            availability: .deviceNotEligible,
            answerer: nil
        )
        XCTAssertEqual(outcome, .unavailable(.deviceNotEligible))
    }

    /// Availability and the model are resolved separately, and it can become
    /// unavailable between the two.
    func testAMissingModelOnAnEligibleMacReadsAsNotReady() async {
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"), availability: .available, answerer: nil
        )
        XCTAssertEqual(outcome, .unavailable(.modelNotReady))
    }

    func testTheServiceRefusesABlankOrOverlongQuestionBeforeTheModel() async {
        let blank = await AskService.answer(
            AskRequest(question: "  "), availability: .available, answerer: NeverAnswers()
        )
        XCTAssertEqual(blank, .nothingAsked)

        let long = String(repeating: "x", count: AskService.maximumQuestionCharacters + 1)
        let overlong = await AskService.answer(
            AskRequest(question: long), availability: .available, answerer: NeverAnswers()
        )
        XCTAssertEqual(overlong, .questionTooLong)
    }

    func testAnEmptyAnswerIsReportedRatherThanShown() async {
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"),
            availability: .available,
            answerer: FixedAnswerer(" \n ")
        )
        XCTAssertEqual(outcome, .empty)
    }

    func testAnAnswerIsTrimmed() async {
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"),
            availability: .available,
            answerer: FixedAnswerer("\n  Paris.  \n")
        )
        XCTAssertEqual(outcome, .answered("Paris."))
    }

    /// The budget is a hard ceiling, not a suggestion: a model that never
    /// returns still costs the user only the budget. See `AsyncDeadline`.
    func testTheDeadlineHoldsAgainstAModelThatNeverReturns() async {
        let started = Date()
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"),
            availability: .available,
            answerer: NeverAnswers(),
            budgetOverride: 0.1
        )
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAThrowingModelIsReportedWithItsOwnMessage() async {
        let outcome = await AskService.answer(
            AskRequest(question: "Anything"),
            availability: .available,
            answerer: ThrowingAnswerer()
        )
        guard case .failed = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
    }

    /// A conversation in a long-lived panel must not rebuild the overrun
    /// `maximumQuestionCharacters` exists to prevent, so only the most recent
    /// exchanges are written into the prompt.
    func testOnlyTheMostRecentExchangesAreWrittenIntoThePrompt() {
        let history = (1 ... AskService.maximumHistoryExchanges + 3).map {
            AskExchange(question: "question \($0)", answer: "answer \($0)")
        }

        let prompt = AskPrompt.prompt(for: AskRequest(question: "latest", history: history))

        let oldestKept = history.count - AskService.maximumHistoryExchanges + 1
        XCTAssertFalse(prompt.contains("question \(oldestKept - 1)"))
        XCTAssertTrue(prompt.contains("question \(oldestKept)"))
        XCTAssertTrue(prompt.contains("question \(history.count)"))
        XCTAssertTrue(prompt.hasSuffix("Q: latest"))
    }

    // MARK: - Where Insert would paste

    /// This app itself is never a target: a panel opened from EchoForge's own
    /// window must fall back to the clipboard, not inherit whichever app an
    /// earlier presentation was over.
    func testTheInsertionTargetIsNeverThisAppItself() {
        let current = NSRunningApplication.current

        XCTAssertNil(
            AskPanelWindowController.capturedInsertionTarget(
                frontmost: current, ownBundleIdentifier: current.bundleIdentifier
            )
        )
        XCTAssertEqual(
            AskPanelWindowController.capturedInsertionTarget(
                frontmost: current, ownBundleIdentifier: "another.app.entirely"
            ),
            current
        )
        XCTAssertNil(
            AskPanelWindowController.capturedInsertionTarget(
                frontmost: nil, ownBundleIdentifier: current.bundleIdentifier
            )
        )
    }

    /// The remembered target lives only as long as the presentation.
    func testHidingThePanelForgetsTheInsertionTarget() {
        let controller = AskPanelWindowController.shared
        controller.insertionTarget = NSRunningApplication.current

        controller.hide()

        XCTAssertNil(controller.insertionTarget)
    }

    // MARK: - Stub models

    private struct FixedAnswerer: AskAnswering {
        let output: String
        init(_ output: String) { self.output = output }
        func answer(_ request: AskRequest) async throws -> String { output }
    }

    private struct NeverAnswers: AskAnswering {
        func answer(_ request: AskRequest) async throws -> String {
            // Deliberately not cancellation-aware: the deadline has to hold
            // against a model that ignores cancellation, which is the case
            // `AsyncDeadline` exists for.
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return "far too late"
        }
    }

    private struct ThrowingAnswerer: AskAnswering {
        struct Failure: Error {}
        func answer(_ request: AskRequest) async throws -> String { throw Failure() }
    }
}

/// The settings a voice follow-up is transcribed with, stated against
/// preferences that would restyle or route a live dictation.
final class AskPanelFollowUpSettingsTests: IsolatedPreferencesTestCase {

    /// A follow-up is a question for the panel: never routed - it must not
    /// reopen the panel it came from - and never restyled, because restyling a
    /// question on its way to the model that is about to answer it changes what
    /// was asked. Only the model-backed stage is withheld; the deterministic
    /// stages keep their own preferences.
    @MainActor
    func testAFollowUpIsNeverRoutedAndNeverRestyled() {
        let preferences = AppPreferences.shared
        preferences.spokenIntentsEnabled = true
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = StyleRewriteCatalog.defaultStyleID

        let settings = AskPanelWindowController.followUpTranscriptionSettings()

        XCTAssertFalse(settings.routesSpokenIntents)
        XCTAssertFalse(settings.styleRewrite.isRunnable)
        // The same preferences would restyle a live dictation, so the pin - not
        // the preference - is what turns the follow-up's rewrite off.
        XCTAssertTrue(Settings(routesSpokenIntents: true).styleRewrite.isRunnable)
    }
}
