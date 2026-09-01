import XCTest

@testable import OpenSuperWhisper

/// English inside Mandarin, end to end on text - the product's own name said in
/// the product's own way.
///
/// `把 PR 開到 feature/login 再 @James` is one utterance for this app's users, and
/// the fixtures below are that shape: Mandarin sentence structure with English
/// product names, branches, handles and identifiers in it. They are text rather
/// than audio on purpose. What an engine hears is pinned against the real
/// weights in `SenseVoiceEngineIntegrationTests`, which is opt-in and skipped by
/// default; what happens to the transcript afterwards is deterministic, offline
/// and has to hold on every machine, so it is asserted here.
///
/// Three claims, and each has its own section:
///
/// 1. **The Chinese half is written in the user's script.** Traditional by
///    default, whichever script the model returned.
/// 2. **The English half is not touched at all.** Byte for byte, including the
///    slash in a branch name and the `@` in a handle.
/// 3. **Paraformer still refuses these.** The bilingual path is one engine's,
///    and the guard in front of the Mandarin-only engine is not softened to make
///    room for it.
///
/// `docs/bilingual-dictation.md` is the whole story.
final class BilingualDictationTests: IsolatedPreferencesTestCase {

    /// One utterance in the three forms it exists in: as SenseVoice writes it,
    /// as a Traditional user must read it, and as Paraformer answers the same
    /// audio.
    private struct MixedUtterance {
        /// What the model returns - Simplified, because both FunASR engines
        /// write Simplified whatever the speaker writes.
        let simplified: String
        /// What the user must end up with.
        let traditional: String
        /// The Latin spans that have to survive the transcript stage exactly.
        let english: [String]
    }

    /// Deliberately five short utterances rather than one long one: the failure
    /// this file exists for is a *share* rule, so the fixtures have to span the
    /// range of how much English a real sentence carries. The first is the
    /// captain's own example and the heaviest - four Chinese words against four
    /// English ones.
    private let utterances: [MixedUtterance] = [
        MixedUtterance(
            simplified: "把 PR 开到 feature/login 再 @James",
            traditional: "把 PR 開到 feature/login 再 @James",
            english: ["PR", "feature/login", "@James"]
        ),
        MixedUtterance(
            simplified: "我们用 SwiftUI 重写了 Settings 这个 pane",
            traditional: "我們用 SwiftUI 重寫了 Settings 這個 pane",
            english: ["SwiftUI", "Settings", "pane"]
        ),
        MixedUtterance(
            simplified: "记得在 Slack 上 tag @Ada，然后把 build 跑一次",
            traditional: "記得在 Slack 上 tag @Ada，然後把 build 跑一次",
            english: ["Slack", "tag", "@Ada", "build"]
        ),
        MixedUtterance(
            simplified: "这个 API 回传 404，先看 nginx 的 log",
            traditional: "這個 API 回傳 404，先看 nginx 的 log",
            english: ["API", "404", "nginx", "log"]
        ),
        MixedUtterance(
            simplified: "我们把 deploy 排在 Q3，先跟 James 确认 staging 环境",
            traditional: "我們把 deploy 排在 Q3，先跟 James 確認 staging 環境",
            english: ["deploy", "Q3", "James", "staging"]
        ),
    ]

    /// The transcript stage with every optional pass off, so what is asserted is
    /// the script conversion and nothing else. The terms dictionary and CJK
    /// spacing have their own tests; letting either run here would be asserting
    /// three features through one expectation.
    private func transcriptStage(
        _ text: String, script: ChineseScriptVariant = .traditional, language: String = "zh"
    ) -> String {
        var settings = Settings()
        settings.selectedLanguage = language
        settings.chineseOutputScript = script
        settings.safeCorrectionEnabled = false
        settings.useAsianAutocorrect = false
        return TextPostProcessor.process(text, settings: settings, terms: []).final
    }

    // MARK: - The Chinese half is written in the user's script

    /// The claim the whole feature rests on: a mixed utterance off the bilingual
    /// engine reaches a Traditional user in Traditional.
    func testMixedUtterancesComeOutInTraditional() {
        for utterance in utterances {
            XCTAssertEqual(
                transcriptStage(utterance.simplified),
                utterance.traditional,
                "the Chinese half of a mixed utterance was not converted: \(utterance.simplified)"
            )
        }
    }

    /// The captain's example on its own, spelled out, because it is the sentence
    /// that used to fail: four Han characters against nineteen Latin letters is
    /// 17% and was read as English, so a Traditional user got `开` back.
    func testTheHeaviestCodeSwitchIsStillChinese() {
        let simplified = "把 PR 开到 feature/login 再 @James"

        XCTAssertTrue(
            ChineseScriptVariant.isChineseText(simplified, languageCode: "zh"),
            "a Mandarin sentence carrying four English words is Mandarin"
        )
        XCTAssertEqual(transcriptStage(simplified), "把 PR 開到 feature/login 再 @James")
    }

    /// The other direction is the same feature. A user who writes Simplified is
    /// not a second-class case of one who does not.
    func testTheUsersOwnChoiceOfScriptIsWhatIsApplied() {
        for utterance in utterances {
            XCTAssertEqual(
                transcriptStage(utterance.traditional, script: .simplified),
                utterance.simplified,
                "converting the other way round lost something: \(utterance.traditional)"
            )
        }
    }

    /// Cantonese is a SenseVoice dictation language of its own, and a Cantonese
    /// speaker mixes in the same English.
    func testCantoneseDictationIsConvertedToo() {
        XCTAssertEqual(
            transcriptStage("我哋今日要 review 呢个 PR", language: "yue"),
            "我哋今日要 review 呢個 PR"
        )
    }

    /// Auto-detect is SenseVoice's other honest answer, and a code-switched
    /// recording is exactly when a user leaves it there.
    func testAutoDetectedMixedDictationIsConvertedToo() {
        XCTAssertEqual(
            transcriptStage("这个 API 回传 404，先看 nginx 的 log", language: "auto"),
            "這個 API 回傳 404，先看 nginx 的 log"
        )
    }

    // MARK: - The English half is not touched at all

    /// Every Latin span survives the transcript stage exactly, including the
    /// slash inside a branch name and the `@` in front of a handle. A conversion
    /// that respaced or rewrote any of it would be corrupting an identifier
    /// somebody is about to paste into a terminal.
    func testEveryEnglishSpanSurvivesByteForByte() {
        for utterance in utterances {
            let converted = transcriptStage(utterance.simplified)
            for span in utterance.english {
                XCTAssertTrue(
                    converted.contains(span),
                    "\(span) did not survive the transcript stage: \(converted)"
                )
            }
        }
    }

    /// The stronger form of the same promise: the conversion is character-wise,
    /// so nothing may be inserted or dropped anywhere in a mixed utterance.
    func testTheCharacterCountOfAMixedUtteranceNeverChanges() {
        for utterance in utterances {
            for script in [ChineseScriptVariant.traditional, .simplified] {
                XCTAssertEqual(
                    transcriptStage(utterance.simplified, script: script).count,
                    utterance.simplified.count,
                    "a mixed utterance changed length converting to \(script.rawValue)"
                )
            }
        }
    }

    /// The gate is a share, so it has two sides, and the side that must not move
    /// is English dictation. A sentence that is English with a Chinese name in it
    /// is English, and the existing promise that English dictation comes back as
    /// English is not weakened by counting words.
    func testEnglishDictationWithAChineseNameIsStillEnglish() {
        for text in [
            "We should ask 张 about the deploy tomorrow morning.",
            "Please merge the 主 branch before you leave today.",
            "The meeting starts at three.",
        ] {
            XCTAssertFalse(
                ChineseScriptVariant.isChineseText(text, languageCode: "zh"),
                "an English sentence was read as Chinese: \(text)"
            )
            XCTAssertEqual(transcriptStage(text), text)
        }
    }

    /// Han is weighed against **words**, not letters, and the two numbers are
    /// stated here so that changing the counting fails a test rather than
    /// quietly re-deciding whose dictation is Chinese. See
    /// `ChineseScriptVariant.isHanDominant`.
    func testHanIsWeighedAgainstWordsRatherThanLetters() {
        // Four Han characters, four Latin words, nineteen Latin letters.
        XCTAssertTrue(ChineseScriptVariant.isHanDominant("把 PR 开到 feature/login 再 @James"))
        // One Han character, eight Latin words. Nothing about the shorter words
        // makes this sentence Chinese.
        XCTAssertFalse(
            ChineseScriptVariant.isHanDominant("We should ask 张 about the deploy tomorrow morning.")
        )
    }

    /// Text with no words at all - digits, symbols, an empty transcript - says
    /// nothing about a language and must not be converted on a division by zero.
    func testTextWithNoWordsIsNotChinese() {
        for text in ["", "   ", "2500 $ 30%", "404 / 500"] {
            XCTAssertFalse(ChineseScriptVariant.isHanDominant(text), "\(text) is not Chinese")
        }
    }

    /// Han characters shared with Japanese and Korean are still ruled out by the
    /// languages that write them, and by kana or Hangul in the text itself. The
    /// word counting changes the Chinese/English line, not this one.
    func testJapaneseAndKoreanAreStillRuledOut() {
        XCTAssertFalse(ChineseScriptVariant.isChineseText("私は大学で国語を勉強しています", languageCode: "auto"))
        XCTAssertFalse(ChineseScriptVariant.isChineseText("안녕하세요 저는 學生입니다", languageCode: "auto"))
        XCTAssertFalse(ChineseScriptVariant.isChineseText("会議は 3 時からです", languageCode: "ja"))
    }

    // MARK: - Paraformer still refuses these

    /// The Mandarin-only engine answers this audio with the sub-word units of a
    /// vocabulary that has no English in it, `@@` markers and all. Every mixed
    /// utterance in that shape is refused, and nothing here repairs one.
    func testParaformerRefusesTheFragmentsItReturnsForMixedSpeech() {
        let asParaformerAnswersIt = [
            "把pr开到fe@@ ature@@ /lo@@ gin再ja@@ mes",
            "记得在sl@@ ack上ta@@ g然后把bu@@ ild跑一次",
            "这个a@@ pi回传404先看ng@@ in@@ x的lo@@ g",
        ]

        for text in asParaformerAnswersIt {
            XCTAssertEqual(
                ParaformerLanguageGuard.rejection(in: text), .bpeFragments,
                "a mixed utterance came back as fragments and was not refused: \(text)"
            )
        }
    }

    /// The captain's example is refused by the share rule as well, with the
    /// markers stripped - so this one does not depend on an upstream defect
    /// staying unfixed. The guard's own documentation records the case that
    /// does: a mostly-Mandarin sentence with a little English in it passes the
    /// share rule, which is why the fixtures below are asserted individually
    /// rather than as a class.
    func testTheHeaviestCodeSwitchIsRefusedEvenWithoutMarkers() {
        XCTAssertEqual(
            ParaformerLanguageGuard.rejection(in: "把pr开到feature/login再james"), .latinScript
        )
    }

    /// A refused mixed dictation keeps the audio, which is what makes "switch to
    /// the bilingual engine and press regenerate" cost one press rather than the
    /// recording.
    func testARefusedMixedDictationKeepsTheRecording() {
        XCTAssertNotEqual(
            DictationFailureOutcome.forError(ParaformerLanguageGuard.failure), .discard,
            "a refused mixed dictation must not throw the audio away"
        )
    }

    // MARK: - The engine the app names for this

    /// One engine transcribes both languages in one recording, and it is the one
    /// the copy and the selector name. Switched exhaustively on `EngineKind`, so
    /// a new engine that quietly claimed it would fail here.
    func testExactlyOneEngineTranscribesBothLanguagesTogether() {
        let bilingual = EngineKind.allCases.filter(\.transcribesEnglishAndChineseTogether)

        XCTAssertEqual(bilingual, [EngineKind.bilingualDictation])
        XCTAssertEqual(EngineKind.bilingualDictation, .sensevoice)
        XCTAssertEqual(EngineSelector.bilingualEngine, EngineKind.bilingualDictation)
    }

    /// The bilingual engine has to be able to be asked for both languages, which
    /// is the pairing a future engine addition is most likely to get wrong.
    func testTheBilingualEngineSupportsBothLanguages() {
        let languages = LanguageUtil.supportedLanguages(
            engine: EngineKind.bilingualDictation, fluidAudioModelVersion: "v3"
        )
        XCTAssertTrue(languages.contains("zh"))
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("auto"))
    }

    /// The cloud engine is not the answer to this and must never become it: the
    /// bilingual path is on-device, and a `true` here would put a recommendation
    /// in front of a consent decision.
    func testTheCloudEngineIsNotOfferedAsTheBilingualOne() {
        XCTAssertFalse(EngineKind.cloud.transcribesEnglishAndChineseTogether)
        XCTAssertFalse(EngineKind.bilingualDictation.usesCloudProvider)
    }
}
