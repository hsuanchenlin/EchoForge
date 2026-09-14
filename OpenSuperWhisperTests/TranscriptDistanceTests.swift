import XCTest

@testable import OpenSuperWhisper

final class TranscriptDistanceTests: XCTestCase {

    func testTheCharacterErrorRateIsTheDistanceOverTheReference() {
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "abcd", hypothesis: "abcd"), 0)
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "abcd", hypothesis: "abxd"), 0.25, "a substitution")
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "abcd", hypothesis: "abd"), 0.25, "a deletion")
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "abcd", hypothesis: "abcde"), 0.25, "an insertion")
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "abcd", hypothesis: ""), 1)
    }

    func testSpacingCaseAndPunctuationDoNotCount() {
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "a b, c.", hypothesis: "ABC"), 0)
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "你好，世界。", hypothesis: "你好 世界"), 0)
    }

    func testAnEmptyReference() {
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: "", hypothesis: "x"), 1)
        XCTAssertEqual(TranscriptDistance.characterErrorRate(reference: ", .", hypothesis: ""), 0, "punctuation alone is an empty reference")
    }
}
