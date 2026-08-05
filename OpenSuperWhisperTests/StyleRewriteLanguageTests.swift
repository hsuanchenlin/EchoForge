import XCTest
@testable import OpenSuperWhisper

/// Pins which language the model is asked in, which is the whole of the Chinese
/// fix: asked in English, the shipping on-device model answers Chinese dictation
/// in English, and the guard then throws the rewrite away.
final class StyleRewriteLanguageTests: XCTestCase {

    private func resolve(
        _ transcript: String,
        languageCode: String = "auto",
        fallback: ChineseScriptVariant = .simplified
    ) -> StyleRewriteLanguage {
        StyleRewriteLanguage.resolve(
            languageCode: languageCode, transcript: transcript, fallbackVariant: fallback
        )
    }

    // MARK: - Chinese

    func testAsksInTraditionalChineseForTraditionalDictation() {
        XCTAssertEqual(
            resolve("那個我們這個禮拜五要出貨", languageCode: "zh"), .chinese(.traditional)
        )
    }

    func testAsksInSimplifiedChineseForSimplifiedDictation() {
        XCTAssertEqual(
            resolve("那个我们这个礼拜五要出货", languageCode: "zh"), .chinese(.simplified)
        )
    }

    /// The transcript is the evidence, so auto-detect needs no help.
    func testRecognisesChineseWhenTheLanguageIsSetToAutoDetect() {
        XCTAssertEqual(resolve("那個我們這個禮拜五要出貨"), .chinese(.traditional))
    }

    func testRecognisesCantoneseDictation() {
        XCTAssertEqual(
            resolve("我哋今個禮拜五出貨", languageCode: "yue"), .chinese(.traditional)
        )
    }

    /// Whichever variant the transcript is in, the model is asked in that one -
    /// a mismatched instruction converts the whole rewrite to its own variant.
    func testTheTranscriptDecidesTheVariantEvenAgainstTheFallback() {
        XCTAssertEqual(
            resolve("那個我們這個禮拜五要出貨", languageCode: "zh", fallback: .simplified),
            .chinese(.traditional)
        )
        XCTAssertEqual(
            resolve("那个我们这个礼拜五要出货", languageCode: "zh", fallback: .traditional),
            .chinese(.simplified)
        )
    }

    /// Most short Chinese sentences use only characters the two variants share,
    /// and one of them still has to be chosen: the user's own is the best answer
    /// available.
    func testFallsBackToTheUsersVariantWhenTheTranscriptDoesNotSay() {
        XCTAssertEqual(
            resolve("我明天去上海", languageCode: "zh", fallback: .traditional),
            .chinese(.traditional)
        )
        XCTAssertEqual(
            resolve("我明天去上海", languageCode: "zh", fallback: .simplified),
            .chinese(.simplified)
        )
    }

    // MARK: - Not Chinese

    /// The setting does not override the text. Leaving the dictation language on
    /// Chinese and speaking a sentence of English must not have it rewritten
    /// into Chinese.
    func testEnglishDictationIsNotAskedForInChineseJustBecauseTheLanguageSaysSo() {
        XCTAssertEqual(resolve("we ship on friday", languageCode: "zh"), .other)
    }

    /// Japanese and Korean are written with Han characters too, so the dictation
    /// language is what rules them out.
    func testJapaneseDictationIsNotTreatedAsChinese() {
        XCTAssertEqual(resolve("金曜日に出荷します", languageCode: "ja"), .other)
    }

    func testKoreanDictationIsNotTreatedAsChinese() {
        XCTAssertEqual(resolve("금요일에 출하합니다", languageCode: "ko"), .other)
    }

    /// Even on auto-detect, kana is enough to say the text is not Chinese.
    func testKanaRulesOutChineseOnAutoDetect() {
        XCTAssertEqual(resolve("金曜日に出荷します"), .other)
    }

    func testEnglishDictationIsAskedForInEnglish() {
        XCTAssertEqual(resolve("we ship on friday", languageCode: "en"), .other)
        XCTAssertEqual(resolve("we ship on friday"), .other)
    }

    func testTextWithNoLettersAtAllIsNotChinese() {
        XCTAssertEqual(resolve("2500 $ 30%"), .other)
        XCTAssertEqual(resolve(""), .other)
    }

    /// Chinese with an English product name in it is still Chinese.
    func testChineseThatBorrowsALatinNameIsStillChinese() {
        XCTAssertEqual(
            resolve("我們用 Kubernetes 部署服務", languageCode: "zh"), .chinese(.traditional)
        )
    }

    // MARK: - Wrapping a custom prompt

    func testLeavesACustomPromptAloneForEveryOtherLanguage() {
        XCTAssertEqual(
            StyleRewriteLanguage.other.wrapping(customPrompt: "Rewrite this as a haiku."),
            "Rewrite this as a haiku."
        )
    }

    func testKeepsTheUsersOwnWordsWhenItWrapsThem() {
        for variant in [ChineseScriptVariant.traditional, .simplified] {
            let wrapped = StyleRewriteLanguage.chinese(variant)
                .wrapping(customPrompt: "Rewrite this as a haiku.")

            XCTAssertTrue(wrapped.hasSuffix("Rewrite this as a haiku."), "\(variant)")
            XCTAssertGreaterThan(wrapped.count, "Rewrite this as a haiku.".count)
        }
    }
}
