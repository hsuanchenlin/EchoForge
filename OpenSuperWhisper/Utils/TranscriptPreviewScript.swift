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
/// Three properties make it safe to run on a preview, and each is a test.
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
///    joined line, so its answer moves as the line grows, and a verdict that
///    moves rewrites characters already on the user's screen. With the language
///    as the only input the verdict is fixed for the session and the conversion
///    is character-wise, so **the line is monotone by construction**: every
///    prefix comes out of a later call exactly as it did out of the earlier one.
/// 3. **It can never show a script the paste will not produce.** A Chinese
///    language is also the branch of `ChineseScriptVariant.isChineseOutput`
///    that needs no evidence, so wherever this converts, the transcript stage
///    converts the same characters the same way. The one place the two part is
///    a language that has not said - `auto`, or a code the app does not know -
///    where the transcript stage may still convert on the text's own evidence
///    and this does not: a preview holds a prefix, and under `auto` a Han-only
///    prefix is as readily the opening of a Japanese sentence. Then the preview
///    shows the engine's own characters, which is what it did before this
///    existed.
enum TranscriptPreviewScript {

    /// `partial` written in `variant`, or exactly as it is when the dictation
    /// language has not said it is Chinese.
    ///
    /// - Parameters:
    ///   - partial: what has been committed so far, as the engine returned it.
    ///   - variant: the user's chosen output script, `Settings.chineseOutputScript`.
    ///   - languageCode: the language the decode ran in. For a live session
    ///     that is `LiveLanguagePin.decodeLanguage` - the pinned language once
    ///     one is pinned, which is a better answer than `auto` and the one the
    ///     engine was actually asked for.
    static func normalized(
        _ partial: PartialTranscript, to variant: ChineseScriptVariant, languageCode: String
    ) -> PartialTranscript {
        guard ChineseScriptVariant.isChineseLanguage(languageCode) else {
            return partial
        }
        return PartialTranscript(
            text: ChineseScriptNormalizer.convert(partial.text, to: variant),
            segment: ChineseScriptNormalizer.convert(partial.segment, to: variant),
            segmentCount: partial.segmentCount)
    }
}
