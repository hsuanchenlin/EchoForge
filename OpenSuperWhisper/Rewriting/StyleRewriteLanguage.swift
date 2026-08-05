import Foundation

/// The language a rewrite is being asked for - which decides what language the
/// model is *asked* in, not only what it is asked to produce.
///
/// This exists because of one measured behaviour of the on-device model: given
/// Chinese dictation and an English style instruction, it frequently answers in
/// English. "Formal Business" translated a Mandarin transcript into English on
/// every attempt, and "Casual Chat" on most of them. `StyleRewriteGuard` caught
/// each one, so nothing wrong reached the user - but the user got no rewrite at
/// all, which is what "I cannot use the rewrite styles for Chinese" looks like
/// from the outside. Asking in Chinese fixes it: measured across the six styles,
/// both scripts and repeated runs, every answer came back Chinese.
///
/// The variant is part of the value for the same reason, one level down. A
/// Traditional instruction converts Simplified dictation to Traditional and the
/// reverse, both silently; matching the instruction's own variant to the
/// transcript's kept every measured run in the transcript's variant. So the
/// question this type answers is not "is it Chinese" but "which Chinese", and
/// there is no `.chinese` without one.
enum StyleRewriteLanguage: Equatable, Sendable {
    case chinese(ChineseScriptVariant)
    /// Everything else, including a dictation language whose transcript came
    /// back in Latin script. English instructions are the default because that
    /// is what the model follows most reliably where it has no reason to switch.
    case other

    var chineseVariant: ChineseScriptVariant? {
        if case .chinese(let variant) = self { return variant }
        return nil
    }

    /// Which language to ask in for one transcript.
    ///
    /// **The transcript decides, and the dictation language only breaks ties.**
    /// A user who leaves the language on Chinese and dictates a sentence of
    /// English must not have it rewritten into Chinese, and a user dictating
    /// Chinese with the language on auto-detect must still get Chinese
    /// instructions. Both fall out of reading the text rather than the setting.
    ///
    /// - Parameters:
    ///   - languageCode: the dictation language, or `auto`. Its only job is to
    ///     rule Chinese *out* for a language that shares the script - Japanese
    ///     kanji and Korean hanja are Han characters too.
    ///   - transcript: the deterministic pipeline's output, the text that will
    ///     be rewritten.
    ///   - fallbackVariant: which variant to ask in when the transcript is
    ///     Chinese but is written entirely in characters the two share.
    ///     Production reads the user's own languages; a test states it.
    static func resolve(
        languageCode: String,
        transcript: String,
        fallbackVariant: ChineseScriptVariant = ChineseScriptVariant.systemPreferred
    ) -> StyleRewriteLanguage {
        guard mayBeChinese(languageCode: languageCode), isHanDominant(transcript) else {
            return .other
        }
        return .chinese(ChineseScriptVariant.detected(in: transcript) ?? fallbackVariant)
    }

    /// The user's own instruction, prefixed so that a Chinese dictation is
    /// restyled in Chinese whatever language they wrote their prompt in.
    ///
    /// A custom prompt is usually written in English even by users who dictate
    /// in Chinese - it is typed into a Settings pane whose own text is English -
    /// and an English instruction is exactly what makes the model answer in
    /// English. The prompt itself is left untouched: this adds a sentence in
    /// front of it and never edits it.
    func wrapping(customPrompt: String) -> String {
        switch self {
        case .other:
            return customPrompt
        case .chinese(.traditional):
            return """
            請依照下面這項指示改寫這段中文逐字稿。不管指示是用哪一種語言寫的，改寫出來的結果都必須是中文，而且要和逐字稿用同一種字體（繁體或簡體）。

            \(customPrompt)
            """
        case .chinese(.simplified):
            return """
            请按照下面这项指示改写这段中文逐字稿。不管指示是用哪一种语言写的，改写出来的结果都必须是中文，而且要和逐字稿用同一种字体（简体或繁体）。

            \(customPrompt)
            """
        }
    }

    // MARK: - Reading the transcript

    /// Whether the dictation language leaves Chinese possible at all.
    ///
    /// Auto-detect and an unknown code both leave it open, because neither says
    /// anything; a language this app knows and that is not Chinese closes it,
    /// which is what keeps Japanese and Korean dictation on the English
    /// instructions their script would otherwise be mistaken for.
    private static func mayBeChinese(languageCode: String) -> Bool {
        let code = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? ""
        if ChineseScriptVariant.chineseLanguageCodes.contains(code) { return true }
        return LanguageUtil.languageNames[code] == nil || code == "auto"
    }

    /// Whether the text is written in Han characters, with no kana or Hangul in
    /// it at all.
    ///
    /// The ratio matches `StyleRewriteGuard`'s script check on purpose - the two
    /// have to agree about what "this transcript is Chinese" means, or the stage
    /// would ask in a language its own guard then rejects. A single kana or
    /// Hangul character is enough to rule it out: Japanese written in kanji
    /// alone is rare, and Japanese written with kana is not Chinese however many
    /// Han characters it also has.
    private static func isHanDominant(_ text: String) -> Bool {
        var letters = 0
        var han = 0
        for character in text where character.isLetter {
            letters += 1
            guard let scalar = character.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x3040 ... 0x30FF,     // Hiragana, Katakana
                 0x1100 ... 0x11FF,     // Hangul jamo
                 0xAC00 ... 0xD7AF:     // Hangul syllables
                return false
            case 0x3400 ... 0x4DBF,     // CJK Extension A
                 0x4E00 ... 0x9FFF,     // CJK Unified Ideographs
                 0xF900 ... 0xFAFF,     // CJK Compatibility Ideographs
                 0x20000 ... 0x2FA1F:   // CJK Extensions B-F and compatibility supplement
                han += 1
            default:
                break
            }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) >= 0.3
    }
}
