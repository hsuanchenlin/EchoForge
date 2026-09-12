import XCTest
@testable import OpenSuperWhisper

/// The cut policy for live dictation, stated as the numbers it is: where a
/// pause is allowed to end an utterance, when the minimum holds one back, what
/// the cap forces, what the tail at stop keeps - and, over every layout a
/// generator can produce, that no cut ever lands inside speech.
///
/// Nothing here needs audio: the policy reads the VAD's segments, and the
/// fixtures state segments directly.
final class LiveCutPolicyTests: XCTestCase {

    private let sampleRate = LiveCutBudget.sampleRate

    /// Whisper's numbers, spelled out so a test reads as seconds.
    private let whisper = LiveCutBudget(minimumSpeechSeconds: 8, pauseSeconds: 0.7, maximumSeconds: 28)

    // MARK: - Fixtures

    private func samples(_ seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }

    private func segment(_ start: Double, _ end: Double) -> WhisperVadSegment {
        WhisperVadSegment(startCs: Int64((start * 100).rounded()), endCs: Int64((end * 100).rounded()))
    }

    private func cut(
        _ segments: [WhisperVadSegment],
        buffer seconds: Double,
        budget: LiveCutBudget? = nil
    ) -> LiveCutDecision {
        LiveCutPolicy.cut(segments: segments, bufferLength: samples(seconds), budget: budget ?? whisper)
    }

    private func tail(
        _ segments: [WhisperVadSegment],
        buffer seconds: Double,
        budget: LiveCutBudget? = nil
    ) -> LiveCutDecision {
        LiveCutPolicy.tail(segments: segments, bufferLength: samples(seconds), budget: budget ?? whisper)
    }

    private func commit(upTo seconds: Double) -> LiveCutDecision {
        .commit(0..<samples(seconds))
    }

    private func discard(upTo seconds: Double) -> LiveCutDecision {
        .discard(0..<samples(seconds))
    }

    // MARK: - Pause

    /// The ordinary case: enough speech, then a pause. The cut is padded 0.1 s
    /// into the pause, the way the segmenter keeps 0.1 s after every segment.
    func testAPauseAfterEnoughSpeechEndsTheUtterance() {
        XCTAssertEqual(cut([segment(0, 10)], buffer: 10.7), commit(upTo: 10.1))
    }

    func testSilenceShorterThanAPauseIsNotAPause() {
        XCTAssertEqual(cut([segment(0, 10)], buffer: 10.69), .wait)
    }

    func testSpeechStillGoingIsNotAPause() {
        XCTAssertEqual(cut([segment(0, 10)], buffer: 10), .wait)
    }

    /// The pause is measured against the buffer end or the next segment - a
    /// 0.2 s breath between two segments is not one, and the buffer is not cut
    /// there even though the speech before it clears the minimum.
    func testABreathBetweenSegmentsIsNotAPause() {
        let segments = [segment(0, 3), segment(3.2, 6.5), segment(6.7, 9)]
        XCTAssertEqual(cut(segments, buffer: 9.5), .wait)
        XCTAssertEqual(cut(segments, buffer: 10), commit(upTo: 9.1))
    }

    /// When the buffer holds two qualifying pauses the later one wins: the
    /// utterance is as long as a pause allows.
    func testTheLatestQualifyingPauseIsChosen() {
        let segments = [segment(0, 9), segment(10, 12)]
        XCTAssertEqual(cut(segments, buffer: 12.8), commit(upTo: 12.1))
        XCTAssertEqual(cut(segments, buffer: 12.3), commit(upTo: 9.1), "the later gap is 0.3 s, not a pause")
    }

    /// Leading silence is part of the utterance when it is too short to be
    /// released on its own; the engine's VAD drops it.
    func testShortLeadingSilenceIsCommittedWithTheSpeech() {
        XCTAssertEqual(cut([segment(0.5, 9)], buffer: 10), commit(upTo: 9.1))
    }

    // MARK: - Minimum

    func testAPauseAfterTooLittleSpeechWaits() {
        XCTAssertEqual(cut([segment(0, 7.9)], buffer: 10), .wait)
        XCTAssertEqual(cut([segment(0, 8)], buffer: 10), commit(upTo: 8.1))
    }

    /// The minimum is detected speech, summed over segments, not the span they
    /// cover: two seconds of words around a long silence is two seconds.
    func testTheMinimumIsSummedSpeechNotSpan() {
        let sparse = [segment(0, 1), segment(8, 9)]
        XCTAssertEqual(cut(sparse, buffer: 10), .wait)

        let dense = [segment(0, 4), segment(4.2, 8.2)]
        XCTAssertEqual(cut(dense, buffer: 9), commit(upTo: 8.3))
    }

    // MARK: - Cap

    func testBelowTheCapTheMinimumHolds() {
        XCTAssertEqual(cut([segment(0, 2)], buffer: 27.9), .wait)
    }

    /// At the cap the minimum no longer applies: two seconds of speech
    /// followed by silence is committed as it is rather than held forever.
    func testTheCapOverridesTheMinimum() {
        XCTAssertEqual(cut([segment(0, 2)], buffer: 28), commit(upTo: 2.1))
    }

    /// A forced cut prefers the longest silence within the last 5 s of the
    /// cap, so the utterance stays long and the cut sits in the widest gap
    /// there is.
    func testTheCapCutsAtTheLongestGapNearTheCap() {
        let segments = [segment(0, 15), segment(15.4, 24), segment(24.2, 26), segment(26.3, 30)]
        XCTAssertEqual(cut(segments, buffer: 30), commit(upTo: 26.1))
    }

    /// A gap of 0.2 s is cut in its middle: the padding never reaches the next
    /// word.
    func testAForcedCutInANarrowGapStaysInItsMiddle() {
        let segments = [segment(0, 20), segment(20.2, 30)]
        XCTAssertEqual(cut(segments, buffer: 30), commit(upTo: 20.1))

        let narrower = [segment(0, 20), segment(20.1, 30)]
        XCTAssertEqual(cut(narrower, buffer: 30), commit(upTo: 20.05))
    }

    /// With no gap near the cap, the latest gap anywhere in the buffer is used.
    func testTheCapFallsBackToTheLatestGap() {
        let segments = [segment(0, 10), segment(10.2, 15), segment(15.4, 30)]
        XCTAssertEqual(cut(segments, buffer: 30), commit(upTo: 15.1))
    }

    /// A tie in the window goes to the later gap.
    func testEqualGapsInTheWindowGoToTheLaterOne() {
        let segments = [segment(0, 24), segment(24.2, 26), segment(26.2, 30)]
        XCTAssertEqual(cut(segments, buffer: 30), commit(upTo: 26.1))
    }

    /// Speech that runs past the cap without a single VAD gap is not cut at
    /// the cap sample. Bounding the buffer is the session's job; a split word
    /// is a wrong paste.
    func testUnbrokenSpeechAtTheCapWaits() {
        XCTAssertEqual(cut([segment(0, 30)], buffer: 30), .wait)
        XCTAssertEqual(cut([segment(0, 60)], buffer: 60), .wait)
    }

    /// The committed range never exceeds the cap, even by the padding.
    func testTheCommittedRangeNeverExceedsTheCap() {
        let segments = [segment(0, 27.95), segment(28.5, 32)]
        XCTAssertEqual(cut(segments, buffer: 32), commit(upTo: 28))

        let past = [segment(0, 28.5), segment(29, 32)]
        XCTAssertEqual(cut(past, buffer: 32), .wait, "the only gap ends past the cap")
    }

    // MARK: - Leading silence

    func testSilenceShorterThanTwoPausesIsKept() {
        XCTAssertEqual(cut([], buffer: 1.39), .wait)
    }

    /// With no speech found yet, everything but a pause's worth is released.
    func testLeadingSilenceIsReleasedKeepingAPauseOfMargin() {
        XCTAssertEqual(cut([], buffer: 1.4), discard(upTo: 0.7))
        XCTAssertEqual(cut([], buffer: 20), discard(upTo: 19.3))
    }

    /// Silence before a segment the VAD has already found is released up to
    /// the cut padding before it, so it does not count against the cap.
    func testSilenceBeforeFoundSpeechIsReleased() {
        XCTAssertEqual(cut([segment(20, 25)], buffer: 25), discard(upTo: 19.9))
    }

    func testSilenceBeforeFoundSpeechIsReleasedBeforeTheCapForcesACut() {
        let segments = [segment(20, 24), segment(24.2, 28)]
        XCTAssertEqual(cut(segments, buffer: 28), discard(upTo: 19.9))
    }

    /// A commit that is ready is not delayed by leading silence.
    func testAReadyCommitBeatsReleasingLeadingSilence() {
        XCTAssertEqual(cut([segment(5, 14)], buffer: 15), commit(upTo: 14.1))
    }

    // MARK: - Tail

    func testTheTailIsTheWholeRemainderWhenItHoldsSpeech() {
        XCTAssertEqual(tail([segment(0.2, 0.7)], buffer: 1), commit(upTo: 1))
        XCTAssertEqual(tail([segment(0, 40)], buffer: 40), commit(upTo: 40), "the tail is never cut")
    }

    func testATailWithTooLittleSpeechIsDropped() {
        XCTAssertEqual(tail([segment(0.2, 0.69)], buffer: 1), discard(upTo: 1))
        XCTAssertEqual(tail([], buffer: 3), discard(upTo: 3))
    }

    func testTheTailMinimumIsSummedSpeech() {
        XCTAssertEqual(tail([segment(0, 0.3), segment(1, 1.3)], buffer: 2), commit(upTo: 2))
    }

    // MARK: - Segment hygiene

    func testSegmentsAreClampedSortedAndMerged() {
        let messy = [segment(6, 12), segment(0, 5), segment(4, 6), segment(11, 12)]
        XCTAssertEqual(cut(messy, buffer: 13), commit(upTo: 12.1), "one 0-12 s stretch, then 1 s of silence")

        let overrunning = [segment(0, 5), segment(4, 40)]
        XCTAssertEqual(cut(overrunning, buffer: 13), .wait, "clamped to the buffer, the speech is still going")
    }

    func testEmptyAndInvertedSegmentsAreIgnored() {
        let segments = [segment(3, 3), segment(5, 2)]
        XCTAssertEqual(cut(segments, buffer: 20), discard(upTo: 19.3))
    }

    // MARK: - Presets

    func testEveryLocalEngineHasAPresetAndTheCloudEngineHasNone() {
        for engine in EngineKind.allCases {
            let preset = LiveCutBudget.preset(for: engine)
            if engine.usesCloudProvider {
                XCTAssertNil(preset, "\(engine) is never chosen for the user and never cut for them")
            } else {
                XCTAssertNotNil(preset, "\(engine) must be able to dictate live")
            }
        }
    }

    func testWhisperWantsLongUtterancesInsideOneWindow() throws {
        let budget = try XCTUnwrap(LiveCutBudget.preset(for: .whisper))
        XCTAssertEqual(budget.minimumSpeechSamples, samples(8))
        XCTAssertEqual(budget.pauseSamples, samples(0.7))
        XCTAssertEqual(budget.maximumSamples, samples(28), "one utterance is at most one 30 s window")
    }

    /// A chunked engine's cap is the chunk it already prefers, so an utterance
    /// decodes as one chunk and Paraformer's token clamp is never reached.
    func testChunkedEnginesAreCappedAtTheirPreferredChunk() {
        XCTAssertEqual(LiveCutBudget.senseVoiceSmall.maximumSamples, AudioChunkBudget.senseVoiceSmall.preferredSamples)
        XCTAssertEqual(LiveCutBudget.paraformerZh.maximumSamples, AudioChunkBudget.paraformerZh.preferredSamples)
        XCTAssertEqual(LiveCutBudget.preset(for: .sensevoice), .senseVoiceSmall)
        XCTAssertEqual(LiveCutBudget.preset(for: .paraformer), .paraformerZh)
        XCTAssertEqual(LiveCutBudget.preset(for: .fluidaudio), .parakeet)
    }

    func testTheFluidAudioEnginesAffordFinerCuts() {
        for budget in [LiveCutBudget.parakeet, .senseVoiceSmall, .paraformerZh] {
            XCTAssertEqual(budget.minimumSpeechSamples, samples(3))
            XCTAssertEqual(budget.pauseSamples, samples(0.6))
        }
    }

    /// Every preset stays inside the 30 s input ceiling the FluidAudio
    /// preprocessors enforce and Whisper's window, and can actually cut.
    func testEveryPresetIsCoherent() {
        for engine in EngineKind.allCases {
            guard let budget = LiveCutBudget.preset(for: engine) else { continue }
            XCTAssertLessThanOrEqual(budget.maximumSamples, samples(AudioChunkBudget.fluidAudioMaximumSeconds), "\(engine)")
            XCTAssertGreaterThan(budget.maximumSamples, budget.minimumSpeechSamples, "\(engine)")
            XCTAssertGreaterThanOrEqual(budget.pauseSamples, 2 * LiveCutBudget.cutPaddingSamples, "\(engine)")
            XCTAssertLessThanOrEqual(budget.capSearchSamples, budget.maximumSamples, "\(engine)")
            XCTAssertEqual(budget.minimumTailSpeechSamples, samples(0.5), "\(engine)")
        }
    }

    // MARK: - Never inside speech

    /// Over every layout a seeded generator produces and every preset, a
    /// committed range ends in silence, a range `cut` discards holds no speech
    /// at all, a range `tail` discards holds less than the tail minimum, and
    /// every range is a non-empty prefix of the buffer.
    func testNoDecisionEverCutsInsideSpeech() {
        var generator = SeededGenerator(seed: 0x5EED_C0DE)
        let budgets = EngineKind.allCases.compactMap(LiveCutBudget.preset(for:))

        for iteration in 0..<600 {
            let layout = randomLayout(using: &generator)
            for budget in budgets {
                assertNeverInsideSpeech(
                    LiveCutPolicy.cut(segments: layout.segments, bufferLength: layout.length, budget: budget),
                    layout: layout, budget: budget, speechAllowedInDiscard: 0,
                    context: "cut iteration \(iteration) budget \(budget.maximumSamples)"
                )
                assertNeverInsideSpeech(
                    LiveCutPolicy.tail(segments: layout.segments, bufferLength: layout.length, budget: budget),
                    layout: layout, budget: budget, speechAllowedInDiscard: budget.minimumTailSpeechSamples - 1,
                    context: "tail iteration \(iteration) budget \(budget.maximumSamples)"
                )
            }
        }
    }

    private struct Layout {
        let segments: [WhisperVadSegment]
        let length: Int
    }

    private func randomLayout(using generator: inout SeededGenerator) -> Layout {
        let length = Int.random(in: 0...samples(70), using: &generator)
        var segments: [WhisperVadSegment] = []
        var cursor = Int.random(in: 0...samples(3), using: &generator)
        while cursor < length && segments.count < 40 {
            let speech = Int.random(in: 1...samples(12), using: &generator)
            let end = min(cursor + speech, length + Int.random(in: 0...samples(2), using: &generator))
            segments.append(WhisperVadSegment(startCs: Int64(cursor * 100 / sampleRate), endCs: Int64(end * 100 / sampleRate)))
            cursor = end + Int.random(in: 0...samples(4), using: &generator)
        }
        if Bool.random(using: &generator) { segments.shuffle(using: &generator) }
        return Layout(segments: segments, length: length)
    }

    private func assertNeverInsideSpeech(
        _ decision: LiveCutDecision,
        layout: Layout,
        budget: LiveCutBudget,
        speechAllowedInDiscard: Int,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let speech = layout.segments.map { segment -> Range<Int> in
            let start = min(max(0, budget.sampleIndex(centiseconds: segment.startCs)), layout.length)
            let end = min(max(0, budget.sampleIndex(centiseconds: segment.endCs)), layout.length)
            return start..<max(start, end)
        }.filter { !$0.isEmpty }

        switch decision {
        case .wait:
            return
        case .commit(let range):
            XCTAssertEqual(range.lowerBound, 0, context, file: file, line: line)
            XCTAssertFalse(range.isEmpty, context, file: file, line: line)
            XCTAssertLessThanOrEqual(range.upperBound, layout.length, context, file: file, line: line)
            for segment in speech {
                XCTAssertFalse(
                    segment.lowerBound < range.upperBound && range.upperBound < segment.upperBound,
                    "\(context): cut at \(range.upperBound) falls inside speech \(segment)",
                    file: file, line: line
                )
            }
        case .discard(let range):
            XCTAssertEqual(range.lowerBound, 0, context, file: file, line: line)
            XCTAssertFalse(range.isEmpty, context, file: file, line: line)
            XCTAssertLessThanOrEqual(range.upperBound, layout.length, context, file: file, line: line)
            let discardedSpeech = speech.reduce(0) { $0 + $1.clamped(to: range).count }
            XCTAssertLessThanOrEqual(
                discardedSpeech, speechAllowedInDiscard,
                "\(context): discarded \(range) holds \(discardedSpeech) samples of speech",
                file: file, line: line
            )
        }
    }

    /// A cut made while recording also respects the cap; the tail does not,
    /// which `testTheTailIsTheWholeRemainderWhenItHoldsSpeech` states.
    func testEveryRecordingCutRespectsTheCap() {
        var generator = SeededGenerator(seed: 0xCA9)
        let budgets = EngineKind.allCases.compactMap(LiveCutBudget.preset(for:))
        for _ in 0..<600 {
            let layout = randomLayout(using: &generator)
            for budget in budgets {
                if case .commit(let range) = LiveCutPolicy.cut(segments: layout.segments, bufferLength: layout.length, budget: budget) {
                    XCTAssertLessThanOrEqual(range.upperBound, budget.maximumSamples)
                }
            }
        }
    }
}

/// A deterministic generator, so a failing layout reproduces from its seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
