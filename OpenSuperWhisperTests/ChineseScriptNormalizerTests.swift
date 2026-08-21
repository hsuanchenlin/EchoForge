import XCTest
@testable import OpenSuperWhisper

/// Pins the promise the Chinese script setting makes: **a Chinese dictation is
/// written in the script the user chose, and nothing else about the text
/// changes.**
///
/// The tests are grouped by the two halves of that sentence. The first half is
/// the conversion - Simplified in, Traditional out, whatever engine produced it.
/// The second half is everything the conversion must not touch: Latin words,
/// digits, timestamps, punctuation, the user's own dictionary entries and
/// snippets, and every language that is not Chinese.
///
/// `docs/chinese-script.md` is the feature's whole story.
final class ChineseScriptNormalizerTests: IsolatedPreferencesTestCase {

    // MARK: - The conversion

    func testSimplifiedInputComesOutTraditional() {
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(
                "我们今天开会讨论这个项目的进度", to: .traditional, languageCode: "zh"
            ),
            "我們今天開會討論這個項目的進度"
        )
    }

    func testTraditionalInputIsLeftAlone() {
        let text = "我們今天開會討論這個專案的進度"
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "zh"), text
        )
    }

    /// The case a user actually hits: one sentence in which the engine used both
    /// scripts. Whisper does this inside a single dictation.
    func testMixedScriptOutputIsMadeConsistent() {
        let converted = ChineseScriptNormalizer.normalized(
            "這個项目的进度很好", to: .traditional, languageCode: "zh"
        )

        XCTAssertEqual(converted, "這個項目的進度很好")
        XCTAssertFalse(
            ChineseScriptVariant.signal(in: converted).simplified > 0,
            "a normalized transcript must not still contain the other script"
        )
    }

    func testConvertingIsIdempotent() {
        let once = ChineseScriptNormalizer.normalized(
            "我们开会", to: .traditional, languageCode: "zh"
        )
        let twice = ChineseScriptNormalizer.normalized(once, to: .traditional, languageCode: "zh")
        XCTAssertEqual(once, twice)
    }

    /// The other direction is the same feature, not a lesser one: a user who
    /// writes Simplified gets the same consistency pointed the other way.
    func testSimplifiedIsAsCompleteAChoiceAsTraditional() {
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(
                "我們今天開會討論這個進度", to: .simplified, languageCode: "zh"
            ),
            "我们今天开会讨论这个进度"
        )
    }

    func testCantoneseIsChineseToo() {
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized("我们今日开会", to: .traditional, languageCode: "yue"),
            "我們今日開會"
        )
    }

    func testAutoDetectedChineseIsNormalizedToo() {
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized("这是自动侦测的中文", to: .traditional, languageCode: "auto"),
            "這是自動偵測的中文"
        )
    }

    // MARK: - What it must not touch

    func testEverythingThatIsNotHanSurvivesExactly() {
        let converted = ChineseScriptNormalizer.normalized(
            "我们用 Kubernetes 部署了 3 个服务，成本 $42.50（约 12%）。\n\t下一步：观察。",
            to: .traditional,
            languageCode: "zh"
        )

        XCTAssertEqual(
            converted,
            "我們用 Kubernetes 部署了 3 個服務，成本 $42.50（約 12%）。\n\t下一步：觀察。"
        )
    }

    /// Whisper's timestamped output is the strongest form of the same promise:
    /// the brackets, digits, arrows and spacing are structure, and a conversion
    /// that moved any of it would corrupt a transcript rather than normalize it.
    func testTimestampsSurviveExactly() {
        let converted = ChineseScriptNormalizer.normalized(
            "[00:00:00.000 --> 00:00:02.480]  我们开会\n[00:00:02.480 --> 00:00:04.000]  讨论进度",
            to: .traditional,
            languageCode: "zh"
        )

        XCTAssertEqual(
            converted,
            "[00:00:00.000 --> 00:00:02.480]  我們開會\n[00:00:02.480 --> 00:00:04.000]  討論進度"
        )
    }

    /// Character-for-character, always. It is what lets every caller treat the
    /// conversion as invisible to anything but the script.
    func testTheCharacterCountNeverChanges() {
        let inputs = [
            "我们开会", "Hello, world!", "会議は三時からです", "안녕하세요", "🙂 123 %$", "",
        ]
        for input in inputs {
            for variant in [ChineseScriptVariant.traditional, .simplified] {
                XCTAssertEqual(
                    ChineseScriptNormalizer.convert(input, to: variant).count, input.count,
                    "\(input) changed length converting to \(variant.rawValue)"
                )
            }
        }
    }

    func testJapaneseIsNeverConverted() {
        // Kanji are Han characters, and 学 / 国 are exactly the characters a
        // Simplified-to-Traditional pass would rewrite. Japanese is not Chinese.
        let text = "私は大学で国語を勉強しています"
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "ja"), text
        )
        // And not even when the dictation language does not say: kana in the
        // text is enough on its own.
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "auto"), text
        )
    }

    func testKoreanIsNeverConverted() {
        let text = "안녕하세요 저는 學生입니다"
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "ko"), text
        )
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "auto"), text
        )
    }

    func testEnglishDictationIsLeftAlone() {
        let text = "The meeting starts at three."
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "en"), text
        )
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "auto"), text
        )
    }

    /// A user who leaves the language on Chinese and dictates an English
    /// sentence gets their English sentence, quoted Chinese name and all.
    func testAnEnglishSentenceUnderAChineseLanguageIsLeftAlone() {
        let text = "We should ask 张 about the deploy tomorrow morning."
        XCTAssertEqual(
            ChineseScriptNormalizer.normalized(text, to: .traditional, languageCode: "zh"), text
        )
    }

    // MARK: - The preference

    func testTraditionalIsTheDefaultOnAFreshInstall() {
        XCTAssertEqual(AppPreferences.shared.chineseOutputScript, .traditional)
    }

    /// The migration case: an install that predates the setting has no value
    /// stored, and must read exactly as a fresh one does rather than as
    /// whatever the Mac's region implies.
    func testAnInstallWithNothingStoredReadsAsTraditional() {
        XCTAssertNil(storedPreference("chineseOutputScript"))
        XCTAssertEqual(Settings().chineseOutputScript, .traditional)
    }

    /// A value written by a newer build - or a hand-edited domain - must not
    /// leave the app converting to something it cannot name.
    func testAnUnreadableStoredValueReadsAsTraditional() {
        PreferenceStore.defaults.set("cursive", forKey: "chineseOutputScript")
        XCTAssertEqual(AppPreferences.shared.chineseOutputScript, .traditional)
    }

    func testChoosingSimplifiedIsHonouredEndToEnd() {
        AppPreferences.shared.chineseOutputScript = .simplified
        let settings = makeSettings(language: "zh")

        XCTAssertEqual(
            TextPostProcessor.process("我們開會討論進度", settings: settings, terms: []).final,
            "我们开会讨论进度"
        )
    }

    func testTheDefaultPreferenceWritesTraditionalThroughTheTranscriptStage() {
        let settings = makeSettings(language: "zh")

        let processed = TextPostProcessor.process("我们开会讨论进度", settings: settings, terms: [])

        XCTAssertEqual(processed.final, "我們開會討論進度")
        // The engine's own output is kept beside it, so History can still show
        // what was heard and "Compare" has something to compare against.
        XCTAssertEqual(processed.raw, "我们开会讨论进度")
        XCTAssertTrue(processed.wasModified)
    }

    // MARK: - The user's own text

    /// The rule the stage order exists for: **the recognizer's words are
    /// converted, the user's own are not.** A dictionary entry is how this user
    /// spells something, in the script they typed it in.
    func testAPersonalTermIsInsertedInTheScriptTheUserStoredIt() {
        let settings = makeSettings(language: "zh")
        let term = PersonalTerm(
            kind: .preferredSpelling, match: "开会", replacement: "开会 (Simplified on purpose)"
        )

        let processed = TextPostProcessor.process(
            "我们开会", settings: settings, terms: [term]
        )

        XCTAssertTrue(
            processed.final.contains("开会 (Simplified on purpose)"),
            "the dictionary's own spelling was converted: \(processed.final)"
        )
        XCTAssertTrue(processed.final.hasPrefix("我們"), processed.final)
    }

    // MARK: - It changes the script and nothing else

    /// **The setting is about how a Chinese transcript is written down, not
    /// about what gets recognized.** It must never make recognition Chinese,
    /// move the dictation language, or tilt auto-detect: an English dictation
    /// stays English, and the language the engine is asked for is the one the
    /// user chose, before and after.
    func testItNeverChangesWhatIsRecognizedOrWhichLanguageIsAskedFor() {
        let prefs = AppPreferences.shared
        prefs.chineseOutputScript = .traditional
        prefs.useAsianAutocorrect = false

        for language in ["en", "auto", "ja", "zh"] {
            prefs.whisperLanguage = language
            let settings = Settings()
            XCTAssertEqual(settings.selectedLanguage, language)

            let english = "The team meets at three to review the deploy."
            XCTAssertEqual(
                TextPostProcessor.process(english, settings: settings, terms: []).final,
                english,
                "English was altered under language \(language)"
            )

            // Reading the setting, and running the whole transcript stage, left
            // the dictation language exactly where the user put it.
            XCTAssertEqual(prefs.whisperLanguage, language)
        }
    }

    /// The structural half of the same promise: the conversion is a pure
    /// function of the text, the chosen script and the dictation language. It
    /// reads no preference and writes none, so there is no path from it to what
    /// the engine is asked to recognize.
    func testTheConversionReadsAndWritesNoPreferences() throws {
        for file in ["Utils/ChineseScriptNormalizer.swift", "Utils/HanCharacterTransform.swift"] {
            let code = strippingComments(try sourceText(of: file))
            for symbol in ["AppPreferences", "PreferenceStore", "whisperLanguage", "UserDefaults"]
            where code.contains(symbol) {
                XCTFail(
                    "\(file) reaches for \(symbol). The conversion takes the script and the "
                        + "language as arguments; a preference read here is a path from an "
                        + "output setting back into what gets recognized."
                )
            }
        }
    }

    // MARK: - Every engine, the same answer

    /// Parity is structural: the conversion is part of the one transcript stage
    /// every engine's output passes through, so no engine can differ. The test
    /// states it anyway, because "no engine can differ" is the claim.
    func testEveryEngineGetsTheSameNormalizedTranscript() {
        for engine in EngineKind.allCases {
            AppPreferences.shared.selectedEngine = engine
            let settings = makeSettings(language: "zh")

            XCTAssertEqual(
                TextPostProcessor.process("我们开会", settings: settings, terms: []).final,
                "我們開會",
                "\(engine.rawValue) produced a different transcript"
            )
        }
    }

    /// And the structural half of the same claim: no engine reaches for the
    /// normalizer itself, and there is exactly one call to the transcript stage
    /// in the whole app.
    func testTheConversionHappensOnlyInTheSharedTranscriptStage() throws {
        var processCallSites: [String] = []

        try scanProductionSources { path, source in
            // Comments dropped: the pipeline diagrams in this project name the
            // stage they document, and a diagram is not a call site.
            let code = strippingComments(source)
            if code.contains("TextPostProcessor.process(") {
                processCallSites.append(path)
            }
            let isEngine = path.hasPrefix("Engines/") || path.hasPrefix("Cloud/")
            if isEngine && code.contains("ChineseScriptNormalizer") {
                XCTFail(
                    "\(path) normalizes Chinese itself. The transcript stage does it once for "
                        + "every engine; a second call site is how two engines start disagreeing."
                )
            }
        }

        XCTAssertEqual(
            processCallSites, ["TranscriptionService.swift"],
            "the transcript stage must have exactly one call site"
        )
    }

    // MARK: - No model, no network

    /// The conversion is ICU and nothing else. This is the claim that makes the
    /// feature usable offline, on every Mac, with identical results - and the
    /// one a later "improvement" would be most tempted to break by asking a
    /// model to pick words rather than characters.
    func testTheConversionReachesNoModelAndNoNetwork() throws {
        let forbidden = [
            "URLSession", "URLRequest", "http", "CloudClient", "StyleRewrit", "Rewriter",
            "FoundationModels", "LanguageModel", "prompt", "await", "async",
        ]

        for file in ["Utils/ChineseScriptNormalizer.swift", "Utils/HanCharacterTransform.swift"] {
            let source = try sourceText(of: file)
            // The documentation in these files names the very things the code
            // must not do, so the scan reads the code and not the prose.
            let code = strippingComments(source)
            for symbol in forbidden where code.contains(symbol) {
                XCTFail("\(file) mentions \(symbol) in code: the conversion is ICU, offline and pure.")
            }
        }

        // And the mapping really is the platform's, in the one file that owns
        // it: everything above is only an absence.
        XCTAssertTrue(
            try strippingComments(sourceText(of: "Utils/HanCharacterTransform.swift"))
                .contains("CFStringTransform")
        )
    }

    /// ICU rather than a table this repository maintains. A hand-written map
    /// would be a second, worse copy of something the platform ships - and it
    /// would rot, one character at a time, with nothing to notice.
    func testTheMappingIsICURatherThanAHandWrittenTable() {
        // Characters deliberately outside `ChineseScriptVariant`'s evidence
        // table, which is a few hundred pairs long. A hand-maintained map would
        // have to list every one of these; ICU already knows them.
        let pairs = [("鑰匙", "钥匙"), ("罐頭", "罐头"), ("鴨舌帽", "鸭舌帽"), ("蠟燭", "蜡烛")]

        for (traditional, simplified) in pairs {
            XCTAssertEqual(
                ChineseScriptNormalizer.convert(simplified, to: .traditional), traditional
            )
            XCTAssertEqual(
                ChineseScriptNormalizer.convert(traditional, to: .simplified), simplified
            )
        }
    }

    // MARK: - Helpers

    private func makeSettings(language: String) -> Settings {
        let prefs = AppPreferences.shared
        prefs.whisperLanguage = language
        // Off, so what these tests assert is the conversion rather than the
        // CJK spacing pass that runs after it.
        prefs.useAsianAutocorrect = false
        prefs.safeCorrectionEnabled = true
        return Settings()
    }

    /// Source with every `//` line dropped, so a scan asserts what the code
    /// does rather than what its comments talk about.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sourceText(of relativePath: String) throws -> String {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Sources are not beside the tests: \(url.path)")
        }
        return text
    }

    private func scanProductionSources(_ check: (String, String) throws -> Void) throws {
        guard let files = FileManager.default
            .enumerator(atPath: Self.sourceRoot.path)?.allObjects as? [String] else {
            throw XCTSkip("Sources are not beside the tests: \(Self.sourceRoot.path)")
        }

        var scanned = 0
        for file in files where file.hasSuffix(".swift") {
            try check(file, try String(contentsOf: Self.sourceRoot.appendingPathComponent(file), encoding: .utf8))
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources, so it proved almost nothing")
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
    }
}
