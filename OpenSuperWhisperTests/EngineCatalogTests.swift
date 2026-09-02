import XCTest

@testable import OpenSuperWhisper

/// What Settings promises the user about each engine.
///
/// These assertions exist because the copy is the product here: an engine
/// described without its caveats is worse than one that is not offered, and the
/// caveats - no punctuation, spoken numbers rewritten as digits, Mandarin only -
/// are exactly what gets lost when someone shortens a string.
final class EngineCatalogTests: XCTestCase {

    func testEveryEngineHasAnEntry() {
        for kind in EngineKind.allCases {
            let entry = EngineCatalog.entry(for: kind)
            XCTAssertFalse(entry.displayName.isEmpty, "\(kind) needs a name")
            XCTAssertFalse(entry.summary.isEmpty, "\(kind) needs a summary")
        }
    }

    /// The picker offers every engine that runs on this Mac, exactly once. A
    /// missing entry here is an engine the user cannot reach at all.
    ///
    /// The one exception is `EngineKind.usesCloudProvider`, and it is an
    /// exception on purpose: every row in this picker is one tap from being
    /// selected, and one tap must not be all it takes to start sending dictation
    /// to a company. The cloud engine is chosen in the Cloud pane, where the
    /// consent sheet is (`CloudConsent`), and the picker shows a banner saying so
    /// while it is in use.
    func testPickerOffersEveryLocalEngineOnceAndNoCloudOne() {
        let local = EngineKind.allCases.filter { !$0.usesCloudProvider }

        XCTAssertEqual(Set(EngineCatalog.pickerOrder), Set(local))
        XCTAssertEqual(EngineCatalog.pickerOrder.count, local.count)
    }

    /// The Chinese default is offered before the alternative it is the default
    /// over - the ordering is the recommendation, so it is not incidental.
    func testTheChineseDefaultIsOfferedBeforeTheAlternative() throws {
        let defaultIndex = try XCTUnwrap(
            EngineCatalog.pickerOrder.firstIndex(of: EngineKind.defaultChineseDictation))
        let alternativeIndex = try XCTUnwrap(
            EngineCatalog.pickerOrder.firstIndex(of: EngineKind.chineseAccuracyAlternative))
        XCTAssertLessThan(defaultIndex, alternativeIndex)
    }

    // MARK: - Licence obligations

    /// FunASR Model Open Source License v1.1 §2.2 requires attributing the source
    /// and author and *retaining the model name*. Renaming either engine to
    /// something like "Chinese (fast)" would breach it, so the name is asserted
    /// rather than left to taste. See `docs/speech-model-attribution.md`.
    func testFunASREnginesRetainTheirModelNames() {
        XCTAssertTrue(
            EngineCatalog.entry(for: .sensevoice).displayName.contains("SenseVoice"),
            "the model licence requires the SenseVoice name to survive in the UI"
        )
        XCTAssertTrue(
            EngineCatalog.entry(for: .paraformer).displayName.contains("Paraformer"),
            "the model licence requires the Paraformer name to survive in the UI"
        )
    }

    /// The in-app half of the attribution surface `docs/speech-model-attribution.md`
    /// says these engines cannot ship without: a credit line naming the author,
    /// and reachable links to the model card, the licence and the conversion.
    func testDownloadedModelsCarryCreditAndLinks() throws {
        for kind in [EngineKind.sensevoice, .paraformer] {
            let entry = EngineCatalog.entry(for: kind)
            let credit = try XCTUnwrap(entry.attributionCredit, "\(kind) needs a credit line")
            XCTAssertTrue(credit.contains("FunASR"), "\(kind) must credit FunASR: \(credit)")

            let labels = entry.attribution.map(\.label)
            XCTAssertTrue(labels.contains("Model card"), "\(kind) links: \(labels)")
            XCTAssertTrue(labels.contains("Model licence"), "\(kind) links: \(labels)")
            XCTAssertTrue(labels.contains("CoreML conversion"), "\(kind) links: \(labels)")
        }
    }

    // MARK: - Honest labels

    /// Paraformer's two disqualifying properties. A user who picks it for
    /// accuracy and only then discovers it emits no punctuation has been misled
    /// by this pane, not by the model.
    func testParaformerStatesThatItIsMandarinOnlyAndUnpunctuated() {
        let notes = EngineCatalog.entry(for: .paraformer).notes.joined(separator: " ").lowercased()
        XCTAssertTrue(notes.contains("no punctuation"), notes)
        XCTAssertTrue(notes.contains("mandarin only"), notes)
        XCTAssertTrue(notes.contains("split into short pieces"), notes)
    }

    /// SenseVoice's trade: punctuation arrives coupled to number conversion, and
    /// the conversion is not always right. The wording is deliberately
    /// "occasionally" - the meaning-changing example recorded upstream did not
    /// reproduce on every machine that looked for it, and copy that claimed it
    /// always happens would be its own kind of dishonest. See
    /// `docs/upstream-issues.md`.
    func testSenseVoiceStatesThePunctuationAndNumeralTrade() {
        let notes = EngineCatalog.entry(for: .sensevoice).notes.joined(separator: " ")
        XCTAssertTrue(notes.contains("punctuation is not available without the conversion"), notes)
        XCTAssertTrue(notes.lowercased().contains("occasionally"), notes)
        XCTAssertFalse(
            notes.lowercased().contains("every"),
            "the numeral defect did not reproduce on every machine; do not claim it always happens: \(notes)"
        )
    }

    /// Both models write Simplified Chinese, and Kongweh writes the transcript
    /// in the script the user chose - Traditional by default. For a Chinese user
    /// that is the most surprising thing about either engine either way round, so
    /// neither entry may leave out what the model does or what the app does with
    /// it. See `docs/chinese-script.md`.
    func testBothChineseEnginesSayWhichScriptTheyWriteAndWhichTheUserGets() {
        for kind in [EngineKind.sensevoice, .paraformer] {
            let notes = EngineCatalog.entry(for: kind).notes.joined(separator: " ")
            XCTAssertTrue(
                notes.contains("Simplified Chinese"),
                "\(kind) must say which script the model writes: \(notes)"
            )
            XCTAssertTrue(
                notes.contains("Kongweh writes your transcript"),
                "\(kind) must say what the app writes, now that it converts: \(notes)"
            )
        }
    }

    // MARK: - The bilingual path

    /// The hint Settings shows under the engine rows names the bilingual engine,
    /// and names it with the model name the FunASR licence requires - which it
    /// gets by reading the entry rather than by spelling one out.
    func testTheBilingualHintNamesTheBilingualEngine() {
        let hint = EngineCatalog.bilingualHint

        XCTAssertTrue(hint.contains("Mixed English and Chinese"), hint)
        XCTAssertTrue(
            hint.contains(EngineCatalog.entry(for: EngineKind.bilingualDictation).displayName), hint)
        XCTAssertTrue(hint.contains("SenseVoice"), "the model licence requires the name here too: \(hint)")
    }

    /// The second line is what makes the first a fact rather than a preference,
    /// so it has to account for all three engines it passes over - and it must
    /// not quietly become an argument for the cloud one.
    func testTheBilingualHintSaysWhyTheOtherEnginesAreNotTheAnswer() {
        let detail = EngineCatalog.bilingualHintDetail

        XCTAssertTrue(detail.contains("Whisper"), detail)
        XCTAssertTrue(detail.contains("Parakeet"), detail)
        XCTAssertTrue(detail.contains("Paraformer"), detail)
        XCTAssertFalse(
            detail.lowercased().contains("cloud"),
            "the bilingual path is on-device; this line must not recommend a provider: \(detail)"
        )
    }

    /// SenseVoice's row is where a user decides, so the one thing no other
    /// engine here can do has to be on it rather than only in a doc.
    func testSenseVoiceStatesThatItTranscribesBothLanguagesAtOnce() {
        let entry = EngineCatalog.entry(for: EngineKind.bilingualDictation)
        let copy = ([entry.summary] + entry.notes).joined(separator: " ")

        XCTAssertTrue(copy.contains("English"), copy)
        XCTAssertTrue(
            copy.contains("mix English into Mandarin") || copy.contains("English and Chinese in one sentence"),
            "the picker row must say the engine handles a code-switched sentence: \(copy)"
        )
    }

    /// And Paraformer's row has to send that user somewhere. "English comes back
    /// as fragments" without naming the engine that does not is half an answer.
    func testParaformerPointsMixedDictationAtTheBilingualEngine() {
        let notes = EngineCatalog.entry(for: .paraformer).notes.joined(separator: " ")

        XCTAssertTrue(
            notes.contains(EngineCatalog.entry(for: EngineKind.bilingualDictation).displayName),
            "the Mandarin-only engine must name the one that does mixed dictation: \(notes)"
        )
    }

    // MARK: - Download figures

    /// C11: SenseVoice is variant-filtered so int8 really is a smaller download;
    /// Paraformer's repo is fetched whole whatever precision is asked for. The
    /// combined figure is the one a user comparing them asks for.
    func testDownloadSizesMatchWhatTheEnginesFetch() throws {
        let senseVoice = try XCTUnwrap(EngineCatalog.entry(for: .sensevoice).download)
        let paraformer = try XCTUnwrap(EngineCatalog.entry(for: .paraformer).download)

        XCTAssertEqual(senseVoice.megabytes, 240)
        XCTAssertEqual(paraformer.megabytes, 653)
        XCTAssertEqual(EngineCatalog.bothChineseEnginesMegabytes, 893)
    }

    /// F7: the path the pane shows is the one FluidAudio actually writes to, and
    /// its last component drops `-coreml`. Rebuilding it from the Hugging Face
    /// slug would show users a folder that does not exist.
    func testCacheDirectoriesAreTheOnesFluidAudioUses() throws {
        let senseVoice = try XCTUnwrap(EngineCatalog.entry(for: .sensevoice).download)
        let paraformer = try XCTUnwrap(EngineCatalog.entry(for: .paraformer).download)

        XCTAssertEqual(senseVoice.cacheDirectory.lastPathComponent, "sensevoice-small")
        XCTAssertEqual(paraformer.cacheDirectory.lastPathComponent, "paraformer-large-zh")
        XCTAssertEqual(senseVoice.cacheDirectory, SenseVoiceEngine.modelCacheDirectory)
        XCTAssertEqual(paraformer.cacheDirectory, ParaformerEngine.modelCacheDirectory)
    }

    /// Whisper and Parakeet choose between several models each, so they keep
    /// their own rows rather than getting a single download row that would have
    /// to name one of them.
    func testOnlySingleModelEnginesHaveADownloadRow() {
        XCTAssertNil(EngineCatalog.entry(for: .whisper).download)
        XCTAssertNil(EngineCatalog.entry(for: .fluidaudio).download)
        XCTAssertNotNil(EngineCatalog.entry(for: .sensevoice).download)
        XCTAssertNotNil(EngineCatalog.entry(for: .paraformer).download)
    }

    // MARK: - Language summary

    /// Derived from `LanguageUtil`, so the summary cannot claim a language the
    /// picker below it does not offer.
    func testLanguageSummaryCollapsesPerEngine() {
        XCTAssertEqual(
            EngineCatalog.languageSummary(for: .paraformer, fluidAudioModelVersion: "v3"),
            "Mandarin only"
        )
        XCTAssertEqual(
            EngineCatalog.languageSummary(for: .sensevoice, fluidAudioModelVersion: "v3"),
            "Mandarin, Cantonese, English, Japanese, Korean, or auto-detect"
        )
        XCTAssertEqual(
            EngineCatalog.languageSummary(for: .fluidaudio, fluidAudioModelVersion: "v2"),
            "English only"
        )
        XCTAssertEqual(
            EngineCatalog.languageSummary(for: .fluidaudio, fluidAudioModelVersion: "v3"),
            "25 languages"
        )
        XCTAssertEqual(
            EngineCatalog.languageSummary(for: .whisper, fluidAudioModelVersion: "v3"),
            "20 languages, or auto-detect"
        )
    }

    /// `zh` next to `yue` has to read Mandarin: both are Chinese, and a summary
    /// that said "Chinese, Cantonese" would be describing the wrong distinction.
    func testTheSummarySaysMandarinWhereCantoneseIsAlsoListed() {
        let summary = EngineCatalog.languageSummary(for: .sensevoice, fluidAudioModelVersion: "v3")
        XCTAssertTrue(summary.contains("Mandarin"))
        XCTAssertFalse(summary.contains("Chinese"))
    }

    // MARK: - Routing Chinese to the default

    /// The Settings-side form of `EngineKind.defaultChineseDictation`: a user who
    /// sets the language to Chinese on a general-purpose engine is offered the
    /// Chinese default rather than silently moved onto it.
    func testChineseOnAGeneralEngineSuggestsTheChineseDefault() {
        for engine in [EngineKind.whisper, .fluidaudio] {
            XCTAssertEqual(
                EngineCatalog.suggestedEngine(forLanguage: "zh", selected: engine),
                EngineKind.defaultChineseDictation,
                "Chinese on \(engine) should offer the Chinese default"
            )
        }
    }

    /// No nagging: neither Chinese engine is told to switch to the other, and
    /// nothing is suggested for a language that has no specialised engine.
    func testNoSuggestionWhenTheEngineIsAlreadyAChineseOne() {
        for engine in [EngineKind.defaultChineseDictation, .chineseAccuracyAlternative] {
            XCTAssertNil(EngineCatalog.suggestedEngine(forLanguage: "zh", selected: engine))
        }
        for language in ["en", "ja", "ko", "auto", "yue"] {
            XCTAssertNil(EngineCatalog.suggestedEngine(forLanguage: language, selected: .whisper))
        }
    }
}
