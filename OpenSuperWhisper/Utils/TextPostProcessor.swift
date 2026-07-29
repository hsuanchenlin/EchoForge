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
    /// The text the app stores, displays and inserts.
    let final: String

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
/// 2. **The insertion stage** - ``prepareForInsertion(_:)``. Affordances that
///    only make sense when text is typed at the user's cursor, and which
///    deliberately do *not* belong to the stored transcript. Only the live
///    dictation indicator inserts text, so only it applies this stage.
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
    static func process(_ text: String, settings: Settings) -> ProcessedText {
        guard !text.isEmpty else { return .unchanged(text) }

        var result = text

        // CJK/Latin spacing. Gated exactly as before: Asian language selected
        // and the user preference enabled.
        if settings.shouldApplyAsianAutocorrect {
            result = AutocorrectWrapper.format(result)
        }

        return ProcessedText(raw: text, final: result)
    }

    // MARK: - Insertion stage

    /// Applies formatting that only makes sense when inserting at the cursor.
    ///
    /// Appends a trailing space after sentence-ending punctuation so that
    /// consecutive dictations do not run together in the target app. This is an
    /// insertion affordance, not part of the transcript: the stored `Recording`
    /// and the history "Copy entire text" button intentionally do not get it,
    /// because neither is typing into a live text field.
    static func prepareForInsertion(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }
}
