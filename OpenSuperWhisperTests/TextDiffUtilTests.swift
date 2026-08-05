import XCTest
@testable import OpenSuperWhisper

/// Pins the comparison behind the Settings preview and the history row.
///
/// Two of these tests matter more than the rest.
/// `testRevisedTextIsReproducedExactlyByEveryComparison` is the honesty check:
/// a comparison that renders anything other than the
/// polished text, character for character, is telling the user their dictation
/// says something it does not. And the case- and whitespace-only cases are what
/// keep a comparison readable - a style that capitalises a sentence has not
/// changed a word, and marking that up would bury the changes that are real.
final class TextDiffUtilTests: XCTestCase {

    private func compare(_ original: String, _ revised: String) -> [TextDiffSegment] {
        TextDiffUtil.compare(original: original, revised: revised)
    }

    /// Every segment a view renders normally, concatenated.
    private func rendered(_ segments: [TextDiffSegment]) -> String {
        segments.filter { $0.kind != .removed }.map(\.text).joined()
    }

    // MARK: - Filler removal

    func testStrikesThroughFillerWordsTheRewriteDropped() {
        XCTAssertEqual(
            compare("um so we ship on friday", "we ship on friday"),
            [
                TextDiffSegment("um so ", .removed),
                TextDiffSegment("we ship on friday", .unchanged)
            ]
        )
    }

    func testStrikesThroughFillerInTheMiddleOfASentence() {
        XCTAssertEqual(
            compare("the budget is like $2,500", "the budget is $2,500"),
            [
                TextDiffSegment("the budget is ", .unchanged),
                TextDiffSegment("like ", .removed),
                TextDiffSegment("$2,500", .unchanged)
            ]
        )
    }

    func testStrikesThroughFillerAtTheEnd() {
        XCTAssertEqual(
            compare("we ship on friday you know", "we ship on friday"),
            [
                TextDiffSegment("we ship on friday", .unchanged),
                TextDiffSegment(" you know", .removed)
            ]
        )
    }

    /// A digit separator is part of the number, not punctuation between two
    /// numbers, or every figure in a dictation would come apart into changes.
    func testKeepsAFigureTogether() {
        XCTAssertEqual(
            compare("uh $2,500 total", "$2,500 total"),
            [
                TextDiffSegment("uh ", .removed),
                TextDiffSegment("$2,500 total", .unchanged)
            ]
        )
    }

    func testKeepsAnApostrophisedWordTogether() {
        XCTAssertEqual(
            compare("um don't ship", "don't ship"),
            [
                TextDiffSegment("um ", .removed),
                TextDiffSegment("don't ship", .unchanged)
            ]
        )
    }

    // MARK: - Replacement

    func testShowsAReplacedWordAsTheOldOneStruckThenTheNew() {
        XCTAssertEqual(
            compare("we should ship it", "we will ship it"),
            [
                TextDiffSegment("we ", .unchanged),
                TextDiffSegment("should", .removed),
                TextDiffSegment("will", .inserted),
                TextDiffSegment(" ship it", .unchanged)
            ]
        )
    }

    func testShowsAddedPunctuationAsAnInsertion() {
        XCTAssertEqual(
            compare("we ship on friday", "we ship on friday."),
            [
                TextDiffSegment("we ship on friday", .unchanged),
                TextDiffSegment(".", .inserted)
            ]
        )
    }

    func testShowsAWholeRewrittenSentence() {
        let segments = compare("um yeah whatever", "Understood.")
        XCTAssertEqual(
            segments,
            [
                TextDiffSegment("um yeah whatever", .removed),
                TextDiffSegment("Understood.", .inserted)
            ]
        )
        XCTAssertEqual(rendered(segments), "Understood.")
    }

    // MARK: - Case and whitespace

    /// Capitalisation is not a change to the user's words, and the polished
    /// spelling is what a matched run is rendered with.
    func testCapitalisationAloneIsNotAChange() {
        XCTAssertEqual(
            compare("we ship on friday", "We ship on Friday"),
            [TextDiffSegment("We ship on Friday", .unchanged)]
        )
        XCTAssertFalse(
            TextDiffUtil.hasVisibleChanges(original: "we ship on friday", revised: "We ship on Friday")
        )
    }

    func testCollapsedWhitespaceIsNotAChange() {
        XCTAssertEqual(
            compare("we   ship\non friday", "we ship on friday"),
            [TextDiffSegment("we ship on friday", .unchanged)]
        )
    }

    func testATrailingNewlineIsReproducedButNeverMarkedUp() {
        XCTAssertEqual(
            compare("we ship\n", "we ship\n\n"),
            [TextDiffSegment("we ship\n\n", .unchanged)]
        )
    }

    /// The indent is the user's, and it is in both texts, so it stays plain -
    /// only the word between it and the rest is struck through.
    func testLeadingWhitespaceIsLeftAloneAroundARemoval() {
        XCTAssertEqual(
            compare("  um we ship", "  we ship"),
            [
                TextDiffSegment("  ", .unchanged),
                TextDiffSegment("um ", .removed),
                TextDiffSegment("we ship", .unchanged)
            ]
        )
    }

    func testWhitespaceOnlyTextsCompareAsUnchanged() {
        XCTAssertEqual(compare("  ", " "), [TextDiffSegment(" ", .unchanged)])
    }

    /// CJK spacing post-processing inserts spaces between CJK and Latin. The
    /// inserted space still travels as its own segment - the revised text must
    /// be reproduced exactly - but an inserted space renders exactly like an
    /// unchanged one, so the comparison must not report it as something to show.
    func testCJKSpacingInsertionIsNotAVisibleChange() {
        let segments = compare("週五deadline到了", "週五 deadline 到了")
        XCTAssertEqual(rendered(segments), "週五 deadline 到了")
        XCTAssertFalse(TextDiffUtil.hasVisibleChanges(in: segments))
        XCTAssertFalse(
            TextDiffUtil.hasVisibleChanges(original: "週五deadline到了", revised: "週五 deadline 到了")
        )
    }

    func testATrimmedTrailingSpaceIsNotAVisibleChange() {
        let segments = compare("we ship ", "we ship")
        XCTAssertEqual(rendered(segments), "we ship")
        XCTAssertFalse(TextDiffUtil.hasVisibleChanges(in: segments))
    }

    // MARK: - Empty input

    func testEmptyOriginalIsAllInsertion() {
        XCTAssertEqual(compare("", "we ship"), [TextDiffSegment("we ship", .inserted)])
    }

    func testEmptyRevisionIsAllRemoval() {
        XCTAssertEqual(compare("we ship", ""), [TextDiffSegment("we ship", .removed)])
    }

    func testTwoEmptyTextsCompareToNothing() {
        XCTAssertTrue(compare("", "").isEmpty)
    }

    // MARK: - CJK

    /// Chinese is written without spaces, so the comparison is per character;
    /// splitting on whitespace would make every Chinese rewrite one enormous
    /// replacement.
    func testComparesChinesePerCharacter() {
        let segments = compare("那個我們禮拜五出貨", "我們禮拜五出貨")
        XCTAssertEqual(
            segments,
            [
                TextDiffSegment("那個", .removed),
                TextDiffSegment("我們禮拜五出貨", .unchanged)
            ]
        )
        XCTAssertEqual(rendered(segments), "我們禮拜五出貨")
    }

    func testComparesMixedChineseAndLatin() {
        let segments = compare("那個 deadline 是禮拜五", "deadline 是禮拜五")
        XCTAssertEqual(rendered(segments), "deadline 是禮拜五")
        XCTAssertEqual(
            segments.filter { $0.kind == .removed }.map(\.text), ["那個 "]
        )
    }

    // MARK: - Invariants

    func testRevisedTextIsReproducedExactlyByEveryComparison() {
        let pairs: [(String, String)] = [
            ("um so I think we should ship the thing on friday, and uh the budget is like $2,500 for the whole quarter, does that work for you",
             "I think we should ship on Friday. The budget is $2,500 for the quarter - does that work for you?"),
            ("那個我覺得我們這個禮拜五要出貨,然後預算大概是兩千五", "我們禮拜五出貨,預算兩千五。"),
            ("hello", "hello"),
            ("  spaced   out  ", "spaced out"),
            ("", "brand new text")
        ]

        for (original, revised) in pairs {
            XCTAssertEqual(
                rendered(compare(original, revised)), revised,
                "comparison of \"\(original)\" did not reproduce its revision"
            )
        }
    }

    func testAdjacentSegmentsOfTheSameKindAreMerged() {
        let segments = compare("um uh so we ship", "we ship")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first, TextDiffSegment("um uh so ", .removed))
    }

    func testHasVisibleChangesReportsARealChange() {
        XCTAssertTrue(
            TextDiffUtil.hasVisibleChanges(original: "um we ship", revised: "we ship")
        )
        XCTAssertFalse(
            TextDiffUtil.hasVisibleChanges(original: "we ship", revised: "we ship")
        )
    }

    /// Past the limit the middle is reported as one replacement rather than
    /// filling a table with a hundred million cells while the user waits.
    func testVeryLongTextsDegradeToASingleReplacement() {
        let original = (0 ..< (TextDiffUtil.maximumComparedTokens + 100))
            .map { "alpha\($0)" }
            .joined(separator: " ")
        let revised = (0 ..< (TextDiffUtil.maximumComparedTokens + 100))
            .map { "beta\($0)" }
            .joined(separator: " ")

        let segments = compare(original, revised)

        XCTAssertEqual(segments.map(\.kind), [.removed, .inserted])
        XCTAssertEqual(rendered(segments), revised)
    }
}
