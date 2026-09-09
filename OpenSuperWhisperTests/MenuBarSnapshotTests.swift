import XCTest

@testable import OpenSuperWhisper

/// What the status item says, and which of the three icons it shows.
///
/// The menu used to be built straight out of four services, so the only way to
/// find out what it said in any given state was to put a Mac into that state -
/// no microphone, no model, a download half finished. `MenuBarState` is that
/// decision on its own, and this is the matrix.
final class MenuBarSnapshotTests: XCTestCase {

    private func state(
        isRecording: Bool = false,
        isProcessing: Bool = false,
        isMissingRequiredPermission: Bool = false,
        canTranscribe: Bool = true,
        shortcutsPaused: Bool = false,
        preparation: ModelPreparation? = nil
    ) -> MenuBarState {
        MenuBarState.resolve(
            isRecording: isRecording, isProcessing: isProcessing,
            isMissingRequiredPermission: isMissingRequiredPermission,
            canTranscribe: canTranscribe, shortcutsPaused: shortcutsPaused,
            preparation: preparation)
    }

    // MARK: - The five states the menu names

    func testAWorkingIdleAppIsReady() {
        XCTAssertEqual(state(), .ready)
        XCTAssertEqual(state().title, "Ready")
        XCTAssertFalse(state().isProblem)
    }

    func testEachStateIsReachable() {
        XCTAssertEqual(state(isRecording: true), .recording)
        XCTAssertEqual(state(isProcessing: true), .processing)
        XCTAssertEqual(state(isMissingRequiredPermission: true), .permissionNeeded)
        XCTAssertEqual(state(canTranscribe: false), .noEngine)
        XCTAssertEqual(state(shortcutsPaused: true), .shortcutsPaused)
        XCTAssertEqual(
            state(preparation: ModelPreparation(engine: .sensevoice, stage: .preparing)),
            .preparingModel(ModelPreparation(engine: .sensevoice, stage: .preparing)))
    }

    /// What is happening **now** wins over what is wrong: a user who is
    /// mid-dictation can see for themselves that their permissions are fine.
    func testWhatIsHappeningNowOutranksWhatIsWrong() {
        XCTAssertEqual(
            state(
                isRecording: true, isMissingRequiredPermission: true, canTranscribe: false,
                shortcutsPaused: true),
            .recording)
        XCTAssertEqual(
            state(isProcessing: true, canTranscribe: false, shortcutsPaused: true), .processing)
    }

    /// A missing permission outranks a pause, because the pause is reversible
    /// from this menu and the permission is not.
    func testAMissingPermissionOutranksAPause() {
        XCTAssertEqual(
            state(isMissingRequiredPermission: true, shortcutsPaused: true), .permissionNeeded)
    }

    /// A model preparing in the background is last of all: it is the only state
    /// in the list that stops nothing.
    func testAPreparingModelYieldsToEverythingElse() {
        let preparation = ModelPreparation(engine: .sensevoice, stage: .downloading(fraction: 0.5))
        XCTAssertEqual(state(shortcutsPaused: true, preparation: preparation), .shortcutsPaused)
        XCTAssertEqual(state(canTranscribe: false, preparation: preparation), .noEngine)
        XCTAssertEqual(state(preparation: preparation).title, preparation.statusLine)
    }

    // MARK: - The icon

    /// Three silhouettes and no animation. The two that are not "fine" are the
    /// two the user can act on: it is listening, or it is not going to answer a
    /// key press.
    func testOnlyThreeIconsAndNoneOfThemAnimate() {
        XCTAssertEqual(state(isRecording: true).icon, .recording)
        XCTAssertEqual(state(shortcutsPaused: true).icon, .paused)
        XCTAssertEqual(state(isMissingRequiredPermission: true).icon, .paused)
        XCTAssertEqual(state(canTranscribe: false).icon, .paused)
        XCTAssertEqual(state().icon, .idle)
        XCTAssertEqual(state(isProcessing: true).icon, .idle)
    }

    /// A download in the background keeps the ordinary icon: dictation carries
    /// on, so nothing about it belongs in a glance at the menu bar.
    func testAModelDownloadDoesNotChangeTheIcon() {
        XCTAssertEqual(
            state(preparation: ModelPreparation(engine: .paraformer, stage: .preparing)).icon,
            .idle)
    }

    func testEveryStateHasATitleAndUsesTheProductName() {
        let preparation = ModelPreparation(engine: .sensevoice, stage: .preparing)
        for state in [
            MenuBarState.ready, .recording, .processing, .permissionNeeded, .noEngine,
            .shortcutsPaused, .preparingModel(preparation),
        ] {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.title.contains("EchoForge"))
        }
    }

    // MARK: - The snapshot's wording

    private func snapshot(
        state: MenuBarState = .ready,
        desired: EngineKind = .sensevoice,
        active: EngineKind? = .sensevoice,
        selectable: [EngineKind] = [.sensevoice],
        canChangeEngine: Bool = true,
        trigger: DictationTrigger = .keyboardShortcut("⌥`"),
        paused: Bool = false,
        transcripts: [MenuBarTranscript] = []
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(
            state: state, desiredEngine: desired, activeEngine: active,
            selectableEngines: selectable, canChangeEngine: canChangeEngine, trigger: trigger,
            shortcutsPaused: paused, preparationFailure: nil, recentTranscripts: transcripts)
    }

    /// The desired-versus-active split, said out loud only while they differ.
    func testTheFallbackNoticeAppearsOnlyWhileAStandInIsRunning() {
        XCTAssertNil(snapshot().fallbackNotice)

        let notice = snapshot(desired: .paraformer, active: .sensevoice).fallbackNotice
        XCTAssertTrue(notice?.contains(EngineCatalog.entry(for: .sensevoice).displayName) ?? false)
        XCTAssertTrue(notice?.contains(EngineCatalog.entry(for: .paraformer).displayName) ?? false)
    }

    func testNothingRunningAtAllIsNotDescribedAsAFallback() {
        XCTAssertNil(snapshot(desired: .paraformer, active: nil).fallbackNotice)
    }

    /// One item that starts and stops, the same thing the dictation key is.
    func testTheDictationItemStopsWhatItStarted() {
        XCTAssertEqual(snapshot().dictationActionTitle, "Start Dictation")
        XCTAssertEqual(snapshot(state: .recording).dictationActionTitle, "Stop Dictation")
    }

    /// Pausing is about **shortcuts**. This app does not own the system's
    /// microphone and must never be read as switching it off.
    func testThePauseItemNamesTheShortcutsAndNeverTheMicrophone() {
        for title in [snapshot().pauseActionTitle, snapshot(paused: true).pauseActionTitle] {
            XCTAssertTrue(title.contains("Shortcuts"))
            XCTAssertFalse(title.lowercased().contains("mic"))
            XCTAssertFalse(title.lowercased().contains("mute"))
        }
        XCTAssertTrue(snapshot().pauseActionTitle.hasPrefix("Pause"))
        XCTAssertTrue(snapshot(paused: true).pauseActionTitle.hasPrefix("Resume"))

        XCTAssertTrue(MenuBarSnapshot.pausedExplanation.contains("microphone is untouched"))
    }

    /// An engine pick during a dictation would change the model decoding words
    /// that have already been spoken - the same rule `EngineCycle` applies to
    /// ⌥M, which defers rather than switching mid-session.
    func testTheEngineCannotBeChangedMidDictation() {
        XCTAssertFalse(snapshot(state: .recording, canChangeEngine: false).canChangeEngine)
    }
}

/// The rule that cannot be expressed as a type: opening the menu must not
/// read the disk or the Keychain.
///
/// A source scan rather than a behavioural test, because the failure it guards
/// against is a future edit adding one line to `snapshot()` - and because the
/// failure it *already caught* cannot be reproduced in a unit test at all. On a
/// build whose signature does not match the Keychain item, deciding the safe
/// engine list inside `menuNeedsUpdate` put a system dialog in front of it: the
/// menu never opened, and the app's whole accessibility tree went with it,
/// because `menuNeedsUpdate` had not returned. It was found by driving the real
/// status item and reading the log.
final class MenuBarMenuOpenCostTests: XCTestCase {

    private func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The body of a function, from its signature to the first line that closes
    /// it at four spaces of indentation.
    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "no function \(signature) to read")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }

    func testNothingOnTheMenuOpenPathReadsTheDiskOrTheKeychain() throws {
        let controller = try source(of: "OpenSuperWhisper/MenuBar/MenuBarController.swift")

        for signature in [
            "func menuNeedsUpdate(_ menu: NSMenu) {",
            "private func snapshot() -> MenuBarSnapshot {",
        ] {
            let body = try self.body(of: signature, in: controller)
            for forbidden in ["EngineAvailability.current", "CloudAccess.", "RecordingStore.shared"] {
                XCTAssertFalse(
                    body.contains(forbidden),
                    "\(signature) reaches \(forbidden). Opening the menu would pay for it - and "
                        + "on a build whose signature does not match the Keychain item, pay for it "
                        + "with a system dialog that never returns.")
            }
        }
    }

    /// And the cloud engine is never offered from the menu, which is the same
    /// product decision `EngineCatalog.pickerOrder` makes: one tap must not be
    /// all it takes to start sending dictation to a company.
    func testTheMenuNeverOffersTheCloudEngine() throws {
        let controller = try source(of: "OpenSuperWhisper/MenuBar/MenuBarController.swift")
        let body = try self.body(of: "private func refreshSelectableEngines() {", in: controller)

        XCTAssertTrue(
            body.contains("isCloudSelectable: false"),
            "the menu bar offers the cloud engine, which is chosen where the consent sheet is")
    }
}

/// Which stored rows reach the menu, and what one line of them looks like.
final class MenuBarTranscriptTests: XCTestCase {

    private func recording(
        transcription: String,
        status: RecordingStatus = .completed,
        provenance: RecordingProvenance = .dictation,
        timestamp: Date = Date()
    ) -> Recording {
        var row = Recording(
            id: UUID(), timestamp: timestamp, fileName: "\(UUID().uuidString).wav",
            transcription: transcription, duration: 3, status: status, progress: 1,
            sourceFileURL: nil)
        row.provenance = provenance
        return row
    }

    // MARK: - What may be shown

    func testOnlyFinishedRowsWithWordsAreOffered() {
        XCTAssertTrue(
            MenuBarTranscript.isOffered(
                status: .completed, provenance: .dictation, transcription: "hello"))
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .transcribing, provenance: .dictation, transcription: "hello"),
            "a row still being decoded has nothing settled to copy")
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .failed, provenance: .dictation, transcription: "hello"))
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .completed, provenance: .dictation, transcription: "   \n "),
            "an empty transcript would put an empty item in the menu")
    }

    /// A YouTube command's transcript is a channel name that was spoken to open
    /// a video, and an Ask capture's is a question whose answer is not in that
    /// column at all. Copy on either would hand the user nonsense.
    func testCommandsAndQuestionsAreNotOfferedAsTranscripts() {
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .completed, provenance: .ask, transcription: "what is this"))
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .completed,
                provenance: .youTubeCommandOpened(summary: "Opened Veritasium"),
                transcription: "veritasium"))
        XCTAssertFalse(
            MenuBarTranscript.isOffered(
                status: .completed,
                provenance: .youTubeCommandNotOpened(reason: .channelUnknown, message: "No match"),
                transcription: "veritasium"))
    }

    func testDictationFilesVoiceEditsAndOlderRowsAreAllOffered() {
        for provenance: RecordingProvenance in [
            .dictation, .fileTranscription, .selectionEdit(instruction: "make it formal"), .unknown,
        ] {
            XCTAssertTrue(
                MenuBarTranscript.isOffered(
                    status: .completed, provenance: provenance, transcription: "text"),
                "\(provenance.kind) produced text the user may want again")
        }
    }

    // MARK: - The preview

    /// A menu item draws a newline as a box, so a dictation with a paragraph
    /// break in it would otherwise put one in the menu bar.
    func testAPreviewIsOneLine() {
        let preview = MenuBarTranscript.preview(of: "first line\nsecond   line\t\tthird")
        XCTAssertEqual(preview, "first line second line third")
    }

    func testALongPreviewIsCutRatherThanWideningTheWholeMenu() {
        let long = String(repeating: "word ", count: 60)
        let preview = MenuBarTranscript.preview(of: long)

        XCTAssertEqual(preview.count, MenuBarTranscript.maximumPreviewCharacters)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testAShortPreviewIsLeftAlone() {
        XCTAssertEqual(MenuBarTranscript.preview(of: "把 PR 開到 feature/login"), "把 PR 開到 feature/login")
    }

    // MARK: - The list

    func testAtMostThreeAreOfferedNewestFirst() {
        let rows = (0..<10).map { recording(transcription: "row \($0)") }
        let offered = MenuBarTranscript.offered(from: rows)

        XCTAssertEqual(offered.count, MenuBarTranscript.count)
        XCTAssertEqual(offered.map(\.preview), ["row 0", "row 1", "row 2"])
    }

    func testRowsThatDoNotQualifyAreSkippedRatherThanShorteningTheList() {
        let rows = [
            recording(transcription: "asked", provenance: .ask),
            recording(transcription: "kept"),
            recording(transcription: "failed", status: .failed),
            recording(transcription: "also kept"),
            recording(transcription: "third"),
        ]

        XCTAssertEqual(
            MenuBarTranscript.offered(from: rows).map(\.preview),
            ["kept", "also kept", "third"])
    }

    /// Copy puts the **whole** transcript on the pasteboard, not the line that
    /// was shown - the preview is a label, not the content.
    func testCopyCarriesTheWholeTranscriptRatherThanThePreview() {
        let long = String(repeating: "word ", count: 60)
        let offered = MenuBarTranscript.offered(from: [recording(transcription: long)])

        XCTAssertEqual(offered.first?.full, long)
        XCTAssertNotEqual(offered.first?.preview, offered.first?.full)
    }
}
