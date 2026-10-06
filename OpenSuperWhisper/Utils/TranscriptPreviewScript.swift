import Foundation

/// Writes the words on screen *while* a dictation is still running in the
/// script the user chose, so the preview reads as the paste will.
///
/// The preview is the one place a transcript reached the user without passing
/// through `TextPostProcessor.process`. That stage normalizes the script at its
/// very front (`ChineseScriptNormalizer`), but it runs once, at the end, over
/// the whole transcript - and the capsule has been showing the engine's own
/// words for the length of the recording by then. Paraformer and SenseVoice
/// return Simplified for a speaker of Taiwanese Mandarin and Whisper mixes the
/// two, so a Traditional user watched their sentence appear in Simplified and
/// then switch script at the paste. `docs/chinese-script.md` is why the app
/// decides the script at all; this is the second, read-only place that decision
/// has to be visible.
///
/// Four properties make it safe to run on a preview, and each is a test.
///
/// 1. **It converts nothing but what is shown.** The committed text a session
///    hands back for post-processing is the engine's own, untouched: the paste
///    still comes from the one transcript stage, over the raw transcript, and
///    this has no way to reach it. A preview is a copy made for the screen.
/// 2. **The language decides, and the text is never consulted.**
///    `ChineseScriptVariant.isChineseLanguage` is the whole gate - the user's
///    own choice of a Chinese dictation language, or the one a live session's
///    detection pinned - and `ChineseScriptNormalizer` performs the conversion.
///    Reading the text here is what a preview cannot afford: the share test the
///    transcript stage falls back to (`isHanDominant`) is asked of the *whole*
///    joined line, so its answer moves as the line grows, and under `auto` a
///    Han-only prefix is as readily the opening of a Japanese sentence. So the
///    language is the only input, and the conversion is character-wise.
/// 3. **The line only grows.** Every caller converts a piece of line once, as
///    it publishes it, and never asks about it again: a live session converts
///    the utterance it has just committed and joins it onto the pieces already
///    shown, and the whole-file decode's growing partials are judged by a
///    language that cannot change while the decode runs. A detection that
///    lands mid-session therefore decides the script of the words after it and
///    never of the words already read. The two callers never write the same
///    line either: a live session's own utterance decodes publish no segments
///    of their own (`TranscriptionService.observePartialTranscripts`), so the
///    service's publisher - whose language is the user's `auto`, with no pin to
///    read - cannot put an unconverted copy of the tail on the capsule a moment
///    before the line arrives in the user's script.
/// 4. **It can never show a script the paste will not produce.** A Chinese
///    language is also the branch of `ChineseScriptVariant.isChineseOutput`
///    that needs no evidence, and a live session hands the language it decoded
///    in back with its transcript (`LiveDictationOutcome.committed`), so the
///    paste is post-processed under the same language the line was judged by
///    and converts the same characters the same way. The one place the two part
///    is text published while the language had not said - `auto`, or a code the
///    app does not know - which is shown in the engine's own characters while
///    the transcript stage may convert it, on the whole transcript's own
///    evidence or on a language the pin named afterwards.
enum TranscriptPreviewScript {

    /// `text` written in `variant`, or exactly as it is when the dictation
    /// language has not said it is Chinese.
    ///
    /// The one gate. A caller with a line that grows calls this per piece as it
    /// publishes the piece, which is what makes property 3 structural.
    ///
    /// - Parameters:
    ///   - text: what is about to be shown, as the engine returned it.
    ///   - variant: the user's chosen output script, `Settings.chineseOutputScript`.
    ///   - languageCode: the language the decode ran in. For a live session
    ///     that is `LiveLanguagePin.decodeLanguage` - the pinned language once
    ///     one is pinned, which is a better answer than `auto`, the one the
    ///     engine was actually asked for, and the one the paste is finished
    ///     with.
    static func converted(
        _ text: String, to variant: ChineseScriptVariant, languageCode: String
    ) -> String {
        guard ChineseScriptVariant.isChineseLanguage(languageCode) else {
            return text
        }
        return ChineseScriptNormalizer.convert(text, to: variant)
    }

    /// A whole published preview in `variant`: `text` and `segment` are two
    /// views of one decode, so they are converted by the one verdict above and
    /// cannot come out in different scripts.
    static func normalized(
        _ partial: PartialTranscript, to variant: ChineseScriptVariant, languageCode: String
    ) -> PartialTranscript {
        PartialTranscript(
            text: converted(partial.text, to: variant, languageCode: languageCode),
            segment: converted(partial.segment, to: variant, languageCode: languageCode),
            segmentCount: partial.segmentCount)
    }
}
