import Foundation

/// What the spoken-intent router decided about one dictation, in the form the
/// rest of the app consumes it.
///
/// It is a separate type from `SpokenIntent` because the two answer different
/// questions. `SpokenIntent` is the router's reading of a transcript and
/// carries the text it extracted; this is what became of that reading once the
/// stage ran, and travels on `StyledTranscript` to whoever has to decide
/// whether the words get pasted.
enum SpokenIntentOutcome: Equatable, Sendable {
    /// Ordinary dictation: insert `StyledTranscript.final` as always. Also the
    /// answer for every caller that never asked the router to look.
    case dictation
    /// A question. **Nothing is inserted** - the text belongs to the Ask panel,
    /// and pasting a question into the user's document is the one thing this
    /// intent must never do.
    case ask(query: String)
    /// A translation. Inserted exactly as dictation is; the target is carried so
    /// a surface can say which language it went into.
    case translated(SpokenTranslationTarget)
    /// A voice snippet fired. Inserted like dictation; the keyword is carried so
    /// a surface can say which template went in.
    case snippet(keyword: String)
    /// The words asked for a channel's latest video. **Nothing is inserted** -
    /// like `.ask`, the transcript was an instruction rather than text - and the
    /// resolution is carried so whoever runs the command can also report the two
    /// ways the channel can fail to be one. See `YouTubeLatestVideoService`.
    case openLatestVideo(YouTubeChannelResolution)

    /// Whether the text goes into whatever the user was typing in.
    ///
    /// False for the two outcomes that are instructions rather than text.
    /// Pasting "open the latest YouTube video from Veritasium" into the document
    /// the user was writing would be the app doing the one thing they did not
    /// ask for.
    var insertsText: Bool {
        switch self {
        case .ask, .openLatestVideo: return false
        case .dictation, .translated, .snippet: return true
        }
    }

    /// The capsule HUD's chip for this outcome, or nil when there is nothing to
    /// promise beyond plain dictation.
    var capsuleMode: CapsuleHUDMode? {
        switch self {
        case .dictation: return nil
        case .ask: return .ask
        case .translated(let target): return .translate(to: target)
        case .snippet(let keyword): return .snippet(named: keyword)
        case .openLatestVideo(let resolution):
            return .openLatestVideo(from: resolution.spokenName)
        }
    }
}

/// The stage that decides whether a dictation was a command, and runs whichever
/// stage it turns out to belong to.
///
/// It sits exactly where the rewriting stage used to be called from, and for
/// plain dictation it *is* the rewriting stage - `SpokenIntentRouter` is pure
/// string matching, so the ordinary path pays a prefix comparison and nothing
/// else. The ways out are the cases of `SpokenIntent`:
///
/// ```
/// TextPostProcessor.process()
///          │
///          ▼
/// SpokenIntentPipeline.apply()          off unless the caller asks and the
///          │                            user switched it on
///          ├── .dictate ─────────► StyleRewriteService.apply()  the chosen style
///          ├── .translate ───────► TranslationRewrite.apply()   the spoken target
///          ├── .snippet ─────────► the stored template, byte for byte
///          ├── .ask ─────────────► nothing at all, marked for the Ask panel
///          └── .openLatestVideo ─► nothing at all, marked for the caller to run
/// ```
///
/// Only live dictation asks for routing (`Settings.routesSpokenIntents`). A
/// dropped file, a queued recording, a regenerate from history and the Ask
/// panel's own voice follow-up all take the plain path, which is what keeps a
/// transcript containing the word "ask" from opening a panel nobody was looking
/// at - and what stops the follow-up from routing itself back into the panel it
/// came from.
enum SpokenIntentPipeline {

    static func apply(to processed: ProcessedText, settings: Settings) async -> StyledTranscript {
        guard settings.routesSpokenIntents else {
            return await StyleRewriteService.apply(to: processed, settings: settings)
        }

        let intent = SpokenIntentRouter.route(
            processed.final,
            snippets: settings.voiceSnippets,
            channels: settings.youTubeChannels,
            fallbackChineseVariant: ChineseScriptVariant.systemPreferred
        )
        await MainActor.run { SpokenIntentActivity.shared.resolved(intent.outcome) }

        switch intent {
        case .dictate:
            return await StyleRewriteService.apply(to: processed, settings: settings)
        case .ask(let query):
            // The rewriting stage is deliberately skipped: restyling a question
            // on its way to a model that is about to answer it changes what was
            // asked for no benefit the user can see.
            return StyledTranscript(
                raw: processed.raw,
                transcript: query,
                final: query,
                status: .notRequested,
                intent: .ask(query: query)
            )
        case .translate(let target, let text):
            return await TranslationRewrite.apply(to: processed, body: text, target: target)
        case .openLatestVideo(let resolution):
            // Nothing is rewritten and nothing is inserted: what the transcript
            // named is a channel, and what happens next is a feed lookup the
            // caller runs. The transcript is still carried and still stored, so
            // the words the user said survive in history either way.
            return StyledTranscript(
                raw: processed.raw,
                transcript: processed.final,
                final: processed.final,
                status: .notRequested,
                intent: .openLatestVideo(resolution)
            )
        case .snippet(let keyword, let expansion):
            // The rewriting stage is skipped, and skipping it is the feature.
            // A template's blank lines, indentation and deliberate lack of a
            // full stop are the user's own formatting; a model asked to polish
            // it would return prose. What is stored is what goes in.
            return StyledTranscript(
                raw: processed.raw,
                transcript: processed.final,
                final: expansion,
                status: .notRequested,
                intent: .snippet(keyword: keyword)
            )
        }
    }
}

extension SpokenIntent {
    /// The outcome this reading implies, before the stage it names has run.
    var outcome: SpokenIntentOutcome {
        switch self {
        case .dictate: return .dictation
        case .ask(let query): return .ask(query: query)
        case .translate(let target, _): return .translated(target)
        case .snippet(let keyword, _): return .snippet(keyword: keyword)
        case .openLatestVideo(let resolution): return .openLatestVideo(resolution)
        }
    }
}

/// Announces that a dictation in flight turned out to be a command.
///
/// The capsule HUD's chip is set when the session starts, from preferences,
/// because that is when it can be: what the chip promises has to be what the
/// pipeline is about to do. A spoken command is the one thing that is not known
/// until the words exist, so the chip has to be told - and this is the same
/// shape `StyleRewriteActivity` uses for the same reason.
///
/// Like that flag it is global, and like that flag the scoping is the view
/// model's job: `CapsuleHUDViewModel.setMode` refuses a change unless the
/// capsule is showing its own decode, so a queue transcription cannot relabel a
/// recording that is still in progress.
@MainActor
final class SpokenIntentActivity: ObservableObject {
    static let shared = SpokenIntentActivity()

    /// The last routing verdict, or nil before anything has been routed.
    @Published private(set) var outcome: SpokenIntentOutcome?

    private init() {}

    func resolved(_ outcome: SpokenIntentOutcome) {
        self.outcome = outcome
    }

    /// Forgets the last verdict, so a new session does not subscribe to a
    /// `@Published` that immediately replays the previous dictation's command.
    func clear() {
        outcome = nil
    }
}
