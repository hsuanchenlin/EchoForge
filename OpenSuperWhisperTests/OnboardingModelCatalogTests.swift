import XCTest

@testable import OpenSuperWhisper

/// What a new user is offered on the first screen they ever see.
///
/// The Chinese half of this list is the whole reason these assertions exist:
/// onboarding is where someone commits several hundred megabytes and a default
/// engine before they have transcribed anything, so what it recommends, what it
/// admits to, and who it credits all have to survive a later edit.
final class OnboardingModelCatalogTests: XCTestCase {

    private let models = OnboardingUnifiedModels.availableModels

    private func row(for kind: EngineKind) throws -> OnboardingUnifiedModel {
        try XCTUnwrap(
            models.first { $0.engineKind == kind && $0.catalogEntry != nil },
            "onboarding offers no row for \(kind)"
        )
    }

    // MARK: - What is offered, and in what order

    /// Both Chinese engines are reachable from onboarding, not just from
    /// Settings: a user who never opens Settings would otherwise dictate Chinese
    /// on Whisper without ever learning there was a choice.
    func testBothChineseEnginesAreOffered() throws {
        XCTAssertNoThrow(try row(for: EngineKind.defaultChineseDictation))
        XCTAssertNoThrow(try row(for: EngineKind.chineseAccuracyAlternative))
    }

    /// The order is the recommendation. The Chinese default leads, the accuracy
    /// alternative follows it, and both come before the general-purpose models
    /// so a user who has just picked Chinese meets them first.
    func testTheChineseDefaultIsOfferedFirst() throws {
        let defaultIndex = try XCTUnwrap(
            models.firstIndex { $0.engineKind == EngineKind.defaultChineseDictation })
        let alternativeIndex = try XCTUnwrap(
            models.firstIndex { $0.engineKind == EngineKind.chineseAccuracyAlternative })
        let firstGeneralIndex = try XCTUnwrap(models.firstIndex { $0.catalogEntry == nil })

        XCTAssertEqual(defaultIndex, 0)
        XCTAssertLessThan(defaultIndex, alternativeIndex)
        XCTAssertLessThan(alternativeIndex, firstGeneralIndex)
    }

    /// Exactly one row is badged, and it is the engine `EngineKind` names as the
    /// Chinese default. Two recommendations would be no recommendation.
    func testOnlyTheChineseDefaultIsRecommended() throws {
        let recommended = models.filter { $0.recommendation != nil }
        XCTAssertEqual(recommended.count, 1)
        XCTAssertEqual(recommended.first?.engineKind, EngineKind.defaultChineseDictation)
        XCTAssertEqual(recommended.first?.recommendation, "Recommended for Chinese")
    }

    // MARK: - One copy of the copy

    /// Names and summaries are `EngineCatalog`'s, not a second hand-written set.
    /// FunASR Model Open Source License v1.1 §2.2 requires the model name to
    /// reach the UI, and a name typed again here is exactly how it would stop
    /// doing so - see `EngineCatalogTests`.
    func testEngineRowsTakeTheirCopyFromTheCatalog() throws {
        for kind in [EngineKind.sensevoice, .paraformer] {
            let model = try row(for: kind)
            let entry = EngineCatalog.entry(for: kind)
            XCTAssertEqual(model.name, entry.displayName)
            XCTAssertEqual(model.description, entry.summary)
        }
    }

    /// The row hands the view the catalog entry, which is what carries the
    /// caveats, the credit line and the three attribution links onboarding is
    /// obliged to show. Whisper and Parakeet rows have none, because they choose
    /// between several models and describe themselves.
    func testOnlyEngineRowsCarryACatalogEntry() throws {
        for kind in [EngineKind.sensevoice, .paraformer] {
            let entry = try XCTUnwrap(try row(for: kind).catalogEntry)
            XCTAssertFalse(entry.notes.isEmpty, "\(kind) must show its caveats in onboarding")
            XCTAssertNotNil(entry.attributionCredit, "\(kind) must credit its author in onboarding")
            XCTAssertEqual(entry.attribution.count, 3, "\(kind) must link card, licence and conversion")
        }

        let general = models.filter { $0.catalogEntry == nil }
        XCTAssertEqual(general.count, 5, "the Whisper and Parakeet rows are unchanged")
    }

    // MARK: - Honest figures

    /// The sizes a user commits to before pressing Download, and the ones
    /// `EngineCatalogTests` pins against what the engines actually fetch.
    func testEngineRowsStateTheirDownloadSize() throws {
        XCTAssertEqual(try row(for: .sensevoice).downloadMegabytes, 240)
        XCTAssertEqual(try row(for: .paraformer).downloadMegabytes, 653)
        XCTAssertNil(models.first { $0.catalogEntry == nil }?.downloadMegabytes)
    }

    /// The status line never claims the engine is ready the moment the download
    /// ends: the CoreML compile is about a minute of invisible work afterwards,
    /// and a first-run experience that hides it reads as a hang.
    func testTheStatusLineAdmitsToTheFirstLoadCompile() throws {
        let model = try row(for: .sensevoice)

        let beforeDownloading = try XCTUnwrap(model.status(isBusy: false, isCompiling: false))
        XCTAssertTrue(beforeDownloading.contains("Neural Engine"), beforeDownloading)
        XCTAssertTrue(beforeDownloading.contains("about a minute"), beforeDownloading)

        let downloading = try XCTUnwrap(model.status(isBusy: true, isCompiling: false))
        XCTAssertTrue(downloading.contains("240 MB"), downloading)

        let compiling = try XCTUnwrap(model.status(isBusy: true, isCompiling: true))
        XCTAssertTrue(compiling.contains("Neural Engine"), compiling)

        XCTAssertNil(
            models.first { $0.catalogEntry == nil }?.status(isBusy: false, isCompiling: false),
            "rows without a measured size have nothing honest to say here"
        )
    }

    // MARK: - Who sees them

    /// ~900 MB of Mandarin-only models stay off the first screen of someone
    /// dictating English, and lead it for someone dictating Chinese. Same rule
    /// Settings already applies to the Hebrew fine-tune.
    func testChineseRowsAreOfferedToPeopleDictatingChinese() throws {
        let senseVoice = try row(for: .sensevoice)

        XCTAssertTrue(
            OnboardingUnifiedModels.isVisible(senseVoice, selectedLanguage: "zh", systemLanguage: "en"))
        XCTAssertTrue(
            OnboardingUnifiedModels.isVisible(senseVoice, selectedLanguage: "en", systemLanguage: "zh"))
        XCTAssertFalse(
            OnboardingUnifiedModels.isVisible(senseVoice, selectedLanguage: "en", systemLanguage: "en"))
    }

    /// A downloaded model is always offered. Hiding one because the language
    /// moved would hide a choice the user already made - and, in onboarding,
    /// would take away the only row that could satisfy the Continue button.
    func testADownloadedChineseRowStaysVisibleInAnyLanguage() throws {
        var senseVoice = try row(for: .sensevoice)
        senseVoice.isDownloaded = true

        XCTAssertTrue(
            OnboardingUnifiedModels.isVisible(senseVoice, selectedLanguage: "de", systemLanguage: "de"))
    }

    /// The general-purpose rows are for everyone, in every language.
    func testGeneralPurposeRowsAreAlwaysOffered() {
        for model in models where model.catalogEntry == nil {
            XCTAssertTrue(
                OnboardingUnifiedModels.isVisible(model, selectedLanguage: "de", systemLanguage: "de"),
                "\(model.name) should be offered whatever the language"
            )
        }
    }

    // MARK: - Language left behind

    /// Picking Paraformer while the picker says German leaves the user on
    /// Mandarin rather than on a language the engine mis-transcribes rather than
    /// refuses.
    func testPickingAMandarinOnlyEngineMovesTheLanguageToMandarin() throws {
        let paraformer = try row(for: .paraformer)
        XCTAssertEqual(paraformer.language(after: "de", fluidAudioModelVersion: "v3"), "zh")
        XCTAssertEqual(paraformer.language(after: "zh", fluidAudioModelVersion: "v3"), "zh")
    }

    /// SenseVoice does five languages, so choosing it does not drag a Japanese
    /// or English user onto Chinese.
    func testTheChineseDefaultKeepsALanguageItSupports() throws {
        let senseVoice = try row(for: .sensevoice)
        XCTAssertEqual(senseVoice.language(after: "ja", fluidAudioModelVersion: "v3"), "ja")
        XCTAssertEqual(senseVoice.language(after: "en", fluidAudioModelVersion: "v3"), "en")
        XCTAssertEqual(senseVoice.language(after: "de", fluidAudioModelVersion: "v3"), "zh")
    }

    /// The rule is not Chinese-specific: Parakeet v2 is English-only and has
    /// silently ignored the language picker since it landed.
    func testAnEnglishOnlyModelMovesTheLanguageToEnglish() throws {
        let parakeet = try XCTUnwrap(models.first { $0.name == "Parakeet v2" })
        XCTAssertEqual(parakeet.language(after: "zh", fluidAudioModelVersion: "v2"), "en")
    }

    // MARK: - What the top picker offers

    /// Before a row is chosen, the picker cannot know which engine to scope
    /// to - and narrowing it early would fight the visibility rule, which
    /// needs the full list to decide whether the Chinese rows even show up.
    func testWithNoRowSelectedThePickerOffersEveryLanguage() {
        XCTAssertEqual(
            OnboardingUnifiedModels.offeredLanguages(selectedModel: nil, fluidAudioModelVersion: "v3"),
            LanguageUtil.availableLanguages
        )
    }

    /// Once a Mandarin-only row is selected, the picker can no longer offer a
    /// language that row would mis-transcribe - the same structural guard
    /// Settings gives its own picker.
    func testWithAMandarinOnlyRowSelectedThePickerOffersOnlyMandarin() throws {
        let paraformer = try row(for: .paraformer)
        XCTAssertEqual(
            OnboardingUnifiedModels.offeredLanguages(selectedModel: paraformer, fluidAudioModelVersion: "v3"),
            ["zh"]
        )
    }

    /// A row that understands several languages offers all of them, not just
    /// the one it was reached with.
    func testWithTheChineseDefaultSelectedThePickerOffersItsFullLanguageSet() throws {
        let senseVoice = try row(for: .sensevoice)
        XCTAssertEqual(
            OnboardingUnifiedModels.offeredLanguages(selectedModel: senseVoice, fluidAudioModelVersion: "v3"),
            LanguageUtil.senseVoiceLanguages
        )
    }
}
