import Foundation

/// Writes a Chinese transcript in the script the user chose, whichever one the
/// recognizer happened to return it in.
///
/// The problem it solves is that the script is not the user's to pick at the
/// microphone. Speech carries no script at all, so which one comes back is a
/// property of the model's training data: Paraformer and SenseVoice return
/// Simplified for a speaker of Taiwanese Mandarin, Whisper returns whichever the
/// audio reminded it of and mixes the two inside one sentence. A user who writes
/// Traditional was left correcting every dictation by hand.
///
/// So the app decides instead, once, in one place:
/// `AppPreferences.chineseOutputScript`, Traditional unless the user says
/// otherwise. `docs/chinese-script.md` is the whole story.
///
/// **It is an output setting and only an output setting.** It never makes
/// recognition Chinese, never moves the dictation language, and never leans on
/// auto-detect: what the engine is asked to recognize, and what it decides it
/// heard, are exactly what they were before this existed. English dictation
/// comes back as English on every path, including a Mac whose dictation
/// language is set to Chinese. This type takes the language as an argument and
/// reads no preference at all, which is what makes that structural rather than
/// a promise.
///
/// Four properties carry it, and each is a test:
///
/// 1. **It is deterministic, offline and character-wise.** ICU does the mapping
///    (`HanCharacterTransform`); there is no model, no network, no prompt and no
///    hand-maintained table of characters. The same input gives the same output
///    on every Mac, every time, with the machine in flight mode.
/// 2. **Nothing but Han characters is touched.** Latin words, digits,
///    punctuation, whitespace, timestamps and emoji come out byte for byte as
///    they went in, because a character whose transform is not exactly one
///    character is kept as it was.
/// 3. **Only a Chinese transcript is converted at all** - both the dictation
///    language and the text itself have to say so
///    (`ChineseScriptVariant.isChineseText`), which is the same predicate the
///    rewriting stage asks the same question with.
/// 4. **It converts the recognizer's words, never the user's.** It runs at the
///    very front of `TextPostProcessor.process`, before the personal terms
///    dictionary splices in anything the user typed themselves, and the
///    spoken-intent stage that inserts a voice snippet runs after it and
///    replaces the text wholesale. A term or a snippet the user stored in one
///    script is inserted in that script.
enum ChineseScriptNormalizer {

    /// The transcript, written in `variant` if it is Chinese and left exactly as
    /// it is if it is not.
    ///
    /// - Parameters:
    ///   - text: the recognizer's output, before anything the user wrote has
    ///     been spliced into it.
    ///   - variant: the user's chosen output script.
    ///   - languageCode: the dictation language, or `auto`. Its job is to rule
    ///     Chinese *out* for a language written in the same characters -
    ///     Japanese kanji and Korean hanja are Han too, and converting 学 to 學
    ///     in a Japanese transcript would be a corruption, not a normalization.
    static func normalized(
        _ text: String, to variant: ChineseScriptVariant, languageCode: String
    ) -> String {
        guard ChineseScriptVariant.isChineseText(text, languageCode: languageCode) else {
            return text
        }
        return convert(text, to: variant)
    }

    /// The conversion with no gate in front of it, for the caller that has
    /// already established the text is Chinese and which script it wants -
    /// `TranslationRewrite`, whose target language *is* the answer.
    static func convert(_ text: String, to variant: ChineseScriptVariant) -> String {
        HanCharacterTransform.transform(to: variant).applied(to: text)
    }
}
