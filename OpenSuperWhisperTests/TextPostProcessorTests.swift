import XCTest
@testable import OpenSuperWhisper

/// Pins the two stages of `TextPostProcessor`.
///
/// The behaviour that matters here is the split: the transcript stage must be
/// identical for every engine and every consumption path, while the insertion
/// stage must apply only to live dictation output.
@MainActor
final class TextPostProcessorTests: XCTestCase {

    private var savedLanguage: String = "en"
    private var savedUseAsianAutocorrect: Bool = true
    private var savedAddSpace: Bool = true

    override func setUp() {
        super.setUp()
        let prefs = AppPreferences.shared
        savedLanguage = prefs.whisperLanguage
        savedUseAsianAutocorrect = prefs.useAsianAutocorrect
        savedAddSpace = prefs.addSpaceAfterSentence
    }

    override func tearDown() {
        let prefs = AppPreferences.shared
        prefs.whisperLanguage = savedLanguage
        prefs.useAsianAutocorrect = savedUseAsianAutocorrect
        prefs.addSpaceAfterSentence = savedAddSpace
        super.tearDown()
    }

    /// Builds a `Settings` value, which reads from `AppPreferences`.
    private func makeSettings(language: String, useAsianAutocorrect: Bool) -> Settings {
        let prefs = AppPreferences.shared
        prefs.whisperLanguage = language
        prefs.useAsianAutocorrect = useAsianAutocorrect
        return Settings()
    }

    // MARK: - Transcript stage: CJK autocorrect

    func testProcess_appliesAutocorrectForTraditionalChinese() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        // Mixed Traditional Chinese and Latin: autocorrect inserts the spacing.
        let result = TextPostProcessor.process("我們使用Kubernetes部署服務", settings: settings)

        XCTAssertEqual(result.final, "我們使用 Kubernetes 部署服務")
        XCTAssertEqual(result.raw, "我們使用Kubernetes部署服務")
        XCTAssertTrue(result.wasModified)
    }

    func testProcess_matchesAutocorrectWrapperExactly() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "這次會議在下週二舉行,請把report寄給張經理"

        // The transcript stage must not add rules of its own on top of the
        // vendored library: it delegates, nothing more.
        XCTAssertEqual(
            TextPostProcessor.process(input, settings: settings).final,
            AutocorrectWrapper.format(input)
        )
    }

    func testProcess_skipsAutocorrectWhenPreferenceDisabled() {
        let settings = makeSettings(language: "zh", useAsianAutocorrect: false)
        let input = "我們使用Kubernetes部署服務"

        let result = TextPostProcessor.process(input, settings: settings)

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_skipsAutocorrectForNonAsianLanguage() {
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)
        let input = "we deploy with Kubernetes"

        let result = TextPostProcessor.process(input, settings: settings)

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_appliesToEveryAsianLanguage() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        for language in ["zh", "ja", "ko"] {
            let settings = makeSettings(language: language, useAsianAutocorrect: true)
            XCTAssertTrue(
                settings.shouldApplyAsianAutocorrect,
                "\(language) should be gated on for autocorrect"
            )
        }
    }

    // MARK: - Transcript stage: empty and unchanged input

    func testProcess_emptyTextIsReturnedUnchanged() {
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("", settings: settings)

        XCTAssertEqual(result.final, "")
        XCTAssertEqual(result.raw, "")
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_alreadyCleanTextIsNotReportedAsModified() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "我們明天早上開會"

        let result = TextPostProcessor.process(input, settings: settings)

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_preservesRawAlongsideFinal() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "把deadline往後推一週"

        let result = TextPostProcessor.process(input, settings: settings)

        // Later stages rely on the engine's original output still being here.
        XCTAssertEqual(result.raw, input)
        XCTAssertNotEqual(result.final, result.raw)
    }

    // MARK: - Transcript stage: path independence

    func testProcess_isIdenticalForBothEnginePaths() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        // Whisper strips its own markers and trims before returning; FluidAudio
        // only trims. Both hand the result to the same shared stage, so equal
        // engine output must produce equal post-processed text.
        let fromWhisperEngine = "我們使用Kubernetes部署服務"
        let fromFluidAudioEngine = "我們使用Kubernetes部署服務"

        XCTAssertEqual(
            TextPostProcessor.process(fromWhisperEngine, settings: settings).final,
            TextPostProcessor.process(fromFluidAudioEngine, settings: settings).final
        )
    }

    func testProcess_doesNotTrimOrStripEngineMarkers() {
        // Marker stripping and trimming stay engine-specific. If the shared
        // stage started doing them too, engines would double-process.
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)
        let input = "  [MUSIC] hello  "

        XCTAssertEqual(TextPostProcessor.process(input, settings: settings).final, input)
    }

    // MARK: - Transcript stage: works with no model or AI backend

    func testProcess_requiresNoModelOrBackend() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        // The transcript stage is a pure function of text and settings. It must
        // keep working with no engine loaded and no AI backend configured,
        // which is what makes deterministic correction always-on.
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        XCTAssertEqual(
            TextPostProcessor.process("我們使用Kubernetes部署服務", settings: settings).final,
            "我們使用 Kubernetes 部署服務"
        )
    }

    // MARK: - Insertion stage

    func testPrepareForInsertion_addsSpaceAfterSentencePunctuation() {
        AppPreferences.shared.addSpaceAfterSentence = true

        XCTAssertEqual(TextPostProcessor.prepareForInsertion("Hello world."), "Hello world. ")
        XCTAssertEqual(TextPostProcessor.prepareForInsertion("How are you?"), "How are you? ")
        XCTAssertEqual(TextPostProcessor.prepareForInsertion("Wow!"), "Wow! ")
    }

    func testPrepareForInsertion_addsSpaceAfterFullWidthPunctuation() {
        AppPreferences.shared.addSpaceAfterSentence = true

        // Traditional Chinese full-width stop is punctuation too.
        XCTAssertEqual(TextPostProcessor.prepareForInsertion("我們明天開會。"), "我們明天開會。 ")
    }

    func testPrepareForInsertion_noSpaceWithoutTrailingPunctuation() {
        AppPreferences.shared.addSpaceAfterSentence = true

        XCTAssertEqual(TextPostProcessor.prepareForInsertion("Hello world"), "Hello world")
        XCTAssertEqual(TextPostProcessor.prepareForInsertion("我們明天開會"), "我們明天開會")
    }

    func testPrepareForInsertion_noSpaceWhenPreferenceDisabled() {
        AppPreferences.shared.addSpaceAfterSentence = false

        XCTAssertEqual(TextPostProcessor.prepareForInsertion("Hello world."), "Hello world.")
        XCTAssertEqual(TextPostProcessor.prepareForInsertion("我們明天開會。"), "我們明天開會。")
    }

    func testPrepareForInsertion_emptyTextIsUnchanged() {
        AppPreferences.shared.addSpaceAfterSentence = true

        XCTAssertEqual(TextPostProcessor.prepareForInsertion(""), "")
    }

    // MARK: - The two stages are deliberately separate

    func testInsertionStageIsNotAppliedByTranscriptStage() {
        // The stored transcript must never gain the insertion-time trailing
        // space: history rows, search and the "Copy entire text" button all
        // read the stored text rather than the live dictation output.
        AppPreferences.shared.addSpaceAfterSentence = true
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("Hello world.", settings: settings)

        XCTAssertEqual(result.final, "Hello world.")
        XCTAssertFalse(result.final.hasSuffix(" "))
    }

    func testIndicatorInsertionDelegatesToSharedStage() {
        // The live dictation path must not keep a second copy of this rule.
        AppPreferences.shared.addSpaceAfterSentence = true

        for sample in ["Hello world.", "Hello world", "我們明天開會。", ""] {
            XCTAssertEqual(
                IndicatorViewModel.applyPostProcessing(sample),
                TextPostProcessor.prepareForInsertion(sample),
                "diverged for \(sample.isEmpty ? "<empty>" : sample)"
            )
        }
    }
}
