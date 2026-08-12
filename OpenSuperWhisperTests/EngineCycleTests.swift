import XCTest

@testable import OpenSuperWhisper

/// What one press of the engine shortcut may land on.
///
/// The promise being pinned here is a single sentence - **a press never lands on
/// an engine that could not transcribe the next dictation** - and every case below
/// is one way that used to be easy to break: an engine whose weights are not
/// there, a Whisper configuration naming a deleted file, an engine that would
/// mis-transcribe the language in use, and the cloud engine, which may only ever
/// be reached on the user's own recorded decision.
final class EngineCycleTests: XCTestCase {

    private func availability(
        _ engines: Set<EngineKind>,
        whisperModels: [String] = []
    ) -> EngineAvailability {
        EngineAvailability(usableEngines: engines, whisperModelPaths: whisperModels)
    }

    private func cycle(
        _ availability: EngineAvailability,
        whisperModelPath: String? = nil,
        language: String = "en",
        fluidAudioModelVersion: String = "v3",
        isCloudSelectable: Bool = false
    ) -> [EngineKind] {
        EngineCycle.available(
            whisperModelPath: whisperModelPath,
            language: language,
            fluidAudioModelVersion: fluidAudioModelVersion,
            availability: availability,
            isCloudSelectable: isCloudSelectable
        )
    }

    // MARK: - What is in the cycle

    /// The order is the picker's order, so learning one teaches the other - and
    /// the cloud engine is last, because a press must not reach the one engine
    /// that leaves the Mac before every local one has been offered.
    func testTheOrderIsThePickerOrderWithCloudLast() {
        XCTAssertEqual(EngineCycle.order, EngineCatalog.pickerOrder + [.cloud])
        XCTAssertEqual(EngineCycle.order.last, .cloud)
    }

    func testOnlyDownloadedEnginesAreOffered() {
        let offered = cycle(availability([.sensevoice]))

        XCTAssertEqual(offered, [.sensevoice])
    }

    /// Whisper is the one engine whose configuration names a file, so "downloaded"
    /// is not enough: the stored file has to still be one that exists. Which
    /// replacement to use is a choice, and this shortcut changes engines rather
    /// than making choices - `EngineConfiguration.recoverIfNeeded` is what repairs
    /// it, at launch.
    func testWhisperIsOfferedOnlyWhenItsStoredModelStillExists() {
        let present = cycle(
            availability([.whisper], whisperModels: ["/models/ggml-large-v3-turbo.bin"]),
            whisperModelPath: "/models/ggml-large-v3-turbo.bin"
        )
        XCTAssertEqual(present, [.whisper])

        let deleted = cycle(
            availability([.whisper], whisperModels: ["/models/ggml-base.bin"]),
            whisperModelPath: "/models/ggml-large-v3-turbo.bin"
        )
        XCTAssertEqual(deleted, [], "the stored Whisper model is gone, so Whisper cannot transcribe")
    }

    /// Paraformer does not refuse German, it returns fluent Mandarin for it. The
    /// Settings picker may reset the dictation language when the user chooses such
    /// an engine, because they are looking at the language control while it
    /// happens; a shortcut pressed into another app must not change two things at
    /// once, so the engine is skipped instead.
    func testAnEngineThatCannotDictateTheLanguageIsSkipped() {
        let german = cycle(availability([.sensevoice, .paraformer]), language: "de")
        XCTAssertEqual(german, [], "neither Chinese engine does German")

        let mandarin = cycle(availability([.sensevoice, .paraformer]), language: "zh")
        XCTAssertEqual(mandarin, [EngineKind.defaultChineseDictation, EngineKind.chineseAccuracyAlternative])
    }

    /// Parakeet's language scope depends on which model version is selected, and
    /// the cycle has to read the same answer `EngineSelector` does.
    func testParakeetIsSkippedForALanguageItsSelectedModelDoesNotDo() {
        let v2 = cycle(availability([.fluidaudio]), language: "de", fluidAudioModelVersion: "v2")
        XCTAssertEqual(v2, [], "Parakeet v2 is English only")

        let v3 = cycle(availability([.fluidaudio]), language: "de", fluidAudioModelVersion: "v3")
        XCTAssertEqual(v3, [.fluidaudio])
    }

    // MARK: - The cloud engine

    /// The PR that added the cloud path made one promise about it: it is never
    /// entered on the app's initiative. Here that means the shortcut offers it only
    /// when the user has already chosen and consented to the cloud and configured
    /// it - which is exactly what `CloudAccess.isSelectable` answers.
    func testCloudIsOfferedOnlyWhenItIsReady() {
        let notReady = cycle(availability([.sensevoice]), language: "zh", isCloudSelectable: false)
        XCTAssertFalse(notReady.contains(.cloud))

        let ready = cycle(availability([.sensevoice]), language: "zh", isCloudSelectable: true)
        XCTAssertEqual(ready, [EngineKind.defaultChineseDictation, .cloud])
    }

    /// A cloud engine the app cannot use is not in the cycle even while it is the
    /// selected engine - and a press from it moves to a working local engine
    /// rather than doing nothing. The misconfiguration is still reported on each
    /// dictation until then (`EngineConfiguration.cloudMisconfigured`); what this
    /// shortcut must not do is *silently* leave it, and a press is not silent.
    func testAMisconfiguredCloudSelectionIsNotInTheCycleAndAPressLeavesIt() {
        let offered = cycle(availability([.sensevoice]), language: "zh", isCloudSelectable: false)

        XCTAssertEqual(EngineCycle.next(after: .cloud, in: offered), .sensevoice)
    }

    /// `isCloudSelectable` is not "the cloud engine is downloaded": there is
    /// nothing to download. A snapshot whose `usableEngines` happens to contain it
    /// - which is what `EngineAvailability.current` writes while it is the selected
    /// engine - must not put it in the cycle on its own.
    func testCloudIsNotOfferedFromTheAvailabilitySnapshotAlone() {
        let offered = cycle(availability([.cloud, .sensevoice]), language: "zh", isCloudSelectable: false)

        XCTAssertEqual(offered, [EngineKind.defaultChineseDictation])
    }

    // MARK: - Walking it

    func testItWrapsAroundInOrder() {
        let offered = cycle(
            availability([.whisper, .fluidaudio, .sensevoice], whisperModels: ["/m/ggml-base.bin"]),
            whisperModelPath: "/m/ggml-base.bin",
            language: "en",
            isCloudSelectable: true
        )
        XCTAssertEqual(offered, [.whisper, .fluidaudio, .sensevoice, .cloud])

        XCTAssertEqual(EngineCycle.next(after: .whisper, in: offered), .fluidaudio)
        XCTAssertEqual(EngineCycle.next(after: .fluidaudio, in: offered), .sensevoice)
        XCTAssertEqual(EngineCycle.next(after: .sensevoice, in: offered), .cloud)
        XCTAssertEqual(EngineCycle.next(after: .cloud, in: offered), .whisper, "it wraps")
    }

    /// An engine that is not in the cycle - its cache deleted while the app ran -
    /// is not an error: the user pressed a key asking for a working engine.
    func testAnEngineOutsideTheCycleMovesToTheFirstEntry() {
        let offered = cycle(availability([.sensevoice, .paraformer]), language: "zh")

        XCTAssertEqual(EngineCycle.next(after: .fluidaudio, in: offered), EngineKind.defaultChineseDictation)
    }

    func testThereIsNowhereToGoWithOneEngineOrNone() {
        XCTAssertNil(EngineCycle.next(after: .sensevoice, in: [.sensevoice]))
        XCTAssertNil(EngineCycle.next(after: .sensevoice, in: []))
    }

    // MARK: - What a press amounts to

    func testAPressSwitches() {
        let outcome = EngineCycle.decide(
            current: .whisper,
            cycle: [.whisper, .sensevoice],
            isDictationInFlight: false
        )

        XCTAssertEqual(outcome, .switched(.sensevoice))
    }

    /// The mid-dictation rule: not refused, deferred. The words already spoken were
    /// spoken to a particular model and have to be decoded by it.
    func testAPressDuringADictationIsDeferredRatherThanRefused() {
        let outcome = EngineCycle.decide(
            current: .whisper,
            cycle: [.whisper, .sensevoice],
            isDictationInFlight: true
        )

        XCTAssertEqual(outcome, .deferred(.sensevoice))
    }

    /// A press that cannot change anything says so, rather than reading as a dead
    /// key: there is no window open to show that nothing happened.
    func testAPressWithOneEngineIsANoOpThatNamesIt() {
        XCTAssertEqual(
            EngineCycle.decide(current: .sensevoice, cycle: [.sensevoice], isDictationInFlight: false),
            .onlyOneEngine(.sensevoice)
        )
        XCTAssertEqual(
            EngineCycle.decide(current: .sensevoice, cycle: [], isDictationInFlight: false),
            .noEngineAvailable
        )
    }

    // MARK: - What it says

    func testTheOverlayNamesTheEngineTheUserWouldRecognise() {
        // The model name inside a FunASR engine's display name is a licence
        // obligation, not a label - see `EngineCatalogTests`. The overlay reads
        // `EngineCatalog` so it cannot drop it.
        XCTAssertEqual(
            EngineSwitchMessage.name(for: .sensevoice, whisperModelPath: nil, cloudModel: "whisper-1"),
            EngineCatalog.entry(for: .sensevoice).displayName
        )

        // Whisper is several files, so its name alone does not say what a dictation
        // will run on.
        XCTAssertEqual(
            EngineSwitchMessage.name(
                for: .whisper,
                whisperModelPath: "/models/ggml-large-v3-turbo.bin",
                cloudModel: "whisper-1"
            ),
            "Whisper - large-v3-turbo"
        )

        // And the cloud engine is whatever model the provider was asked for.
        XCTAssertEqual(
            EngineSwitchMessage.name(for: .cloud, whisperModelPath: nil, cloudModel: "gpt-4o-transcribe"),
            "Cloud - gpt-4o-transcribe"
        )
        XCTAssertEqual(
            EngineSwitchMessage.name(for: .cloud, whisperModelPath: nil, cloudModel: "   "),
            "Cloud"
        )
    }

    /// A deferred press has to say both halves. "Engine: SenseVoice-Small" alone
    /// would be a lie about the words currently being decoded.
    func testADeferredPressSaysItAppliesLater() {
        let text = EngineSwitchMessage.text(
            for: .deferred(.sensevoice),
            whisperModelPath: nil,
            cloudModel: "whisper-1"
        )

        XCTAssertTrue(text.contains(EngineCatalog.entry(for: .sensevoice).displayName))
        XCTAssertTrue(text.contains("after this dictation"))
    }

    /// The overlay draws a cloud rather than a waveform for the one engine that is
    /// not on this Mac, and the flag it does that from is derived from the engine -
    /// not from matching "Cloud" in a sentence that may be reworded.
    func testTheAnnouncementSaysWhenItIsAboutTheEngineThatLeavesTheMac() {
        let cloud = EngineSwitchMessage.announcement(
            for: .switched(.cloud), whisperModelPath: nil, cloudModel: "whisper-1"
        )
        XCTAssertTrue(cloud.isCloud)

        for outcome: EngineSwitchOutcome in [
            .switched(.sensevoice), .deferred(.whisper), .onlyOneEngine(.fluidaudio), .noEngineAvailable,
        ] {
            XCTAssertFalse(
                EngineSwitchMessage.announcement(
                    for: outcome, whisperModelPath: nil, cloudModel: "whisper-1"
                ).isCloud,
                "\(outcome)"
            )
        }
    }

    func testNoEngineAvailableSaysWhatTheRestOfTheAppSays() {
        XCTAssertEqual(
            EngineSwitchMessage.text(for: .noEngineAvailable, whisperModelPath: nil, cloudModel: ""),
            EngineConfiguration.unavailableShortMessage
        )
    }
}
