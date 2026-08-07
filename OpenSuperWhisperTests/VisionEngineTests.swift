import CoreGraphics
import Foundation
import XCTest

@testable import OpenSuperWhisper

/// Everything a screen query decides between the screenshot and the answer: how
/// large the image gets, what the model is actually told, and how the Ask panel
/// carries a picture through a conversation.
///
/// Both halves of the engine are injected, so none of it needs an on-device
/// model, a window server or a Screen Recording grant. What stays uncovered is
/// `VisionTextRecognizer`'s call into the Vision framework and the
/// `FoundationModels` session `VisionEngineFactory` builds.
final class VisionEngineTests: XCTestCase {

    // MARK: - How large the model's copy is

    func testAnImageInsideTheCapIsNeverEnlarged() {
        let small = CGSize(width: 640, height: 400)
        XCTAssertEqual(ScreenshotDownscale.fittedSize(for: small), small)

        let exactly = CGSize(width: ScreenshotDownscale.maximumDimension, height: 400)
        XCTAssertEqual(ScreenshotDownscale.fittedSize(for: exactly), exactly)
    }

    func testTheLongestEdgeIsCappedAndTheAspectRatioIsKept() {
        let retinaWindow = CGSize(width: 3024, height: 1890)

        let fitted = ScreenshotDownscale.fittedSize(for: retinaWindow)

        XCTAssertEqual(max(fitted.width, fitted.height), ScreenshotDownscale.maximumDimension)
        XCTAssertEqual(
            fitted.width / fitted.height,
            retinaWindow.width / retinaWindow.height,
            accuracy: 0.01
        )

        // Portrait is the same rule read the other way round.
        let tall = ScreenshotDownscale.fittedSize(for: CGSize(width: 1200, height: 4000))
        XCTAssertEqual(tall.height, ScreenshotDownscale.maximumDimension)
        XCTAssertLessThan(tall.width, tall.height)
    }

    /// A 4000×1 strip would otherwise round to a zero-height image, which no
    /// drawing context accepts.
    func testAnExtremeAspectRatioStillHasAPixelInEachDirection() {
        let strip = ScreenshotDownscale.fittedSize(for: CGSize(width: 4000, height: 1))

        XCTAssertEqual(strip.width, ScreenshotDownscale.maximumDimension)
        XCTAssertGreaterThanOrEqual(strip.height, 1)
    }

    func testADegenerateSizeIsRefusedRatherThanDividedBy() {
        XCTAssertEqual(ScreenshotDownscale.fittedSize(for: .zero), .zero)
        XCTAssertEqual(ScreenshotDownscale.fittedSize(for: CGSize(width: 100, height: 0)), .zero)
        XCTAssertEqual(
            ScreenshotDownscale.fittedSize(for: CGSize(width: 100, height: 100), maximumDimension: 0),
            .zero
        )
    }

    func testTheCapCanBeToldWhereItIs() {
        let fitted = ScreenshotDownscale.fittedSize(
            for: CGSize(width: 800, height: 600), maximumDimension: 400
        )
        XCTAssertEqual(fitted, CGSize(width: 400, height: 300))
    }

    func testAnOversizedImageIsActuallyRedrawnSmaller() {
        let image = Self.makeImage(width: 2400, height: 1200)

        let downscaled = ScreenshotDownscale.downscaled(image)

        XCTAssertEqual(downscaled.width, Int(ScreenshotDownscale.maximumDimension))
        XCTAssertEqual(downscaled.height, Int(ScreenshotDownscale.maximumDimension / 2))
    }

    func testAnImageAlreadyInsideTheCapIsHandedBackUntouched() {
        let image = Self.makeImage(width: 800, height: 600)

        let downscaled = ScreenshotDownscale.downscaled(image)

        XCTAssertTrue(downscaled === image)
    }

    // MARK: - Reading the screen in the order it is written

    /// Vision returns observations in no guaranteed order, and a model handed a
    /// shuffled invoice answers confidently about the wrong number.
    func testTextIsOrderedTopToBottomThenLeftToRight() {
        // Vision's origin is bottom-left, so a larger y is higher on screen.
        let lines = [
            ScreenTextLine(text: "total", boundingBox: CGRect(x: 0.1, y: 0.20, width: 0.2, height: 0.05)),
            ScreenTextLine(text: "Invoice", boundingBox: CGRect(x: 0.1, y: 0.90, width: 0.3, height: 0.05)),
            ScreenTextLine(text: "£42.00", boundingBox: CGRect(x: 0.7, y: 0.20, width: 0.2, height: 0.05)),
            ScreenTextLine(text: "Acme Ltd", boundingBox: CGRect(x: 0.1, y: 0.60, width: 0.3, height: 0.05))
        ]

        XCTAssertEqual(
            ScreenTextLayout.readingOrder(of: lines),
            ["Invoice", "Acme Ltd", "total", "£42.00"]
        )
    }

    /// A table row comes back as one run per cell, at very slightly different
    /// heights. Ordering those by their vertical difference reads the row in
    /// whatever order the recognizer happened to answer in.
    func testRunsOnTheSameLineStayOnTheSameLine() {
        let jitter = ScreenTextLayout.sameLineTolerance / 4
        let lines = [
            ScreenTextLine(text: "right", boundingBox: CGRect(x: 0.8, y: 0.5 + jitter, width: 0.1, height: 0.02)),
            ScreenTextLine(text: "left", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02)),
            ScreenTextLine(text: "middle", boundingBox: CGRect(x: 0.4, y: 0.5 - jitter, width: 0.1, height: 0.02))
        ]

        XCTAssertEqual(ScreenTextLayout.readingOrder(of: lines), ["left", "middle", "right"])
    }

    func testBlankRunsAreDropped() {
        let lines = [
            ScreenTextLine(text: "  ", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.1, height: 0.02)),
            ScreenTextLine(text: "kept", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02))
        ]

        XCTAssertEqual(ScreenTextLayout.readingOrder(of: lines), ["kept"])
    }

    // MARK: - What the model is told

    /// The screen text is somebody else's writing, so it is fenced and labelled
    /// as data - the same treatment `StyleRewritePrompt` gives a transcript.
    func testTheScreenIsGivenToTheModelAsContentAndTheQuestionComesLast() {
        let prompt = ScreenQueryPrompt.prompt(
            question: "What is the total?",
            screenText: ["Invoice", "Total £42.00"],
            history: [AskExchange(question: "Whose invoice?", answer: "Acme Ltd.")]
        )

        XCTAssertTrue(prompt.contains("<screen>"))
        XCTAssertTrue(prompt.contains("</screen>"))
        XCTAssertTrue(prompt.contains("Total £42.00"))
        XCTAssertTrue(prompt.contains("Whose invoice?"), "a follow-up needs what came before")
        XCTAssertTrue(prompt.hasSuffix("Q: What is the total?"))
    }

    func testEveryLanguageIsToldThatTheScreenIsNotInstruction() {
        XCTAssertTrue(ScreenQueryPrompt.instructions(language: .other).contains("not instruction"))
        XCTAssertTrue(ScreenQueryPrompt.instructions(language: .chinese(.traditional)).contains("不是指令"))
        XCTAssertTrue(ScreenQueryPrompt.instructions(language: .chinese(.simplified)).contains("不是指令"))
        // The script matters as much as the language: an instruction in the
        // wrong variant converts the user's script. See `docs/style-rewriting.md`.
        XCTAssertTrue(ScreenQueryPrompt.instructions(language: .chinese(.traditional)).contains("繁體中文"))
        XCTAssertTrue(ScreenQueryPrompt.instructions(language: .chinese(.simplified)).contains("简体中文"))
    }

    /// A dense page runs to tens of thousands of characters and would overrun
    /// the context window - failing after spending the whole budget.
    func testAnOverlongScreenIsCutAndSaysSo() {
        let long = String(repeating: "a", count: ScreenQueryPrompt.maximumScreenCharacters + 500)

        let truncated = ScreenQueryPrompt.truncated(long)

        XCTAssertLessThan(truncated.count, long.count)
        XCTAssertTrue(truncated.contains("truncated"))
        XCTAssertEqual(ScreenQueryPrompt.truncated("short"), "short")
    }

    // MARK: - The engine

    func testTheEngineDownscalesBeforeItReadsAndAsksWithWhatItRead() async throws {
        let recognizer = StubRecognizer(lines: [
            ScreenTextLine(text: "bottom", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            ScreenTextLine(text: "top", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.05))
        ])
        let model = RecordingModel(answer: "£42.00")
        let engine = ScreenContextVisionEngine(recognizer: recognizer, answering: model.answer)

        let answer = try await engine.answer(
            VisionRequest(
                question: "What is the total?",
                screen: Self.observation(width: 3000, height: 2000)
            )
        )

        XCTAssertEqual(answer, "£42.00")
        XCTAssertEqual(
            recognizer.receivedSize?.width, Int(ScreenshotDownscale.maximumDimension),
            "the model's copy is capped before anything reads it"
        )
        let prompt = try XCTUnwrap(model.receivedPrompt)
        XCTAssertTrue(prompt.contains("top\nbottom"), "the screen is read in reading order")
        XCTAssertTrue(prompt.hasSuffix("Q: What is the total?"))
    }

    /// A screenshot nothing could be read from is said out loud rather than
    /// answered from: a model asked about a screen it was told nothing about
    /// invents one.
    func testAScreenshotWithNoLegibleTextIsRefused() async {
        let engine = ScreenContextVisionEngine(
            recognizer: StubRecognizer(lines: []),
            answering: RecordingModel(answer: "should not happen").answer
        )

        do {
            _ = try await engine.answer(
                VisionRequest(question: "What is this?", screen: Self.observation())
            )
            XCTFail("an unreadable screenshot has to be reported")
        } catch let error as VisionEngineError {
            XCTAssertEqual(error, .nothingLegible)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTheModelIsAddressedInTheLanguageOfTheQuestion() async throws {
        let model = RecordingModel(answer: "好")
        let engine = ScreenContextVisionEngine(
            recognizer: StubRecognizer(lines: [
                ScreenTextLine(text: "發票", boundingBox: CGRect(x: 0, y: 0.5, width: 0.2, height: 0.05))
            ]),
            answering: model.answer
        )

        _ = try await engine.answer(
            VisionRequest(question: "這張畫面上的總金額是多少？", screen: Self.observation())
        )

        XCTAssertEqual(model.receivedLanguage, .chinese(.traditional))
    }

    // MARK: - Routing: a question about a screen is never answered without it

    func testAQuestionCarryingAScreenshotGoesToTheVisionEngine() async {
        let vision = StubVisionEngine(answer: "A spreadsheet.")
        let plain = ShouldNotAnswer()

        let outcome = await AskService.answer(
            AskRequest(question: "What am I looking at?", screen: Self.observation()),
            availability: .available,
            answerer: plain,
            vision: vision
        )

        XCTAssertEqual(outcome, .answered("A spreadsheet."))
        XCTAssertEqual(vision.requestCount, 1)
    }

    func testAQuestionWithoutAScreenshotNeverReachesTheVisionEngine() async {
        let vision = StubVisionEngine(answer: "should not happen")

        let outcome = await AskService.answer(
            AskRequest(question: "What is the capital of France?"),
            availability: .available,
            answerer: FixedAnswerer("Paris."),
            vision: vision
        )

        XCTAssertEqual(outcome, .answered("Paris."))
        XCTAssertEqual(vision.requestCount, 0)
    }

    /// Answering from the words alone would be a confident reply about a screen
    /// nothing ever looked at.
    func testAScreenQueryWithNoVisionEngineIsRefusedRatherThanAnsweredBlind() async {
        let outcome = await AskService.answer(
            AskRequest(question: "What is on my screen?", screen: Self.observation()),
            availability: .available,
            answerer: FixedAnswerer("I cannot see it, but probably a browser."),
            vision: nil
        )

        XCTAssertEqual(outcome, .unavailable(.modelNotReady))
    }

    func testTheDeadlineHoldsOverAVisionEngineThatNeverReturns() async {
        let started = Date()

        let outcome = await AskService.answer(
            AskRequest(question: "What is on my screen?", screen: Self.observation()),
            availability: .available,
            answerer: nil,
            vision: NeverAnswersVision(),
            budgetOverride: 0.1
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAnUnreadableScreenReachesTheUserAsASentence() async {
        let outcome = await AskService.answer(
            AskRequest(question: "What is on my screen?", screen: Self.observation()),
            availability: .available,
            answerer: nil,
            vision: ThrowingVisionEngine(error: .nothingLegible)
        )

        XCTAssertEqual(outcome, .failed(VisionEngineError.nothingLegible.message))
    }

    // MARK: - Fixtures

    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func observation(width: Int = 400, height: Int = 300) -> ScreenObservation {
        ScreenObservation(
            image: makeImage(width: width, height: height),
            source: .window(applicationName: "Numbers", title: "Invoice")
        )
    }
}

// MARK: - Stubs

private final class StubRecognizer: ScreenTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let lines: [ScreenTextLine]
    private var received: (width: Int, height: Int)?

    init(lines: [ScreenTextLine]) {
        self.lines = lines
    }

    var receivedSize: (width: Int, height: Int)? {
        lock.withLock { received }
    }

    func recognizeText(in image: CGImage) async throws -> [ScreenTextLine] {
        lock.withLock { received = (image.width, image.height) }
        return lines
    }
}

/// The language model half of the engine, which remembers what it was given.
private final class RecordingModel: @unchecked Sendable {
    private let lock = NSLock()
    private let answerText: String
    private var prompt: String?
    private var language: StyleRewriteLanguage?

    init(answer: String) {
        self.answerText = answer
    }

    var receivedPrompt: String? { lock.withLock { prompt } }
    var receivedLanguage: StyleRewriteLanguage? { lock.withLock { language } }

    @Sendable
    func answer(_ prompt: String, _ language: StyleRewriteLanguage) async throws -> String {
        lock.withLock {
            self.prompt = prompt
            self.language = language
        }
        return answerText
    }
}

private final class StubVisionEngine: VisionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let answerText: String
    private var received = 0

    init(answer: String) {
        self.answerText = answer
    }

    var requestCount: Int { lock.withLock { received } }

    func answer(_ request: VisionRequest) async throws -> String {
        lock.withLock { received += 1 }
        return answerText
    }
}

private struct ThrowingVisionEngine: VisionEngine {
    let error: VisionEngineError
    func answer(_ request: VisionRequest) async throws -> String { throw error }
}

private struct NeverAnswersVision: VisionEngine {
    func answer(_ request: VisionRequest) async throws -> String {
        // Deliberately not cancellation-aware: the deadline has to hold against
        // work that ignores cancellation. See `AsyncDeadline`.
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return "far too late"
    }
}

private struct FixedAnswerer: AskAnswering {
    let output: String
    init(_ output: String) { self.output = output }
    func answer(_ request: AskRequest) async throws -> String { output }
}

private struct ShouldNotAnswer: AskAnswering {
    func answer(_ request: AskRequest) async throws -> String {
        XCTFail("a question about a screenshot must not be answered by the plain answerer")
        return ""
    }
}

/// The Ask panel with a screenshot attached to a question: what it shows, what
/// it hands the model, and the rule that keeps a screenshot from following the
/// user into their next question.
@MainActor
final class AskPanelScreenQueryTests: XCTestCase {

    private final class StubAnswerer: @unchecked Sendable {
        private let lock = NSLock()
        private let outcome: AskOutcome
        private var received: [AskRequest] = []

        init(_ outcome: AskOutcome) {
            self.outcome = outcome
        }

        var requests: [AskRequest] { lock.withLock { received } }

        func answer(_ request: AskRequest) async -> AskOutcome {
            lock.withLock { received.append(request) }
            return outcome
        }
    }

    private func makeViewModel(_ outcome: AskOutcome) -> (AskPanelViewModel, StubAnswerer) {
        let stub = StubAnswerer(outcome)
        return (AskPanelViewModel { await stub.answer($0) }, stub)
    }

    /// Runs the ask task until the view model reaches `state`, bounded so a
    /// regression fails instead of hanging the suite.
    private func yieldUntil(_ viewModel: AskPanelViewModel, reaches state: AskPanelState) async {
        for _ in 0..<1000 where viewModel.state != state {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.state, state)
    }

    func testAScreenQueryRunsFromTheShortcutThroughToAnAnsweredExchange() async {
        let (viewModel, stub) = makeViewModel(.answered("A spreadsheet of invoices."))
        var started = 0
        viewModel.onStartVoiceCapture = { started += 1 }
        let screen = VisionEngineTests.observation()

        let token = viewModel.startScreenQuery()
        XCTAssertNotNil(token)
        XCTAssertEqual(viewModel.state, .listening)
        XCTAssertTrue(viewModel.isScreenQuery)
        XCTAssertEqual(started, 1, "the microphone starts with the screenshot, not after it")

        viewModel.attachScreen(screen, token: token)
        XCTAssertEqual(viewModel.pendingScreen, screen)

        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("What am I looking at?")

        XCTAssertEqual(stub.requests.first?.screen, screen, "the model is asked about the screenshot")
        XCTAssertEqual(viewModel.exchanges.first?.screen, screen, "the badge stays with the exchange")
        XCTAssertEqual(viewModel.answer, "A spreadsheet of invoices.")
        XCTAssertNil(viewModel.pendingScreen)
        XCTAssertFalse(viewModel.isScreenQuery)
    }

    /// The capture races the user's own speech, and can lose: a transcript that
    /// arrives first waits for the screenshot instead of asking without it - a
    /// screen query is never answered blind.
    func testATranscriptThatBeatsTheScreenshotWaitsForItInsteadOfAskingBlind() async {
        let (viewModel, stub) = makeViewModel(.answered("A spreadsheet."))
        let screen = VisionEngineTests.observation()
        let token = viewModel.startScreenQuery()
        viewModel.finishVoiceFollowUp()

        let asking = Task { await viewModel.voiceCaptureDidProduce("What am I looking at?") }
        await yieldUntil(viewModel, reaches: .thinking(question: "What am I looking at?"))
        XCTAssertTrue(stub.requests.isEmpty, "the question must not be sent before the screenshot")

        viewModel.attachScreen(screen, token: token)
        await asking.value

        XCTAssertEqual(stub.requests.first?.screen, screen)
        XCTAssertEqual(viewModel.answer, "A spreadsheet.")
        XCTAssertEqual(viewModel.exchanges.first?.screen, screen)
    }

    /// A capture that fails after the question was already transcribed fails
    /// the query the same way a failure during recording does, instead of being
    /// swallowed while the question is answered blind.
    func testACaptureFailureAfterTheTranscriptFailsTheQueryInsteadOfAskingBlind() async {
        let (viewModel, stub) = makeViewModel(.answered("should not happen"))
        let token = viewModel.startScreenQuery()
        viewModel.finishVoiceFollowUp()

        let asking = Task { await viewModel.voiceCaptureDidProduce("What am I looking at?") }
        await yieldUntil(viewModel, reaches: .thinking(question: "What am I looking at?"))

        viewModel.screenCaptureDidFail(ScreenCaptureError.nothingToCapture.message, token: token)
        await asking.value

        XCTAssertEqual(viewModel.state, .failed(ScreenCaptureError.nothingToCapture.message))
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertFalse(viewModel.isScreenQuery)
        XCTAssertNil(viewModel.pendingScreen)
    }

    /// A capture that never resolves at all cannot hang the panel: the wait has
    /// its own budget, and running it out fails the query with a sentence.
    func testAWedgedCaptureFailsTheQueryInsideItsBudget() async {
        let (viewModel, stub) = makeViewModel(.answered("should not happen"))
        viewModel.captureWaitBudget = 0.05
        viewModel.startScreenQuery()
        viewModel.finishVoiceFollowUp()

        await viewModel.voiceCaptureDidProduce("What am I looking at?")

        XCTAssertEqual(viewModel.state, .failed(AskPanelViewModel.captureTimedOutMessage))
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertFalse(viewModel.isScreenQuery)
    }

    /// Closing the panel while a question is waiting on its screenshot abandons
    /// the wait with everything else instead of leaving the ask suspended.
    func testClosingThePanelWhileAQuestionWaitsForItsScreenshotAbandonsIt() async {
        let (viewModel, stub) = makeViewModel(.answered("should not happen"))
        viewModel.startScreenQuery()
        viewModel.finishVoiceFollowUp()

        let asking = Task { await viewModel.voiceCaptureDidProduce("What is this?") }
        await yieldUntil(viewModel, reaches: .thinking(question: "What is this?"))

        viewModel.close()
        await asking.value

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// A typed question is about nothing but its words - a screenshot that
    /// silently followed the user into the next question would be answering
    /// about a window they had moved on from.
    func testAScreenshotIsUsedOnceAndNeverFollowsTheNextQuestion() async {
        let (viewModel, stub) = makeViewModel(.answered("Something."))

        let token = viewModel.startScreenQuery()
        viewModel.attachScreen(VisionEngineTests.observation(), token: token)
        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("What is this?")
        await viewModel.ask("And what is the capital of France?")

        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNotNil(stub.requests[0].screen)
        XCTAssertNil(stub.requests[1].screen)
    }

    /// A capture that lands after the user threw the query away belongs to
    /// nothing.
    func testAScreenshotArrivingAfterCancellationIsDropped() async {
        let (viewModel, stub) = makeViewModel(.answered("should not happen"))

        let token = viewModel.startScreenQuery()
        viewModel.cancelVoiceFollowUp()
        viewModel.attachScreen(VisionEngineTests.observation(), token: token)

        XCTAssertNil(viewModel.pendingScreen)
        XCTAssertFalse(viewModel.isScreenQuery)
        XCTAssertEqual(viewModel.state, .idle)

        await viewModel.ask("A plain question")
        XCTAssertNil(stub.requests.first?.screen)
    }

    /// The delivery is keyed to the query that started the capture, not to how
    /// the panel happens to look: a follow-up the user starts after abandoning
    /// a screen query is listening again, and the abandoned query's capture
    /// must neither attach to it nor cancel it.
    func testAStaleCaptureCannotHijackAnUnrelatedVoiceFollowUp() async {
        let (viewModel, stub) = makeViewModel(.answered("Paris."))
        var cancelled = 0
        viewModel.onCancelVoiceCapture = { cancelled += 1 }
        let token = viewModel.startScreenQuery()
        viewModel.cancelVoiceFollowUp()
        XCTAssertEqual(cancelled, 1)

        viewModel.startVoiceFollowUp()
        XCTAssertEqual(viewModel.state, .listening)

        viewModel.attachScreen(VisionEngineTests.observation(), token: token)
        XCTAssertNil(viewModel.pendingScreen, "a capture from an abandoned query must not attach")

        viewModel.screenCaptureDidFail("boom", token: token)
        XCTAssertEqual(viewModel.state, .listening, "a stale failure must not cancel the follow-up")
        XCTAssertEqual(cancelled, 1)

        viewModel.finishVoiceFollowUp()
        await viewModel.voiceCaptureDidProduce("What is the capital of France?")

        XCTAssertNil(stub.requests.first?.screen)
        XCTAssertEqual(viewModel.answer, "Paris.")
    }

    /// The user asked about their screen. Without the screenshot there is no
    /// question left to answer, so the recording stops rather than carrying on
    /// into a blind answer.
    func testAFailedCaptureStopsTheRecordingAndSaysWhy() async {
        let (viewModel, stub) = makeViewModel(.answered("should not happen"))
        var cancelled = 0
        viewModel.onCancelVoiceCapture = { cancelled += 1 }

        let token = viewModel.startScreenQuery()
        viewModel.screenCaptureDidFail(ScreenCaptureError.permissionDenied.message, token: token)

        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(viewModel.state, .failed(ScreenCaptureError.permissionDenied.message))
        XCTAssertFalse(viewModel.isBusy)
        XCTAssertNil(viewModel.pendingScreen)

        // The late transcript of a capture that was already abandoned changes
        // nothing.
        await viewModel.voiceCaptureDidProduce("what is this")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testARefusedPermissionIsShownWithoutRecordingAnything() {
        let (viewModel, _) = makeViewModel(.answered("should not happen"))
        var started = 0
        viewModel.onStartVoiceCapture = { started += 1 }

        viewModel.screenQueryRefused(ScreenCaptureError.permissionDenied.message)

        XCTAssertEqual(started, 0)
        XCTAssertEqual(viewModel.state, .failed(ScreenCaptureError.permissionDenied.message))
        XCTAssertFalse(viewModel.isScreenQuery)
    }

    /// Closing the panel forgets the screenshot with everything else: a screen
    /// query lives exactly as long as the conversation it belongs to.
    func testClosingThePanelForgetsTheScreenshot() {
        let (viewModel, _) = makeViewModel(.answered("unused"))

        let token = viewModel.startScreenQuery()
        viewModel.attachScreen(VisionEngineTests.observation(), token: token)
        viewModel.close()

        XCTAssertNil(viewModel.pendingScreen)
        XCTAssertFalse(viewModel.isScreenQuery)
        XCTAssertTrue(viewModel.exchanges.isEmpty)
    }

    /// The first refused ⌥S is the one where the OS permission dialog is
    /// already on screen, so the panel explains and nothing else opens; every
    /// later refusal has no dialog left, so it goes to System Settings.
    func testTheFirstRefusalLeavesTheSystemDialogAsTheOnlyOtherSurface() {
        let first = AskPanelWindowController.screenRecordingRefusal(previouslyAsked: false)
        XCTAssertFalse(first.opensSystemSettings)
        XCTAssertTrue(first.message.contains("dialog"), "the sentence points at the OS dialog")

        let later = AskPanelWindowController.screenRecordingRefusal(previouslyAsked: true)
        XCTAssertTrue(later.opensSystemSettings)
        XCTAssertEqual(later.message, ScreenCaptureError.permissionDenied.message)
    }

    /// ⌥S is a toggle, and only the half of it that is still being spoken is
    /// something to finish - `AskPanelWindowController.toggleScreenQuery` reads
    /// this rather than `isBusy`, so a second press while the model is answering
    /// does not take a screenshot the panel would refuse.
    func testOnlyASpokenScreenQueryIsSomethingToFinish() async {
        let (viewModel, _) = makeViewModel(.answered("Something."))
        // No capture ever resolves in this test, so the final ask waits out the
        // capture budget; the default would stall the suite for its full 10 s.
        viewModel.captureWaitBudget = 0.05

        XCTAssertFalse(viewModel.isCapturingScreenQuery)

        viewModel.startScreenQuery()
        XCTAssertTrue(viewModel.isCapturingScreenQuery)

        viewModel.finishVoiceFollowUp()
        XCTAssertTrue(viewModel.isCapturingScreenQuery, "still theirs while it transcribes")

        await viewModel.voiceCaptureDidProduce("What is this?")
        XCTAssertFalse(viewModel.isCapturingScreenQuery)
    }

    func testAScreenQueryIsRefusedWhileSomethingElseIsInFlight() {
        let (viewModel, _) = makeViewModel(.answered("unused"))
        var started = 0
        viewModel.onStartVoiceCapture = { started += 1 }

        viewModel.startVoiceFollowUp()
        viewModel.startScreenQuery()

        XCTAssertEqual(started, 1)
        XCTAssertFalse(viewModel.isScreenQuery, "the follow-up already running is not a screen query")
    }
}
