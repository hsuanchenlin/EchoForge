import XCTest

@testable import OpenSuperWhisper

/// What the app is willing to claim about a microphone, and when.
///
/// All of it is a pure function of samples and a clock, which is the point: the
/// alternative is a rule that can only be checked by plugging a headset in and
/// whispering at it. Every threshold here is stated in dBFS because that is the
/// unit it was measured in - see `MicrophoneSignalMonitor`.
final class MicrophoneSignalTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds `duration` seconds of one reading at the sample rate the recorder
    /// actually publishes at.
    private func feed(
        _ monitor: inout MicrophoneSignalMonitor,
        _ level: MicrophoneLevel,
        seconds duration: TimeInterval
    ) {
        let interval = AudioRecorder.levelSampleInterval
        var elapsed: TimeInterval = 0
        while elapsed <= duration {
            monitor.record(level, at: start.addingTimeInterval(elapsed))
            elapsed += interval
        }
    }

    // MARK: - Nothing is claimed early

    /// The first moments of a capture are not evidence. A Bluetooth input is
    /// still coming up to gain and the user has not started talking, so a
    /// verdict there would fire on almost every dictation.
    func testNothingIsClaimedInsideTheGracePeriod() {
        var monitor = MicrophoneSignalMonitor()
        feed(&monitor, .silent, seconds: MicrophoneSignalMonitor.graceInterval - 0.2)

        XCTAssertEqual(
            monitor.signal(at: start.addingTimeInterval(MicrophoneSignalMonitor.graceInterval - 0.2)),
            .measuring)
    }

    func testAMonitorThatHasSeenNothingAtAllSaysNothing() {
        let monitor = MicrophoneSignalMonitor()
        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(60)), .measuring)
    }

    // MARK: - The three diagnostics

    func testSilenceForLongEnoughIsReportedAsNoSignal() {
        var monitor = MicrophoneSignalMonitor()
        feed(&monitor, .silent, seconds: MicrophoneSignalMonitor.graceInterval + 0.5)

        XCTAssertEqual(
            monitor.signal(at: start.addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 0.5)),
            .noSignal)
    }

    func testAudibleButQuietSpeechIsReportedAsLow() {
        var monitor = MicrophoneSignalMonitor()
        // Above the noise floor, below the level speech has to reach.
        let quiet = MicrophoneLevel(averageDecibels: -44, peakDecibels: -36)
        feed(&monitor, quiet, seconds: MicrophoneSignalMonitor.graceInterval + 0.5)

        XCTAssertEqual(
            monitor.signal(at: start.addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 0.5)),
            .low)
    }

    func testOrdinarySpeechIsReportedAsGood() {
        var monitor = MicrophoneSignalMonitor()
        // Speech at a normal distance: about -20 dBFS mean, peaking near -12.
        let speech = MicrophoneLevel(averageDecibels: -20, peakDecibels: -12)
        feed(&monitor, speech, seconds: MicrophoneSignalMonitor.graceInterval + 0.5)

        XCTAssertEqual(
            monitor.signal(at: start.addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 0.5)),
            .good)
    }

    /// Clipping is the one state that is already damaging the recording, so it
    /// is raised at once rather than waiting out the grace period - the user can
    /// act on it mid-sentence and nothing else here can be acted on that fast.
    func testASingleClippedBufferIsReportedImmediately() {
        var monitor = MicrophoneSignalMonitor()
        monitor.record(MicrophoneLevel(averageDecibels: -6, peakDecibels: 0), at: start)

        XCTAssertEqual(monitor.signal(at: start), .clipping)
    }

    func testClippingExpiresRatherThanStickingForTheWholeRecording() {
        var monitor = MicrophoneSignalMonitor()
        monitor.record(MicrophoneLevel(averageDecibels: -6, peakDecibels: 0), at: start)
        // The recording carries on at an ordinary level.
        feed(&monitor, MicrophoneLevel(averageDecibels: -20, peakDecibels: -12), seconds: 3)

        XCTAssertEqual(
            monitor.signal(at: start.addingTimeInterval(3)), .good,
            "a syllable that clipped once must not label the rest of the dictation")
    }

    /// And it does not expire straight back into the grace period either: a
    /// clipped buffer inside the first second and a half leaves the capsule with
    /// nothing to say, not with a verdict it has not earned.
    func testClippingInsideTheGracePeriodFallsBackToMeasuring() {
        var monitor = MicrophoneSignalMonitor()
        monitor.record(MicrophoneLevel(averageDecibels: -6, peakDecibels: 0), at: start)

        let afterHold = start.addingTimeInterval(MicrophoneSignalMonitor.clippingHoldInterval + 0.1)
        XCTAssertLessThan(afterHold.timeIntervalSince(start), MicrophoneSignalMonitor.graceInterval)
        XCTAssertEqual(monitor.signal(at: afterHold), .measuring)
    }

    // MARK: - The rule that stops false alarms

    /// Somebody who says a sentence and then thinks for a moment has not lost
    /// their microphone. The loudest peak of the whole capture is what decides,
    /// so silence *after* speech is silence, not a fault.
    func testAPauseAfterSpeakingIsNotReportedAsNoSignal() {
        var monitor = MicrophoneSignalMonitor()
        feed(&monitor, MicrophoneLevel(averageDecibels: -20, peakDecibels: -10), seconds: 2)
        feed(&monitor, .silent, seconds: 5)

        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(7)), .good)
    }

    /// And the reverse: a capture that only ever managed a whisper stays "low"
    /// rather than being upgraded by a quiet room.
    func testTheVerdictNeverImprovesOnItsOwn() {
        var monitor = MicrophoneSignalMonitor()
        feed(&monitor, MicrophoneLevel(averageDecibels: -44, peakDecibels: -36), seconds: 2)
        feed(&monitor, .silent, seconds: 5)

        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(7)), .low)
    }

    func testResetForgetsThePreviousCapture() {
        var monitor = MicrophoneSignalMonitor()
        feed(&monitor, MicrophoneLevel(averageDecibels: -20, peakDecibels: -10), seconds: 3)
        monitor.reset()

        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(10)), .measuring)
        XCTAssertNil(monitor.startedAt)
    }

    // MARK: - The thresholds themselves

    /// The three thresholds have to be ordered, or a signal could be both too
    /// quiet and clipping.
    func testTheThresholdsAreOrdered() {
        XCTAssertLessThan(
            MicrophoneSignalMonitor.silenceDecibels, MicrophoneSignalMonitor.lowSignalDecibels)
        XCTAssertLessThan(
            MicrophoneSignalMonitor.lowSignalDecibels, MicrophoneSignalMonitor.clippingDecibels)
        XCTAssertLessThanOrEqual(MicrophoneSignalMonitor.clippingDecibels, 0)
    }

    /// The silence threshold has to sit above the meter's own floor, or a room
    /// the meter already draws as empty would never be reported as empty.
    func testSilenceIsJudgedAboveTheMetersFloor() {
        XCTAssertGreaterThan(
            MicrophoneSignalMonitor.silenceDecibels, AudioRecorder.levelSilenceDecibels,
            "a threshold at or below the floor can never be crossed by a real reading")
    }

    // MARK: - What is said about each state

    func testOnlyTheThreeProblemsSayAnything() {
        for signal in [MicrophoneSignal.measuring, .good] {
            XCTAssertFalse(signal.isDiagnostic)
            XCTAssertNil(signal.shortLabel)
            XCTAssertNil(signal.advice)
            XCTAssertNil(signal.announcement)
            XCTAssertNil(signal.symbolName)
        }

        for signal in [MicrophoneSignal.noSignal, .low, .clipping] {
            XCTAssertTrue(signal.isDiagnostic)
            XCTAssertFalse(signal.shortLabel?.isEmpty ?? true, "\(signal) has no label")
            XCTAssertFalse(signal.advice?.isEmpty ?? true, "\(signal) has no advice")
            XCTAssertFalse(signal.symbolName?.isEmpty ?? true, "\(signal) has no symbol")
        }
    }

    /// Each sentence names something the user can change. The point of these
    /// states is that a level meter alone cannot say which of them it is, so a
    /// diagnostic that only restates the meter is worth nothing.
    func testEachDiagnosticNamesSomethingToDoAboutIt() {
        XCTAssertTrue(MicrophoneSignal.noSignal.advice?.contains("input") ?? false)
        XCTAssertTrue(MicrophoneSignal.noSignal.advice?.contains("muted") ?? false)
        XCTAssertTrue(MicrophoneSignal.low.advice?.contains("distance") ?? false)
        XCTAssertTrue(MicrophoneSignal.clipping.advice?.contains("input volume") ?? false)
    }

    /// The announcement is heard once with no pane around it, so it carries the
    /// whole sentence rather than the pill's two words.
    func testTheAnnouncementCarriesMoreThanThePillDoes() {
        for signal in [MicrophoneSignal.noSignal, .low, .clipping] {
            let announcement = signal.announcement ?? ""
            XCTAssertTrue(announcement.contains(signal.shortLabel ?? "\u{0}"))
            XCTAssertTrue(announcement.contains(signal.advice ?? "\u{0}"))
        }
    }

    /// The product name, not the release identity, in anything the user reads.
    func testTheAdviceUsesTheProductName() {
        XCTAssertTrue(MicrophoneSignal.noSignal.advice?.contains("Kongweh") ?? false)
        for signal in [MicrophoneSignal.noSignal, .low, .clipping] {
            XCTAssertFalse(signal.advice?.contains("EchoForge") ?? true)
        }
    }

    // MARK: - The meter's own arithmetic

    func testNormalizedAndDecibelsAreInverses() {
        for value in stride(from: Float(0), through: 1, by: 0.1) {
            let decibels = MicrophoneLevel.decibels(forNormalized: value)
            XCTAssertEqual(AudioRecorder.normalizedLevel(decibels: decibels), value, accuracy: 0.0001)
        }
    }

    func testAReadingDescribedByItsBarHeightPeaksWhereItWasAsked() {
        let level = MicrophoneLevel.normalized(average: 0.3, peak: 0.8)
        XCTAssertEqual(level.normalizedAverage, 0.3, accuracy: 0.0001)
        XCTAssertEqual(level.normalizedPeak, 0.8, accuracy: 0.0001)
    }

    func testSilenceReadsAsSilenceOnBothScales() {
        XCTAssertEqual(MicrophoneLevel.silent.normalizedAverage, 0)
        XCTAssertEqual(MicrophoneLevel.silent.normalizedPeak, 0)
    }
}
