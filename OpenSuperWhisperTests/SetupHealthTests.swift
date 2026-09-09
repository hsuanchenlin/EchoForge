import XCTest

@testable import OpenSuperWhisper

/// The one question Settings could not answer, and every way it can be answered.
///
/// `SetupHealth.checks` is a pure function of a snapshot, so this describes a
/// Mac rather than being one: no microphone, no model, no TCC grant and no
/// network are needed to assert what the pane says about any of them.
final class SetupHealthTests: XCTestCase {

    // MARK: - A Mac where nothing is wrong

    /// Every case below is this one with a single field changed, which is how
    /// the interesting states actually occur.
    private func healthy() -> SetupHealthInputs {
        SetupHealthInputs(
            selection: EngineSelection(
                desired: .sensevoice, active: .sensevoice, activeWhisperModelPath: nil,
                interimReason: nil),
            preparation: nil,
            preparationFailure: nil,
            inventory: [
                ModelInventoryEntry(
                    engine: .sensevoice, readiness: .ready, installedBytes: 268_000_000,
                    expectedMegabytes: 240, cacheDirectories: [URL(fileURLWithPath: "/tmp/m")])
            ],
            dictationLanguage: "zh",
            chineseOutputScript: .traditional,
            fluidAudioModelVersion: "v3",
            microphoneCount: 1,
            currentMicrophoneName: "MacBook Pro Microphone",
            isMicrophoneGranted: true,
            isAccessibilityGranted: true,
            isScreenRecordingGranted: true,
            trigger: .keyboardShortcut("⌥`"),
            shortcutConflicts: [],
            cloudIsCompiledIn: true,
            cloudTranscriptionSelected: false,
            cloudTranslationEnabled: false,
            cloudHost: nil)
    }

    private func check(_ topic: SetupHealthTopic, _ inputs: SetupHealthInputs) throws
        -> SetupHealthCheck {
        try XCTUnwrap(SetupHealth.checks(inputs).first { $0.topic == topic })
    }

    func testAWorkingInstallSaysSoAndAsksForNothing() {
        let checks = SetupHealth.checks(healthy())

        XCTAssertEqual(checks.count, SetupHealthTopic.allCases.count)
        XCTAssertTrue(checks.allSatisfy { $0.status == .ok }, "\(checks.filter { $0.status != .ok })")
        XCTAssertEqual(SetupHealth.summary(for: checks), "Kongweh is ready.")
        XCTAssertEqual(SetupHealth.worstStatus(in: checks), .ok)
    }

    /// The rows are a fixed list a user learns the shape of. Sorting them by
    /// severity would move them about as the state changed, which is a pane
    /// nobody can scan; the summary carries the urgency instead.
    func testTheRowsKeepTheirOrderWhateverTheStateIs() {
        var broken = healthy()
        broken.isAccessibilityGranted = false
        broken.microphoneCount = 0

        XCTAssertEqual(
            SetupHealth.checks(broken).map(\.topic), SetupHealthTopic.allCases)
        XCTAssertEqual(
            SetupHealth.checks(healthy()).map(\.topic), SetupHealthTopic.allCases)
    }

    // MARK: - The engine the user chose, and the one that is running

    /// The distinction the whole engine area exists to keep. A user waiting on a
    /// 240 MB download is not misconfigured, and the pane has to say which
    /// engine is theirs and which is standing in.
    func testAPendingEngineNamesBothItselfAndWhatIsStandingIn() throws {
        var inputs = healthy()
        inputs.selection = EngineSelection(
            desired: .paraformer, active: .sensevoice, activeWhisperModelPath: nil,
            interimReason: .previousModel)

        let engine = try check(.engine, inputs)
        XCTAssertEqual(engine.status, .attention)
        XCTAssertTrue(engine.detail.contains(EngineCatalog.entry(for: .paraformer).displayName))
        XCTAssertTrue(engine.detail.contains(EngineCatalog.entry(for: .sensevoice).displayName))
        XCTAssertTrue(engine.detail.contains("before"), "it must say why that one is running")
    }

    func testTheStarterModelStandingInSaysWhereItCameFrom() throws {
        var inputs = healthy()
        inputs.selection = EngineSelection(
            desired: .paraformer, active: .sensevoice, activeWhisperModelPath: nil,
            interimReason: .starterModel)

        XCTAssertTrue(try check(.engine, inputs).detail.contains("came with the app"))
    }

    /// The gap `EngineSelector` cannot close: a stand-in that does the user's
    /// language but not the *pair* of languages they speak in one sentence.
    func testAStandInThatCannotDoBilingualDictationSaysSo() throws {
        var inputs = healthy()
        inputs.selection = EngineSelection(
            desired: EngineKind.bilingualDictation, active: .paraformer,
            activeWhisperModelPath: nil, interimReason: .previousModel)

        let note = try XCTUnwrap(try check(.engine, inputs).note)
        XCTAssertTrue(note.contains("Mandarin"))
        XCTAssertTrue(note.contains("regenerate"), "the recording is kept, and that is the point")
    }

    func testNoUsableEngineBlocksAndSaysWhereToGo() throws {
        var inputs = healthy()
        inputs.selection = EngineSelection(
            desired: .sensevoice, active: nil, activeWhisperModelPath: nil, interimReason: nil)
        inputs.inventory = []

        let engine = try check(.engine, inputs)
        XCTAssertEqual(engine.status, .blocked)
        XCTAssertEqual(engine.destination, .model)
        XCTAssertEqual(SetupHealth.summary(for: SetupHealth.checks(inputs)), "Kongweh cannot dictate yet.")
    }

    // MARK: - The model

    func testADownloadInFlightIsReportedWithoutSoundingLikeAFault() throws {
        var inputs = healthy()
        inputs.preparation = ModelPreparation(
            engine: .paraformer, stage: .downloading(fraction: 0.3))

        let model = try check(.model, inputs)
        XCTAssertEqual(model.status, .attention)
        XCTAssertTrue(model.detail.contains("30%"))
        XCTAssertTrue(model.note?.contains("carries on") ?? false)
    }

    func testAFailedPreparationOffersTheRetryRatherThanRepeatingTheError() throws {
        var inputs = healthy()
        inputs.selection = EngineSelection(
            desired: .paraformer, active: .sensevoice, activeWhisperModelPath: nil,
            interimReason: .previousModel)
        inputs.preparationFailure = "The network connection was lost"

        let model = try check(.model, inputs)
        XCTAssertEqual(model.status, .attention)
        XCTAssertTrue(model.detail.contains("network connection"))
        XCTAssertTrue(model.note?.contains("Retry") ?? false)
    }

    /// The state a "downloaded" badge could never show.
    func testAHalfInstalledCacheIsNamedRatherThanIgnored() throws {
        var inputs = healthy()
        inputs.inventory = [
            ModelInventoryEntry(
                engine: .sensevoice, readiness: .incomplete, installedBytes: 90_000_000,
                expectedMegabytes: 240, cacheDirectories: [URL(fileURLWithPath: "/tmp/m")])
        ]

        let model = try check(.model, inputs)
        XCTAssertEqual(model.status, .attention)
        XCTAssertTrue(model.detail.contains("will not load"))
    }

    func testTheModelRowStatesWhatTheModelsAreCosting() throws {
        XCTAssertTrue(
            (try check(.model, healthy()).note ?? "").contains("MB"),
            "the disk figure is half the reason to open this pane")
    }

    // MARK: - Language and script

    /// The output script is stated only where it changes anything - Chinese, and
    /// auto-detect, which may turn out to be Chinese. The same predicate the
    /// Transcription pane shows the control with.
    func testTheChineseScriptIsNamedOnlyWhereItApplies() throws {
        XCTAssertTrue(try check(.language, healthy()).detail.contains("繁體"))

        var english = healthy()
        english.dictationLanguage = "en"
        english.selection = EngineSelection(
            desired: .fluidaudio, active: .fluidaudio, activeWhisperModelPath: nil,
            interimReason: nil)
        let detail = try check(.language, english).detail
        XCTAssertFalse(detail.contains("繁體"))
        XCTAssertFalse(detail.contains("简体"))
    }

    func testSimplifiedIsNamedInItsOwnScript() throws {
        var inputs = healthy()
        inputs.chineseOutputScript = .simplified
        XCTAssertTrue(try check(.language, inputs).detail.contains("简体"))
    }

    /// Paraformer is Mandarin-only, so somebody who has chosen it and set the
    /// language to German has a pairing nothing else will warn them about until
    /// their transcript comes back as fluent, wrong Mandarin.
    func testALanguageTheChosenEngineCannotDoIsFlagged() throws {
        var inputs = healthy()
        inputs.dictationLanguage = "de"
        inputs.selection = EngineSelection(
            desired: .paraformer, active: .paraformer, activeWhisperModelPath: nil,
            interimReason: nil)

        let language = try check(.language, inputs)
        XCTAssertEqual(language.status, .attention)
        XCTAssertTrue(language.note?.contains("German") ?? false)
        XCTAssertEqual(language.destination, .transcription)
    }

    // MARK: - Microphone and permissions

    func testNoMicrophoneGrantBlocksAndNamesTheSystemPane() throws {
        var inputs = healthy()
        inputs.isMicrophoneGranted = false

        let microphone = try check(.microphone, inputs)
        XCTAssertEqual(microphone.status, .blocked)
        XCTAssertTrue(microphone.note?.contains("System Settings") ?? false)
    }

    func testNoMicrophoneAtAllIsADifferentSentence() throws {
        var inputs = healthy()
        inputs.microphoneCount = 0

        let microphone = try check(.microphone, inputs)
        XCTAssertEqual(microphone.status, .blocked)
        XCTAssertTrue(microphone.detail.contains("No microphone"))
    }

    func testTheSelectedInputIsNamed() throws {
        XCTAssertTrue(try check(.microphone, healthy()).detail.contains("MacBook Pro Microphone"))
    }

    func testAccessibilityIsRequiredAndScreenRecordingIsNot() throws {
        var withoutAccessibility = healthy()
        withoutAccessibility.isAccessibilityGranted = false
        XCTAssertEqual(try check(.permissions, withoutAccessibility).status, .blocked)

        // Screen Recording is conditional on one shortcut and must never gate
        // the app - the same rule `PermissionsManager.isMissingRequiredPermission`
        // keeps - so a missing grant is a fact about a feature, not a fault.
        var withoutScreen = healthy()
        withoutScreen.isScreenRecordingGranted = false
        let permissions = try check(.permissions, withoutScreen)
        XCTAssertEqual(permissions.status, .ok)
        XCTAssertTrue(permissions.note?.contains("Screen Recording") ?? false)
    }

    // MARK: - The key

    func testTheTriggerInForceIsWhatIsNamed() throws {
        var mouse = healthy()
        mouse.trigger = .mouseButton(.button4)
        XCTAssertTrue(try check(.shortcut, mouse).detail.contains(MouseButton.button4.displayName))

        var modifier = healthy()
        modifier.trigger = .modifierKey(.rightCommand)
        XCTAssertTrue(
            try check(.shortcut, modifier).detail.contains(ModifierKey.rightCommand.displayName))
    }

    func testNoShortcutIsDescribedRatherThanCorrected() throws {
        var inputs = healthy()
        inputs.trigger = .none

        let shortcut = try check(.shortcut, inputs)
        XCTAssertEqual(shortcut.status, .attention)
        XCTAssertTrue(shortcut.note?.contains("menu bar") ?? false, "there is another way in")
    }

    func testACollisionBetweenTwoOfTheAppsOwnShortcutsIsReported() throws {
        var inputs = healthy()
        inputs.shortcutConflicts = [
            ShortcutConflict(keys: "⌥A", purposes: ["Ask panel", "Voice edit"])
        ]

        let shortcut = try check(.shortcut, inputs)
        XCTAssertEqual(shortcut.status, .attention)
        XCTAssertTrue(shortcut.note?.contains("⌥A") ?? false)
        XCTAssertEqual(shortcut.destination, .shortcuts)
    }

    // MARK: - Where speech goes

    /// The row that has to be exactly right. It reports configuration, not
    /// intent.
    func testADefaultInstallSaysEverythingStaysOnTheMac() throws {
        let privacy = try check(.privacy, healthy())
        XCTAssertEqual(privacy.status, .ok)
        XCTAssertTrue(privacy.detail.contains("stays on this Mac"))
    }

    func testAConfiguredCloudEngineIsStatedWithItsHost() throws {
        var inputs = healthy()
        inputs.cloudTranscriptionSelected = true
        inputs.cloudHost = "api.openai.com"

        let privacy = try check(.privacy, inputs)
        XCTAssertEqual(privacy.status, .attention)
        XCTAssertTrue(privacy.detail.contains("recordings"))
        XCTAssertTrue(privacy.detail.contains("api.openai.com"))
        XCTAssertTrue(
            privacy.note?.contains("stays on this Mac") ?? false,
            "the six on-device features must not be tarred with the same brush")
    }

    func testCloudTranslationOnItsOwnIsStatedAsTextRatherThanAudio() throws {
        var inputs = healthy()
        inputs.cloudTranslationEnabled = true

        let privacy = try check(.privacy, inputs)
        XCTAssertTrue(privacy.detail.contains("translate"))
        XCTAssertFalse(privacy.detail.contains("recordings"))
    }

    func testAnOfflineOnlyBuildSaysItHasNoCloudPathAtAll() throws {
        var inputs = healthy()
        inputs.cloudIsCompiledIn = false
        inputs.cloudTranscriptionSelected = true

        let privacy = try check(.privacy, inputs)
        XCTAssertEqual(privacy.status, .ok)
        XCTAssertTrue(privacy.detail.contains("no cloud path"))
    }

    /// Nothing on this path may say EchoForge: that is the release and storage
    /// identity, and the pane is read by users.
    func testEveryLineUsesTheProductName() {
        var inputs = healthy()
        inputs.cloudTranscriptionSelected = true
        inputs.cloudHost = "api.openai.com"
        inputs.trigger = .none
        inputs.isAccessibilityGranted = false

        for check in SetupHealth.checks(inputs) + SetupHealth.checks(healthy()) {
            XCTAssertFalse(check.title.contains("EchoForge"))
            XCTAssertFalse(check.detail.contains("EchoForge"))
            XCTAssertFalse(check.note?.contains("EchoForge") ?? false)
        }
    }

    // MARK: - The summary

    func testTheSummaryReportsTheWorstThingOnThePane() {
        var attention = healthy()
        attention.trigger = .none
        XCTAssertEqual(
            SetupHealth.summary(for: SetupHealth.checks(attention)),
            "Kongweh is ready, with a few things worth knowing.")

        var blocked = attention
        blocked.microphoneCount = 0
        XCTAssertEqual(
            SetupHealth.summary(for: SetupHealth.checks(blocked)), "Kongweh cannot dictate yet.")
    }
}

/// Which trigger is in force, and which of this app's own shortcuts collide.
final class DictationShortcutTests: XCTestCase {

    /// Resolved in the same order `ShortcutManager.setupRecordingTrigger`
    /// resolves it, or the hint names a key the app is not listening on.
    func testAMouseButtonWinsOverAModifierWhichWinsOverTheKeyboardShortcut() {
        XCTAssertEqual(
            DictationTrigger.resolve(
                mouseButton: .button4, modifierKey: .rightCommand, keyboardShortcut: "⌥`"),
            .mouseButton(.button4))
        XCTAssertEqual(
            DictationTrigger.resolve(
                mouseButton: .none, modifierKey: .rightCommand, keyboardShortcut: "⌥`"),
            .modifierKey(.rightCommand))
        XCTAssertEqual(
            DictationTrigger.resolve(
                mouseButton: .none, modifierKey: .none, keyboardShortcut: "⌥`"),
            .keyboardShortcut("⌥`"))
    }

    func testNothingBoundIsItsOwnState() {
        let trigger = DictationTrigger.resolve(
            mouseButton: .none, modifierKey: .none, keyboardShortcut: nil)

        XCTAssertEqual(trigger, .none)
        XCTAssertFalse(trigger.isBound)
        XCTAssertEqual(trigger.shortDescription, "", "a menu item cannot show a sentence")
        XCTAssertEqual(trigger.longDescription, "Not set")
    }

    /// A mouse button's symbol is unreadable on its own, so the long form is a
    /// different string rather than the same one.
    func testTheLongFormOfAMouseButtonIsReadable() {
        let trigger = DictationTrigger.mouseButton(.middle)
        XCTAssertEqual(trigger.longDescription, MouseButton.middle.displayName)
        XCTAssertNotEqual(trigger.longDescription, trigger.shortDescription)
    }

    /// The main window's hint used to re-derive the three-mode resolution
    /// inline, which is how a hint drifts into naming a key the app is not
    /// listening on. It reads `DictationTrigger.current` now; this scan fails
    /// if a second derivation grows back beside the one this type owns.
    func testTheMainWindowHintReadsTheTriggerFromTheOneResolver() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/ContentView.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("Sources are not beside the tests: \(source.path)")
        }

        guard let start = text.range(of: "var currentShortcutDescription"),
              let end = text.range(of: "\n    }", range: start.upperBound..<text.endIndex)
        else {
            XCTFail("currentShortcutDescription is gone, and this scan needs re-pointing")
            return
        }

        XCTAssertTrue(
            text[start.upperBound..<end.lowerBound].contains("DictationTrigger.current()"),
            "the main window's hint re-derives the trigger instead of asking DictationTrigger")
    }

    // MARK: - Conflicts

    func testTwoShortcutsOnTheSameKeysCollide() {
        let conflicts = ShortcutConflicts.conflicts(in: [
            AppShortcutBinding(purpose: "Ask panel", keys: "⌥A"),
            AppShortcutBinding(purpose: "Voice edit", keys: "⌥A"),
            AppShortcutBinding(purpose: "Switch engine", keys: "⌥M"),
        ])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.keys, "⌥A")
        XCTAssertEqual(conflicts.first?.purposes, ["Ask panel", "Voice edit"])
        XCTAssertTrue(conflicts.first?.message.contains("Only one") ?? false)
    }

    func testUnboundShortcutsCollideWithNothing() {
        let conflicts = ShortcutConflicts.conflicts(in: [
            AppShortcutBinding(purpose: "Ask panel", keys: nil),
            AppShortcutBinding(purpose: "Voice edit", keys: nil),
            AppShortcutBinding(purpose: "Start dictation", keys: ""),
        ])

        XCTAssertTrue(conflicts.isEmpty, "two shortcuts that do nothing cannot collide")
    }

    func testThreeOnTheSameKeysAreOneCollisionNamingAllThree() {
        let conflicts = ShortcutConflicts.conflicts(in: [
            AppShortcutBinding(purpose: "A", keys: "⌥X"),
            AppShortcutBinding(purpose: "B", keys: "⌥X"),
            AppShortcutBinding(purpose: "C", keys: "⌥X"),
        ])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.purposes.count, 3)
    }

    func testShortcutsThatDifferDoNotCollide() {
        let conflicts = ShortcutConflicts.conflicts(in: [
            AppShortcutBinding(purpose: "Ask panel", keys: "⌥A"),
            AppShortcutBinding(purpose: "Voice edit", keys: "⌥E"),
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }
}

/// What the five-second microphone test is willing to conclude, and when.
///
/// The verdict path is the whole of it: this feature exists to tell somebody
/// whether their input works, so a wrong verdict is worse than no feature.
@MainActor
final class MicrophoneTestVerdictTests: XCTestCase {

    /// A test that ran its full five seconds and heard nothing really did hear
    /// nothing: five seconds is more than three times the monitor's grace
    /// interval, so declining to answer there would be the pane refusing the one
    /// question it was asked.
    func testAFullLengthSilentTestReportsNoSignal() {
        XCTAssertGreaterThan(
            MicrophoneTestViewModel.duration, MicrophoneSignalMonitor.graceInterval * 3,
            "the full-length mapping below is only honest while this holds")
    }

    /// An early Stop inside the grace interval has gathered no evidence, and
    /// must not borrow the full-length reading. Reporting "No signal" there
    /// tells somebody who just spoke clearly to go and check an input that is
    /// working, which is the one thing a diagnostic must not do.
    func testStoppingInsideTheGraceIntervalSaysItWasTooShortRatherThanNoSignal() {
        var monitor = MicrophoneSignalMonitor()
        let start = Date()
        // Loud, clear speech - and stopped almost immediately.
        monitor.record(MicrophoneLevel(averageDecibels: -20, peakDecibels: -10), at: start)

        let verdict = monitor.signal(at: start.addingTimeInterval(0.3))
        XCTAssertEqual(
            verdict, .measuring,
            "the monitor has not looked at loudestPeak yet, which is the state the card "
                + "must report as 'too short' rather than as 'no signal'")
    }

    /// The two sentences are different claims and must not be confused: one
    /// reports a measurement, the other reports the absence of one.
    func testTheTooShortSentenceMakesNoClaimAboutTheMicrophone() {
        let tooShort = MicrophoneTestCard.tooShortText
        XCTAssertFalse(tooShort.contains("No signal"))
        XCTAssertFalse(tooShort.lowercased().contains("not reaching"))
        XCTAssertTrue(tooShort.lowercased().contains("too soon"))

        XCTAssertTrue(
            MicrophoneTestCard.verdictText(for: .noSignal).contains("Nothing is reaching"))
    }
}
