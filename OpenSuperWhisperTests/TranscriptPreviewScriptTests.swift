import XCTest

@testable import OpenSuperWhisper

/// The preview the capsule shows while a dictation is still running, and the
/// rule that it is written in the script the paste will be written in.
///
/// Everything the transcript stage promises about script normalization
/// (`ChineseScriptNormalizerTests`) has to hold here too, because this is the
/// same decision made one stage earlier for the screen alone: only Chinese is
/// converted, nothing but Han characters is touched, and the preview can never
/// reach the transcript.
final class TranscriptPreviewScriptTests: XCTestCase {

    private func preview(_ text: String, segment: String? = nil) -> PartialTranscript {
        PartialTranscript(text: text, segment: segment ?? text, segmentCount: 1)
    }

    // MARK: - The conversion

    /// The bug this exists for: Paraformer, SenseVoice and Whisper hand back
    /// Simplified for a speaker of Taiwanese Mandarin, and the capsule showed
    /// it for the length of the recording before the paste switched script.
    func testASimplifiedPreviewIsShownInTraditional() {
        let shown = TranscriptPreviewScript.normalized(
            preview("我们开会讨论这个项目"), to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "我們開會討論這個項目")
        XCTAssertEqual(shown.segment, "我們開會討論這個項目")
    }

    /// Traditional is the default, but the setting is as complete a choice the
    /// other way: a user who writes Simplified sees Simplified.
    func testTheChosenScriptIsHonouredBothWays() {
        let shown = TranscriptPreviewScript.normalized(
            preview("我們開會"), to: .simplified, languageCode: "zh")

        XCTAssertEqual(shown.text, "我们开会")
    }

    /// Auto-detect leaves Chinese possible, which is what a live session
    /// decodes its first utterance under.
    func testAutoDetectedChineseIsConvertedToo() {
        let shown = TranscriptPreviewScript.normalized(
            preview("我们开会"), to: .traditional, languageCode: "auto")

        XCTAssertEqual(shown.text, "我們開會")
    }

    /// The line grows and never rewrites itself, and the conversion has to
    /// leave that true: it is character-wise, so every prefix already on screen
    /// comes out of a later call exactly as it did out of the earlier one.
    func testAGrowingPreviewNeverRewritesWhatIsAlreadyShown() {
        let first = TranscriptPreviewScript.normalized(
            preview("我们开会。"), to: .traditional, languageCode: "zh")
        let second = TranscriptPreviewScript.normalized(
            preview("我们开会。然后发布。", segment: "然后发布。"),
            to: .traditional, languageCode: "zh")

        XCTAssertTrue(second.text.hasPrefix(first.text))
        XCTAssertEqual(second.segment, "然後發布。")
    }

    /// `segmentCount` is the engine's count of what it has committed, not
    /// something a script conversion gets an opinion about.
    func testTheSegmentCountIsCarriedThrough() {
        let shown = TranscriptPreviewScript.normalized(
            PartialTranscript(text: "我们开会", segment: "开会", segmentCount: 7),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.segmentCount, 7)
    }

    // MARK: - What is left alone

    func testEnglishIsLeftExactlyAsItIs() {
        let partial = preview("We ship on Friday.")
        XCTAssertEqual(
            TranscriptPreviewScript.normalized(partial, to: .traditional, languageCode: "en"),
            partial)
    }

    /// A user whose dictation language is Chinese but who said a sentence of
    /// English gets their English back, the same clause the transcript stage
    /// holds.
    func testAnEnglishSentenceUnderAChineseLanguageIsLeftAlone() {
        let partial = preview("We ship the release on Friday.")
        XCTAssertEqual(
            TranscriptPreviewScript.normalized(partial, to: .traditional, languageCode: "zh"),
            partial)
    }

    /// Kanji and hanja are Han characters too, and 学 → 學 in a Japanese
    /// preview is a corruption rather than a normalization. A live session
    /// pinned to Japanese asks with `ja`, which is what closes this.
    func testJapaneseAndKoreanAreNeverConverted() {
        for (text, language) in [("今日は学校に行きます", "ja"), ("韓國語 학교", "ko")] {
            let partial = preview(text)
            XCTAssertEqual(
                TranscriptPreviewScript.normalized(
                    partial, to: .traditional, languageCode: language),
                partial,
                "\(language) was converted")
        }
    }

    /// Latin words, digits, punctuation and emoji come out byte for byte, so a
    /// code-switched preview is converted without its English being touched.
    func testOnlyHanCharactersAreTouched() {
        let shown = TranscriptPreviewScript.normalized(
            preview("把 PR 开到 feature/login 再 @James 👍"),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "把 PR 開到 feature/login 再 @James 👍")
    }

    func testAnEmptyPreviewSurvives() {
        let partial = PartialTranscript(text: "", segment: "", segmentCount: 0)
        XCTAssertEqual(
            TranscriptPreviewScript.normalized(partial, to: .traditional, languageCode: "zh"),
            partial)
    }

    // MARK: - One verdict for the whole preview

    /// `text` and `segment` are two views of one decode, so the Han-dominance
    /// test is asked once, of the joined text. A two-character segment of a
    /// Chinese sentence would fail that test on its own, and the line would
    /// then convert in pieces: the sentence in the user's script and the newest
    /// words in the engine's.
    func testTheSegmentFollowsTheWholePreviewsVerdict() {
        let shown = TranscriptPreviewScript.normalized(
            PartialTranscript(
                text: "我们开会讨论这个项目的进度", segment: "OK 开会", segmentCount: 2),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "我們開會討論這個項目的進度")
        XCTAssertEqual(shown.segment, "OK 開會")
    }

    // MARK: - It is the same decision, not a second one

    /// The preview and the paste must never disagree, so both ask
    /// `ChineseScriptVariant` whether the text is Chinese and both convert with
    /// `ChineseScriptNormalizer`. This checks the two answers line up over a
    /// range of inputs rather than trusting that they were written to.
    func testThePreviewAgreesWithTheTranscriptStage() {
        let cases = [
            ("我们开会", "zh"), ("我們開會", "zh"), ("We ship on Friday.", "en"),
            ("今日は学校に行きます", "ja"), ("把 PR 开到 feature/login", "zh"),
            ("第一句。第二句。", "auto"),
        ]
        for (text, language) in cases {
            let shown = TranscriptPreviewScript.normalized(
                preview(text), to: .traditional, languageCode: language)
            XCTAssertEqual(
                shown.text,
                ChineseScriptNormalizer.normalized(
                    text, to: .traditional, languageCode: language),
                "the preview and the transcript stage disagreed about \(text)")
        }
    }

    /// And the structural half: the preview conversion has exactly one call
    /// site in the app, so the two surfaces that show a preview cannot drift.
    func testThePreviewConversionHasOneImplementation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        var callers: [String] = []
        var scanned = 0

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let name = url.lastPathComponent
            if code.contains("TranscriptPreviewScript.normalized(") {
                callers.append(name)
            }
            // A preview is the only thing allowed to convert a script outside
            // the transcript stage, and it may only do it through this type.
            if name == "LiveDictationSession.swift" {
                XCTAssertFalse(
                    code.contains("ChineseScriptNormalizer"),
                    "the live session converts a script itself; the preview goes through "
                        + "TranscriptPreviewScript and the paste through the transcript stage")
            }
        }

        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources")
        XCTAssertEqual(
            callers.sorted(), ["LiveDictationSession.swift", "TranscriptionService.swift"],
            "the two surfaces that publish a preview are the only callers")
    }
}
