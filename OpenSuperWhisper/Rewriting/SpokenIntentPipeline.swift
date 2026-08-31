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
    /// The utterance the YouTube command hotkey captured, and which channel the
    /// allowlist made of it. **Nothing is inserted** - this session never had
    /// any text to insert - and the resolution is carried so whoever runs the
    /// command can also report the ways the channel can fail to be one.
    /// Only a `.youTubeCommand` session can produce it. See
    /// `YouTubeLatestVideoService` and `DictationPurpose`.
    ///
    /// It carries `YouTubeCommandResolution` rather than the bare resolution so
    /// what the optional on-device chooser did travels with the answer as far as
    /// history, which is the only durable surface that can tell the user a model
    /// was - or was not - consulted about their failed command.
    case openLatestVideo(YouTubeCommandResolution)
    /// The utterance the voice-edit hotkey captured. **The instruction is never
    /// inserted** - the rewrite of the selected text is, and that paste happens
    /// after this outcome, on the session that holds the capture. Only a
    /// `.selectionEdit` session can produce it. See `SelectionEditRewrite`.
    case selectionEdit(instruction: String)

    /// Whether the text goes into whatever the user was typing in.
    ///
    /// False for the outcomes that are not the words to insert. A question
    /// belongs to the Ask panel, a command capture was never on its way to a
    /// document, and a voice-edit instruction is the instruction - pasting it
    /// would type those words instead of replacing the selection.
    var insertsText: Bool {
        switch self {
        case .ask, .openLatestVideo, .selectionEdit: return false
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
        case .openLatestVideo(let command):
            return .openLatestVideo(from: command.spokenName)
        case .selectionEdit:
            return nil
        }
    }

    /// What this outcome puts in history.
    ///
    /// A command's provenance is provisional here - the feed has not been
    /// fetched and Chrome has not been asked for anything - so it says "not
    /// opened" until the report replaces it. See
    /// `RecordingProvenance.pendingCommand`.
    var provenance: RecordingProvenance {
        switch self {
        case .dictation, .translated, .snippet: return .dictation
        case .ask: return .ask
        case .openLatestVideo(let command): return .pendingCommand(command)
        case .selectionEdit(let instruction):
            return .selectionEdit(instruction: instruction)
        }
    }
}

extension SpokenIntentOutcome {
    /// The command outcome, spelled with a bare resolution.
    ///
    /// Kept so every caller that has no model attempt to report - which is every
    /// caller but the pipeline - reads exactly as it did before the attempt
    /// existed.
    static func openLatestVideo(
        _ resolution: YouTubeChannelResolution,
        modelMatch: YouTubeChannelModelMatchAttempt = .notNeeded,
        candidates: [YouTubeChannel] = []
    ) -> SpokenIntentOutcome {
        .openLatestVideo(
            YouTubeCommandResolution(
                resolution: resolution, modelMatch: modelMatch, candidates: candidates))
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
///          ├── purpose == .youTubeCommand ─► the channel to open, no text
///          ├── purpose == .selectionEdit ──► the spoken instruction, no paste
///          ├── .dictate ─────────► StyleRewriteService.apply()  the chosen style
///          ├── .translate ───────► TranslationRewrite.apply()   the spoken target
///          ├── .snippet ─────────► the stored template, byte for byte
///          └── .ask ─────────────► nothing at all, marked for the Ask panel
/// ```
///
/// The first branch leaves before any of the others are considered, and it is
/// the only one that can produce `.openLatestVideo`. A dictation cannot reach it
/// however it is worded, because `SpokenIntentRouter` has no case for it - see
/// `DictationPurpose`.
///
/// Only live dictation asks for routing (`Settings.routesSpokenIntents`). A
/// dropped file, a queued recording, a regenerate from history and the Ask
/// panel's own voice follow-up all take the plain path, which is what keeps a
/// transcript containing the word "ask" from opening a panel nobody was looking
/// at - and what stops the follow-up from routing itself back into the panel it
/// came from.
enum SpokenIntentPipeline {

    static func apply(to processed: ProcessedText, settings: Settings) async -> StyledTranscript {
        // The command hotkey's capture leaves here before anything else runs.
        // It is not a dictation, so nothing below applies to it: no style, no
        // question, no snippet, no translation, and no text on its way out.
        if settings.purpose == .youTubeCommand {
            return await youTubeCommand(to: processed, settings: settings)
        }
        // The voice-edit hotkey's capture leaves here before anything else
        // runs. The spoken words are the instruction, not the text to insert,
        // so no style, no question, no snippet, no translation, and no paste
        // of the instruction itself. The session that holds the selected text
        // is what runs `SelectionEditRewrite` afterwards.
        if settings.purpose == .selectionEdit {
            return StyledTranscript(
                raw: processed.raw,
                transcript: processed.final,
                final: processed.final,
                status: .notRequested,
                intent: .selectionEdit(instruction: processed.final)
            )
        }

        guard settings.routesSpokenIntents else {
            return await StyleRewriteService.apply(to: processed, settings: settings)
        }

        let intent = SpokenIntentRouter.route(
            processed.final,
            snippets: settings.voiceSnippets,
            // A bare "翻譯成中文" means the Chinese this user writes, and they
            // have now said which that is: the script every one of their
            // transcripts is written in. Reading their Mac's region instead
            // could answer a Traditional user's translation in Simplified.
            fallbackChineseVariant: settings.chineseOutputScript
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

    /// The whole of what the YouTube command hotkey's capture becomes.
    ///
    /// Three steps and no others: read the words as a channel name
    /// (`YouTubeCommandRouter`), let the on-device model choose from the user's
    /// own list if the deterministic tiers could not and the user asked for that
    /// (`YouTubeChannelModelMatch`), and hand the answer on for the caller to
    /// run. The transcript is carried so the words survive in history, and
    /// `SpokenIntentOutcome.insertsText` is false for it, so nothing downstream
    /// can paste them.
    private static func youTubeCommand(
        to processed: ProcessedText, settings: Settings
    ) async -> StyledTranscript {
        func result(_ command: YouTubeCommandResolution) -> StyledTranscript {
            StyledTranscript(
                raw: processed.raw,
                transcript: processed.final,
                final: processed.final,
                status: .notRequested,
                intent: .openLatestVideo(command)
            )
        }

        // The key stays bound while the feature is off so that a press can say
        // so; a hotkey that silently does nothing is the one answer a user
        // cannot act on.
        guard let channels = settings.youTubeChannels else {
            return result(YouTubeCommandResolution(
                resolution: .disabled(spoken: processed.final.trimmingCharacters(
                    in: .whitespacesAndNewlines))))
        }

        let resolution = YouTubeCommandRouter.resolve(processed.final, channels: channels)
        await MainActor.run {
            SpokenIntentActivity.shared.resolved(.openLatestVideo(resolution))
        }

        // The list the lookup was made against travels with the answer, so the
        // recovery picker can only ever offer rows this command itself could
        // have reached. Re-reading the store when the picker opens would let a
        // Settings edit made in between widen what one press can do.
        let resolved = await YouTubeChannelModelMatch.refine(
            resolution,
            in: channels,
            isEnabled: settings.youTubeChannelModelMatch
        ).withCandidates(channels.reachable)
        if resolved.resolution != resolution {
            await MainActor.run {
                SpokenIntentActivity.shared.resolved(.openLatestVideo(resolved))
            }
        }
        return result(resolved)
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
