import XCTest

@testable import OpenSuperWhisper

/// The rule that separates what the user chose from what is actually running.
///
/// Every case here is a moment a shipped EchoForge used to spend refusing to
/// transcribe: the minutes after choosing an engine while its 240 MB download
/// ran, a first launch before anything had been fetched, a relaunch during a
/// download. The whole point of `EngineSelector` is that none of those is an
/// error any more - and that none of them writes to the user's selection either.
final class EngineSelectionTests: XCTestCase {

    private func availability(_ engines: Set<EngineKind>, whisperModels: [String] = []) -> EngineAvailability {
        EngineAvailability(usableEngines: engines, whisperModelPaths: whisperModels)
    }

    private func resolve(
        desired: EngineKind,
        desiredWhisperModelPath: String? = nil,
        lastReady: EngineKind? = nil,
        lastReadyWhisperModelPath: String? = nil,
        language: String = "en",
        availability: EngineAvailability
    ) -> EngineSelection {
        EngineSelector.resolve(
            desired: desired,
            desiredWhisperModelPath: desiredWhisperModelPath,
            lastReady: lastReady,
            lastReadyWhisperModelPath: lastReadyWhisperModelPath,
            language: language,
            fluidAudioModelVersion: "v3",
            availability: availability
        )
    }

    // MARK: - The user's choice wins whenever it can

    func testDesiredEngineThatCanLoad_isTheActiveEngine() {
        let selection = resolve(desired: .sensevoice, availability: availability([.sensevoice, .paraformer]))

        XCTAssertEqual(selection.active, .sensevoice)
        XCTAssertNil(selection.interimReason)
        XCTAssertFalse(selection.isDesiredEnginePending)
    }

    /// A working desired engine ends the question. Nothing "better" is
    /// substituted, including the starter model.
    func testDesiredEngineIsNeverPassedOverForTheStarter() {
        let selection = resolve(
            desired: .whisper,
            desiredWhisperModelPath: "/models/turbo.bin",
            lastReady: EngineSelector.starterEngine,
            availability: availability(
                [.whisper, EngineSelector.starterEngine],
                whisperModels: ["/models/turbo.bin"]
            )
        )

        XCTAssertEqual(selection.active, .whisper)
        XCTAssertEqual(selection.activeWhisperModelPath, "/models/turbo.bin")
        XCTAssertNil(selection.interimReason)
    }

    // MARK: - The previous model stands in

    /// The case this whole change exists for: a Whisper user taps Paraformer,
    /// whose 653 MB are not downloaded. Dictation used to fail for the length of
    /// the download; now it carries on with Whisper.
    func testChoosingAnUndownloadedEngine_keepsDictatingOnThePreviousModel() {
        let selection = resolve(
            desired: .paraformer,
            lastReady: .whisper,
            lastReadyWhisperModelPath: "/models/turbo.bin",
            language: "zh",
            availability: availability([.whisper], whisperModels: ["/models/turbo.bin"])
        )

        XCTAssertEqual(selection.active, .whisper)
        XCTAssertEqual(selection.activeWhisperModelPath, "/models/turbo.bin")
        XCTAssertEqual(selection.interimReason, .previousModel)
        XCTAssertTrue(selection.isDesiredEnginePending)
        XCTAssertTrue(selection.canTranscribe)
    }

    /// The desired engine is still exactly what the user asked for, whatever is
    /// running instead. This is the assertion the requirement turns on.
    func testAnInterimEngineNeverBecomesTheDesiredOne() {
        let selection = resolve(
            desired: .paraformer,
            lastReady: .whisper,
            lastReadyWhisperModelPath: "/models/turbo.bin",
            language: "zh",
            availability: availability([.whisper], whisperModels: ["/models/turbo.bin"])
        )

        XCTAssertEqual(selection.desired, .paraformer)
    }

    /// A previous model whose files have since gone is not a stand-in.
    func testAPreviousModelThatIsNoLongerOnDisk_isNotUsed() {
        let selection = resolve(
            desired: .paraformer,
            lastReady: .whisper,
            lastReadyWhisperModelPath: "/models/deleted.bin",
            language: "zh",
            availability: availability([], whisperModels: [])
        )

        XCTAssertNil(selection.active)
        XCTAssertFalse(selection.canTranscribe)
    }

    /// Paraformer does not refuse German, it returns fluent Mandarin for it. An
    /// engine that would silently do that to the user's words is not a stand-in,
    /// it is a different failure - so it is passed over.
    func testAPreviousModelThatCannotDoTheLanguage_isNotUsed() {
        let selection = resolve(
            desired: .whisper,
            desiredWhisperModelPath: "/models/turbo.bin",
            lastReady: .paraformer,
            language: "de",
            availability: availability([.paraformer])
        )

        XCTAssertNil(selection.active)
        XCTAssertEqual(selection.desired, .whisper)
    }

    // MARK: - The starter model

    /// A first launch: nothing was ever ready, and the weights that ship with the
    /// app answer for it. This is what makes the app usable before any download.
    func testFirstLaunchWithOnlyTheStarterInstalled_dictatesOnTheStarter() {
        let selection = resolve(
            desired: .whisper,
            desiredWhisperModelPath: nil,
            lastReady: nil,
            availability: availability([EngineSelector.starterEngine])
        )

        XCTAssertEqual(selection.active, EngineSelector.starterEngine)
        XCTAssertEqual(selection.interimReason, .starterModel)
        XCTAssertEqual(selection.desired, .whisper)
        XCTAssertTrue(selection.canTranscribe)
    }

    /// The previous model is preferred over the starter: it is what the user was
    /// actually dictating with.
    func testThePreviousModelIsPreferredOverTheStarter() {
        let selection = resolve(
            desired: .paraformer,
            lastReady: .fluidaudio,
            language: "en",
            availability: availability([.fluidaudio, EngineSelector.starterEngine])
        )

        XCTAssertEqual(selection.active, .fluidaudio)
        XCTAssertEqual(selection.interimReason, .previousModel)
    }

    /// The starter only stands in for a language it can actually do.
    func testTheStarterIsNotUsedForALanguageItCannotDo() {
        let selection = resolve(
            desired: .whisper,
            lastReady: nil,
            language: "de",
            availability: availability([EngineSelector.starterEngine])
        )

        XCTAssertNil(selection.active)
    }

    // MARK: - Nothing at all

    func testNothingDownloaded_cannotTranscribeAndSaysSo() {
        let selection = resolve(desired: .whisper, availability: availability([]))

        XCTAssertNil(selection.active)
        XCTAssertFalse(selection.canTranscribe)
        XCTAssertTrue(selection.isDesiredEnginePending)
    }

    /// The starter engine being the desired one is not an interim state: it is
    /// simply the engine, and the app must not describe it as standing in for
    /// itself.
    func testTheStarterAsTheDesiredEngine_isNotAnInterimState() {
        let selection = resolve(
            desired: EngineSelector.starterEngine,
            language: "zh",
            availability: availability([EngineSelector.starterEngine])
        )

        XCTAssertNil(selection.interimReason)
        XCTAssertFalse(selection.isDesiredEnginePending)
    }
}

/// Which engines the app can make ready on its own, and which it must not try to.
final class EnginePreparabilityTests: XCTestCase {

    /// Whisper names a *file*. When that file is gone the app cannot tell whether
    /// the user wants the 1.6 GB Turbo Large back or something smaller, so it
    /// does not guess - and that is why a deleted Whisper model is still a stale
    /// configuration for `EngineConfiguration.resolve` to recover from.
    func testWhisperIsNotPreparedAutomatically() {
        XCTAssertFalse(EngineConfiguration.isPreparable(engine: .whisper))
    }

    func testEveryOtherEngineCanBePreparedInTheBackground() {
        for engine: EngineKind in [.fluidaudio, .sensevoice, .paraformer] {
            XCTAssertTrue(
                EngineConfiguration.isPreparable(engine: engine),
                "\(engine) is one identified download; nothing should make the user drive it"
            )
        }
    }
}
