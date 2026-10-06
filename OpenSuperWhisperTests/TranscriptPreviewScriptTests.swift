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

    private func shown(
        _ partial: PartialTranscript, to variant: ChineseScriptVariant,
        languageCode: String
    ) -> PartialTranscript {
        TranscriptPreviewScript.normalized(partial, to: variant, languageCode: languageCode)
    }

    // MARK: - The conversion

    /// The bug this exists for: Paraformer, SenseVoice and Whisper hand back
    /// Simplified for a speaker of Taiwanese Mandarin, and the capsule showed
    /// it for the length of the recording before the paste switched script.
    func testASimplifiedPreviewIsShownInTraditional() {
        let shown = shown(
            preview("我们开会讨论这个项目"), to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "我們開會討論這個項目")
        XCTAssertEqual(shown.segment, "我們開會討論這個項目")
    }

    /// Traditional is the default, but the setting is as complete a choice the
    /// other way: a user who writes Simplified sees Simplified.
    func testTheChosenScriptIsHonouredBothWays() {
        let shown = shown(
            preview("我們開會"), to: .simplified, languageCode: "zh")

        XCTAssertEqual(shown.text, "我们开会")
    }

    /// The language a live session pinned is a Chinese one, which is how an
    /// `auto` Mandarin session converts from its first published utterance:
    /// the pin lands on that utterance's decode, before it reaches the line.
    func testAPinnedChineseLanguageConverts() {
        let shown = shown(
            preview("我们开会"), to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "我們開會")
    }

    /// Cantonese is a Chinese language here too - SenseVoice offers it as its
    /// own dictation language and whisper detects it as `yue`.
    func testCantoneseConverts() {
        let shown = shown(
            preview("我们开会"), to: .traditional, languageCode: "yue")

        XCTAssertEqual(shown.text, "我們開會")
    }

    /// The line grows and never rewrites itself, and the conversion has to
    /// leave that true: it is character-wise, so every prefix already on screen
    /// comes out of a later call exactly as it did out of the earlier one.
    func testAGrowingPreviewNeverRewritesWhatIsAlreadyShown() {
        let first = shown(
            preview("我们开会。"), to: .traditional, languageCode: "zh")
        let second = shown(
            preview("我们开会。然后发布。", segment: "然后发布。"),
            to: .traditional, languageCode: "zh")

        XCTAssertTrue(second.text.hasPrefix(first.text))
        XCTAssertEqual(second.segment, "然後發布。")
    }

    /// The same property where it used to break, in both directions, because
    /// this is the whole reason the gate does not read the text.
    ///
    /// Both of these sequences cross `hanShareThreshold` - the first upwards,
    /// the second downwards - as the line grows, so a verdict asked of the
    /// joined text would flip mid-session and rewrite the prefix already on
    /// screen. The share of the line is not an input here, so neither does.
    func testCrossingTheHanShareThresholdMidSessionChangesNothingOnScreen() {
        // Upwards: utterance 1 is 2 Han against 6 English words - 0.25, below
        // the threshold - and utterance 2 takes the joined line to 0.63.
        let openingBelow = shown(
            preview("这个 PR should be ready by Friday"),
            to: .traditional, languageCode: "zh")
        let joinedAbove = shown(
            preview(
                "这个 PR should be ready by Friday 我们明天开会讨论",
                segment: "我们明天开会讨论"),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(openingBelow.text, "這個 PR should be ready by Friday")
        XCTAssertTrue(
            joinedAbove.text.hasPrefix(openingBelow.text),
            "the prefix on screen was rewritten when the line rose above the threshold: "
                + joinedAbove.text)

        // Downwards: the line starts Chinese and a long English clause drags
        // the joined share to 0.15.
        let openingAbove = shown(preview("这个 PR"), to: .traditional, languageCode: "zh")
        let joinedBelow = shown(
            preview(
                "这个 PR we should land it before Friday and tell the team",
                segment: "we should land it before Friday and tell the team"),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(openingAbove.text, "這個 PR")
        XCTAssertTrue(
            joinedBelow.text.hasPrefix(openingAbove.text),
            "the prefix on screen was rewritten when the line fell below the threshold: "
                + joinedBelow.text)
    }

    /// `segmentCount` is the engine's count of what it has committed, not
    /// something a script conversion gets an opinion about.
    func testTheSegmentCountIsCarriedThrough() {
        let shown = shown(
            PartialTranscript(text: "我们开会", segment: "开会", segmentCount: 7),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.segmentCount, 7)
    }

    /// A Chinese session that opens with a sentence of English still converts
    /// the Chinese that follows: the first words do not get to decide the
    /// recording, because no words decide anything here.
    func testAnOpeningEnglishUtteranceDoesNotCloseChinese() {
        let first = shown(
            preview("OK let's start."), to: .traditional, languageCode: "zh")
        let second = shown(
            preview("OK let's start. 我们开会讨论这个项目", segment: "我们开会讨论这个项目"),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(first.text, "OK let's start.")
        XCTAssertEqual(second.text, "OK let's start. 我們開會討論這個項目")
    }

    // MARK: - Until the language says Chinese

    /// `auto` is not an answer, so nothing is converted under it. A whole
    /// transcript's characters are evidence enough for the transcript stage,
    /// but a preview is a prefix: these two characters are as readily the
    /// opening of a Japanese sentence.
    func testAnUnsettledAutoPreviewIsShownAsDecoded() {
        let partial = preview("学校")
        XCTAssertEqual(
            shown(partial, to: .traditional, languageCode: "auto"),
            partial)
    }

    /// A kanji-only prefix under `auto` is the case that forced the language to
    /// be the only input: the text says "Han-dominant" and means nothing, and
    /// converting on it showed a Traditional user `學校に行きます` - characters
    /// no stage of this app would write and the paste would never produce.
    func testAnAutoJapaneseSentenceIsNeverConvertedByItsKanjiOnlyPrefix() {
        let first = shown(preview("学校"), to: .traditional, languageCode: "auto")
        let second = shown(
            preview("学校に行きます", segment: "に行きます"),
            to: .traditional, languageCode: "auto")

        XCTAssertEqual(first.text, "学校")
        XCTAssertEqual(second.text, "学校に行きます")
        XCTAssertEqual(second.segment, "に行きます")
    }

    /// A language this app does not know says nothing either, so it converts
    /// nothing - the same answer `auto` gets, for the same reason.
    func testAnUnknownLanguageIsShownAsDecoded() {
        let partial = preview("我们开会")
        XCTAssertEqual(
            shown(partial, to: .traditional, languageCode: "xx"),
            partial)
    }

    // MARK: - What is left alone

    func testEnglishIsLeftExactlyAsItIs() {
        let partial = preview("We ship on Friday.")
        XCTAssertEqual(
            shown(partial, to: .traditional, languageCode: "en"),
            partial)
    }

    /// A user whose dictation language is Chinese but who said a sentence of
    /// English gets their English back - not because the sentence was judged,
    /// but because the conversion has no Han character to touch.
    func testAnEnglishSentenceUnderAChineseLanguageIsLeftAlone() {
        let partial = preview("We ship the release on Friday.")
        XCTAssertEqual(
            shown(partial, to: .traditional, languageCode: "zh"),
            partial)
    }

    /// Kanji and hanja are Han characters too, and 学 → 學 in a Japanese
    /// preview is a corruption rather than a normalization. A live session
    /// pinned to Japanese asks with `ja`, which is what closes this.
    ///
    /// Both fixtures are deliberately **kanji- and hanja-only**: a single kana
    /// or Hangul character makes `isHanDominant` refuse on its own, which would
    /// let these assertions hold with the language gate deleted. These are
    /// Han-dominant, so the language code is the only thing standing between
    /// 学 and 學.
    func testJapaneseAndKoreanAreNeverConverted() {
        for (text, language) in [("東京都庁見学", "ja"), ("大韓民國", "ko")] {
            XCTAssertTrue(
                ChineseScriptVariant.isHanDominant(text),
                "\(text) is not Han-dominant, so this case would pass without the language gate")
            let partial = preview(text)
            XCTAssertEqual(
                shown(
                    partial, to: .traditional, languageCode: language),
                partial,
                "\(language) was converted")
        }
    }

    /// Latin words, digits, punctuation and emoji come out byte for byte, so a
    /// code-switched preview is converted without its English being touched.
    func testOnlyHanCharactersAreTouched() {
        let shown = shown(
            preview("把 PR 开到 feature/login 再 @James 👍"),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "把 PR 開到 feature/login 再 @James 👍")
    }

    func testAnEmptyPreviewSurvives() {
        let partial = PartialTranscript(text: "", segment: "", segmentCount: 0)
        XCTAssertEqual(
            shown(partial, to: .traditional, languageCode: "zh"),
            partial)
    }

    // MARK: - One verdict for the whole preview

    /// `text` and `segment` are two views of one decode and cannot disagree
    /// about the script, because the verdict is the language and neither of
    /// them is consulted. Judged separately on their own characters, a
    /// two-character segment would fail a test its own sentence passes and the
    /// line would convert in pieces: the sentence in the user's script and the
    /// newest words in the engine's.
    func testTheSegmentFollowsTheWholePreviewsVerdict() {
        let shown = shown(
            PartialTranscript(
                text: "我们开会讨论这个项目的进度", segment: "OK 开会", segmentCount: 2),
            to: .traditional, languageCode: "zh")

        XCTAssertEqual(shown.text, "我們開會討論這個項目的進度")
        XCTAssertEqual(shown.segment, "OK 開會")
    }

    // MARK: - One piece at a time

    /// The entry point a line that grows uses: a caller converts each piece as
    /// it publishes it, which is what keeps a verdict arriving later from
    /// reaching a piece already on screen (`LiveDictationSession`).
    func testAPieceIsConvertedOnItsOwnVerdict() {
        XCTAssertEqual(
            TranscriptPreviewScript.converted("我们开会。", to: .traditional, languageCode: "zh"),
            "我們開會。")
        XCTAssertEqual(
            TranscriptPreviewScript.converted("我们开会。", to: .traditional, languageCode: "auto"),
            "我们开会。")
    }

    /// And converting the pieces is converting the line. The transform is
    /// character-wise and Han for Han, so `CommittedTranscript.joined` answers
    /// its seam test the same either side of it: a session whose language said
    /// Chinese from the first utterance shows, piece by piece, exactly what the
    /// transcript stage will produce over the whole raw transcript.
    func testJoiningConvertedPiecesIsConvertingTheJoinedLine() {
        let pieces = ["这个 PR should be ready by Friday", "我们明天开会讨论", "OK thanks."]
        let converted = pieces.map {
            TranscriptPreviewScript.converted($0, to: .traditional, languageCode: "zh")
        }

        XCTAssertEqual(
            CommittedTranscript.joined(converted),
            ChineseScriptNormalizer.normalized(
                CommittedTranscript.joined(pieces), to: .traditional, languageCode: "zh"))
    }

    // MARK: - The shared conversion rule

    /// Once the language has said, the preview and the paste must never
    /// disagree - a user who watches the script change at the paste is looking
    /// at the same bug this feature exists to remove, pointed the other way. So
    /// a Chinese dictation language is the branch of
    /// `ChineseScriptVariant.isChineseOutput` that needs no evidence, and this
    /// checks the two stages line up over a range of inputs rather than
    /// trusting that they were written to.
    ///
    /// The fourth case is the one that used to fail: a sentence whose Han share
    /// is 0.15 was converted on the preview and left alone at the paste.
    func testThePreviewAgreesWithTheTranscriptStage() {
        let cases = [
            ("我们开会", "zh"), ("我們開會", "zh"), ("We ship on Friday.", "en"),
            ("这个 PR we should land it before Friday and tell the team", "zh"),
            ("这个 PR should be ready by Friday", "zh"),
            ("We should ask 张 about the deploy tomorrow morning.", "zh"),
            ("東京都庁見学", "ja"), ("把 PR 开到 feature/login", "zh"),
            ("第一句。第二句。", "zh"), ("我们开会", "ko"),
        ]
        for (text, language) in cases {
            let shown = shown(
                preview(text), to: .traditional, languageCode: language)
            XCTAssertEqual(
                shown.text,
                ChineseScriptNormalizer.normalized(
                    text, to: .traditional, languageCode: language),
                "the preview and the transcript stage disagreed about \(text)")
        }
    }

    /// And the one place they part, stated as its own clause so it cannot be
    /// mistaken for an oversight: the transcript stage converts Han-dominant
    /// text under `auto`, because by then the whole transcript is in front of
    /// it; the preview, which has a prefix, does not.
    func testTheOneDifferenceFromTheTranscriptStageIsTheUnsettledLanguage() {
        let raw = "我们开会"
        let shown = shown(preview(raw), to: .traditional, languageCode: "auto")

        XCTAssertEqual(shown.text, raw)
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(raw, to: .traditional, languageCode: "auto"),
            "我們開會",
            "the transcript stage still converts an auto-detected Chinese transcript")
    }

}
