import XCTest
@testable import OpenSuperWhisper

/// The capsule's state machine, driven the way a dictation drives it.
///
/// Both halves of the timing are injected - the clock and the auto-hide timer -
/// so these assert the badge durations and the generation guard without the suite
/// spending 1.5 seconds per case waiting for a real `DispatchQueue` deadline.
@MainActor
final class CapsuleHUDViewModelTests: XCTestCase {

    /// One pending auto-hide, as scheduled by the view model.
    private struct ScheduledHide {
        let delay: TimeInterval
        let work: () -> Void
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var scheduled: [ScheduledHide] = []

    private func makeViewModel() -> CapsuleHUDViewModel {
        CapsuleHUDViewModel(
            now: { [unowned self] in self.clock },
            schedule: { [unowned self] delay, work in
                self.scheduled.append(ScheduledHide(delay: delay, work: work))
            }
        )
    }

    /// Runs every auto-hide the view model has asked for, the way the real timer
    /// eventually would.
    private func fireScheduledHides() {
        let pending = scheduled
        scheduled = []
        for hide in pending {
            hide.work()
        }
    }

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_000_000)
        scheduled = []
    }

    // MARK: - The happy path

    func testIdleThroughRecordingAndPolishingToComplete() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.state, .idle)

        viewModel.beginSession(mode: .dictate)
        XCTAssertEqual(viewModel.state, .connecting)

        viewModel.beginRecording()
        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertEqual(viewModel.recordingStartedAt, clock)

        viewModel.beginPolishing(.transcribing)
        XCTAssertEqual(viewModel.state, .polishing(.transcribing))

        viewModel.beginPolishing(.rewriting)
        XCTAssertEqual(viewModel.state, .polishing(.rewriting))

        viewModel.complete()
        XCTAssertEqual(viewModel.state, .complete)
    }

    func testCompleteAutoHidesAfterItsOwnDuration() {
        let viewModel = makeViewModel()
        var hidden = 0
        viewModel.onHide = { hidden += 1 }

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.complete()

        XCTAssertEqual(scheduled.map(\.delay), [CapsuleHUDViewModel.completeVisibleDuration])
        XCTAssertEqual(viewModel.state, .complete)

        fireScheduledHides()
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(hidden, 1)
    }

    func testErrorAutoHidesAfterTheLongerDuration() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.fail("No speech detected")

        XCTAssertEqual(viewModel.state, .error("No speech detected"))
        XCTAssertEqual(scheduled.map(\.delay), [CapsuleHUDViewModel.errorVisibleDuration])
        XCTAssertGreaterThan(
            CapsuleHUDViewModel.errorVisibleDuration,
            CapsuleHUDViewModel.completeVisibleDuration,
            "A sentence to read needs longer on screen than a checkmark to notice"
        )

        fireScheduledHides()
        XCTAssertEqual(viewModel.state, .idle)
    }

    // MARK: - What must never show a checkmark

    func testThePolishingLabelOnlyMovesForwards() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        viewModel.beginPolishing(.rewriting)

        viewModel.follow(.decoding)

        XCTAssertEqual(
            viewModel.state, .polishing(.rewriting),
            "The engine has finished by the time the rewrite starts; saying otherwise is a lie about the wait"
        )
    }

    func testARewriteAnnouncedAfterTheSessionEndedDoesNotReopenTheCapsule() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        viewModel.dismiss()

        viewModel.beginPolishing(.rewriting)

        XCTAssertEqual(viewModel.state, .idle)
    }

    func testARewriteFromAnotherFlowDoesNotHijackARecordingCapsule() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        XCTAssertEqual(viewModel.state, .connecting)

        // A queue transcription - file drop, open-with, history regenerate -
        // raises the global rewrite flag while this dictation is still being
        // captured. Its rewrite is not this session's wait.
        viewModel.beginPolishing(.rewriting)
        XCTAssertEqual(viewModel.state, .connecting)

        viewModel.beginRecording()
        viewModel.beginPolishing(.rewriting)

        XCTAssertEqual(
            viewModel.state, .recording,
            "A rewrite may only follow this session's own decode"
        )
    }

    func testCompleteIsIgnoredWhenNothingIsInFlight() {
        let viewModel = makeViewModel()

        viewModel.complete()

        XCTAssertEqual(viewModel.state, .idle, "A capsule that is not up must not appear to report success")
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testCompleteDoesNotReplaceAMessageAlreadyOnScreen() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.fail(CapsuleHUDViewModel.noEngineMessage)
        scheduled = []

        viewModel.complete()

        XCTAssertEqual(viewModel.state, .error(CapsuleHUDViewModel.noEngineMessage))
        XCTAssertTrue(scheduled.isEmpty, "The message's own auto-hide still owns the rest of its life")
    }

    func testCancelledSessionEndsWithoutABadge() {
        let viewModel = makeViewModel()
        var cancelled = 0
        viewModel.onCancel = { cancelled += 1 }

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        viewModel.cancel()

        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(viewModel.state, .idle)

        // The cancellation makes the transcription fail, and that failure comes
        // back through the session's outcome. It must not resurrect the capsule.
        viewModel.finish(result: nil)
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testCancelOnlyAppliesWhileThereIsWorkToCancel() {
        let viewModel = makeViewModel()
        var cancelled = 0
        viewModel.onCancel = { cancelled += 1 }

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.cancel()

        XCTAssertEqual(cancelled, 0, "The capsule offers no cancel button while recording")
        XCTAssertEqual(viewModel.state, .recording)
    }

    // MARK: - Ending a session

    func testEndWithoutBadgeDismissesAnActiveCapsule() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.endWithoutBadge()

        XCTAssertEqual(viewModel.state, .idle)
    }

    func testEndWithoutBadgeLeavesATerminalBadgeAlone() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.complete()
        viewModel.endWithoutBadge()

        XCTAssertEqual(viewModel.state, .complete)
    }

    func testFinishMapsEveryOutcomeOntoWhatIsShown() {
        for (result, expected) in [
            (DictationResult.inserted(styleNotice: nil), CapsuleHUDState.complete),
            (DictationResult.inserted(styleNotice: "Kept the original: it drops the number \"42\"."),
             CapsuleHUDState.error("Kept the original: it drops the number \"42\".")),
            (DictationResult.noSpeech, CapsuleHUDState.error("No speech detected")),
            (DictationResult.failed("The audio could not be transcribed."),
             CapsuleHUDState.error("The audio could not be transcribed."))
        ] {
            let viewModel = makeViewModel()
            viewModel.beginSession(mode: .dictate)
            viewModel.beginRecording()
            viewModel.beginPolishing(.transcribing)

            viewModel.finish(result: result)

            XCTAssertEqual(viewModel.state, expected, "for \(result)")
        }
    }

    func testARefusedRewriteBadgeStaysUpAsLongAsAnyOtherSentence() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: CapsuleHUDMode(label: "Polish"))
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        viewModel.beginPolishing(.rewriting)

        viewModel.finish(result: .inserted(styleNotice: "Kept the original: the rewrite took too long."))

        XCTAssertEqual(
            viewModel.state, .error("Kept the original: the rewrite took too long."),
            "The text was inserted either way; the badge is where the kept-the-original story is told"
        )
        XCTAssertEqual(scheduled.map(\.delay), [CapsuleHUDViewModel.errorVisibleDuration])
    }

    // MARK: - A stale auto-hide

    func testAHideLeftOverFromTheLastDictationDoesNotCloseTheNextOne() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.complete()

        // The user starts talking again inside the badge's 1.5 seconds.
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        fireScheduledHides()

        XCTAssertEqual(viewModel.state, .recording, "The previous session's hide must not take this capsule away")
    }

    func testASecondSessionStartsFromACleanCapsule() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: CapsuleHUDMode(label: "Polish"))
        viewModel.beginRecording()
        viewModel.pushLevel(.normalized(average: 0.8))
        viewModel.dismiss()

        clock = clock.addingTimeInterval(30)
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        XCTAssertEqual(viewModel.mode, .dictate)
        XCTAssertEqual(viewModel.levels, [])
        XCTAssertEqual(viewModel.recordingStartedAt, clock)
    }

    // MARK: - Following the indicator

    func testFollowingTheIndicatorsOwnStates() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)

        viewModel.follow(.connecting)
        XCTAssertEqual(viewModel.state, .connecting)

        viewModel.follow(.recording)
        XCTAssertEqual(viewModel.state, .recording)

        viewModel.follow(.decoding)
        XCTAssertEqual(viewModel.state, .polishing(.transcribing))

        viewModel.follow(.noMicrophone)
        XCTAssertEqual(viewModel.state, .error("No microphone"))

        viewModel.follow(.noEngine)
        XCTAssertEqual(viewModel.state, .error(CapsuleHUDViewModel.noEngineMessage))
    }

    func testTheTwoBusyPathsGetTheirOwnSentences() {
        let stopped = makeViewModel()
        stopped.beginSession(mode: .dictate)
        stopped.beginRecording()
        stopped.follow(.busy(.audioQueued))
        XCTAssertEqual(
            stopped.state, .error("Still transcribing - queued"),
            "Stopping while busy really does queue the audio"
        )

        let refused = makeViewModel()
        refused.beginSession(mode: .dictate)
        refused.follow(.busy(.startRefused))
        XCTAssertEqual(
            refused.state, .error("Busy - try again in a moment"),
            "A refused start captured nothing and queued nothing, so it must not say 'queued'"
        )
    }

    // MARK: - The channel picker's wait

    /// The card and the capsule are two presentations of one session, and the
    /// card stops showing a spinner while the picker waits on the user. The
    /// capsule must not keep claiming the engine is still running either.
    func testThePickersWaitIsNotShownAsTranscribing() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.follow(.decoding)
        XCTAssertEqual(viewModel.state, .polishing(.transcribing))

        viewModel.follow(.awaitingChannelChoice)

        XCTAssertEqual(
            viewModel.state, .awaitingChannelChoice,
            "The picker waits on the user, so \"Transcribing…\" would be a lie about the wait"
        )
    }

    /// The wait is not a failure and not an ending: the session is still in
    /// flight and finishes on whatever the user chooses in the picker.
    func testTheSessionStillFinishesFromThePickersWait() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.follow(.awaitingChannelChoice)

        // Chosen, and the video opened: Chrome is in front of the user, which
        // is a clearer answer than a checkmark drawn over the top of it.
        viewModel.finish(result: .openedVideo(channel: "valley101"))
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testARefusalAfterThePickerReplacesTheWait() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.follow(.awaitingChannelChoice)

        viewModel.follow(.commandFailed("You cancelled the choice"))

        XCTAssertEqual(viewModel.state, .error("You cancelled the choice"))
        XCTAssertEqual(scheduled.map(\.delay), [CapsuleHUDViewModel.errorVisibleDuration])
    }

    /// The same guards `beginPolishing` carries: a picker announced for a
    /// session that has already ended must not reopen the capsule or take a
    /// badge down before it was read.
    func testThePickersWaitDoesNotReopenAnIdleCapsuleOrReplaceABadge() {
        let idle = makeViewModel()
        idle.follow(.awaitingChannelChoice)
        XCTAssertEqual(idle.state, .idle)

        let done = makeViewModel()
        done.beginSession(mode: .dictate)
        done.beginRecording()
        done.complete()
        done.follow(.awaitingChannelChoice)
        XCTAssertEqual(done.state, .complete)
    }

    // MARK: - The Esc confirmation

    func testTheFirstEscIsVisiblyAcknowledgedWhileRecording() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.setCancelConfirmation(true)
        XCTAssertFalse(viewModel.isConfirmingCancel, "There is no recording yet to confirm cancelling")

        viewModel.beginRecording()
        viewModel.setCancelConfirmation(true)
        XCTAssertTrue(viewModel.isConfirmingCancel)
        XCTAssertEqual(viewModel.state, .recording, "The confirmation changes what the pill says, not the session")

        viewModel.setCancelConfirmation(false)
        XCTAssertFalse(viewModel.isConfirmingCancel, "The confirmation window lapsing takes the message with it")
    }

    func testACancelConfirmationDoesNotSurviveTheSession() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.setCancelConfirmation(true)
        viewModel.dismiss()
        XCTAssertFalse(viewModel.isConfirmingCancel)

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.setCancelConfirmation(true)
        viewModel.beginPolishing(.transcribing)
        viewModel.finish(result: .inserted(styleNotice: nil))
        viewModel.beginSession(mode: .dictate)
        XCTAssertFalse(
            viewModel.isConfirmingCancel,
            "A fresh capsule must not open onto the previous session's warning"
        )
    }

    func testConnectingDoesNotStartTheTimer() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.follow(.connecting)

        XCTAssertNil(
            viewModel.recordingStartedAt,
            "Time spent reaching a Bluetooth microphone is not in the recording"
        )

        clock = clock.addingTimeInterval(2)
        viewModel.follow(.recording)

        XCTAssertEqual(viewModel.recordingStartedAt, clock)
        XCTAssertEqual(viewModel.elapsed(at: clock.addingTimeInterval(5)), 5, accuracy: 0.001)
    }

    // MARK: - The mode chip

    func testTheChipNamesPlainDictationWhenNothingWillRewriteIt() {
        XCTAssertEqual(CapsuleHUDMode.forStyleRewrite(.disabled, availability: .available), .dictate)
    }

    func testTheChipNamesTheStyleThatWillRun() {
        let polish = StyleRewriteConfiguration(
            isEnabled: true,
            style: StyleRewriteCatalog.style(forStoredID: "polish"),
            customPrompt: ""
        )

        XCTAssertEqual(
            CapsuleHUDMode.forStyleRewrite(polish, availability: .available).label,
            StyleRewriteCatalog.style(forStoredID: "polish").shortName
        )
    }

    /// Rewriting is on by default, so a Mac that cannot run the on-device model
    /// arrives here with a runnable configuration on every dictation. The chip
    /// still has to say what is actually going to happen to the words, which is
    /// nothing.
    func testTheChipPromisesNoRewriteOnAMacThatCannotRunOne() {
        let polish = StyleRewriteConfiguration(
            isEnabled: true,
            style: StyleRewriteCatalog.style(forStoredID: "polish"),
            customPrompt: ""
        )

        XCTAssertEqual(
            CapsuleHUDMode.forStyleRewrite(polish, availability: .appleIntelligenceOff), .dictate
        )
        XCTAssertEqual(
            CapsuleHUDMode.forStyleRewrite(polish, availability: .unsupportedSystem), .dictate
        )
        XCTAssertEqual(
            CapsuleHUDMode.forStyleRewrite(polish, availability: .modelNotReady), .dictate
        )
    }

    func testTheChipPromisesNoRewriteForACustomStyleWithNoPrompt() {
        let unwritten = StyleRewriteConfiguration(
            isEnabled: true,
            style: StyleRewriteCatalog.style(forStoredID: StyleRewriteStyle.customID),
            customPrompt: "   "
        )

        XCTAssertEqual(CapsuleHUDMode.forStyleRewrite(unwritten, availability: .available), .dictate)
    }

    func testEveryStyleHasAChipLabelShortEnoughForThePill() {
        for style in StyleRewriteCatalog.styles {
            XCTAssertFalse(style.shortName.isEmpty, "\(style.id) has no chip label")
            XCTAssertLessThanOrEqual(
                style.shortName.count, 10,
                "\(style.id)'s chip label does not fit a 40 pt pill"
            )
        }
    }

    // MARK: - The chip renaming itself for a spoken command

    /// The chip is set from preferences when the session starts, because that
    /// is everything that can be known before the words exist. A spoken command
    /// is only recognised once they do, which is during the decode.
    func testASpokenCommandRenamesTheChipDuringTheDecode() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)

        viewModel.setMode(.ask)

        XCTAssertEqual(viewModel.mode, .ask)
        XCTAssertEqual(viewModel.mode.label, "Ask")
    }

    func testATranslationChipNamesTheLanguage() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)

        viewModel.setMode(.translate(to: SpokenTranslationTarget(languageCode: "es")))

        XCTAssertEqual(viewModel.mode.label, "Translate Spanish")
    }

    /// `SpokenIntentActivity` is global, and every transcription flow passes
    /// through it. A queue item's routing - file drop, open-with, history
    /// regenerate - must not relabel a recording that is still in progress, so
    /// the chip only changes while the capsule is showing its own decode.
    func testARoutingVerdictCannotRelabelASessionThatIsNotDecoding() {
        for arrange in [
            { (viewModel: CapsuleHUDViewModel) in },
            { $0.beginSession(mode: .dictate) },
            { $0.beginSession(mode: .dictate); $0.beginRecording() },
            { $0.beginSession(mode: .dictate); $0.beginRecording(); $0.complete() },
            { $0.beginSession(mode: .dictate); $0.beginRecording(); $0.fail("No speech detected") },
        ] {
            let viewModel = makeViewModel()
            arrange(viewModel)
            let before = viewModel.mode

            viewModel.setMode(.ask)

            XCTAssertEqual(viewModel.mode, before, "state \(viewModel.state) accepted a chip change")
        }
    }

    /// A question's answer goes to the Ask panel, so the capsule has nothing
    /// left to say - and a checkmark reading "Inserted" over the panel would be
    /// saying something that did not happen.
    func testAQuestionEndsTheCapsuleWithoutABadge() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        viewModel.setMode(.ask)

        viewModel.finish(result: .asked)

        XCTAssertEqual(viewModel.state, .idle)
    }

    // MARK: - The level meter

    func testLevelsAreOnlyCollectedWhileRecording() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        viewModel.pushLevel(.normalized(average: 0.5))
        XCTAssertEqual(viewModel.levels, [], "Nothing is being captured while the microphone is being reached")

        viewModel.beginRecording()
        viewModel.pushLevel(.normalized(average: 0.5))
        XCTAssertEqual(viewModel.levels, [0.5])

        viewModel.beginPolishing(.transcribing)
        viewModel.pushLevel(.normalized(average: 0.9))
        XCTAssertEqual(viewModel.levels, [0.5], "A late meter sample must not extend a finished waveform")
    }

    func testTheWaveformKeepsOnlyItsMostRecentSamples() throws {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        let total = CapsuleHUDViewModel.waveformSampleCount + 5
        for index in 0 ..< total {
            viewModel.pushLevel(.normalized(average: Float(index) / Float(total)))
        }

        XCTAssertEqual(viewModel.levels.count, CapsuleHUDViewModel.waveformSampleCount)
        XCTAssertEqual(
            try XCTUnwrap(viewModel.levels.last),
            Float(total - 1) / Float(total),
            accuracy: 0.001,
            "The newest sample is the last one, which is the edge the waveform grows from"
        )
    }

    func testLevelsAreClampedToWhatTheMeterCanDraw() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        // Below the meter's floor and above its ceiling, in the dBFS the
        // hardware actually reports.
        viewModel.pushLevel(MicrophoneLevel(averageDecibels: -300, peakDecibels: -300))
        viewModel.pushLevel(MicrophoneLevel(averageDecibels: 12, peakDecibels: 12))

        XCTAssertEqual(viewModel.levels, [0, 1])
    }

    func testTheMeterIsAtRestInASilentRoomAndFullWhenClipping() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: -160), 0, accuracy: 0.001)
        XCTAssertEqual(
            AudioRecorder.normalizedLevel(decibels: AudioRecorder.levelSilenceDecibels), 0, accuracy: 0.001
        )
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: 0), 1, accuracy: 0.001)
        // Speech at a normal distance averages about -20 dBFS, and has to look
        // like something is happening.
        XCTAssertGreaterThan(AudioRecorder.normalizedLevel(decibels: -20), 0.4)
        XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: -.infinity), 0)
    }

    // MARK: - What the meter is allowed to say

    /// The diagnostic follows the same rule the bars do: it belongs to a capture
    /// that is running. A sample arriving after the microphone was given back
    /// would otherwise let one dictation's tail raise a warning over the next.
    func testTheSignalIsOnlyJudgedWhileRecording() {
        let viewModel = makeViewModel()

        viewModel.beginSession(mode: .dictate)
        clock = clock.addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 1)
        viewModel.pushLevel(.silent)
        XCTAssertEqual(viewModel.signal, .measuring, "nothing is being captured yet")

        viewModel.beginRecording()
        viewModel.pushLevel(.silent)
        clock = clock.addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 1)
        viewModel.pushLevel(.silent)
        XCTAssertEqual(viewModel.signal, .noSignal)

        viewModel.beginPolishing(.transcribing)
        viewModel.pushLevel(.normalized(average: 0.9, peak: 1))
        XCTAssertEqual(
            viewModel.signal, .noSignal,
            "a late sample must not revise the verdict on a capture that is over")
    }

    func testASilentCaptureReportsNoSignalWithoutABarEverMoving() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate, microphoneName: "MacBook Pro Microphone")
        viewModel.beginRecording()

        for _ in 0 ..< 40 {
            viewModel.pushLevel(.silent)
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }

        XCTAssertEqual(viewModel.signal, .noSignal)
        XCTAssertEqual(viewModel.levels.allSatisfy { $0 == 0 }, true, "no fake activity is drawn")
        XCTAssertEqual(viewModel.microphoneName, "MacBook Pro Microphone")
    }

    func testOrdinarySpeechNeverRaisesADiagnostic() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        for _ in 0 ..< 80 {
            viewModel.pushLevel(MicrophoneLevel(averageDecibels: -20, peakDecibels: -11))
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }

        XCTAssertEqual(viewModel.signal, .good)
    }

    /// The one channel VoiceOver has here fires on entry, never per sample: the
    /// meter publishes twenty readings a second, and twenty announcements a
    /// second is the one way this feature could do harm.
    func testEachDiagnosticIsAnnouncedOnceAndOnlyOnEntry() {
        let viewModel = makeViewModel()
        var announced: [MicrophoneSignal] = []
        viewModel.onSignalDiagnostic = { announced.append($0) }

        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        for _ in 0 ..< 80 {
            viewModel.pushLevel(.silent)
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }

        XCTAssertEqual(announced, [.noSignal])

        // A clipped buffer is a different state and is worth saying; going back
        // to silence afterwards is not.
        viewModel.pushLevel(MicrophoneLevel(averageDecibels: -4, peakDecibels: 0))
        clock = clock.addingTimeInterval(MicrophoneSignalMonitor.clippingHoldInterval + 0.1)
        for _ in 0 ..< 10 {
            viewModel.pushLevel(.silent)
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }

        XCTAssertEqual(announced, [.noSignal, .clipping])
    }

    func testANewSessionStartsFromNoOpinionAgain() {
        let viewModel = makeViewModel()
        var announced: [MicrophoneSignal] = []
        viewModel.onSignalDiagnostic = { announced.append($0) }

        viewModel.beginSession(mode: .dictate, microphoneName: "Amiron wireless")
        viewModel.beginRecording()
        for _ in 0 ..< 80 {
            viewModel.pushLevel(.silent)
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }
        XCTAssertEqual(viewModel.signal, .noSignal)

        viewModel.beginSession(mode: .dictate, microphoneName: "MacBook Pro Microphone")
        XCTAssertEqual(viewModel.signal, .measuring)
        XCTAssertEqual(viewModel.microphoneName, "MacBook Pro Microphone")

        viewModel.beginRecording()
        for _ in 0 ..< 80 {
            viewModel.pushLevel(.silent)
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }
        XCTAssertEqual(
            announced, [.noSignal, .noSignal],
            "the second capture is a second chance to tell the user")
    }

    func testTheDiagnosticLineNamesTheInputWhenThereIsOneToName() {
        XCTAssertEqual(
            CapsuleHUDView.signalDiagnosticText(.noSignal, microphoneName: "Amiron wireless"),
            "No signal · Amiron wireless")
        XCTAssertEqual(
            CapsuleHUDView.signalDiagnosticText(.low, microphoneName: nil), "Low signal")
        XCTAssertEqual(
            CapsuleHUDView.signalDiagnosticText(.low, microphoneName: ""), "Low signal")
        XCTAssertNil(CapsuleHUDView.signalDiagnosticText(.good, microphoneName: "Anything"))
        XCTAssertNil(CapsuleHUDView.signalDiagnosticText(.measuring, microphoneName: "Anything"))
    }

    /// Colour never carries a diagnostic on its own - the second line says the
    /// same thing in words - and a merely quiet recording is not painted as a
    /// warning, because a warning colour on every quiet dictation stops being read.
    func testOnlyTheTwoDamagingStatesChangeTheMetersColour() {
        XCTAssertEqual(CapsuleHUDWaveform.tint(for: .noSignal), .orange)
        XCTAssertEqual(CapsuleHUDWaveform.tint(for: .clipping), .orange)
        XCTAssertEqual(CapsuleHUDWaveform.tint(for: .low), .accentColor)
        XCTAssertEqual(CapsuleHUDWaveform.tint(for: .good), .accentColor)
        XCTAssertEqual(CapsuleHUDWaveform.tint(for: .measuring), .accentColor)
    }

    // MARK: - The duration

    func testDurationTextHoldsItsShapeAsItRuns() {
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 0), "0:00")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 0.9), "0:00")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 7.9), "0:07")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 59), "0:59")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 60), "1:00")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 65), "1:05")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 3599), "59:59")
    }

    func testDurationTextGrowsAnHoursFieldOnlyWhenItNeedsOne() {
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 3600), "1:00:00")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 3661), "1:01:01")
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: 36000), "10:00:00")
    }

    func testDurationTextNeverShowsNegativeTime() {
        XCTAssertEqual(CapsuleHUDViewModel.durationText(for: -5), "0:00")
    }

    func testElapsedIsZeroBeforeCaptureStarts() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.elapsed(at: clock), 0)

        viewModel.beginSession(mode: .dictate)
        XCTAssertEqual(viewModel.elapsed(at: clock.addingTimeInterval(10)), 0)
    }

    func testElapsedNeverRunsBackwards() {
        let viewModel = makeViewModel()
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        XCTAssertEqual(viewModel.elapsed(at: clock.addingTimeInterval(-30)), 0)
    }

    // MARK: - Where the pill lands

    /// A 27" display with a 25 pt menu bar, in the coordinates AppKit reports.
    private static let display = (
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visible: CGRect(x: 0, y: 0, width: 2560, height: 1415)
    )

    /// Where the pill itself ends up, given where the panel was put.
    private func pillTop(forOrigin origin: NSPoint, windowSize: CGSize) -> CGFloat {
        origin.y + windowSize.height - CapsuleHUDView.pillTopInset
    }

    func testThePillHangsBelowTheMenuBarAndIsCentred() {
        let size = CapsuleHUDView.windowSize
        let origin = CapsuleHUDWindowController.origin(
            visibleFrame: Self.display.visible, screenFrame: Self.display.frame, windowSize: size
        )

        XCTAssertEqual(origin.x + size.width / 2, Self.display.visible.midX, accuracy: 0.001)
        XCTAssertEqual(
            pillTop(forOrigin: origin, windowSize: size),
            Self.display.visible.maxY - CapsuleHUDWindowController.topMargin,
            accuracy: 0.001,
            "The pill, not the panel around it, is what has to clear the menu bar"
        )
    }

    func testTheTransparentTopMarginIsNotClampedOntoTheScreen() {
        let size = CapsuleHUDView.windowSize
        let origin = CapsuleHUDWindowController.origin(
            visibleFrame: Self.display.visible, screenFrame: Self.display.frame, windowSize: size
        )

        XCTAssertGreaterThan(
            origin.y + size.height,
            Self.display.visible.maxY,
            "Clamping the whole panel inside the visible frame would drop the pill by half the margin"
        )
    }

    func testAScreenSmallerThanThePanelStillPutsItOnScreen() {
        let size = CapsuleHUDView.windowSize
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 60)
        let origin = CapsuleHUDWindowController.origin(
            visibleFrame: tiny, screenFrame: tiny, windowSize: size
        )

        XCTAssertEqual(origin.x, tiny.minX, "Clamped to the left edge rather than centred off it")
        XCTAssertGreaterThanOrEqual(origin.y, tiny.minY)
    }

    /// The pill has two heights, and the taller one must grow **downwards**: the
    /// panel's top margin is transparent and deliberately overlaps the menu bar,
    /// so a pill centred in the panel would climb into it as it grew.
    func testAnExpandedPillGrowsDownwardsRatherThanIntoTheMenuBar() {
        XCTAssertGreaterThan(
            CapsuleHUDView.expandedCapsuleHeight, CapsuleHUDView.capsuleHeight)
        XCTAssertLessThanOrEqual(
            CapsuleHUDView.pillTopInset + CapsuleHUDView.expandedCapsuleHeight,
            CapsuleHUDView.windowSize.height,
            "the expanded pill has to fit inside the panel, shadow margin and all")

        let size = CapsuleHUDView.windowSize
        let origin = CapsuleHUDWindowController.origin(
            visibleFrame: Self.display.visible, screenFrame: Self.display.frame, windowSize: size
        )
        XCTAssertEqual(
            pillTop(forOrigin: origin, windowSize: size),
            Self.display.visible.maxY - CapsuleHUDWindowController.topMargin,
            accuracy: 0.001,
            "the pill's top is the same whichever height it is drawn at")
    }

    /// The engine-switch pill sits below the capsule's slot, and the slot it has
    /// to clear is the tallest the capsule can be: a capsule reporting a
    /// microphone problem is exactly the one that must not be covered up.
    func testTheEngineSwitchPillClearsTheExpandedCapsule() {
        XCTAssertGreaterThanOrEqual(
            EngineSwitchHUD.capsuleClearance, CapsuleHUDView.expandedCapsuleHeight)
    }

    func testTheSecondScreenGetsItsOwnCoordinates() {
        let size = CapsuleHUDView.windowSize
        let right = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
        let origin = CapsuleHUDWindowController.origin(
            visibleFrame: right, screenFrame: right, windowSize: size
        )

        XCTAssertEqual(origin.x + size.width / 2, right.midX, accuracy: 0.001)
        XCTAssertEqual(
            pillTop(forOrigin: origin, windowSize: size),
            right.maxY - CapsuleHUDWindowController.topMargin,
            accuracy: 0.001
        )
    }
}
