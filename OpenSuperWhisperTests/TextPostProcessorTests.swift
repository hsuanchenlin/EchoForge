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
    private var savedSafeCorrection: Bool = true

    override func setUp() {
        super.setUp()
        let prefs = AppPreferences.shared
        savedLanguage = prefs.whisperLanguage
        savedUseAsianAutocorrect = prefs.useAsianAutocorrect
        savedAddSpace = prefs.addSpaceAfterSentence
        savedSafeCorrection = prefs.safeCorrectionEnabled
    }

    override func tearDown() {
        let prefs = AppPreferences.shared
        prefs.whisperLanguage = savedLanguage
        prefs.useAsianAutocorrect = savedUseAsianAutocorrect
        prefs.addSpaceAfterSentence = savedAddSpace
        prefs.safeCorrectionEnabled = savedSafeCorrection
        super.tearDown()
    }

    /// Builds a `Settings` value, which reads from `AppPreferences`.
    private func makeSettings(
        language: String,
        useAsianAutocorrect: Bool,
        safeCorrectionEnabled: Bool = true
    ) -> Settings {
        let prefs = AppPreferences.shared
        prefs.whisperLanguage = language
        prefs.useAsianAutocorrect = useAsianAutocorrect
        prefs.safeCorrectionEnabled = safeCorrectionEnabled
        return Settings()
    }

    // MARK: - Transcript stage: CJK autocorrect

    func testProcess_appliesAutocorrectForTraditionalChinese() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        // Mixed Traditional Chinese and Latin: autocorrect inserts the spacing.
        let result = TextPostProcessor.process("我們使用Kubernetes部署服務", settings: settings, terms: [])

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
            TextPostProcessor.process(input, settings: settings, terms: []).final,
            AutocorrectWrapper.format(input)
        )
    }

    func testProcess_skipsAutocorrectWhenPreferenceDisabled() {
        let settings = makeSettings(language: "zh", useAsianAutocorrect: false)
        let input = "我們使用Kubernetes部署服務"

        let result = TextPostProcessor.process(input, settings: settings, terms: [])

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_skipsAutocorrectForNonAsianLanguage() {
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)
        let input = "we deploy with Kubernetes"

        let result = TextPostProcessor.process(input, settings: settings, terms: [])

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

        let result = TextPostProcessor.process("", settings: settings, terms: [])

        XCTAssertEqual(result.final, "")
        XCTAssertEqual(result.raw, "")
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_alreadyCleanTextIsNotReportedAsModified() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "我們明天早上開會"

        let result = TextPostProcessor.process(input, settings: settings, terms: [])

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
    }

    func testProcess_preservesRawAlongsideFinal() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "把deadline往後推一週"

        let result = TextPostProcessor.process(input, settings: settings, terms: [])

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
            TextPostProcessor.process(fromWhisperEngine, settings: settings, terms: []).final,
            TextPostProcessor.process(fromFluidAudioEngine, settings: settings, terms: []).final
        )
    }

    func testProcess_doesNotTrimOrStripEngineMarkers() {
        // Marker stripping and trimming stay engine-specific. If the shared
        // stage started doing them too, engines would double-process.
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)
        let input = "  [MUSIC] hello  "

        XCTAssertEqual(TextPostProcessor.process(input, settings: settings, terms: []).final, input)
    }

    // MARK: - Transcript stage: works with no model or AI backend

    func testProcess_requiresNoModelOrBackend() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        // The transcript stage is a pure function of text and settings. It must
        // keep working with no engine loaded and no AI backend configured,
        // which is what makes deterministic correction always-on.
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        XCTAssertEqual(
            TextPostProcessor.process("我們使用Kubernetes部署服務", settings: settings, terms: []).final,
            "我們使用 Kubernetes 部署服務"
        )
    }

    // MARK: - Transcript stage: personal terms dictionary

    func testProcess_defaultsToApplyingSafeCorrection() {
        // The toggle is on out of the box and depends on nothing: no model, no
        // network, no macOS version. Reading the unset default is the assertion.
        UserDefaults.standard.removeObject(forKey: "safeCorrectionEnabled")

        XCTAssertTrue(AppPreferences.shared.safeCorrectionEnabled)
        XCTAssertTrue(Settings().safeCorrectionEnabled)
    }

    func testProcess_readsTheSharedDictionaryWhenNoTermsArePassed() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "我們使用Kubernetes部署服務"

        // Pins the wiring without depending on what is in the user's own
        // terms.json: omitting the argument must be the same as passing the
        // shared store's active entries.
        XCTAssertEqual(
            TextPostProcessor.process(input, settings: settings),
            TextPostProcessor.process(
                input, settings: settings, terms: PersonalTermsStore.shared.activeTerms
            )
        )
    }

    func testProcess_appliesTermsWithNoLanguageGate() {
        // Terms are not an Asian-language feature: unlike autocorrect they run
        // whatever language is selected.
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "k8s", replacement: "Kubernetes")]
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("we deploy with k8s", settings: settings, terms: terms)

        XCTAssertEqual(result.final, "we deploy with Kubernetes")
        XCTAssertEqual(result.raw, "we deploy with k8s")
    }

    func testProcess_skipsTermsWhenSafeCorrectionIsDisabled() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]
        let settings = makeSettings(
            language: "en", useAsianAutocorrect: false, safeCorrectionEnabled: false
        )

        let result = TextPostProcessor.process("貼到頂頂群", settings: settings, terms: terms)

        XCTAssertEqual(result.final, "貼到頂頂群")
        XCTAssertTrue(result.mustSurviveTokens.isEmpty)
    }

    func testProcess_leavesTextAloneWhenNoEntryApplies() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]
        let settings = makeSettings(language: "en", useAsianAutocorrect: true)
        let input = "nothing in this sentence is in the dictionary"

        let result = TextPostProcessor.process(input, settings: settings, terms: terms)

        XCTAssertEqual(result.final, input)
        XCTAssertFalse(result.wasModified)
        XCTAssertTrue(result.mustSurviveTokens.isEmpty)
    }

    func testProcess_reportsAppliedTermsAsMustSurviveTokens() {
        let terms = [
            PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken"),
            PersonalTerm(kind: .protect, match: "useState")
        ]
        let settings = makeSettings(language: "en", useAsianAutocorrect: false)

        let result = TextPostProcessor.process("阿肯問useState", settings: settings, terms: terms)

        // Nothing consumes this yet. It is produced now because only this stage
        // knows what it corrected or pinned, and a later rewriting stage would
        // have to check its own output still contains it.
        XCTAssertEqual(result.mustSurviveTokens, ["阿 Ken", "useState"])
    }

    // MARK: - Transcript stage: terms run before CJK autocorrect

    func testProcess_appliesTermsBeforeAutocorrectSoTheyMatchWhatWasSaid() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "k8s", replacement: "Kubernetes")]
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("我們用k8s部署服務", settings: settings, terms: terms)

        // The entry has to see the unspaced text the engine produced. Had
        // autocorrect run first, the input would already be "我們用 k8s 部署服務"
        // and a "k8s" entry would still match - but any entry whose match spans
        // a CJK/Latin boundary would not.
        XCTAssertEqual(result.final, "我們用 Kubernetes 部署服務")
    }

    func testProcess_termMatchSpanningAScriptBoundaryOnlyWorksBeforeAutocorrect() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let terms = [PersonalTerm(kind: .name, match: "阿Ken", replacement: "阿 Ken")]
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("阿Ken負責驗收", settings: settings, terms: terms)

        XCTAssertEqual(result.final, "阿 Ken 負責驗收")
    }

    func testProcess_protectedSpanSurvivesAutocorrectByteForByte() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)
        let input = "我們用useState管理狀態"

        // Without the entry, autocorrect respaces the Latin run.
        let unprotected = TextPostProcessor.process(input, settings: settings, terms: [])
        XCTAssertEqual(unprotected.final, "我們用 useState 管理狀態")

        // With it, the pinned span comes out exactly as spoken - which means no
        // spacing is introduced next to it either.
        let protectedResult = TextPostProcessor.process(
            input, settings: settings, terms: [PersonalTerm(kind: .protect, match: "useState")]
        )
        XCTAssertEqual(protectedResult.final, input)
    }

    func testProcess_autocorrectStillRunsOnTheTextAroundAProtectedSpan() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process(
            "先看useState再談Kubernetes部署",
            settings: settings,
            terms: [PersonalTerm(kind: .protect, match: "useState")]
        )

        // Only the protected span is held out; the rest is formatted as usual.
        XCTAssertEqual(result.final, "先看useState再談 Kubernetes 部署")
    }

    func testProcess_protectedSpanSurvivesWhenItIsTheWholeTranscript() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process(
            "恰恰好", settings: settings, terms: [PersonalTerm(kind: .protect, match: "恰恰好")]
        )

        XCTAssertEqual(result.final, "恰恰好")
    }

    func testProcess_protectedSpanSurvivesEvenWithAutocorrectDisabled() {
        let settings = makeSettings(language: "zh", useAsianAutocorrect: false)
        let input = "我們用useState管理狀態"

        let result = TextPostProcessor.process(
            input, settings: settings, terms: [PersonalTerm(kind: .protect, match: "useState")]
        )

        XCTAssertEqual(result.final, input)
    }

    func testProcess_correctedTermsSurviveAutocorrectUnaltered() throws {
        try XCTSkipUnless(AutocorrectWrapper.isAvailable(), "autocorrect library unavailable")
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]
        let settings = makeSettings(language: "zh", useAsianAutocorrect: true)

        let result = TextPostProcessor.process("我把報告貼在頂頂群裡了", settings: settings, terms: terms)

        XCTAssertEqual(result.final, "我把報告貼在釘釘群裡了")
        XCTAssertEqual(result.mustSurviveTokens, ["釘釘群"])
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

        let result = TextPostProcessor.process("Hello world.", settings: settings, terms: [])

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
