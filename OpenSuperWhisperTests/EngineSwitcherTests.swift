import Combine
import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper

/// The shortcut end to end, minus the window server: what a press writes, what it
/// says, and what it does with a press that arrives mid-dictation.
///
/// The persistence assertions are made against the real preference
/// (`AppPreferences.selectedEngine` in a throwaway suite) rather than a spy,
/// because "the shortcut is exactly equivalent to picking it in Settings" is a
/// claim about that one stored value and nothing else. `EngineSelectionCommand` is
/// what both go through.
@MainActor
final class EngineSwitcherTests: IsolatedPreferencesTestCase {

    private var announced: [EngineSwitchAnnouncement] = []
    private var inFlight = false
    private var cloudSelectable = false
    private var availability = EngineAvailability(usableEngines: [], whisperModelPaths: [])
    private var applied: [EngineKind] = []
    private let activity = PassthroughSubject<Void, Never>()

    /// A switcher whose only fakes are the four things a unit test cannot have: a
    /// Mac with models on it, a configured provider, a dictation in flight, and a
    /// screen. Writing the preference is left real.
    private func makeSwitcher(
        recordAppliedInsteadOfWriting: Bool = false
    ) -> EngineSwitcher {
        EngineSwitcher(
            preferences: .shared,
            availability: { [unowned self] in self.availability },
            isCloudSelectable: { [unowned self] in self.cloudSelectable },
            isDictationInFlight: { [unowned self] in self.inFlight },
            apply: { [unowned self] engine in
                self.applied.append(engine)
                guard !recordAppliedInsteadOfWriting else { return }
                EngineSelectionCommand.select(engine)
            },
            announce: { [unowned self] announcement in self.announced.append(announcement) },
            activityChanges: { [unowned self] in self.activity.eraseToAnyPublisher() }
        )
    }

    // MARK: - The default shortcut

    /// ⌥M, and free: a default that collided with one of the other three would
    /// silently take one of them away on every existing install.
    func testTheDefaultShortcutIsFreeAlongsideTheOthers() {
        let defaults: [KeyboardShortcuts.Shortcut?] = [
            KeyboardShortcuts.Name.toggleRecord.defaultShortcut,
            KeyboardShortcuts.Name.askPanel.defaultShortcut,
            KeyboardShortcuts.Name.askAboutScreen.defaultShortcut,
            KeyboardShortcuts.Name.cycleEngine.defaultShortcut,
        ]

        XCTAssertEqual(
            KeyboardShortcuts.Name.cycleEngine.defaultShortcut,
            KeyboardShortcuts.Shortcut(.m, modifiers: .option)
        )
        XCTAssertEqual(Set(defaults.compactMap { $0 }).count, defaults.count, "two shortcuts share a default")
    }

    // MARK: - A press

    func testAPressPersistsTheNextEngineAndNamesIt() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])

        let outcome = makeSwitcher().advance()

        XCTAssertEqual(outcome, .switched(EngineKind.chineseAccuracyAlternative))
        XCTAssertEqual(AppPreferences.shared.selectedEngine, EngineKind.chineseAccuracyAlternative)
        XCTAssertEqual(
            announced.map(\.text),
            ["Engine: \(EngineCatalog.entry(for: EngineKind.chineseAccuracyAlternative).displayName)"]
        )
        XCTAssertEqual(announced.map(\.isCloud), [false])
    }

    /// The whole point of a cycle: pressing it enough times comes back.
    func testPressingItRoundTheCycleReturnsToWhereItStarted() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])
        let switcher = makeSwitcher()

        switcher.advance()
        switcher.advance()

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(applied, [EngineKind.chineseAccuracyAlternative, .sensevoice])
    }

    /// Nothing is written when there is nowhere to go, and the user is told why -
    /// there is no window open for a silent no-op to be visible in.
    func testAPressWithOneUsableEngineWritesNothing() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])

        let outcome = makeSwitcher().advance()

        XCTAssertEqual(outcome, .onlyOneEngine(.sensevoice))
        XCTAssertEqual(applied, [])
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(announced.count, 1)
        XCTAssertTrue(announced[0].text.contains(EngineCatalog.entry(for: .sensevoice).displayName))
    }

    func testAPressWithNothingDownloadedSaysNoEngineIsSetUp() {
        AppPreferences.shared.selectedEngine = .whisper

        let outcome = makeSwitcher().advance()

        XCTAssertEqual(outcome, .noEngineAvailable)
        XCTAssertEqual(applied, [])
        XCTAssertEqual(announced.map(\.text), [EngineConfiguration.unavailableShortMessage])
    }

    /// The cloud engine is reachable by shortcut, but only on the decision the user
    /// already made in the Cloud pane: `isCloudSelectable` is `CloudAccess` having
    /// said yes to consent, base URL, model and key.
    func testCloudIsReachedOnlyWhenItIsReady() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])

        // Not configured: the one usable engine is the selected one, so there is
        // nowhere to go at all.
        XCTAssertEqual(makeSwitcher().advance(), .onlyOneEngine(.sensevoice))

        cloudSelectable = true
        // Recorded rather than written: selecting the cloud engine for real would
        // send `EngineAvailability.current` to the Keychain from a unit test.
        XCTAssertEqual(makeSwitcher(recordAppliedInsteadOfWriting: true).advance(), .switched(.cloud))
    }

    // MARK: - Mid-dictation

    /// A press during a dictation changes nothing yet. The words already spoken
    /// were spoken to a particular model and are decoded by it.
    func testAPressDuringADictationChangesNothingYet() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])
        inFlight = true

        let switcher = makeSwitcher()
        let outcome = switcher.advance()

        XCTAssertEqual(outcome, .deferred(EngineKind.chineseAccuracyAlternative))
        XCTAssertEqual(applied, [])
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(switcher.pendingEngine, EngineKind.chineseAccuracyAlternative)
        XCTAssertTrue(announced[0].text.contains("after this dictation"))
    }

    func testTheDeferredSwitchIsAppliedWhenTheDictationEnds() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])
        inFlight = true

        let switcher = makeSwitcher()
        switcher.advance()

        // Still in flight: a wake-up in the gap between the recorder stopping and
        // the transcription starting must not apply anything.
        activity.send()
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)

        inFlight = false
        activity.send()

        XCTAssertEqual(AppPreferences.shared.selectedEngine, EngineKind.chineseAccuracyAlternative)
        XCTAssertNil(switcher.pendingEngine)
        XCTAssertEqual(
            announced.last?.text,
            "Engine: \(EngineCatalog.entry(for: EngineKind.chineseAccuracyAlternative).displayName)"
        )
    }

    /// Two presses during one dictation move two places, so the shortcut behaves
    /// the same whether or not a dictation happens to be running.
    func testASecondPressDuringADictationAdvancesFromThePendingEngine() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])
        inFlight = true

        let switcher = makeSwitcher()
        switcher.advance()
        let second = switcher.advance()

        XCTAssertEqual(second, .deferred(.sensevoice), "two steps round a two-engine cycle is back")
        XCTAssertEqual(switcher.pendingEngine, .sensevoice)

        inFlight = false
        activity.send()

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
    }

    /// A wait can be long enough for the pending engine to stop being usable - a
    /// cache deleted, a key removed. Applying it then would land the user on an
    /// engine that cannot transcribe, which is the one thing the shortcut promises
    /// not to do, so with nothing else to move to nothing is written.
    func testAPendingEngineThatStoppedBeingUsableIsNotApplied() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])
        inFlight = true

        let switcher = makeSwitcher()
        switcher.advance()
        XCTAssertEqual(switcher.pendingEngine, EngineKind.chineseAccuracyAlternative)

        availability = EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: [])
        inFlight = false
        activity.send()

        XCTAssertEqual(applied, [])
        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertNil(switcher.pendingEngine)
        XCTAssertTrue(
            announced.last?.text.contains(EngineCatalog.entry(for: .sensevoice).displayName) == true,
            "the user was promised an engine, so they are told what happened instead: \(announced)"
        )
    }

    /// And when something else *is* usable, the press is carried out as though it
    /// had been made now: the user asked for a working engine, so they get the next
    /// one - and the overlay names what actually happened rather than the engine
    /// they were promised.
    func testAPendingEngineThatStoppedBeingUsableFallsThroughToTheNextOne() {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.selectedWhisperModelPath = "/models/ggml-base.bin"
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(
            usableEngines: [.whisper, .sensevoice, .paraformer],
            whisperModelPaths: ["/models/ggml-base.bin"]
        )
        inFlight = true

        let switcher = makeSwitcher()
        switcher.advance()
        XCTAssertEqual(switcher.pendingEngine, .sensevoice)

        // SenseVoice's cache is gone by the time the dictation ends.
        availability = EngineAvailability(
            usableEngines: [.whisper, .paraformer],
            whisperModelPaths: ["/models/ggml-base.bin"]
        )
        inFlight = false
        activity.send()

        XCTAssertEqual(applied, [EngineKind.chineseAccuracyAlternative])
        XCTAssertEqual(AppPreferences.shared.selectedEngine, EngineKind.chineseAccuracyAlternative)
        XCTAssertEqual(
            announced.last?.text,
            "Engine: \(EngineCatalog.entry(for: EngineKind.chineseAccuracyAlternative).displayName)",
            "the overlay may only name the engine that was actually selected"
        )
    }

    // MARK: - Equivalence with the Settings picker

    /// A press changes one thing. The cycle only contains engines that already do
    /// the language being dictated, so - unlike the picker, which resets the
    /// language while the user is looking at the control - the shortcut can never
    /// move it.
    func testTheShortcutNeverChangesTheDictationLanguage() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.selectedWhisperModelPath = "/models/ggml-base.bin"
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(
            usableEngines: [.whisper, .fluidaudio, .sensevoice, .paraformer],
            whisperModelPaths: ["/models/ggml-base.bin"]
        )
        let switcher = makeSwitcher()

        for _ in 0 ..< 6 {
            switcher.advance()
            XCTAssertEqual(AppPreferences.shared.whisperLanguage, "zh")
            XCTAssertTrue(
                LanguageUtil.supportedLanguages(
                    engine: AppPreferences.shared.selectedEngine,
                    fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
                ).contains("zh"),
                "\(AppPreferences.shared.selectedEngine) cannot dictate Mandarin"
            )
        }

        // Parakeet v3 has no Mandarin, so it is one of the engines that was never
        // offered even though its weights are there.
        XCTAssertFalse(applied.contains(.fluidaudio))
    }

    /// Nothing in the shortcut's path writes `lastReadyEngine` - the value that
    /// keeps dictation running on the previous model while a new one prepares.
    /// Only a load that succeeded may write it (`TranscriptionService`).
    func testTheShortcutNeverWritesTheLastReadyEngine() {
        AppPreferences.shared.selectedEngine = .sensevoice
        AppPreferences.shared.whisperLanguage = "zh"
        availability = EngineAvailability(usableEngines: [.sensevoice, .paraformer], whisperModelPaths: [])

        makeSwitcher().advance()

        XCTAssertNil(storedPreference("lastReadyEngine"))
    }
}
