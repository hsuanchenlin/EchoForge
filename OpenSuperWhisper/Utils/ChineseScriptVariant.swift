import Foundation

/// Which of the two Chinese writing systems a piece of text is written in.
///
/// This is not the same question `ChineseScriptFolding` answers. That one folds
/// the two together so a dictionary entry written in either matches dictation in
/// the other; this one tells them apart, because three callers need to know
/// which one the user is actually writing in:
///
/// - it is the value of the user's own choice of output script
///   (`AppPreferences.chineseOutputScript`), which `ChineseScriptNormalizer`
///   writes every Chinese transcript in - Traditional unless they said
///   otherwise;
/// - the rewriting stage picks the instruction written in that variant, since an
///   instruction written in the other one converts the whole rewrite to it (a
///   Simplified dictation restyled by a Traditional instruction came back in
///   Traditional every time it was measured against the shipping on-device
///   model);
/// - `StyleRewriteGuard` refuses a rewrite that switched variant, because to the
///   user that is their own words coming back in a script they do not write.
enum ChineseScriptVariant: String, Equatable, Sendable {
    case traditional
    case simplified

    /// How many characters in `text` are exclusive to each variant.
    ///
    /// Evidence, not a census: a count of zero means "this text does not say",
    /// never "this text is the other one". Both callers are written around that.
    struct Signal: Equatable, Sendable {
        let traditional: Int
        let simplified: Int

        /// True when the text uses one variant's characters and none of the
        /// other's - the only case in which it can be said to be *in* a variant.
        var isDecisive: Bool {
            (traditional > 0) != (simplified > 0)
        }
    }

    static func signal(in text: String) -> Signal {
        var traditional = 0
        var simplified = 0
        for character in text {
            if traditionalOnly.contains(character) { traditional += 1 }
            if simplifiedOnly.contains(character) { simplified += 1 }
        }
        return Signal(traditional: traditional, simplified: simplified)
    }

    /// The variant `text` is written in, or nil when its characters do not say.
    ///
    /// Lightly mixed text - a quoted name, a dictionary term the user spells in
    /// the other variant - still resolves to whichever side it mostly uses, so
    /// that choosing an instruction always has an answer. The guard does not use
    /// this: inventing a single character of the other variant is enough for it,
    /// and it reads `signal(in:)` directly.
    static func detected(in text: String) -> ChineseScriptVariant? {
        let signal = signal(in: text)
        if signal.traditional > signal.simplified { return .traditional }
        if signal.simplified > signal.traditional { return .simplified }
        return nil
    }

    /// The variant this Mac's user most likely writes, for text whose own
    /// characters do not say.
    ///
    /// Their languages first - a Traditional user's list has `zh-Hant` in it
    /// whatever their region - and the region only when none of them is Chinese
    /// at all.
    static var systemPreferred: ChineseScriptVariant {
        preferred(
            languages: Locale.preferredLanguages,
            regionCode: Locale.current.region?.identifier
        )
    }

    /// The rule behind `systemPreferred`, as a pure function so it is testable.
    static func preferred(languages: [String], regionCode: String?) -> ChineseScriptVariant {
        for identifier in languages {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier,
                  chineseLanguageCodes.contains(code) else { continue }
            return language.script?.identifier == "Hant" ? .traditional : .simplified
        }
        return traditionalRegions.contains(regionCode ?? "") ? .traditional : .simplified
    }

    /// The language codes whose speakers write Chinese characters. Cantonese is
    /// here because SenseVoice offers it as its own dictation language.
    static let chineseLanguageCodes: Set<String> = ["zh", "yue", "cmn", "nan", "hak", "wuu"]

    private static let traditionalRegions: Set<String> = ["TW", "HK", "MO"]

    // MARK: - Is this text Chinese at all?

    /// Whether a transcript dictated with `languageCode` selected is Chinese.
    ///
    /// **One predicate, and every stage that has to answer this question reads
    /// it.** `ChineseScriptNormalizer` decides whether to write the transcript
    /// in the user's chosen script by it, and `StyleRewriteLanguage` decides
    /// whether to address the model in Chinese by it. Two answers to "is this
    /// Chinese" is how a stage ends up rewriting text its own guard then
    /// refuses, or converting a script the rest of the app does not think is
    /// Chinese at all.
    ///
    /// Both halves are needed and neither is enough. The language code alone
    /// cannot say - a user who leaves the language on Chinese and dictates a
    /// sentence of English must not have it converted - and the text alone
    /// cannot either, because Japanese kanji and Korean hanja are Han
    /// characters too.
    static func isChineseText(_ text: String, languageCode: String) -> Bool {
        mayBeChinese(languageCode: languageCode) && isHanDominant(text)
    }

    /// Whether the dictation language leaves Chinese possible at all.
    ///
    /// Auto-detect and an unknown code both leave it open, because neither says
    /// anything; a language this app knows and that is not Chinese closes it,
    /// which is what keeps Japanese and Korean dictation out of a stage written
    /// for the script they share.
    static func mayBeChinese(languageCode: String) -> Bool {
        let code = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? ""
        if chineseLanguageCodes.contains(code) { return true }
        return LanguageUtil.languageNames[code] == nil || code == "auto"
    }

    /// The share of a transcript's words that have to be Han before it counts as
    /// Chinese.
    ///
    /// Named rather than inlined because it is the one number the code-switching
    /// case turns on, and because `BilingualDictationTests` pins it: moving it is
    /// a decision about whose dictation is Chinese, not a tuning knob.
    static let hanShareThreshold = 0.3

    /// Whether the text is written in Han characters, with no kana or Hangul in
    /// it at all.
    ///
    /// **Han characters are weighed against whole words, not against letters,**
    /// and that is the whole of the code-switching fix. A Han character is a
    /// word; a Latin letter is a fraction of one. Counting both as "letters"
    /// systematically undercounts the Chinese in a mixed utterance, and it
    /// undercounts it hardest in exactly the sentences this app is for: the
    /// English a Taiwanese engineer mixes into Mandarin is product names,
    /// branches and handles, which are long. `把 PR 開到 feature/login 再 @James`
    /// is four Han words against four Latin ones - and against nineteen Latin
    /// letters, which is how the same sentence used to be classified as English
    /// and handed back to a Traditional user still written in Simplified. See
    /// `docs/bilingual-dictation.md`.
    ///
    /// A single kana or Hangul character is still enough to rule Chinese out:
    /// Japanese written in kanji alone is rare, and Japanese written with kana is
    /// not Chinese however many Han characters it also has.
    ///
    /// The trade this makes is stated rather than hidden: an English sentence
    /// naming two Chinese people is now Chinese to this predicate, where a
    /// sentence naming one is not. That is the shape of every threshold, and this
    /// side of it is the cheap one - the cost is a name converted to the script
    /// the user writes in, against a whole daily utterance in the wrong script.
    ///
    /// `StyleRewriteGuard` counts letters instead, and deliberately: it asks
    /// whether a *rewrite* changed script, which is a comparison of two texts
    /// against each other rather than a claim about either, so both sides of it
    /// move together whatever the unit. This is the one place that answers "is
    /// this text Chinese" outright, and every stage that needs that answer -
    /// `ChineseScriptNormalizer` and `StyleRewriteLanguage` - reads it here.
    static func isHanDominant(_ text: String) -> Bool {
        var han = 0
        var otherWords = 0
        var insideOtherWord = false

        for character in text {
            guard character.isLetter, let scalar = character.unicodeScalars.first else {
                insideOtherWord = false
                continue
            }
            switch scalar.value {
            case 0x3040 ... 0x30FF,     // Hiragana, Katakana
                 0x1100 ... 0x11FF,     // Hangul jamo
                 0xAC00 ... 0xD7AF:     // Hangul syllables
                return false
            default:
                break
            }
            if HanCharacterTransform.isHan(scalar) {
                han += 1
                insideOtherWord = false
            } else {
                if !insideOtherWord { otherWords += 1 }
                insideOtherWord = true
            }
        }

        let words = han + otherWords
        guard words > 0 else { return false }
        return Double(han) / Double(words) >= hanShareThreshold
    }

    // MARK: - The characters

    /// Character pairs that exist in one variant and not the other, in order:
    /// `traditionalCharacters[i]` is written `simplifiedCharacters[i]` in
    /// Simplified Chinese.
    ///
    /// Deliberately not a complete conversion table. Every pair here is one
    /// whose Simplified form is *not* also a normal Traditional character, which
    /// is what lets a single occurrence count as evidence. The well-known
    /// ambiguous ones - `里`, `后`, `只`, `面`, `干`, `台`, `云`, `表` - are left
    /// out on purpose: they are ordinary Traditional characters too, and
    /// counting them would let a correct rewrite be refused.
    ///
    /// `ChineseScriptVariantTests` checks every pair against ICU's `Hant-Hans`
    /// transform, so a typo in either string fails a test rather than quietly
    /// mis-reading a user's script.
    static let traditionalCharacters =
        "個這說們麼為學國時會對來點樣沒開過覺從東車長問間見話讓應該還買賣錢銀實現產業專傳體團導節級統經給結網議認識讀語誰請謝變邊進遠運連達遲張歡權龍鳳麗義習鄉書樂藝醫藥觀願難離屬舊區廣處備條務動勞華單雙發頭顯題顧風飛飯餓館馬驗驚魚鳥麥黃齊龜輪軟較輸選適遞鐘錯鋼錄鍵門關閉際陳陽陰隨險雞電靈韓頁顏類養兒內兩冊減幫帶廳戰戲執擇擊數斷樓標機檢歲歷歸殺氣漢潔燈爾獨環當畢療眾睜碼確積穩競筆簡籃紙細終組絕綠維綜緊線練縣總織續罷職聯聲聽腦臉興舉蘇蘭號補裝規視親計訂討訓記訪設許訴診詞試詩詳誤課調談論諸謀講證譯護讚貝負財責貨貧貴費賀資賓賺購贏賽輕農遺釋針鐵鑰陸隊階雖雜靜響頂順預領頻顆飄鬧魯鮮黨齒禮塊嗎嘗圖園圓場壓壞夢婦媽孫將尋屆島"

    static let simplifiedCharacters =
        "个这说们么为学国时会对来点样没开过觉从东车长问间见话让应该还买卖钱银实现产业专传体团导节级统经给结网议认识读语谁请谢变边进远运连达迟张欢权龙凤丽义习乡书乐艺医药观愿难离属旧区广处备条务动劳华单双发头显题顾风飞饭饿馆马验惊鱼鸟麦黄齐龟轮软较输选适递钟错钢录键门关闭际陈阳阴随险鸡电灵韩页颜类养儿内两册减帮带厅战戏执择击数断楼标机检岁历归杀气汉洁灯尔独环当毕疗众睁码确积稳竞笔简篮纸细终组绝绿维综紧线练县总织续罢职联声听脑脸兴举苏兰号补装规视亲计订讨训记访设许诉诊词试诗详误课调谈论诸谋讲证译护赞贝负财责货贫贵费贺资宾赚购赢赛轻农遗释针铁钥陆队阶虽杂静响顶顺预领频颗飘闹鲁鲜党齿礼块吗尝图园圆场压坏梦妇妈孙将寻届岛"

    private static let traditionalOnly = Set(traditionalCharacters)
    private static let simplifiedOnly = Set(simplifiedCharacters)
}
