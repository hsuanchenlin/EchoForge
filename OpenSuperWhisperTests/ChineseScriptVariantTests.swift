import XCTest
@testable import OpenSuperWhisper

/// Pins the character table that decides which Chinese a user writes.
///
/// Two callers depend on it being right in opposite directions: the rewriting
/// stage picks its instruction from it, and `StyleRewriteGuard` refuses a
/// rewrite from it. A character in the wrong column would therefore either
/// convert a user's script or refuse every correct rewrite, so the table is
/// checked against ICU rather than trusted.
final class ChineseScriptVariantTests: XCTestCase {

    // MARK: - The table

    func testTheTwoColumnsLineUp() {
        XCTAssertEqual(
            ChineseScriptVariant.traditionalCharacters.count,
            ChineseScriptVariant.simplifiedCharacters.count
        )
    }

    /// Every pair checked against the same ICU transform the terms dictionary
    /// folds with, so a typo in either string fails here instead of quietly
    /// mis-reading someone's dictation.
    func testEveryPairAgreesWithICU() {
        let traditional = Array(ChineseScriptVariant.traditionalCharacters)
        let simplified = Array(ChineseScriptVariant.simplifiedCharacters)

        for (index, pair) in zip(traditional, simplified).enumerated() {
            XCTAssertEqual(
                ChineseScriptFolding.fold(pair.0), pair.1,
                "pair \(index): \(pair.0) does not fold onto \(pair.1)"
            )
            // The Simplified form has to be a Simplified form: one that ICU
            // would itself convert is a Traditional character in the wrong
            // column.
            XCTAssertEqual(
                ChineseScriptFolding.fold(pair.1), pair.1,
                "pair \(index): \(pair.1) is not a Simplified character"
            )
        }
    }

    func testNoCharacterAppearsInBothColumns() {
        let traditional = Set(ChineseScriptVariant.traditionalCharacters)
        let simplified = Set(ChineseScriptVariant.simplifiedCharacters)

        XCTAssertTrue(traditional.intersection(simplified).isEmpty)
        XCTAssertEqual(traditional.count, ChineseScriptVariant.traditionalCharacters.count)
        XCTAssertEqual(simplified.count, ChineseScriptVariant.simplifiedCharacters.count)
    }

    /// The characters left out on purpose. Each is an ordinary Traditional
    /// character as well as a Simplified one, so counting it would let a correct
    /// Traditional rewrite be refused.
    func testTheKnownAmbiguousCharactersAreNotCounted() {
        for character in "里后只面干台云表几万" {
            let signal = ChineseScriptVariant.signal(in: String(character))

            XCTAssertEqual(signal.simplified, 0, "\(character) is counted as Simplified")
            XCTAssertEqual(signal.traditional, 0, "\(character) is counted as Traditional")
        }
    }

    // MARK: - Reading text

    func testReadsTraditionalText() {
        XCTAssertEqual(ChineseScriptVariant.detected(in: "我們這個禮拜五要出貨"), .traditional)
    }

    func testReadsSimplifiedText() {
        XCTAssertEqual(ChineseScriptVariant.detected(in: "我们这个礼拜五要出货"), .simplified)
    }

    /// Text made only of characters the two share does not say which it is, and
    /// saying so is the point: the caller falls back rather than guessing.
    func testSaysNothingAboutTextWrittenInSharedCharacters() {
        XCTAssertNil(ChineseScriptVariant.detected(in: "我明天去上海"))
        XCTAssertNil(ChineseScriptVariant.detected(in: "we ship on friday"))
    }

    /// Lightly mixed text still has to resolve to something, because an
    /// instruction has to be written in one of the two.
    func testTakesTheMajorityOfMixedText() {
        XCTAssertEqual(
            ChineseScriptVariant.detected(in: "这个礼拜五要给台積電出货"), .simplified
        )
    }

    func testCountsBothSidesOfMixedText() {
        let signal = ChineseScriptVariant.signal(in: "这个礼拜五要给台積電出货")

        XCTAssertGreaterThan(signal.traditional, 0)
        XCTAssertGreaterThan(signal.simplified, 0)
        XCTAssertFalse(signal.isDecisive)
    }

    func testTextInOneVariantIsDecisive() {
        XCTAssertTrue(ChineseScriptVariant.signal(in: "我們這個禮拜五要出貨").isDecisive)
        XCTAssertTrue(ChineseScriptVariant.signal(in: "我们这个礼拜五要出货").isDecisive)
        XCTAssertFalse(ChineseScriptVariant.signal(in: "我明天去上海").isDecisive)
    }

    // MARK: - The user's own preference

    func testPrefersTheVariantOfTheUsersOwnChineseLanguage() {
        XCTAssertEqual(
            ChineseScriptVariant.preferred(languages: ["en-TW", "zh-Hant-TW"], regionCode: "TW"),
            .traditional
        )
        XCTAssertEqual(
            ChineseScriptVariant.preferred(languages: ["zh-Hans-CN", "en-US"], regionCode: "CN"),
            .simplified
        )
    }

    /// A user in Taiwan or Hong Kong with no Chinese in their language list
    /// still writes Traditional.
    func testFallsBackToTheRegionWhenNoLanguageIsChinese() {
        XCTAssertEqual(
            ChineseScriptVariant.preferred(languages: ["en-US"], regionCode: "HK"), .traditional
        )
        XCTAssertEqual(
            ChineseScriptVariant.preferred(languages: ["en-US"], regionCode: "US"), .simplified
        )
        XCTAssertEqual(ChineseScriptVariant.preferred(languages: [], regionCode: nil), .simplified)
    }

    /// Cantonese is one of SenseVoice's dictation languages, and its users write
    /// Traditional.
    func testReadsCantoneseAsAChineseLanguage() {
        XCTAssertEqual(
            ChineseScriptVariant.preferred(languages: ["yue-Hant-HK"], regionCode: "HK"),
            .traditional
        )
    }
}
