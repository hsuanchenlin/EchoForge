import XCTest
@testable import OpenSuperWhisper

/// The spoken-command grammar, in all three languages it is written for.
///
/// The router is pure string matching, so every case here is the whole
/// behaviour rather than a proxy for it. The bias the tests are written around
/// is the one the feature is built on: **anything the grammar does not
/// recognise is dictation**, because a mis-read command costs the user their
/// paste and a missed one costs them a retry.
final class SpokenIntentRouterTests: XCTestCase {

    // MARK: - Helpers

    private func ask(_ transcript: String) -> String? {
        guard case .ask(let query) = SpokenIntentRouter.route(transcript) else { return nil }
        return query
    }

    private func translate(
        _ transcript: String, fallbackChineseVariant: ChineseScriptVariant? = nil
    ) -> (target: SpokenTranslationTarget, text: String)? {
        guard case .translate(let target, let text) = SpokenIntentRouter.route(
            transcript, fallbackChineseVariant: fallbackChineseVariant
        ) else { return nil }
        return (target, text)
    }

    private func isDictation(_ transcript: String) -> Bool {
        guard case .dictate(let text) = SpokenIntentRouter.route(transcript) else { return false }
        // The ordinary case hands back exactly what it was given, punctuation,
        // spacing and all - the router is not allowed to edit a dictation.
        XCTAssertEqual(text, transcript)
        return true
    }

    // MARK: - Ask, in English

    func testEnglishAskPrefixIsStripped() {
        XCTAssertEqual(ask("Ask: what is the capital of France?"), "what is the capital of France?")
    }

    func testEnglishAskAcceptsACommaWhereTheSpeakerPaused() {
        XCTAssertEqual(ask("Ask, how many grams in an ounce"), "how many grams in an ounce")
    }

    func testEnglishAskIsCaseInsensitive() {
        XCTAssertEqual(ask("ASK: who wrote Dubliners"), "who wrote Dubliners")
    }

    /// The rule that makes the English form safe to switch on. "Ask" is an
    /// ordinary verb, and a dictation that opens with it is far more common than
    /// a command; only the punctuation of a real pause promotes it.
    func testEnglishAskWithoutPunctuationStaysDictation() {
        XCTAssertTrue(isDictation("Ask him to call me back when he lands"))
        XCTAssertTrue(isDictation("ask the team whether Friday works"))
    }

    func testEnglishAskWithNothingBehindItStaysDictation() {
        XCTAssertTrue(isDictation("Ask:"))
        XCTAssertTrue(isDictation("Ask,   "))
    }

    // MARK: - Ask, in Chinese

    func testTraditionalChineseAskPrefixIsStripped() {
        XCTAssertEqual(ask("請問台北今天天氣如何？"), "台北今天天氣如何？")
        XCTAssertEqual(ask("請問：一英吋是幾公分"), "一英吋是幾公分")
    }

    func testSimplifiedChineseAskPrefixIsStripped() {
        XCTAssertEqual(ask("请问上海今天天气如何？"), "上海今天天气如何？")
        XCTAssertEqual(ask("请问，一英寸是几厘米"), "一英寸是几厘米")
    }

    /// The spec's own form: a bare `問` with the pause written as a space, which
    /// is what promotes it over the ordinary verb.
    func testBareChineseAskNeedsItsDelimiter() {
        XCTAssertEqual(ask("問 台北在哪裡"), "台北在哪裡")
        XCTAssertEqual(ask("问：上海在哪里"), "上海在哪里")
        XCTAssertTrue(isDictation("問他什麼時候到"))
        XCTAssertTrue(isDictation("问他什么时候到"))
    }

    // MARK: - Translate, in English

    func testEnglishTranslateSetsTargetAndStripsThePrefix() {
        let intent = translate("Translate to Spanish: the meeting is at three")
        XCTAssertEqual(intent?.target.languageCode, "es")
        XCTAssertNil(intent?.target.chineseVariant)
        XCTAssertEqual(intent?.text, "the meeting is at three")
    }

    func testEnglishTranslateAcceptsItsOtherPhrasings() {
        for transcript in [
            "Translate into German: good morning",
            "Translate this to German: good morning",
            "Translate this into German: good morning",
            "Translate it to German: good morning",
            "Translate German: good morning",
        ] {
            let intent = translate(transcript)
            XCTAssertEqual(intent?.target.languageCode, "de", transcript)
            XCTAssertEqual(intent?.text, "good morning", transcript)
        }
    }

    /// Whatever the speaker's pause came back as, the body starts after it.
    func testEnglishTranslateSurvivesAMissingColon() {
        XCTAssertEqual(translate("Translate to French see you tomorrow")?.text, "see you tomorrow")
    }

    /// The longer name has to win, or "traditional chinese" is read as
    /// "chinese" preceded by nothing.
    func testTheLongestLanguageNameWins() {
        let traditional = translate("Translate to Traditional Chinese: good luck")
        XCTAssertEqual(traditional?.target.languageCode, "zh")
        XCTAssertEqual(traditional?.target.chineseVariant, .traditional)
        XCTAssertEqual(traditional?.target.displayName, "Traditional Chinese")

        let simplified = translate("Translate to Simplified Chinese: good luck")
        XCTAssertEqual(simplified?.target.chineseVariant, .simplified)
        XCTAssertEqual(simplified?.target.displayName, "Simplified Chinese")
    }

    /// The chip has room for one word, so the two variants share a short name
    /// even though they do not share a full one.
    func testChineseVariantsShareAShortName() {
        let target = SpokenTranslationTarget(languageCode: "zh", chineseVariant: .simplified)
        XCTAssertEqual(target.shortDisplayName, "Chinese")
        XCTAssertEqual(CapsuleHUDMode.translate(to: target).label, "Translate Chinese")
    }

    // MARK: - Translate, in Chinese

    func testTraditionalChineseTranslateSetsTargetAndStripsThePrefix() {
        let intent = translate("翻譯成英文：我明天再跟你確認")
        XCTAssertEqual(intent?.target.languageCode, "en")
        XCTAssertEqual(intent?.text, "我明天再跟你確認")
    }

    func testSimplifiedChineseTranslateSetsTargetAndStripsThePrefix() {
        let intent = translate("翻译成日语：我明天再跟你确认")
        XCTAssertEqual(intent?.target.languageCode, "ja")
        XCTAssertEqual(intent?.text, "我明天再跟你确认")
    }

    func testChineseTranslateAcceptsItsOtherPhrasings() {
        for transcript in ["翻成西班牙文：早安", "譯成西班牙文：早安", "幫我翻譯成西班牙文：早安"] {
            let intent = translate(transcript)
            XCTAssertEqual(intent?.target.languageCode, "es", transcript)
            XCTAssertEqual(intent?.text, "早安", transcript)
        }
    }

    // MARK: - Resolving which Chinese

    /// A named variant is the user's own answer and is taken as given, whatever
    /// the caller would have guessed.
    func testANamedChineseVariantOverridesTheFallback() {
        let intent = translate("翻譯成簡體中文：早安", fallbackChineseVariant: .traditional)
        XCTAssertEqual(intent?.target.chineseVariant, .simplified)
    }

    /// A bare "Chinese" says nothing about which one, so the caller's answer -
    /// in the app, the user's own languages - stands in.
    func testABareChineseTakesTheFallbackVariant() {
        XCTAssertEqual(
            translate("Translate to Chinese: good morning", fallbackChineseVariant: .traditional)?
                .target.chineseVariant,
            .traditional
        )
        XCTAssertEqual(
            translate("翻譯成中文：good morning", fallbackChineseVariant: .simplified)?
                .target.chineseVariant,
            .simplified
        )
    }

    /// The fallback only exists for Chinese, where the distinction does.
    func testTheFallbackVariantIsNotAppliedToOtherLanguages() {
        let intent = translate("Translate to Spanish: hello", fallbackChineseVariant: .traditional)
        XCTAssertNil(intent?.target.chineseVariant)
    }

    // MARK: - Falling back to dictation

    func testAnUnknownLanguageStaysDictation() {
        XCTAssertTrue(isDictation("Translate to Klingon: live long and prosper"))
    }

    func testATranslateCommandWithNothingToTranslateStaysDictation() {
        XCTAssertTrue(isDictation("Translate to Spanish"))
        XCTAssertTrue(isDictation("翻譯成英文："))
    }

    func testASentenceThatMerelyContainsTheWordTranslateStaysDictation() {
        XCTAssertTrue(isDictation("Translate the document before Friday please"))
        XCTAssertTrue(isDictation("I asked her to translate it into Spanish for me"))
    }

    func testOrdinaryDictationIsUntouched() {
        XCTAssertTrue(isDictation("Let's ship the release on Thursday."))
        XCTAssertTrue(isDictation("我明天下午三點到，先去飯店放行李。"))
        XCTAssertTrue(isDictation(""))
        XCTAssertTrue(isDictation("   "))
    }

    /// A marker only counts at the front. Recognising one mid-sentence would
    /// turn every dictation that mentions asking into a question.
    func testAMarkerInTheMiddleOfASentenceIsIgnored() {
        XCTAssertTrue(isDictation("Tell them I will ask: what is the deadline?"))
        XCTAssertTrue(isDictation("我等一下請問他"))
    }

    // MARK: - The lexicon

    /// Every language name the picker knows is a name a user can say, because
    /// both read `LanguageUtil.languageNames` - a second hand-written list here
    /// would drift from the one on screen.
    func testEveryPickerLanguageCanBeNamedOutLoud() {
        for (code, name) in LanguageUtil.languageNames where code != "auto" {
            let intent = translate("Translate to \(name): hello")
            XCTAssertEqual(intent?.target.languageCode, code, name)
        }
    }

    /// A target with no name would show the user its ISO code.
    func testEveryTargetTheLexiconCanProduceHasADisplayName() {
        for entry in SpokenLanguageLexicon.names {
            XCTAssertNotNil(
                LanguageUtil.languageNames[entry.code],
                "\(entry.spelling) resolves to \(entry.code), which has no display name"
            )
        }
    }

    /// A language name that runs into the next word is not that language.
    func testALanguageNameMustEndWhereItEnds() {
        XCTAssertTrue(isDictation("Translate Frenchman: hello"))
    }

    // MARK: - What the rest of the app is told

    func testTheOutcomeCarriedOnAStyledTranscriptMatchesTheReading() {
        XCTAssertEqual(SpokenIntentRouter.route("Ask: why").outcome, .ask(query: "why"))
        XCTAssertEqual(SpokenIntentRouter.route("hello there").outcome, .dictation)

        guard case .translate(let target, _) = SpokenIntentRouter.route(
            "Translate to Spanish: hello"
        ) else {
            return XCTFail("expected a translate intent")
        }
        XCTAssertEqual(SpokenIntentRouter.route("Translate to Spanish: hello").outcome,
                       .translated(target))
    }

    /// The one rule the insertion path turns on: a question is never pasted
    /// into whatever the user was typing in.
    func testOnlyAQuestionWithholdsTheText() {
        XCTAssertFalse(SpokenIntentOutcome.ask(query: "why").insertsText)
        XCTAssertTrue(SpokenIntentOutcome.dictation.insertsText)
        XCTAssertTrue(
            SpokenIntentOutcome.translated(SpokenTranslationTarget(languageCode: "es")).insertsText
        )
    }

    func testTheCapsuleChipNamesTheCommandAndNothingElse() {
        XCTAssertNil(SpokenIntentOutcome.dictation.capsuleMode)
        XCTAssertEqual(SpokenIntentOutcome.ask(query: "why").capsuleMode?.label, "Ask")
        XCTAssertEqual(
            SpokenIntentOutcome.translated(SpokenTranslationTarget(languageCode: "ja")).capsuleMode?.label,
            "Translate Japanese"
        )
    }

    // MARK: - The transcript this router is handed has already been normalized

    /// `ChineseScriptNormalizer` rewrites the transcript into the user's chosen
    /// script *before* the router sees it, command prefix included. So every CJK
    /// spelling the grammar knows has to survive that conversion in both
    /// directions - a Simplified speaker whose output script is Traditional says
    /// "翻译成意大利语" and this router is handed "翻譯成意大利語".
    ///
    /// The check is generated rather than written out, because the failure it
    /// catches is someone adding one spelling of a new word and not the other,
    /// which no hand-written case would cover.
    func testEveryCJKSpellingSurvivesScriptNormalization() {
        var known = Set(SpokenLanguageLexicon.variantNames.keys)
        known.formUnion(SpokenLanguageLexicon.aliases.keys)
        known.formUnion(SpokenIntentGrammar.askMarkers.map(\.text))
        known.formUnion(SpokenIntentGrammar.translateMarkers.map(\.text))
        known.formUnion(SpokenIntentGrammar.snippetMarkers.map(\.text))

        for spelling in known where spelling.contains(where: { !$0.isASCII }) {
            for variant in [ChineseScriptVariant.traditional, .simplified] {
                let converted = ChineseScriptNormalizer.convert(spelling, to: variant)
                XCTAssertTrue(
                    known.contains(converted),
                    "\(spelling) becomes \(converted) in \(variant.rawValue), which the grammar "
                        + "does not know - that command turns back into dictation for anyone "
                        + "whose output script is the other one"
                )
            }
        }
    }

    /// The same thing said end to end: the command a Simplified speaker dictates
    /// still routes after their Traditional-output transcript has been written.
    func testACommandStillRoutesAfterTheTranscriptWasConvertedToTheOtherScript() {
        let spoken = "翻译成意大利语：这个项目的进度"
        let normalized = ChineseScriptNormalizer.normalized(
            spoken, to: .traditional, languageCode: "zh"
        )
        XCTAssertNotEqual(normalized, spoken)

        guard case .translate(let target, let body) = SpokenIntentRouter.route(normalized) else {
            return XCTFail("expected a translate intent, got \(SpokenIntentRouter.route(normalized))")
        }
        XCTAssertEqual(target.languageCode, "it")
        XCTAssertEqual(body, "這個項目的進度")
    }

    func testAChineseQuestionStillRoutesAfterConversion() {
        let normalized = ChineseScriptNormalizer.normalized(
            "请问明天几点开会", to: .traditional, languageCode: "zh"
        )
        XCTAssertEqual(ask(normalized), "明天幾點開會")
    }
}
