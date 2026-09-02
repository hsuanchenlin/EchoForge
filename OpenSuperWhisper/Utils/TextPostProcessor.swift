import Foundation

/// A transcription after post-processing, carrying the engine's raw output
/// alongside the text the app actually uses.
///
/// Only `final` is consumed today. `raw` exists because every later stage of
/// the post-processing pipeline (terms dictionary, guarded LLM rewrite) has to
/// be able to show the user what they originally said and fall back to it, and
/// that is impossible to retrofit once the raw text has been discarded at the
/// engine boundary.
struct ProcessedText: Equatable {
    /// Exactly what the transcription engine returned, before any formatting.
    let raw: String
    /// The transcript text consumed by the app before live-output formatting.
    let final: String
    /// What the personal terms dictionary wrote into ``final``.
    ///
    /// Nothing reads this yet. It is produced here because only the terms stage
    /// knows which spans it corrected or pinned, and a later rewriting stage
    /// would have to check its own output still contains them before that
    /// output could be accepted. See `TermsCorrection.mustSurviveTokens`.
    let mustSurviveTokens: [String]

    init(raw: String, final: String, mustSurviveTokens: [String] = []) {
        self.raw = raw
        self.final = final
        self.mustSurviveTokens = mustSurviveTokens
    }

    /// True when post-processing changed the engine's output.
    var wasModified: Bool { raw != final }

    static func unchanged(_ text: String) -> ProcessedText {
        ProcessedText(raw: text, final: text)
    }
}

/// The single place where transcribed text is post-processed.
///
/// There are two deliberately separate stages, and the distinction is the
/// point of this type:
///
/// 1. **The transcript stage** - ``process(_:settings:)``. Formatting that
///    belongs to the transcription itself, so it must be identical no matter
///    how the text was produced or will be consumed. It runs once, in
///    `TranscriptionService`, which is the single choke point every engine and
///    every caller passes through. This is what gets stored in `Recording`.
///
/// 2. **The insertion stage** - ``prepareForInsertion(_:)``. Live-output
///    affordances that deliberately do *not* belong to the stored transcript.
///    Only the live dictation indicator applies this stage.
///
/// Keeping these apart is what makes the queue and live paths consistent where
/// they should be and intentionally different where they should be. See
/// `TextPostProcessorTests` for the pinned behaviour of both.
enum TextPostProcessor {

    // MARK: - Transcript stage

    /// Applies transcript-level formatting shared by every consumption path.
    ///
    /// Previously this lived inside each engine, duplicated between
    /// `WhisperEngine` and `FluidAudioEngine`, which meant a third engine could
    /// silently ship without it. Engines now return their text unformatted and
    /// this runs once for all of them.
    ///
    /// The order of the three deterministic passes is load-bearing.
    ///
    /// Chinese script normalization runs **before either of the others**, and
    /// the rule it follows is: *convert the recognizer's words, never the
    /// user's*. Everything the user wrote themselves - a dictionary entry, a
    /// voice snippet template - is spliced in after it and is inserted in the
    /// script they stored it in. See `ChineseScriptNormalizer`.
    ///
    /// The personal terms dictionary then runs **before CJK spacing**, so
    /// entries match what the user actually said rather than a respaced version
    /// of it, and the spans it protects are held out of CJK autocorrect.
    /// Reversing those two would let autocorrect respace a term the user had
    /// just pinned. Normalization cannot break a term match either way, because
    /// the matcher compares script-folded text (`ChineseScriptFolding`).
    ///
    /// `terms` is injectable for tests; in the app it is `settings.personalTerms`,
    /// the same dictionary Whisper was shown before decoding. Passing terms does
    /// not bypass the toggle - `safeCorrectionEnabled` still decides whether the
    /// stage runs at all.
    static func process(
        _ text: String,
        settings: Settings,
        terms: [PersonalTerm]? = nil
    ) -> ProcessedText {
        guard !text.isEmpty else { return .unchanged(text) }

        // Which Chinese this transcript is written in. Deterministic and
        // offline - ICU, one character at a time - and a no-op for every
        // language that is not Chinese. It runs first so that what it converts
        // is the machine's words and never the user's.
        let normalized = ChineseScriptNormalizer.normalized(
            text,
            to: settings.chineseOutputScript,
            languageCode: settings.selectedLanguage
        )

        // Deterministic safe correction: no model, no network, no macOS 26.
        // Independent of any later style-rewriting setting.
        let activeTerms = settings.safeCorrectionEnabled
            ? (terms ?? settings.personalTerms)
            : []
        let corrected = PersonalTermsCorrector.apply(activeTerms, to: normalized)

        var result = corrected.text

        // CJK/Latin spacing. Gated exactly as before: Asian language selected
        // and the user preference enabled.
        if settings.shouldApplyAsianAutocorrect {
            result = applyAsianAutocorrect(to: corrected)
        }

        return ProcessedText(
            raw: text, final: result, mustSurviveTokens: corrected.mustSurviveTokens
        )
    }

    /// Runs the CJK/Latin spacing library over everything except the spans the
    /// dictionary marked never-correct.
    ///
    /// The library is a C function that takes a string and returns a string, so
    /// there is no way to tell it to leave a range alone. Splitting the text at
    /// the protected boundaries and formatting only the gaps is what actually
    /// guarantees a pinned span comes out byte-identical. The visible
    /// consequence is that no spacing is introduced immediately adjacent to a
    /// protected span either, which is the honest reading of "never correct".
    private static func applyAsianAutocorrect(to correction: TermsCorrection) -> String {
        guard !correction.protectedRanges.isEmpty else {
            return AutocorrectWrapper.format(correction.text)
        }

        let characters = Array(correction.text)
        var result = ""
        var cursor = 0

        for range in correction.protectedRanges {
            if cursor < range.lowerBound {
                result += AutocorrectWrapper.format(String(characters[cursor ..< range.lowerBound]))
            }
            result += String(characters[range])
            cursor = range.upperBound
        }
        if cursor < characters.count {
            result += AutocorrectWrapper.format(String(characters[cursor...]))
        }

        return result
    }

    // MARK: - Insertion stage

    /// Applies formatting for text emitted by the live dictation path.
    ///
    /// Appends a trailing space after punctuation so that
    /// consecutive dictations do not run together in the target app. This is an
    /// insertion affordance, not part of the transcript: the stored `Recording`
    /// and the history "Copy entire text" button intentionally do not get it.
    static func prepareForInsertion(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }
}
