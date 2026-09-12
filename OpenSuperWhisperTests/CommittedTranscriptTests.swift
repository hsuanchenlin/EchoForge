import XCTest
@testable import OpenSuperWhisper

/// The joiner both SenseVoice's chunks and live dictation's utterances go
/// through: the seam rule per writing system, what is dropped, and that a
/// single utterance is returned exactly as the engine produced it.
final class CommittedTranscriptTests: XCTestCase {

    private func joined(_ pieces: [String]) -> String {
        CommittedTranscript(utterances: pieces).text
    }

    // MARK: - Spacing at the seam

    /// Chinese does not separate words, and the engines punctuate, so a space
    /// at the seam is text the user did not say.
    func testHanPiecesAreJoinedWithoutASpace() {
        XCTAssertEqual(joined(["今天天氣很好，", "我們去公園。"]), "今天天氣很好，我們去公園。")
        XCTAssertEqual(joined(["今天天氣很好", "我們去公園"]), "今天天氣很好我們去公園")
    }

    func testLatinPiecesAreJoinedWithOneSpace() {
        XCTAssertEqual(joined(["We struck gold.", "The rest is history."]), "We struck gold. The rest is history.")
        XCTAssertEqual(joined(["one", "two", "three"]), "one two three")
    }

    /// Kana and fullwidth punctuation are scripts without word spaces too;
    /// Hangul is not, because Korean is written with spaces.
    func testKanaAndFullwidthPunctuationJoinWithoutASpaceAndHangulWithOne() {
        XCTAssertEqual(joined(["きょうは", "いい天気です。"]), "きょうはいい天気です。")
        XCTAssertEqual(joined(["好嗎？", "好"]), "好嗎？好")
        XCTAssertEqual(joined(["안녕하세요.", "반갑습니다."]), "안녕하세요. 반갑습니다.")
    }

    /// The seam is decided by the characters on either side of it. A Han
    /// piece next to a Latin one gets no space, because the post-processing
    /// stage owns the spacing between the two scripts and must see the text as
    /// the engine would have written it in one piece.
    func testAHanSeamNextToLatinGetsNoSpace() {
        XCTAssertEqual(joined(["把 PR 開到", "feature/login 再 @James"]), "把 PR 開到feature/login 再 @James")
        XCTAssertEqual(joined(["open the PR", "然後通知 James"]), "open the PR然後通知 James")
    }

    // MARK: - Dropped pieces

    func testEmptyAndWhitespacePiecesAreDropped() {
        XCTAssertEqual(joined(["", "  ", "\n"]), "")
        XCTAssertEqual(joined(["hello", "", " \n", "world"]), "hello world")
    }

    /// An engine handed near-silence answers with a stray mark rather than
    /// nothing, and that mark must not reach the user's document.
    func testPunctuationOnlyPiecesAreDropped() {
        for piece in [".", "...", "。", "，。", "?!", " - ", "…", "「」", "、"] {
            XCTAssertNil(CommittedTranscript.kept(piece), "\(piece.debugDescription) is not speech")
        }
        XCTAssertEqual(joined(["我們去公園。", "。", "然後回家。"]), "我們去公園。然後回家。")
        XCTAssertEqual(joined(["We went out.", "...", "Then home."]), "We went out. Then home.")
    }

    /// A piece with one letter or digit in it is speech, whatever else it holds.
    func testAPieceWithALetterOrADigitIsKept() {
        XCTAssertEqual(CommittedTranscript.kept("a."), "a.")
        XCTAssertEqual(CommittedTranscript.kept("... 3"), "... 3")
        XCTAssertEqual(CommittedTranscript.kept("。好。"), "。好。")
    }

    func testAppendReportsWhetherThePieceWasKept() {
        var transcript = CommittedTranscript()
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertFalse(transcript.append("..."))
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertTrue(transcript.append("hello"))
        XCTAssertEqual(transcript.utterances, ["hello"])
        XCTAssertFalse(transcript.isEmpty)
    }

    // MARK: - One utterance

    /// A dictation the policy never cut must read exactly as the whole-file
    /// decode would: one kept utterance comes back byte for byte, internal
    /// whitespace, newlines and all. Only the surrounding whitespace every
    /// engine already strips from its output is removed.
    func testASingleUtteranceIsReturnedByteForByte() {
        let pieces = [
            "把 PR 開到 feature/login 再 @James",
            "We  struck   gold.\nThe rest\tis history.",
            "Ünïcödé - “quotes”, 100%, 3.14, e-mail@example.com",
            "😀 said hello",
            "[BLANK_AUDIO] left as the engine wrote it",
        ]
        for piece in pieces {
            var transcript = CommittedTranscript()
            transcript.append(piece)
            XCTAssertEqual(transcript.text, piece)
            XCTAssertEqual(Array(transcript.text.utf8), Array(piece.utf8))
        }
    }

    func testSurroundingWhitespaceIsTrimmedAsTheEnginesTrimTheirOutput() {
        XCTAssertEqual(joined(["  hello \n"]), "hello")
        XCTAssertEqual(joined([" 你好 "]), "你好")
    }

    /// The static join is the same rule `append` builds on, so a caller with
    /// pieces in hand and one appending as it goes cannot drift apart.
    func testJoinedAndAppendAgree() {
        let pieces = ["We struck gold.", "然後呢？", "The rest is history."]
        var transcript = CommittedTranscript()
        for piece in pieces { transcript.append(piece) }
        XCTAssertEqual(transcript.text, CommittedTranscript.joined(pieces))
        XCTAssertEqual(transcript.text, "We struck gold.然後呢？The rest is history.")
    }
}
