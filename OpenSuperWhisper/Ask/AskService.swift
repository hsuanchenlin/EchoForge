import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// One question and the answer it got.
///
/// Kept so a follow-up can be a follow-up: "and in euros?" means nothing
/// without the question before it. The whole conversation lives in the panel
/// and dies with it - nothing here is written to the database, the pasteboard
/// or anywhere else. See `docs/ask-panel.md`.
struct AskExchange: Equatable, Sendable, Identifiable {
    let id: UUID
    let question: String
    let answer: String

    init(id: UUID = UUID(), question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

/// One question to put to the on-device model.
struct AskRequest: Equatable, Sendable {
    let question: String
    /// Earlier turns of this conversation, oldest first.
    let history: [AskExchange]
    /// The language the model is asked in, which is read off the question
    /// itself - the same measurement `StyleRewriteLanguage` documents: the model
    /// answers in the language it was addressed in, so a Chinese question asked
    /// in English comes back in English.
    let language: StyleRewriteLanguage

    init(question: String, history: [AskExchange] = [], language: StyleRewriteLanguage? = nil) {
        self.question = question
        self.history = history
        self.language = language
            ?? StyleRewriteLanguage.resolve(languageCode: "auto", transcript: question)
    }
}

/// Anything that can answer a question on this Mac.
///
/// A protocol for the same reason `StyleRewriting` is one: every rule around it
/// - the deadline, the empty answer, the unavailable model - has to be testable,
/// and the machine running the tests may have no on-device model at all.
protocol AskAnswering: Sendable {
    func answer(_ request: AskRequest) async throws -> String
}

/// What one Ask attempt produced.
///
/// Every case that is not `answered` is something the panel says out loud.
/// Unlike a rewrite, there is no silent fallback available here: the user
/// pressed a button and is watching an empty card, so "nothing happened" is not
/// an outcome this feature is allowed to have.
enum AskOutcome: Equatable, Sendable {
    case answered(String)
    /// This Mac cannot run the model. Carries why: the same model as rewriting,
    /// so the same reasons and the same fix - named for this feature rather
    /// than for that one.
    case unavailable(StyleRewriteAvailability)
    /// There was no question.
    case nothingAsked
    /// Longer than the model is asked to take in one go.
    case questionTooLong
    /// The model returned nothing usable.
    case empty
    /// The answer did not arrive inside its budget.
    case timedOut
    /// The model itself failed - refused, ran out of context, or errored.
    case failed(String)

    var answer: String? {
        if case .answered(let text) = self { return text }
        return nil
    }

    /// One sentence for the panel. Nil only when there is an answer to show
    /// instead.
    var explanation: String? {
        switch self {
        case .answered:
            return nil
        case .unavailable(let availability):
            return availability.explanation(for: .ask)
        case .nothingAsked:
            return "Ask a question first."
        case .questionTooLong:
            return "That question is too long to answer (over \(AskService.maximumQuestionCharacters) characters)."
        case .empty:
            return "The answer came back empty."
        case .timedOut:
            return "The answer took too long."
        case .failed(let message):
            return message
        }
    }
}

/// Asking the on-device model a question, with a deadline.
///
/// It is deliberately not a stage of the transcription pipeline: nothing it
/// produces is inserted, stored or pasted on its own. The answer goes onto a
/// panel the user is looking at, and reaches another app only when they press
/// **Insert into Active App** - which is why there is no `StyleRewriteGuard`
/// here. That guard exists because a rewrite replaces the user's own words on
/// their way into another application without anyone reading them first; an
/// answer is read first, by definition.
enum AskService {

    /// Above this the question is not put to the model at all - it would
    /// overrun the context window and fail after spending the whole budget.
    static let maximumQuestionCharacters = 2000

    /// How many prior exchanges a follow-up keeps.
    ///
    /// The history is written into every prompt, so a conversation in a
    /// long-lived panel would otherwise rebuild exactly the failure
    /// `maximumQuestionCharacters` exists to prevent: a prompt that overruns
    /// the context window and errors after spending the whole budget. The most
    /// recent exchanges are the ones a follow-up actually refers to, so those
    /// are the ones kept.
    static let maximumHistoryExchanges = 6

    /// How long an answer may take.
    ///
    /// Far longer than a rewrite's budget, and that is the difference between
    /// the two features rather than an inconsistency: a rewrite is holding up a
    /// paste into another app, while this is a panel the user opened on purpose
    /// and is sitting in front of. The ceiling still exists so a wedged model
    /// ends in a sentence rather than in a spinner nobody can stop.
    static let budget: TimeInterval = 30

    /// Runs one question against an injected model.
    ///
    /// Every input the decision depends on is a parameter, so the tests state
    /// the situation rather than inheriting it from the Mac they run on.
    static func answer(
        _ request: AskRequest,
        availability: StyleRewriteAvailability,
        answerer: AskAnswering?,
        budgetOverride: TimeInterval? = nil
    ) async -> AskOutcome {
        let question = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .nothingAsked }
        guard availability.canRun else { return .unavailable(availability) }
        // Availability and the model are resolved separately and it can become
        // unavailable between the two - the same reason the rewriting stage
        // reports this as not-ready rather than as the availability it just read.
        guard let answerer else { return .unavailable(.modelNotReady) }
        guard question.count <= maximumQuestionCharacters else { return .questionTooLong }

        let text: String
        do {
            text = try await AsyncDeadline.run(budget: budgetOverride ?? budget) {
                try await answerer.answer(request)
            }
        } catch is AsyncDeadline.Exceeded {
            return .timedOut
        } catch is CancellationError {
            return .timedOut
        } catch {
            return .failed(error.localizedDescription)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return .answered(trimmed)
    }

    /// The production entry point: resolves what this Mac can do, then asks.
    ///
    /// Tests never reach the model through here - the same rule the engine
    /// loader and the rewriting stage follow, and for the same reason.
    static func answer(_ request: AskRequest) async -> AskOutcome {
        let isRunningTests = await MainActor.run { OpenSuperWhisperApp.isRunningTests }
        guard !isRunningTests else { return .unavailable(.unsupportedSystem) }
        return await answer(
            request,
            availability: AskModelFactory.availability(),
            answerer: AskModelFactory.makeAnswerer()
        )
    }
}

/// The app's answer to "can this Mac answer a question, and with what".
///
/// It shares `StyleRewriterFactory.availability()` rather than asking again:
/// there is one on-device model, one set of reasons it might be missing, and
/// one sentence to show the user about each. What this adds is the backend.
enum AskModelFactory {

    static func availability() -> StyleRewriteAvailability {
        StyleRewriterFactory.availability()
    }

    static func makeAnswerer() -> AskAnswering? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availability().canRun else { return nil }
        return FoundationModelsAskAnswerer()
        #else
        return nil
        #endif
    }

    /// Loads the model before the first question needs it. Called when the Ask
    /// panel opens, which is the moment the user is about to wait for it.
    static func prewarmIfAvailable() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availability().canRun else { return }
        LanguageModelSession(instructions: AskPrompt.instructions(language: .other)).prewarm()
        #endif
    }
}

/// How the model is asked a question, kept apart from the asking.
///
/// The transcript-is-never-instruction rule that `StyleRewritePrompt` carries is
/// deliberately absent, and its absence is the whole difference between the two:
/// here the user's words *are* the instruction. That is safe precisely because
/// the answer has nowhere to go on its own - it is drawn on a panel, and it
/// leaves only when the user presses a button next to it.
enum AskPrompt {

    static func instructions(language: StyleRewriteLanguage) -> String {
        switch language {
        case .chinese(.traditional):
            return """
            你在回答使用者用語音問的問題，答案會顯示在螢幕上一張小卡片裡。

            - 用繁體中文回答，而且要和問題用同一種字體。
            - 直接回答，講重點。可以的話控制在三、四句話以內。
            - 不確定或不知道的事就直說，不要編。
            - 不要複述問題，也不要加開場白。
            """
        case .chinese(.simplified):
            return """
            你在回答用户用语音问的问题，答案会显示在屏幕上一张小卡片里。

            - 用简体中文回答，而且要和问题用同一种字体。
            - 直接回答，讲重点。可以的话控制在三、四句话以内。
            - 不确定或不知道的事就直说，不要编。
            - 不要复述问题，也不要加开场白。
            """
        case .other:
            return """
            You answer questions asked out loud, and the answer is shown on a \
            small card on screen.

            - Answer in the language the question was asked in.
            - Answer directly and get to the point. Three or four sentences \
            where that is enough.
            - Say plainly when you do not know or cannot be sure. Never invent \
            a fact, a figure or a source.
            - Do not repeat the question back and do not open with a preamble.
            """
        }
    }

    /// The prompt for one turn: the most recent earlier turns, then the
    /// question.
    ///
    /// The history is written into the prompt rather than kept in a live
    /// `LanguageModelSession` because the panel outlives any one session - it
    /// can be left open across dictations - and a stored session that was
    /// created when the Mac was in a different state is a harder thing to reason
    /// about than a string this file builds every time. Only the last
    /// `AskService.maximumHistoryExchanges` exchanges are written; that constant
    /// says why the history cannot be unbounded.
    static func prompt(for request: AskRequest) -> String {
        let history = request.history.suffix(AskService.maximumHistoryExchanges)
        guard !history.isEmpty else { return request.question }
        let transcript = history
            .map { "Q: \($0.question)\nA: \($0.answer)" }
            .joined(separator: "\n\n")
        return """
        \(transcript)

        Q: \(request.question)
        """
    }
}

#if canImport(FoundationModels)
/// The on-device backend: Apple's system language model, the same one the
/// rewriting stage uses.
///
/// Chosen for the reason that decides every model question in this app:
/// dictation is the most private thing it touches, and a feature that mailed a
/// spoken question to a third party by default is not a trade this app makes.
/// Everything the Ask panel does happens on the Mac it is running on.
@available(macOS 26.0, *)
struct FoundationModelsAskAnswerer: AskAnswering {

    func answer(_ request: AskRequest) async throws -> String {
        let session = LanguageModelSession(
            instructions: AskPrompt.instructions(language: request.language)
        )
        let response = try await session.respond(
            to: AskPrompt.prompt(for: request),
            // Slightly above the rewriting stage's near-deterministic setting:
            // an answer is prose the user reads once rather than a substitution
            // for their own words, so the tighter setting buys nothing here.
            options: GenerationOptions(temperature: 0.4)
        )
        return response.content
    }
}
#endif
