import XCTest

@testable import OpenSuperWhisper

/// What the model inventory says is on the disk, and what it will let a user do
/// about it.
///
/// Every case here is driven through injected sizes and an availability
/// snapshot, so the states worth checking - a half-finished cache, a cache
/// deleted behind the app's back, the last engine that can transcribe - can be
/// described rather than produced. Producing them means downloading nine hundred
/// megabytes and then breaking it.
final class ModelInventoryTests: XCTestCase {

    private func availability(
        _ usable: Set<EngineKind>, whisperModelPaths: [String] = []
    ) -> EngineAvailability {
        EngineAvailability(usableEngines: usable, whisperModelPaths: whisperModelPaths)
    }

    // MARK: - What is on the disk

    /// An engine whose own check says it will load is Ready, whatever the
    /// directory happens to weigh.
    func testAnEngineThatLoadsIsReady() {
        let entries = ModelInventory.measure(
            availability: availability([.sensevoice]),
            engines: [.sensevoice],
            sizeOfDirectory: { _ in 268_000_000 })

        XCTAssertEqual(entries.first?.readiness, .ready)
        XCTAssertEqual(entries.first?.installedBytes, 268_000_000)
    }

    /// The state the "downloaded" badge could never show: bytes on the disk that
    /// no engine can use. An interrupted download leaves exactly this, and
    /// without a name for it the only visible symptom is a model that downloads
    /// itself again every launch.
    func testBytesOnDiskThatWillNotLoadAreCalledIncomplete() {
        let entries = ModelInventory.measure(
            availability: availability([]),
            engines: [.paraformer],
            sizeOfDirectory: { _ in 120_000_000 })

        XCTAssertEqual(entries.first?.readiness, .incomplete)
        XCTAssertTrue(entries.first?.hasBytesToRemove ?? false)
    }

    func testAnEmptyCacheIsNotInstalled() {
        let entries = ModelInventory.measure(
            availability: availability([]), engines: [.paraformer], sizeOfDirectory: { _ in 0 })

        XCTAssertEqual(entries.first?.readiness, .notInstalled)
        XCTAssertFalse(entries.first?.hasBytesToRemove ?? true)
    }

    /// A preparation in flight outranks everything else: the disk is being
    /// written to, so what is on it now is not the answer to anything.
    func testAModelBeingPreparedSaysSoRatherThanReportingHalfACache() {
        let entries = ModelInventory.measure(
            availability: availability([]),
            preparing: [ModelPreparation(engine: .sensevoice, stage: .downloading(fraction: 0.4))],
            engines: [.sensevoice],
            sizeOfDirectory: { _ in 90_000_000 })

        XCTAssertEqual(entries.first?.readiness, .preparing(.downloading(fraction: 0.4)))
        XCTAssertEqual(entries.first?.readiness.label, "Downloading 40%")
    }

    /// Two transfers can be in flight at once - the background preparation of
    /// the desired engine and a download started from Settings are different
    /// tasks - and both rows have to say so.
    func testTwoPreparationsInFlightAreBothReflected() {
        let entries = ModelInventory.measure(
            availability: availability([]),
            preparing: [
                ModelPreparation(engine: .sensevoice, stage: .preparing),
                ModelPreparation(engine: .paraformer, stage: .downloading(fraction: 0.1)),
            ],
            engines: [.sensevoice, .paraformer],
            sizeOfDirectory: { _ in 50_000_000 })

        XCTAssertEqual(entries.first?.readiness, .preparing(.preparing))
        XCTAssertEqual(entries.last?.readiness, .preparing(.downloading(fraction: 0.1)))
    }

    /// A preparation of a *different* engine does not masquerade as this row's:
    /// the engine with bytes and no loader is still Incomplete.
    func testAPreparationOfAnotherEngineDoesNotChangeThisRow() {
        let entries = ModelInventory.measure(
            availability: availability([]),
            preparing: [ModelPreparation(engine: .sensevoice, stage: .preparing)],
            engines: [.paraformer],
            sizeOfDirectory: { _ in 50_000_000 })

        XCTAssertEqual(entries.first?.readiness, .incomplete)
    }

    /// The row's language tags name languages, not modes: auto-detect is how
    /// the engine is asked, not something it transcribes.
    func testLanguageTagsNameLanguagesRatherThanModes() {
        let whisper = ModelInventory.languageNames(for: .whisper, fluidAudioModelVersion: "v3")
        XCTAssertTrue(whisper.contains("English"))
        XCTAssertTrue(whisper.contains("Chinese"))
        XCTAssertFalse(whisper.contains("Auto-detect"))

        XCTAssertEqual(
            ModelInventory.languageNames(for: .paraformer, fluidAudioModelVersion: "v3"),
            ["Chinese"])
        XCTAssertEqual(
            ModelInventory.languageNames(for: .fluidaudio, fluidAudioModelVersion: "v2"),
            ["English"])
        XCTAssertEqual(
            ModelInventory.languageNames(for: .fluidaudio, fluidAudioModelVersion: "v3").count,
            LanguageUtil.parakeetV3Languages.count)
    }

    func testAnIndeterminatePreparationDoesNotInventAPercentage() {
        XCTAssertEqual(ModelReadiness.preparing(.preparing).label, "Preparing")
    }

    /// The cloud engine downloads nothing, and the inventory says that rather
    /// than reporting it as a model somebody forgot to install.
    func testTheCloudEngineIsListedAsHavingNoLocalWeights() {
        let entries = ModelInventory.measure(
            availability: availability([.cloud]), engines: [.cloud], sizeOfDirectory: { _ in 0 })

        XCTAssertEqual(entries.first?.readiness, .noWeightsToInstall)
        XCTAssertEqual(entries.first?.cacheDirectories, [])
        XCTAssertFalse(entries.first?.hasBytesToRemove ?? true)
    }

    /// Both Parakeet caches count. A user who has tried v2 and v3 is paying for
    /// both, and a total that only knew about the selected one would understate
    /// the disk by the size of a whole model.
    func testParakeetCountsEveryModelVersionItCaches() {
        let directories = ModelInventory.cacheDirectories(for: .fluidaudio)
        XCTAssertEqual(directories.count, FluidAudioModelVersion.allCases.count)
        XCTAssertEqual(Set(directories).count, directories.count, "one directory per version")
    }

    /// Every engine that downloads weights has to name where they land, or the
    /// disk total is quietly wrong.
    func testEveryLocalEngineNamesItsCache() {
        for engine in EngineKind.allCases where !engine.usesCloudProvider {
            XCTAssertFalse(
                ModelInventory.cacheDirectories(for: engine).isEmpty,
                "\(engine) contributes bytes nothing is counting")
        }
    }

    func testTheTotalIsTheSumOfTheParts() {
        let entries = ModelInventory.measure(
            availability: availability([.sensevoice, .paraformer]),
            engines: [.sensevoice, .paraformer],
            sizeOfDirectory: { _ in 100 })

        XCTAssertEqual(ModelInventory.totalBytes(entries), 200)
    }

    func testSizesReadTheWayFinderWritesThem() {
        XCTAssertEqual(DirectorySize.describe(0), "None on disk")
        XCTAssertTrue(DirectorySize.describe(268_000_000).contains("MB"))
        XCTAssertTrue(DirectorySize.describe(2_400_000_000).contains("GB"))
    }

    func testTheSizeSummaryStatesBothTheDownloadAndTheDisk() {
        let installed = ModelInventoryEntry(
            engine: .sensevoice, readiness: .ready, installedBytes: 268_000_000,
            expectedMegabytes: 240, cacheDirectories: [URL(fileURLWithPath: "/tmp/x")])
        XCTAssertTrue(installed.sizeSummary.contains("240 MB"))
        XCTAssertTrue(installed.sizeSummary.contains("MB on disk"))

        let absent = ModelInventoryEntry(
            engine: .sensevoice, readiness: .notInstalled, installedBytes: 0,
            expectedMegabytes: 240, cacheDirectories: [URL(fileURLWithPath: "/tmp/x")])
        XCTAssertTrue(absent.sizeSummary.contains("nothing on disk"))
    }

    /// The inventory reads its words from the catalog rather than keeping a
    /// second copy, so the model name a licence requires cannot be dropped here
    /// while it survives in the picker.
    func testEveryRowNamesTheModelAndWhatItIsFor() {
        for engine in ModelInventory.listedEngines {
            let entry = ModelInventoryEntry(
                engine: engine, readiness: .notInstalled, installedBytes: 0,
                expectedMegabytes: nil, cacheDirectories: [])
            XCTAssertEqual(entry.displayName, EngineCatalog.entry(for: engine).displayName)
            XCTAssertFalse(entry.outcome.isEmpty, "\(engine) has no outcome to lead with")
            XCTAssertFalse(entry.character.isEmpty, "\(engine) does not say how it trades off")
        }
    }

    func testTheListedEnginesAreThePickersPlusTheCloudOne() {
        for engine in EngineCatalog.pickerOrder {
            XCTAssertTrue(ModelInventory.listedEngines.contains(engine))
        }
        XCTAssertEqual(
            ModelInventory.listedEngines.contains(.cloud), CloudBuild.isCompiledIn,
            "an offline-only build has no cloud engine to account for")
    }

    // MARK: - Removing weights

    private func decide(
        engine: EngineKind,
        installedBytes: Int64 = 200_000_000,
        usable: Set<EngineKind>,
        active: EngineKind?,
        isTranscribing: Bool = false,
        preparing: [EngineKind] = [],
        language: String = "en",
        whisperModelPaths: [String] = []
    ) -> Result<ModelRemoval.Consequence, ModelRemoval.Refusal> {
        ModelRemoval.decide(
            engine: engine,
            installedBytes: installedBytes,
            availability: availability(usable, whisperModelPaths: whisperModelPaths),
            activeEngine: active,
            isTranscribing: isTranscribing,
            preparing: preparing,
            language: language,
            fluidAudioModelVersion: "v3")
    }

    /// Deleting the files a loaded engine is reading from is how a decode ends
    /// in a crash rather than in a transcript.
    func testRemovalIsRefusedWhileTheEngineIsTranscribing() {
        let decision = decide(
            engine: .sensevoice, usable: [.sensevoice, .whisper], active: .sensevoice,
            isTranscribing: true)

        XCTAssertEqual(decision, .failure(.engineIsInUse))
    }

    /// A transcription on a *different* engine is not a reason to refuse: only
    /// the engine that is actually loaded is at risk.
    func testATranscriptionOnAnotherEngineDoesNotBlockRemoval() {
        let decision = decide(
            engine: .paraformer, usable: [.paraformer, .sensevoice], active: .sensevoice,
            isTranscribing: true)

        XCTAssertEqual(decision, .success(.none))
    }

    /// Removing a directory a download is still writing into leaves exactly the
    /// half-cache the inventory exists to name.
    func testRemovalIsRefusedWhileTheModelIsBeingPrepared() {
        let decision = decide(
            engine: .paraformer, usable: [.sensevoice], active: .sensevoice,
            preparing: [.paraformer])

        XCTAssertEqual(decision, .failure(.engineIsBeingPrepared))
    }

    /// The Settings pane's own download and the background preparation of the
    /// desired engine are different transfers, and both can be in flight:
    /// removal is refused when the engine is *any* of them, not only the first.
    func testRemovalIsRefusedWhenTheEngineIsAnyOfTheTransfersInFlight() {
        let decision = decide(
            engine: .paraformer, usable: [.sensevoice], active: .sensevoice,
            preparing: [.sensevoice, .paraformer])

        XCTAssertEqual(decision, .failure(.engineIsBeingPrepared))
    }

    func testRemovalIsRefusedWhenThereIsNothingThere() {
        let decision = decide(
            engine: .paraformer, installedBytes: 0, usable: [.sensevoice], active: .sensevoice)

        XCTAssertEqual(decision, .failure(.nothingInstalled))
    }

    func testTheCloudEngineHasNothingToRemove() {
        let decision = decide(engine: .cloud, usable: [.cloud], active: .cloud)
        XCTAssertEqual(decision, .failure(.engineHasNoWeights))
    }

    /// Removing what is not being used costs a download and nothing else.
    func testRemovingAnUnusedModelIsUneventful() {
        let decision = decide(
            engine: .paraformer, usable: [.paraformer, .sensevoice], active: .sensevoice)

        XCTAssertEqual(decision, .success(.none))
    }

    /// The fallback is resolved against what would be left, not against what is
    /// there now - "what still works afterwards" is a different question.
    func testRemovingTheActiveModelNamesWhatWouldTakeOver() {
        let decision = decide(
            engine: .sensevoice, usable: [.sensevoice, .fluidaudio], active: .sensevoice)

        XCTAssertEqual(decision, .success(.losesTheActiveEngine(fallback: .fluidaudio)))
    }

    /// The warning the whole type exists for.
    func testRemovingTheLastUsableModelSaysDictationWillStop() {
        let decision = decide(engine: .sensevoice, usable: [.sensevoice], active: .sensevoice)

        XCTAssertEqual(decision, .success(.leavesNothingThatCanTranscribe))
        XCTAssertTrue(ModelRemoval.Consequence.leavesNothingThatCanTranscribe.isSevere)
        XCTAssertFalse(ModelRemoval.Consequence.none.isSevere)
    }

    /// A configured cloud engine is not a fallback for a deleted local one. The
    /// same rule `EngineSelector` and `recoveryOrder` keep: nothing may move a
    /// user's audio off their Mac without being asked.
    func testAConfiguredCloudEngineIsNeverOfferedAsTheFallback() {
        let decision = decide(
            engine: .sensevoice, usable: [.sensevoice, .cloud], active: .sensevoice)

        XCTAssertEqual(decision, .success(.leavesNothingThatCanTranscribe))
    }

    /// Whisper is the engine whose weights are several files, and removing it
    /// removes all of them - so the fallback has to be resolved against a
    /// Whisper with no models rather than against its stored path.
    func testRemovingWhisperTakesEveryWhisperModelWithIt() {
        let decision = decide(
            engine: .whisper, usable: [.whisper], active: .whisper,
            whisperModelPaths: ["/models/large.bin", "/models/tiny.bin"])

        XCTAssertEqual(decision, .success(.leavesNothingThatCanTranscribe))
    }

    func testEveryRefusalAndConsequenceSaysSomethingUseful() {
        for refusal in [
            ModelRemoval.Refusal.engineIsInUse, .engineIsBeingPrepared, .nothingInstalled,
            .engineHasNoWeights,
        ] {
            XCTAssertFalse(refusal.message.isEmpty)
        }
        for consequence in [
            ModelRemoval.Consequence.none, .losesTheActiveEngine(fallback: .whisper),
            .leavesNothingThatCanTranscribe,
        ] {
            let message = consequence.message(for: .sensevoice)
            XCTAssertTrue(
                message.contains(EngineCatalog.entry(for: .sensevoice).displayName),
                "the confirmation has to name what is about to be deleted")
            XCTAssertFalse(message.contains("EchoForge"), "the user reads the product name")
        }
    }

    // MARK: - What is recommended, and what is never done about it

    private func machine(
        language: String, system: String = "en", memory: UInt64 = 32 << 30, mixes: Bool = false
    ) -> EngineRecommendation.Machine {
        EngineRecommendation.Machine(
            dictationLanguage: language, systemLanguage: system, physicalMemoryBytes: memory,
            mixesEnglishAndChinese: mixes, fluidAudioModelVersion: "v3")
    }

    func testMixingEnglishAndChineseEndsTheQuestion() {
        XCTAssertEqual(
            EngineRecommendation.engine(for: machine(language: "en", mixes: true)),
            EngineKind.bilingualDictation)
        XCTAssertEqual(
            EngineRecommendation.engine(for: machine(language: "de", mixes: true)),
            EngineKind.bilingualDictation)
    }

    func testChineseGetsTheChineseDefault() {
        XCTAssertEqual(
            EngineRecommendation.engine(for: machine(language: "zh")),
            EngineKind.defaultChineseDictation)
    }

    func testEnglishGetsTheFastEngine() {
        XCTAssertEqual(EngineRecommendation.engine(for: machine(language: "en")), .fluidaudio)
    }

    /// A language nothing specialised covers gets the engine that does every
    /// language.
    func testAnUncoveredLanguageGetsWhisper() {
        XCTAssertEqual(EngineRecommendation.engine(for: machine(language: "he")), EngineKind.fallback)
    }

    /// Auto-detect says nothing about what the user speaks, so the system's own
    /// language stands in rather than the recommendation defaulting to English.
    func testAutoDetectFallsBackToTheSystemLanguage() {
        XCTAssertEqual(
            EngineRecommendation.engine(for: machine(language: "auto", system: "zh")),
            EngineKind.defaultChineseDictation)
    }

    /// The rule that makes this safe: a recommendation is a sentence, never a
    /// selection, and it can never be the cloud engine.
    func testTheCloudEngineIsNeverRecommended() {
        for language in ["en", "zh", "de", "he", "auto"] {
            for mixes in [true, false] {
                XCTAssertNotEqual(
                    EngineRecommendation.engine(for: machine(language: language, mixes: mixes)),
                    .cloud)
            }
        }
    }

    func testEveryRecommendationExplainsItselfAndNamesTheCost() {
        for language in ["en", "zh", "de", "he", "auto"] {
            let reason = EngineRecommendation.reason(for: machine(language: language))
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("EchoForge"))
        }
        XCTAssertTrue(
            EngineRecommendation.reason(for: machine(language: "zh")).contains("MB"),
            "a recommendation that does not say what it costs is an instruction")
    }

    /// Memory is a note beside the Whisper models, never a different engine: all
    /// four run on any Apple Silicon Mac, and what memory decides is whether the
    /// biggest Whisper model is a good trade.
    func testMemoryOnlyEverAddsANote() {
        XCTAssertNil(EngineRecommendation.memoryNote(for: machine(language: "en", memory: 32 << 30)))
        let note = EngineRecommendation.memoryNote(for: machine(language: "en", memory: 8 << 30))
        XCTAssertTrue(note?.contains("8 GB") ?? false)

        XCTAssertEqual(
            EngineRecommendation.engine(for: machine(language: "en", memory: 8 << 30)),
            EngineRecommendation.engine(for: machine(language: "en", memory: 64 << 30)),
            "memory must not quietly change which engine is recommended")
    }
}
