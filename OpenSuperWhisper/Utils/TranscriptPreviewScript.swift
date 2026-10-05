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
/// 2. **It uses the transcript stage's predicate and transform.**
///    `ChineseScriptVariant` gates it and `ChineseScriptNormalizer` performs
///    it, and it converts nothing until the language itself says Chinese -
///    the user's own choice of a Chinese dictation language, or the one a live
///    session's detection pinned (`ChineseScriptVariant.isChineseLanguage`).
///    The transcript stage settles for `mayBeChinese` because it reads a
///    finished transcript; a preview is a prefix, and under `auto` a Han-only
///    prefix is as readily the opening of a Japanese sentence - the kana that
///    would rule Chinese out has not been spoken yet. So an unsettled `auto`
///    preview is shown exactly as the engine wrote it, which is what it did
///    before this existed.
/// 3. **One verdict covers the whole preview.** `text` and `segment` are two
///    views of one decode, so the Han-dominance test is asked once, of the
///    joined text, and the segment follows it. Asking separately would let a
///    two-character segment fail a test its own sentence passes, and the line
///    would convert in pieces. Once conversion starts, the verdict remains
///    true for the session so later code-switched English cannot rewrite an
///    already displayed prefix.
struct TranscriptPreviewScript {
    private var conversionTriggered = false

    /// `partial` written in `variant`, or exactly as it is when it is not a
    /// Chinese transcript.
    ///
    /// - Parameters:
    ///   - partial: what has been committed so far, as the engine returned it.
    ///   - variant: the user's chosen output script, `Settings.chineseOutputScript`.
    ///   - languageCode: the language the decode ran in. For a live session
    ///     that is `LiveLanguagePin.decodeLanguage` - the pinned language once
    ///     one is pinned, which is a better answer than `auto` and the one the
    ///     engine was actually asked for.
    mutating func normalized(
        _ partial: PartialTranscript, to variant: ChineseScriptVariant, languageCode: String
    ) -> PartialTranscript {
        guard ChineseScriptVariant.isChineseLanguage(languageCode) else {
            return partial
        }
        if !conversionTriggered {
            conversionTriggered = ChineseScriptVariant.isChineseText(
                partial.text, languageCode: languageCode)
        }
        guard conversionTriggered else {
            return partial
        }
        return PartialTranscript(
            text: ChineseScriptNormalizer.convert(partial.text, to: variant),
            segment: ChineseScriptNormalizer.convert(partial.segment, to: variant),
            segmentCount: partial.segmentCount)
    }
}
