import Foundation

/// What the Ask panel is showing.
///
/// It mirrors one question's life and nothing else. `AskPanelWindowController`
/// owns the panel and derives its visibility from whether a view model is
/// presented at all, so nothing here has to know about windows.
enum AskPanelState: Equatable {
    /// Open, with nothing asked yet.
    case idle
    /// A voice follow-up is being captured.
    case listening
    /// The follow-up audio has stopped and is being turned into text.
    case transcribing
    /// The model is working on `question`.
    case thinking(question: String)
    /// The answer arrived.
    case answered(AskExchange)
    /// Something the user needs told: no model on this Mac, nothing heard, the
    /// answer took too long.
    case failed(String)
}

/// The Ask panel's state machine, and the only thing that decides what it shows.
///
/// Free of AppKit, of the panel and of the model: the window, the microphone
/// and the answering are all injected, which is what makes every transition -
/// including the ones that are easiest to get wrong, like an answer arriving
/// after the panel was closed - testable without a window server or an on-device
/// model. See `AskPanelViewModelTests`.
///
/// Two rules in it carry the feature:
///
/// - **An answer belongs to the question that asked for it.** The panel can be
///   closed, reset or asked something else while the model is working, and a
///   late answer must not land on top of whatever replaced it. A generation
///   counter, the same device `CapsuleHUDViewModel` uses for its auto-hides,
///   is what makes that a fact.
/// - **Nothing leaves the panel on its own.** Copying and inserting are
///   closures the controller supplies and the user triggers; this type never
///   reaches the pasteboard or another application.
@MainActor
final class AskPanelViewModel: ObservableObject {

    @Published private(set) var state: AskPanelState = .idle

    /// What the user is typing. Bound to the field, and cleared the moment a
    /// question is accepted so a follow-up starts from an empty box.
    @Published var draft: String = ""

    /// The conversation so far, oldest first. It exists only while the panel
    /// does - see `AskExchange`.
    @Published private(set) var exchanges: [AskExchange] = []

    /// Called when the user asks for the answer to go somewhere. The controller
    /// supplies both; this type has no idea what a pasteboard is.
    var onCopy: ((String) -> Void)?
    var onInsert: ((String) -> Void)?

    /// Called when the user closes the panel.
    var onClose: (() -> Void)?

    /// Called when the user asks to speak their next question. The controller
    /// starts the capture and reports back through `voiceCapture…`.
    var onStartVoiceCapture: (() -> Void)?

    /// Called when the user has finished speaking and wants what they said used.
    var onFinishVoiceCapture: (() -> Void)?

    /// Called when the user throws away a capture that is still running.
    var onCancelVoiceCapture: (() -> Void)?

    private let answering: @Sendable (AskRequest) async -> AskOutcome

    /// Which question the visible state belongs to. Every transition moves it
    /// on, and an answer that comes back against a stale value is dropped.
    private var generation = 0

    init(answering: @escaping @Sendable (AskRequest) async -> AskOutcome = AskService.answer) {
        self.answering = answering
    }

    // MARK: - What the view reads

    /// True while something is running and a second request would collide with
    /// it. The panel disables its inputs on this.
    var isBusy: Bool {
        switch state {
        case .listening, .transcribing, .thinking: return true
        case .idle, .answered, .failed: return false
        }
    }

    /// The answer on screen, or nil when there is not one.
    var answer: String? {
        if case .answered(let exchange) = state { return exchange.answer }
        return nil
    }

    /// Whether **Copy to Clipboard** and **Insert into Active App** do anything.
    var canUseAnswer: Bool { answer != nil }

    /// Whether the typed question can be submitted.
    var canSubmitDraft: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Asking

    /// Asks whatever is in the text field.
    func submit() async {
        await ask(draft)
    }

    /// Asks one question, from wherever it came - typed, spoken as a command, or
    /// captured as a follow-up.
    ///
    /// A blank question is refused rather than sent: an empty prompt does not
    /// get a neutral answer from a language model, it gets an arbitrary one.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(AskOutcome.nothingAsked.explanation ?? "Ask a question first.")
            return
        }
        // A second question while one is in flight would race the first one's
        // answer onto the same card. The panel disables its controls on
        // `isBusy`; this is the rule underneath that.
        guard !isBusy else { return }

        generation += 1
        let asked = generation
        draft = ""
        state = .thinking(question: trimmed)

        let outcome = await answering(
            AskRequest(question: trimmed, history: exchanges)
        )

        // The panel may have been closed, reset, or asked something else while
        // the model worked.
        guard generation == asked else { return }

        switch outcome {
        case .answered(let text):
            let exchange = AskExchange(question: trimmed, answer: text)
            exchanges.append(exchange)
            state = .answered(exchange)
        default:
            state = .failed(outcome.explanation ?? "The question could not be answered.")
        }
    }

    // MARK: - Voice follow-up

    /// The user asked to speak their next question.
    func startVoiceFollowUp() {
        guard !isBusy else { return }
        generation += 1
        state = .listening
        onStartVoiceCapture?()
    }

    /// The user has said their piece and wants it used.
    ///
    /// Ignored unless a capture is actually running, which is what keeps a
    /// capture the user already cancelled from reopening the spinner.
    func finishVoiceFollowUp() {
        guard state == .listening else { return }
        state = .transcribing
        onFinishVoiceCapture?()
    }

    /// The capture produced text. Nothing heard is its own message rather than
    /// an empty question, because "say that again" and "this Mac cannot answer"
    /// are different things to be told.
    func voiceCaptureDidProduce(_ text: String) async {
        guard state == .listening || state == .transcribing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("No speech detected")
            return
        }
        // The capture is over, so this is no longer busy and `ask` may run.
        state = .idle
        await ask(trimmed)
    }

    /// The capture failed for a reason worth telling the user.
    func voiceCaptureDidFail(_ message: String) {
        guard state == .listening || state == .transcribing else { return }
        fail(message)
    }

    /// The user stopped a capture that was still running.
    func cancelVoiceFollowUp() {
        guard state == .listening || state == .transcribing else { return }
        generation += 1
        onCancelVoiceCapture?()
        // Back to whatever the panel was showing before, so cancelling costs
        // the user nothing they had already been given.
        state = exchanges.last.map(AskPanelState.answered) ?? .idle
    }

    // MARK: - What the user does with the answer

    func copyAnswer() {
        guard let answer else { return }
        onCopy?(answer)
    }

    func insertAnswer() {
        guard let answer else { return }
        onInsert?(answer)
    }

    /// The user closed the panel. The conversation goes with it.
    func close() {
        reset()
        onClose?()
    }

    /// Puts the panel back to how it opens, and abandons anything in flight.
    func reset() {
        generation += 1
        state = .idle
        draft = ""
        exchanges = []
    }

    private func fail(_ message: String) {
        generation += 1
        state = .failed(message)
    }
}
