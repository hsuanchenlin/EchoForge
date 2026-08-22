import Foundation

/// What one dictation turned out to be asking for.
///
/// Three cases, and the ordinary one is deliberately first among equals:
/// **anything the grammar does not recognise is dictation**, unchanged, on its
/// way into whatever app the user was typing in. Every rule below is written to
/// fail towards that case, because a mis-read command costs the user their
/// paste and a missed command costs them nothing but a retry.
enum SpokenIntent: Equatable, Sendable {
    /// Ordinary dictation. Carries the transcript exactly as it arrived.
    case dictate(String)
    /// A question for the Ask panel, with the marker stripped off the front.
    case ask(query: String)
    /// Text to translate, with the marker and the language name stripped.
    case translate(target: SpokenTranslationTarget, text: String)
    /// A voice snippet, and the template it expands into. The expansion is the
    /// user's own text and is carried through untouched - see `VoiceSnippet`.
    case snippet(keyword: String, expansion: String)

    // There is deliberately **no case here that opens anything**. Opening a
    // channel's latest video is not a reading of a dictation at all: it has its
    // own hotkey, its own capture and its own router (`YouTubeCommandRouter`),
    // so no transcript the dictation shortcut captured can reach a browser
    // however it is worded. See `DictationPurpose`.
}

/// The language a `translate` intent named, and the two ways it is written down.
///
/// `languageCode` is what the instruction and the rest of the app key on;
/// `chineseVariant` exists because "翻譯成中文" and "翻譯成簡體中文" are two
/// different requests that share a language code, and the difference is visible
/// in every character of the answer.
struct SpokenTranslationTarget: Equatable, Sendable {
    /// An ISO code from `LanguageUtil.languageNames`, so every surface that
    /// names a language keeps reading it from one place.
    let languageCode: String

    /// Which Chinese the user asked for, when they said. `nil` for every other
    /// language, and for a bare "Chinese" - `route` resolves that one against
    /// the caller's fallback (the user's chosen output script) rather than
    /// guessing here.
    let chineseVariant: ChineseScriptVariant?

    init(languageCode: String, chineseVariant: ChineseScriptVariant? = nil) {
        self.languageCode = languageCode
        self.chineseVariant = chineseVariant
    }

    /// The full name, for the panel and the docs: "Traditional Chinese".
    var displayName: String {
        guard let chineseVariant else {
            return LanguageUtil.languageNames[languageCode] ?? languageCode
        }
        return chineseVariant == .traditional ? "Traditional Chinese" : "Simplified Chinese"
    }

    /// The name where there is room for one word - the capsule HUD's mode chip,
    /// which reads "Translate Chinese" rather than "Translate Traditional
    /// Chinese". The same division `StyleRewriteStyle` makes between `name` and
    /// `shortName`.
    var shortDisplayName: String {
        LanguageUtil.languageNames[languageCode] ?? languageCode
    }
}

/// Turns a transcript into what the app should do with it, by grammar alone.
///
/// Deterministic and pure on purpose. The obvious alternative - asking the
/// on-device model to classify the dictation - would put a model in front of
/// *every* dictation, make "did my words get pasted" depend on how the model
/// felt about them, and cost the user a second of latency on the plain path
/// that is 99 % of the traffic. A table of prefixes is instead exactly as
/// predictable as the user's own habit, and this file is the whole
/// specification of it.
///
/// The routing is off by default (`AppPreferences.spokenIntentsEnabled`) and
/// only the live dictation path asks for it - see `SpokenIntentPipeline`.
/// `docs/spoken-intents.md` is the feature's whole story.
enum SpokenIntentRouter {

    /// Classifies one transcript.
    ///
    /// - Parameters:
    ///   - transcript: the deterministic pipeline's output - script
    ///     normalization, personal terms and CJK spacing have all run, which is
    ///     what makes a user's own spelling of a language name work, and why
    ///     every CJK spelling below is listed in both scripts.
    ///   - snippets: the user's voice snippets, already filtered to the ones
    ///     that may fire. Empty - the default - is every caller that does not
    ///     have them, and a router with no snippets behaves exactly as it did
    ///     before they existed.
    ///   - fallbackChineseVariant: which Chinese "翻譯成中文" means when the
    ///     request itself does not say. Production passes the user's chosen
    ///     output script; a test states it.
    static func route(
        _ transcript: String,
        snippets: [VoiceSnippet] = [],
        fallbackChineseVariant: ChineseScriptVariant? = nil
    ) -> SpokenIntent {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .dictate(transcript) }

        // The built-in grammar is tried first, so a snippet keyword can never
        // take a command away from the two features that shipped before it.
        // Nothing here competes in practice - a translation needs a language
        // name and "Ask:" needs its punctuation - and a fixed order is one less
        // thing for a user's own keyword to change about the app.
        if let translate = matchTranslate(trimmed, fallbackChineseVariant: fallbackChineseVariant) {
            return translate
        }
        if let ask = matchAsk(trimmed) {
            return ask
        }
        if let snippet = matchSnippet(trimmed, snippets: snippets) {
            return snippet
        }
        return .dictate(transcript)
    }

    // MARK: - Ask

    private static func matchAsk(_ text: String) -> SpokenIntent? {
        for marker in SpokenIntentGrammar.askMarkers {
            guard let rest = remainder(after: marker, in: text) else { continue }
            // The delimiter did its job by being there; it is punctuation the
            // speaker's pause turned into, not part of what they asked.
            let query = strippingLeadingSeparators(rest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A marker with nothing behind it is a word the user said, not a
            // question they asked.
            guard !query.isEmpty else { continue }
            return .ask(query: query)
        }
        return nil
    }

    // MARK: - Translate

    private static func matchTranslate(
        _ text: String, fallbackChineseVariant: ChineseScriptVariant?
    ) -> SpokenIntent? {
        for marker in SpokenIntentGrammar.translateMarkers {
            guard let afterMarker = remainder(after: marker, in: text) else { continue }
            let afterSeparator = strippingLeadingSeparators(afterMarker)
            guard let named = SpokenLanguageLexicon.matchLeadingName(in: afterSeparator) else {
                // "Translate to Klingon: …" names no language this app knows, so
                // there is no translation to run and the words are dictation.
                continue
            }
            let body = strippingLeadingSeparators(named.remainder)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // "Translate to Spanish" on its own set a target and gave nothing to
            // translate. Dictating those three words is the only reading left.
            guard !body.isEmpty else { continue }
            return .translate(
                target: SpokenTranslationTarget(
                    languageCode: named.languageCode,
                    chineseVariant: named.chineseVariant ?? impliedVariant(
                        for: named.languageCode, fallback: fallbackChineseVariant
                    )
                ),
                text: body
            )
        }
        return nil
    }

    /// A bare "Chinese" carries no variant of its own, so the caller's fallback
    /// stands in - and only for Chinese, where the distinction exists.
    private static func impliedVariant(
        for languageCode: String, fallback: ChineseScriptVariant?
    ) -> ChineseScriptVariant? {
        guard ChineseScriptVariant.chineseLanguageCodes.contains(languageCode) else { return nil }
        return fallback
    }

    /// What follows `marker` at the start of `text`, comparing both with their
    /// whitespace removed.
    ///
    /// Only this grammar uses it, and only because its markers are the ones that
    /// mix scripts: a transcript writes "打開 YouTube 最新影片" or
    /// "打開YouTube最新影片" depending on the engine and the day, and a table of
    /// every spacing of every marker would be a table that is always missing the
    /// one a user just said. The delimiter rule is applied to the remainder
    /// exactly as `remainder(after:in:)` applies it, so an English marker still
    /// has to end at a word boundary.
    static func remainderIgnoringInternalWhitespace(
        after marker: SpokenIntentMarker, in text: String
    ) -> String? {
        let characters = Array(text)
        let needle = Array(marker.text).filter { !$0.isWhitespace }
        var position = 0
        var matched = 0

        while matched < needle.count {
            guard position < characters.count else { return nil }
            let character = characters[position]
            if character.isWhitespace {
                position += 1
                continue
            }
            guard String(character).lowercased() == String(needle[matched]).lowercased() else {
                return nil
            }
            position += 1
            matched += 1
        }

        let rest = String(characters[position...])
        switch marker.delimiter {
        case .none:
            return rest
        case .punctuation:
            guard let first = rest.first, isSeparatorPunctuation(first) else { return nil }
            return rest
        case .punctuationOrSpace:
            guard let first = rest.first,
                  isSeparatorPunctuation(first) || first.isWhitespace else { return nil }
            return rest
        }
    }

    // MARK: - Snippets

    /// Two ways to fire a snippet, and both of them demand a keyword this user
    /// actually stored.
    ///
    /// 1. **Marker-led** - "insert email signoff", "插入會議記錄". The marker is an
    ///    ordinary word, so what carries the reading is not the marker but the
    ///    exact keyword behind it: "insert a row here" names no snippet and is
    ///    dictation, the same way "Translate the document" names no language.
    /// 2. **The keyword alone** - a dictation that is nothing but the trigger.
    ///    It has to be the *whole* transcript, which is what keeps a keyword
    ///    that is also an ordinary phrase from swallowing the sentence it
    ///    appears in. "Email signoff." said on its own is a macro; "the email
    ///    signoff was wrong" is dictation.
    ///
    /// Nothing partial fires: a remainder that does not match a keyword in full
    /// leaves the transcript alone, because inserting the wrong template costs
    /// the user their dictation and a missed trigger costs them a retry.
    private static func matchSnippet(_ text: String, snippets: [VoiceSnippet]) -> SpokenIntent? {
        guard !snippets.isEmpty else { return nil }
        // First one wins, so two enabled snippets sharing a trigger resolve to
        // the one nearer the top of the user's own list rather than to whichever
        // a dictionary happened to hash first.
        var index: [String: VoiceSnippet] = [:]
        for snippet in snippets where snippet.isValid {
            let key = snippet.triggerKey
            if index[key] == nil { index[key] = snippet }
        }
        guard !index.isEmpty else { return nil }

        for marker in SpokenIntentGrammar.snippetMarkers {
            guard let rest = remainder(after: marker, in: text) else { continue }
            let key = VoiceSnippetTrigger.normalize(rest)
            guard let snippet = index[key] else { continue }
            return .snippet(keyword: snippet.keyword, expansion: snippet.expansion)
        }

        guard let snippet = index[VoiceSnippetTrigger.normalize(text)] else { return nil }
        return .snippet(keyword: snippet.keyword, expansion: snippet.expansion)
    }

    // MARK: - Matching one marker

    /// What follows `marker` at the start of `text`, or nil when the marker is
    /// not there or is not delimited the way it requires.
    static func remainder(after marker: SpokenIntentMarker, in text: String) -> String? {
        guard let range = text.range(
            of: marker.text, options: [.caseInsensitive, .anchored], locale: nil
        ) else { return nil }

        let rest = String(text[range.upperBound...])
        switch marker.delimiter {
        case .none:
            return rest
        case .punctuation:
            guard let first = rest.first, isSeparatorPunctuation(first) else { return nil }
            return rest
        case .punctuationOrSpace:
            guard let first = rest.first,
                  isSeparatorPunctuation(first) || first.isWhitespace else { return nil }
            return rest
        }
    }

    /// The punctuation a speaker's pause comes back as. Both widths, because a
    /// Chinese transcript uses the full-width forms throughout.
    private static let separatorPunctuation: Set<Character> = [
        ":", "：", ",", "，", "、", "-", "–", "—", ".", "。", "？", "?", "！", "!",
    ]

    private static func isSeparatorPunctuation(_ character: Character) -> Bool {
        separatorPunctuation.contains(character)
    }

    /// Shared with `YouTubeCommandRouter`, which strips the same punctuation a
    /// speaker's pause becomes off the front of a command it recognised.
    static func strippingLeadingSeparators(_ text: String) -> String {
        String(text.drop { isSeparatorPunctuation($0) || $0.isWhitespace })
    }
}

/// One spoken prefix, and how much punctuation it needs behind it to count.
///
/// The delimiter is the whole defence against a false positive, and false
/// positives are the only failure of this feature that costs a user anything:
/// a mis-read command sends their dictation somewhere they did not ask for,
/// while a missed command leaves them exactly where they were.
struct SpokenIntentMarker: Equatable, Sendable {
    enum Delimiter: Equatable, Sendable {
        /// The marker is a phrase nothing else starts with, so what follows it
        /// may follow immediately.
        case none
        /// A pause is required, and the transcript writes a pause as
        /// punctuation. For markers that are also ordinary words.
        case punctuation
        /// Punctuation or a space. For markers that are ordinary words in a
        /// language written without spaces, where a space is itself the pause.
        case punctuationOrSpace
    }

    let text: String
    let delimiter: Delimiter
}

/// The prefixes, in the order they are tried.
///
/// Longest first within each family, so "translate into" is not read as
/// "translate" followed by a language called "into".
enum SpokenIntentGrammar {

    /// "Ask: what is the capital of France" - and its Chinese equivalents.
    ///
    /// Every one of these is also an ordinary word, which is why every one of
    /// them is delimited:
    ///
    /// - English `ask` needs punctuation. "Ask him to call me back" is a
    ///   sentence people dictate, and a space would let it through.
    /// - `請問` / `请问` is a fixed polite formula that opens a question, so it
    ///   needs nothing behind it. It is not free of ambiguity - "请问他什么时候来"
    ///   is "please ask him when he is coming" - and that is the documented
    ///   cost of making the Chinese form usable at all, since Mandarin
    ///   transcripts do not come back with a space after it.
    /// - bare `問` / `问` needs punctuation or a space, which is what the space
    ///   in "問 [問題]" is doing.
    static let askMarkers: [SpokenIntentMarker] = [
        SpokenIntentMarker(text: "ask", delimiter: .punctuation),
        SpokenIntentMarker(text: "請問", delimiter: .none),
        SpokenIntentMarker(text: "请问", delimiter: .none),
        SpokenIntentMarker(text: "問", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "问", delimiter: .punctuationOrSpace),
    ]

    /// "Translate to Spanish: …" - and its Chinese equivalents.
    ///
    /// None of these need a delimiter of their own: a language name has to
    /// follow, and that is a much stronger constraint than any punctuation.
    /// "Translate the document for me" names no language and stays dictation.
    static let translateMarkers: [SpokenIntentMarker] = [
        SpokenIntentMarker(text: "translate this into", delimiter: .none),
        SpokenIntentMarker(text: "translate this to", delimiter: .none),
        SpokenIntentMarker(text: "translate it into", delimiter: .none),
        SpokenIntentMarker(text: "translate it to", delimiter: .none),
        SpokenIntentMarker(text: "translate into", delimiter: .none),
        SpokenIntentMarker(text: "translate to", delimiter: .none),
        SpokenIntentMarker(text: "translate", delimiter: .none),
        SpokenIntentMarker(text: "幫我翻譯成", delimiter: .none),
        SpokenIntentMarker(text: "帮我翻译成", delimiter: .none),
        SpokenIntentMarker(text: "翻譯成", delimiter: .none),
        SpokenIntentMarker(text: "翻译成", delimiter: .none),
        SpokenIntentMarker(text: "翻譯為", delimiter: .none),
        SpokenIntentMarker(text: "翻译为", delimiter: .none),
        SpokenIntentMarker(text: "翻成", delimiter: .none),
        SpokenIntentMarker(text: "譯成", delimiter: .none),
        SpokenIntentMarker(text: "译成", delimiter: .none),
    ]

    /// "Open the latest YouTube video from [channel]" and "open the YouTube
    /// channel [channel]" - and their Chinese equivalents.
    ///
    /// Two families, and the second one is why this table is not only about
    /// videos. A user names the thing they have in mind, and that is as easily
    /// the **channel** as the video: "open YouTube channel Valley 101" was said
    /// into the command key four times running and refused every time as an
    /// unknown channel - because with no marker matched the whole sentence
    /// becomes the spoken name, and no allowlist has a row called "open youtube
    /// channel valley 101". The refusal then names the allowlist, which was the
    /// one thing that was right. Both families ask this app for the same thing,
    /// so both are listed.
    ///
    /// Longest first within each family, so "open the latest YouTube video from"
    /// is not read as "open the latest YouTube video" followed by a channel
    /// called "from", and "open the YouTube channel" is not read as "open"
    /// followed by one called "the YouTube channel". No marker here is a prefix
    /// of another, which is what lets the families sit in separate blocks.
    ///
    /// Every spelling names YouTube. That is not decoration: it is what keeps
    /// this grammar from reaching a sentence anyone would dictate, and it is why
    /// this is the one command whose failures are reported instead of falling
    /// back to dictation. The English forms end in "from" or in "channel" and
    /// take a space or punctuation behind it; the Chinese ones need no
    /// delimiter, for the reason every CJK marker here does not - a Mandarin
    /// transcript has no space to require - and are matched with whitespace
    /// ignored, since an engine may write "打開 YouTube 最新影片" or
    /// "打開YouTube最新影片" for the same words.
    ///
    /// Widening the *marker* is not widening the *match*: what follows still has
    /// to be one stored spelling in full, through the same two tiers
    /// (`YouTubeChannelAllowlist.resolve`), so "open YouTube channel Valley"
    /// and "open YouTube channel Bali 101" reach nothing, exactly as they did.
    ///
    /// Every CJK spelling is listed in both scripts, closed under ICU's
    /// per-character conversion - which is why 啓 stands beside 啟 and 視頻
    /// beside 视频: the transcript this router reads has already been written in
    /// the user's chosen script by `ChineseScriptNormalizer`, so a Simplified
    /// speaker whose output is Traditional says "打开YouTube最新视频" and the
    /// router is handed "打開YouTube最新視頻". A spelling whose converted form
    /// were missing would turn that command back into dictation and paste it.
    /// `SpokenIntentRouterTests` converts every entry both ways and fails if
    /// the result is not also an entry.
    static let openLatestVideoMarkers: [SpokenIntentMarker] = [
        SpokenIntentMarker(text: "open the latest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "open the newest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play the latest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play the newest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "open latest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play latest youtube video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "open youtube latest video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play youtube latest video from", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "打開YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "打开YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "打開YouTube最新的影片", delimiter: .none),
        SpokenIntentMarker(text: "打开YouTube最新的影片", delimiter: .none),
        SpokenIntentMarker(text: "打开YouTube最新视频", delimiter: .none),
        SpokenIntentMarker(text: "打開YouTube最新視頻", delimiter: .none),
        SpokenIntentMarker(text: "開啟YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "开启YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "開啓YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "开启YouTube最新视频", delimiter: .none),
        SpokenIntentMarker(text: "開啓YouTube最新視頻", delimiter: .none),
        SpokenIntentMarker(text: "播放YouTube最新影片", delimiter: .none),
        SpokenIntentMarker(text: "播放YouTube最新视频", delimiter: .none),
        SpokenIntentMarker(text: "播放YouTube最新視頻", delimiter: .none),
        // The channel family. Same command, same answer - the newest video from
        // the named channel - said as the channel rather than as the video.
        SpokenIntentMarker(text: "open the youtube channel", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play the youtube channel", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "open youtube channel", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "play youtube channel", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "打開YouTube頻道", delimiter: .none),
        SpokenIntentMarker(text: "打开YouTube频道", delimiter: .none),
        SpokenIntentMarker(text: "開啟YouTube頻道", delimiter: .none),
        SpokenIntentMarker(text: "開啓YouTube頻道", delimiter: .none),
        SpokenIntentMarker(text: "开启YouTube频道", delimiter: .none),
        SpokenIntentMarker(text: "播放YouTube頻道", delimiter: .none),
        SpokenIntentMarker(text: "播放YouTube频道", delimiter: .none),
    ]

    /// "Insert email signoff" - and its Chinese equivalents.
    ///
    /// Longest first, so "insert snippet meeting template" is not read as
    /// "insert" followed by a snippet called "snippet meeting template".
    ///
    /// The English markers need a space or punctuation behind them because they
    /// are ordinary words; the Chinese ones need nothing, for the reason every
    /// CJK marker here does - a Mandarin transcript has no space to require. In
    /// both cases the real constraint is the one that follows: what comes after
    /// the marker has to be a keyword this user stored, or the words stay
    /// dictation.
    static let snippetMarkers: [SpokenIntentMarker] = [
        SpokenIntentMarker(text: "insert snippet", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "insert", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "snippet", delimiter: .punctuationOrSpace),
        SpokenIntentMarker(text: "插入片語", delimiter: .none),
        SpokenIntentMarker(text: "插入片语", delimiter: .none),
        SpokenIntentMarker(text: "插入", delimiter: .none),
    ]
}

/// The language names a user can say, and the codes they mean.
///
/// English names come from `LanguageUtil.languageNames`, which is the app's one
/// list of what a language is called - a second hand-written copy here would
/// drift from the picker. The aliases and the Chinese names are what this file
/// adds, because nobody says "auto-detect" out loud and nobody dictating
/// Mandarin says "Spanish".
enum SpokenLanguageLexicon {

    /// One matched name: the code it means, whether it pinned a Chinese variant,
    /// and what was left of the transcript behind it.
    struct Match: Equatable {
        let languageCode: String
        let chineseVariant: ChineseScriptVariant?
        let remainder: String
    }

    /// Names that carry a Chinese variant with them. Kept apart from the plain
    /// table because these are the only entries whose match says more than a
    /// language code.
    ///
    /// Every CJK spelling here and in `aliases` is listed in **both** scripts,
    /// and that is now load-bearing rather than merely generous: the transcript
    /// this router reads has already been written in the user's chosen script by
    /// `ChineseScriptNormalizer`, so a Simplified speaker whose output is
    /// Traditional says "翻译成意大利语" and the router is handed
    /// "翻譯成意大利語". A spelling whose counterpart were missing would turn
    /// that command back into dictation. `SpokenIntentRouterTests` converts
    /// every entry both ways and fails if the result is not also an entry.
    static let variantNames: [String: ChineseScriptVariant] = [
        "traditional chinese": .traditional,
        "chinese traditional": .traditional,
        "simplified chinese": .simplified,
        "chinese simplified": .simplified,
        "繁體中文": .traditional,
        "繁体中文": .traditional,
        "繁中": .traditional,
        "正體中文": .traditional,
        "正体中文": .traditional,
        "简体中文": .simplified,
        "簡體中文": .simplified,
        "简中": .simplified,
        "簡中": .simplified,
    ]

    /// Everything else a user might say, beyond the English names the picker
    /// already knows.
    static let aliases: [String: String] = [
        "mandarin": "zh",
        "putonghua": "zh",
        "中文": "zh",
        "普通話": "zh",
        "普通话": "zh",
        "國語": "zh",
        "国语": "zh",
        "華語": "zh",
        "华语": "zh",
        "粵語": "yue",
        "粤语": "yue",
        "廣東話": "yue",
        "广东话": "yue",
        "英文": "en",
        "英語": "en",
        "英语": "en",
        "日文": "ja",
        "日語": "ja",
        "日语": "ja",
        "韓文": "ko",
        "韓語": "ko",
        "韩文": "ko",
        "韩语": "ko",
        "西班牙文": "es",
        "西班牙語": "es",
        "西班牙语": "es",
        "法文": "fr",
        "法語": "fr",
        "法语": "fr",
        "德文": "de",
        "德語": "de",
        "德语": "de",
        "俄文": "ru",
        "俄語": "ru",
        "俄语": "ru",
        "葡萄牙文": "pt",
        "葡萄牙語": "pt",
        "葡萄牙语": "pt",
        "義大利文": "it",
        "意大利文": "it",
        "义大利文": "it",
        "義大利語": "it",
        "意大利語": "it",
        "意大利语": "it",
        "义大利语": "it",
        "荷蘭文": "nl",
        "荷兰文": "nl",
        "阿拉伯文": "ar",
        "阿拉伯語": "ar",
        "阿拉伯语": "ar",
        "希伯來文": "he",
        "希伯来文": "he",
        "土耳其文": "tr",
        "土耳其語": "tr",
        "土耳其语": "tr",
        "波蘭文": "pl",
        "波兰文": "pl",
        "瑞典文": "sv",
        "瑞典語": "sv",
        "瑞典语": "sv",
        "印尼文": "id",
        "印尼語": "id",
        "印尼语": "id",
        "印地文": "hi",
        "印地語": "hi",
        "印地语": "hi",
        "芬蘭文": "fi",
        "芬兰文": "fi",
        "烏克蘭文": "uk",
        "乌克兰文": "uk",
        "越南文": "vi",
        "越南語": "vi",
        "越南语": "vi",
        "泰文": "th",
        "泰語": "th",
        "泰语": "th",
    ]

    /// Every spelling this app recognises, longest first.
    ///
    /// The order is what makes "traditional chinese" beat "chinese": both match
    /// the same prefix and only the longer one is the request the user made.
    static let names: [(spelling: String, code: String, variant: ChineseScriptVariant?)] = {
        var entries: [(String, String, ChineseScriptVariant?)] = []
        for (spelling, variant) in variantNames {
            entries.append((spelling, "zh", variant))
        }
        for (spelling, code) in aliases {
            entries.append((spelling, code, nil))
        }
        for (code, name) in LanguageUtil.languageNames where code != "auto" {
            entries.append((name.lowercased(), code, nil))
        }
        return entries.sorted { left, right in
            left.0.count == right.0.count ? left.0 < right.0 : left.0.count > right.0.count
        }
    }()

    /// The language named at the start of `text`, if any.
    static func matchLeadingName(in text: String) -> Match? {
        for entry in names {
            guard let range = text.range(
                of: entry.spelling, options: [.caseInsensitive, .anchored], locale: nil
            ) else { continue }
            // A Latin name has to end where it ends: "Frenchman" is not
            // French. Only ASCII spellings can take that check - the body a
            // CJK name introduces is itself letters, so requiring a boundary
            // would refuse every real CJK command. The accepted cost is that
            // "德語課…" reads as German followed by "課…"; see the known limits
            // in docs/spoken-intents.md.
            let rest = String(text[range.upperBound...])
            if let next = rest.first, next.isLetter, entry.spelling.allSatisfy(\.isASCII) {
                continue
            }
            return Match(
                languageCode: entry.code, chineseVariant: entry.variant, remainder: rest
            )
        }
        return nil
    }
}
