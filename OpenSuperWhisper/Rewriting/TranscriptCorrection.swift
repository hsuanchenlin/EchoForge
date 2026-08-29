import Foundation

/// The "Fix with AI" action on a history card: a second pass over a transcript
/// the engine already produced, correcting the errors that come from *hearing*
/// rather than from speaking - Chinese homophones, mis-heard characters,
/// misspellings, wrong word boundaries - by reading the sentence around them.
///
/// It is a sibling of `StyleRewriteService` in the way `TranslationRewrite` is,
/// and shares everything that makes that stage safe: the `StyleRewriting`
/// protocol, `StyleRewriterFactory`'s availability, `AsyncDeadline`'s hard
/// budget, `StyleRewriteGuard`, and `StyledTranscript` as the result. What it
/// does not share is the moment and the instruction. Rewriting runs on every
/// dictation on its way into another app; this runs when a user presses a button
/// on a row they are reading, and asks for the one change rewriting is careful
/// not to make - the characters themselves.
///
/// Three things here are absolute.
///
/// - **It is on-device only.** `OnDeviceModelFeature.correction` has no
///   `cloudFeature`, the same way rewriting, Ask and channel matching have none.
///   A history row is every dictation the user ever made, and a button that
///   quietly posted one to a provider is not a trade this app makes.
///   `docs/cloud-api.md` states the two features that may leave the Mac, and
///   this is not one of them.
/// - **It can only correct a transcript or leave it alone.** Every path out
///   returns the row unchanged or a candidate that survived the guard, so the
///   press can cost the user a wait and nothing else. The audio is never
///   touched, and neither is any row but this one.
/// - **The original is kept.** What the row said before the press becomes its
///   `rawTranscription`, which is what "Show original" and "Compare" already
///   read - so a correction is always inspectable and never the only copy.
///
/// `docs/history-ai-fix.md` is the whole story.
enum TranscriptCorrection {

    /// The synthetic style a correction is guarded as.
    ///
    /// Not in `StyleRewriteCatalog` and it must not be: that catalog is the list
    /// Settings offers for *dictation*, and its identifiers are persisted in the
    /// user's preferences. This one is never stored anywhere - it exists because
    /// `StyleRewriteStatus.applied` reports an identifier, the same reason
    /// `TranslationRewrite.styleID` does.
    static let styleID = "fixWithAI"

    /// What the model is told to do.
    ///
    /// `.preserving` is the shape, and it is the strictest one the guard has:
    /// the correction must stay within that shape's length bounds, in the same
    /// script and Chinese variant, with every number and currency symbol intact.
    /// That is the right envelope for this stage - a homophone fix changes
    /// characters rather than meaning, so anything wider would only be
    /// permission for the model to do something the user did not ask for.
    ///
    /// Three hand-written texts for the same reason `StyleRewriteStyle` has
    /// them: the instruction's own script decides the answer's script, so a
    /// Traditional transcript is asked about in Traditional Chinese. The English
    /// text is what every non-Chinese dictation gets, and it is written for the
    /// same failure - "recieve" for "receive", "their" for "there" - because
    /// mis-hearing is not a Chinese-only problem.
    static let style = StyleRewriteStyle(
        id: styleID,
        name: "Fix with AI",
        shortName: "Fix",
        summary: "Fixes homophones, mis-heard characters and typos from context.",
        instructions: StyleRewriteInstructions(
            english: """
            Correct the errors this text picked up from speech recognition: \
            homophones, mis-heard or misspelled words, and wrong word \
            boundaries. Decide each one from the sentence around it and from \
            common sense about what the speaker meant. Change nothing else - \
            keep the speaker's own wording, tone, sentence order and \
            punctuation, and keep every fact, name, number and amount exactly \
            as it stands. Repeat anything that is already correct unchanged.
            """,
            traditionalChinese: """
            修正這段文字在語音辨識時聽錯而產生的錯誤：同音字、聽錯的字、錯字，\
            以及斷詞斷錯的地方。每一處都要依照前後文和常識判斷說話者原本要說的是\
            哪個字。除此之外什麼都不要改——保留說話者自己的用詞、語氣、句子順序和\
            標點，事實、人名、數字和金額都要和原文完全一樣。整篇都要用繁體字書寫。\
            本來就正確的地方原封不動照抄。
            """,
            simplifiedChinese: """
            修正这段文字在语音识别时听错而产生的错误：同音字、听错的字、错字，\
            以及断词断错的地方。每一处都要依照前后文和常识判断说话者原本要说的是\
            哪个字。除此之外什么都不要改——保留说话者自己的用词、语气、句子顺序和\
            标点，事实、人名、数字和金额都要和原文完全一样。整篇都要用简体字书写。\
            本来就正确的地方原封不动照抄。
            """
        ),
        shape: .preserving
    )

    /// The configuration handed to `StyleRewriteService`.
    ///
    /// Enabled unconditionally, and that is the point: this is a button the user
    /// pressed, not a stage that runs behind them, so the Settings toggle that
    /// governs dictation-time rewriting has no say over it. A user who never
    /// wants their dictations restyled can still fix one row.
    static let configuration = StyleRewriteConfiguration(
        isEnabled: true, style: style, customPrompt: ""
    )

    // MARK: - What a press asks for

    /// Whether this row can be corrected at all, and with what.
    ///
    /// Pure, so the button's own rule is testable without a model, a database or
    /// a Mac that has Apple Intelligence. `nil` means there is nothing to press:
    /// a row still in the queue has no transcript yet, and a failed row's
    /// "transcript" is the failure message, which is the app's words rather than
    /// the user's.
    static func request(for recording: Recording) -> TranscriptCorrectionRequest? {
        guard recording.status == .completed else { return nil }
        let text = recording.transcription
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptCorrectionRequest(
            recordingID: recording.id,
            text: text,
            // "If it is not already set" - and it is already set whenever
            // post-processing changed this row once before. Overwriting it with
            // the post-processed text would throw away the only copy of what the
            // engine actually heard, which is the one thing this row can never
            // get back.
            original: recording.originalTranscriptionForCorrection
        )
    }

    /// The dictionary spellings a correction is not allowed to lose.
    ///
    /// `ProcessedText.mustSurviveTokens` is produced by the terms stage at
    /// dictation time and is not stored, so it cannot be read back off a history
    /// row. This is the honest reconstruction: every enabled entry whose own
    /// output is literally present in the transcript. Those are spellings the
    /// user typed themselves to say how their vocabulary is written, and a model
    /// asked to fix homophones is exactly the thing most likely to "correct" a
    /// name back into one.
    ///
    /// A `protect` entry emits what it matched rather than a replacement
    /// (`PersonalTermKind.substitutesText`), so it is the match that has to
    /// survive.
    static func mustSurviveTokens(in text: String, terms: [PersonalTerm]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { term -> String? in
            guard term.isEnabled else { return nil }
            let token = term.kind.substitutesText ? term.replacement : term.match
            guard !token.isEmpty, text.contains(token) else { return nil }
            return seen.insert(token).inserted ? token : nil
        }
    }

    // MARK: - Running one

    /// Runs the stage against an injected rewriter.
    ///
    /// Every input the decision depends on is a parameter, the same way
    /// `StyleRewriteService.apply` and `TranslationRewrite.apply` take them, so
    /// every failure path is testable on a Mac with no on-device model.
    static func apply(
        to request: TranscriptCorrectionRequest,
        languageCode: String,
        availability: StyleRewriteAvailability,
        rewriter: StyleRewriting?,
        mustSurvive: [String] = [],
        fallbackChineseVariant: ChineseScriptVariant = ChineseScriptVariant.systemPreferred,
        budgetOverride: TimeInterval? = nil
    ) async -> StyledTranscript {
        await StyleRewriteService.apply(
            to: ProcessedText(
                raw: request.original, final: request.text, mustSurviveTokens: mustSurvive),
            configuration: configuration,
            languageCode: languageCode,
            availability: availability,
            rewriter: rewriter,
            fallbackChineseVariant: fallbackChineseVariant,
            budgetOverride: budgetOverride
                ?? TranscriptCorrectionBudget.seconds(forCharacterCount: request.text.count)
        )
    }

    /// The production entry point: resolves what this Mac can do, then runs the
    /// stage.
    ///
    /// Tests never reach the model through here - the same rule the engine
    /// loader, the rewriting stage and the translation stage follow, and for the
    /// same reason: a test host must not start work that depends on the machine
    /// it happens to be running on.
    static func apply(
        to request: TranscriptCorrectionRequest, settings: Settings, terms: [PersonalTerm]
    ) async -> StyledTranscript {
        let isRunningTests = await MainActor.run { OpenSuperWhisperApp.isRunningTests }
        guard !isRunningTests else {
            return StyledTranscript(
                raw: request.original,
                transcript: request.text,
                final: request.text,
                status: .notRequested
            )
        }

        // The same marker the other two model stages raise, for the same reason:
        // the capsule's "Polishing…" is about the model working, and a
        // correction is the model working.
        await MainActor.run { StyleRewriteActivity.shared.begin() }
        let result = await apply(
            to: request,
            languageCode: settings.selectedLanguage,
            // Asked without a feature, because `OnDeviceModelFeature.correction`
            // has no cloud path at all. Spelled out rather than implied: there is
            // no configuration of this app in which a history row leaves the Mac.
            availability: StyleRewriterFactory.availability(for: .correction),
            rewriter: StyleRewriterFactory.makeRewriter(for: .correction),
            mustSurvive: mustSurviveTokens(in: request.text, terms: terms),
            fallbackChineseVariant: settings.chineseOutputScript
        )
        await MainActor.run { StyleRewriteActivity.shared.end() }
        if let explanation = result.status.explanation(for: .correction), !result.status.didRewrite {
            print("Fix with AI: \(explanation)")
        }
        return result
    }

    // MARK: - What it changed

    /// What a finished correction does to the row.
    ///
    /// Pure, and separate from the running, because it is where the one case the
    /// stage's own status cannot express is decided: the guard accepted a
    /// candidate that is *identical* to the transcript. That is a success as far
    /// as the model is concerned and a no-op as far as the row is concerned, and
    /// writing it would leave the card with an "AI Polished" badge, a "Show
    /// original" disclosure and two identical texts behind it.
    static func outcome(
        of styled: StyledTranscript, request: TranscriptCorrectionRequest
    ) -> TranscriptCorrectionOutcome {
        guard styled.status.didRewrite else {
            return .unchanged(
                styled.status.explanation(for: .correction)
                    ?? "Nothing was changed.")
        }
        guard styled.final != request.text else {
            return .unchanged("Nothing needed fixing - this transcript is already correct.")
        }
        return .corrected(text: styled.final, original: request.original)
    }
}

/// One press of "Fix with AI", as the values it depends on.
///
/// A value rather than a `Recording` so the stage never sees - and so can never
/// write to - the row it came from. See `TranscriptCorrection.request(for:)`.
struct TranscriptCorrectionRequest: Equatable, Sendable {
    let recordingID: UUID
    /// The text handed to the model: what the row shows now.
    let text: String
    /// What the row must keep as its original if the correction lands - the
    /// engine's own words where the row already has them, and otherwise the
    /// text being corrected.
    let original: String
}

/// What a finished correction changes about a history row.
enum TranscriptCorrectionOutcome: Equatable, Sendable {
    /// The correction survived the guard and differs from what the row shows.
    case corrected(text: String, original: String)
    /// The row keeps exactly what it had. Carries the sentence the card shows,
    /// which is the stage's own explanation wherever there is one.
    case unchanged(String)

    var correctedText: String? {
        if case .corrected(let text, _) = self { return text }
        return nil
    }

    /// The sentence to put on the card, or nil when the row simply changed.
    var note: String? {
        if case .unchanged(let sentence) = self { return sentence }
        return nil
    }
}

/// How long one correction may take before the row is left as it was.
///
/// Deliberately not `StyleRewriteBudget`, and the difference between the two is
/// the whole difference between the stages. That budget is a hard ceiling
/// because a dictation's rewrite is racing text on its way into the app the user
/// was typing in, where anything past a few seconds is worth less than the
/// transcript arriving now. Nothing is racing here: the user pressed a button on
/// a card and is watching a spinner on it. So this one is longer - but it is
/// still a ceiling, because a request that never returns leaves that spinner up
/// for the rest of the session.
enum TranscriptCorrectionBudget {
    static let base: TimeInterval = 8
    static let perCharacter: TimeInterval = 1.0 / 100.0
    static let ceiling: TimeInterval = 45

    static func seconds(forCharacterCount count: Int) -> TimeInterval {
        min(ceiling, base + Double(max(0, count)) * perCharacter)
    }
}
