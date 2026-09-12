import Foundation

/// What to do with the audio a live dictation has not committed yet.
///
/// Every range is a prefix of the uncommitted buffer, in samples at
/// `LiveCutBudget.sampleRate`: the buffer is contiguous and the policy only
/// ever releases its front, so the session can drop the range and keep the
/// rest without re-indexing anything.
enum LiveCutDecision: Equatable {

    /// Keep buffering. Nothing in the buffer is ready, or the only cut available
    /// would land inside speech.
    case wait

    /// Decode `range` as one utterance and release it.
    case commit(Range<Int>)

    /// Release `range` without decoding it: the VAD found no speech in it.
    case discard(Range<Int>)
}

/// Decides where a live dictation is cut into utterances.
///
/// A pure function of the VAD's segments over the uncommitted buffer, the
/// buffer's length and the engine's `LiveCutBudget`. It holds the whole risk of
/// live decoding - a cut through a word is a wrong word pasted, and a clip too
/// short is a hallucinated one - as numbers a test can state. Three rules, in
/// priority order:
///
/// 1. **Never inside speech.** A cut lands only in silence the VAD reported.
///    When the cap is reached and the buffer holds one unbroken stretch of
///    speech the answer is `.wait`, not a cut at the cap sample; bounding the
///    buffer is the session's job, and falling back to the whole-file decode
///    costs seconds where a split word costs a wrong paste.
/// 2. **A pause ends an utterance that is long enough.** The latest pause of
///    at least `pauseSamples` before which the buffer holds `minimumSpeechSamples`
///    of detected speech ends the utterance there, padded 0.1 s into the pause.
///    The minimum is speech the VAD detected, summed, not the span it covers.
/// 3. **The cap forces a cut.** Once the buffer reaches `maximumSamples`, the
///    minimum no longer applies and the cut goes to the longest silence within
///    `capSearchSamples` of the cap, or the latest silence before it - so the
///    utterance stays long and the cut still sits in a gap the VAD found.
///
/// Leading silence is released without a decode once it is at least a pause
/// long, keeping a margin the VAD could still turn into the start of a
/// segment. With no speech found yet that margin is one whole pause: the VAD
/// reports a segment once it has heard 250 ms of speech and pads it 30 ms, so
/// a pause is comfortably longer than the delay before an onset shows up.
/// Before a segment it has already found, the cut padding is margin enough.
enum LiveCutPolicy {

    /// Where to cut the uncommitted buffer while the recording is still going.
    ///
    /// - Parameters:
    ///   - segments: the VAD's speech segments over the buffer, in centiseconds
    ///     of it. Any order; clamped to the buffer and merged where they touch.
    ///   - bufferLength: samples in the uncommitted buffer.
    ///   - budget: the engine's numbers.
    static func cut(
        segments: [WhisperVadSegment],
        bufferLength: Int,
        budget: LiveCutBudget
    ) -> LiveCutDecision {
        let speech = speechRanges(from: segments, sampleCount: bufferLength, budget: budget)
        let candidates = cutCandidates(speech, sampleCount: bufferLength, budget: budget)

        if let pause = candidates.last(where: {
            $0.gap >= budget.pauseSamples && $0.speechSoFar >= budget.minimumSpeechSamples
        }) {
            return .commit(0..<pause.cutIndex)
        }

        // Leading silence counts against the cap and buys nothing, so it goes
        // before the cap can force a short utterance because of it. With no
        // speech at all the margin is a whole pause; before a segment the VAD
        // has already found the onset, so the cut padding is margin enough.
        let leadingSilence = speech.first?.lowerBound ?? bufferLength
        let margin = speech.isEmpty ? budget.pauseSamples : LiveCutBudget.cutPaddingSamples
        let releasable = leadingSilence - margin
        if releasable >= budget.pauseSamples {
            return .discard(0..<releasable)
        }

        guard bufferLength >= budget.maximumSamples else { return .wait }

        let window = (budget.maximumSamples - budget.capSearchSamples)...budget.maximumSamples
        var longestInWindow: Candidate?
        for candidate in candidates where window.contains(candidate.speechEnd) {
            // `>=` so a tie goes to the later gap and the utterance stays long.
            if candidate.gap >= (longestInWindow?.gap ?? 0) {
                longestInWindow = candidate
            }
        }
        if let forced = longestInWindow ?? candidates.last {
            return .commit(0..<forced.cutIndex)
        }
        return .wait
    }

    /// What to do with the buffer once the key has gone up: everything left is
    /// the last utterance, decoded if the VAD found enough speech in it and
    /// dropped as silence otherwise. Never `.wait` - there is nothing more to
    /// wait for - and never cut, whatever its length: the session should have
    /// asked `cut` while recording, and every engine decodes a long file.
    static func tail(
        segments: [WhisperVadSegment],
        bufferLength: Int,
        budget: LiveCutBudget
    ) -> LiveCutDecision {
        let speech = speechRanges(from: segments, sampleCount: bufferLength, budget: budget)
        let detected = speech.reduce(0) { $0 + $1.count }
        guard detected > 0, detected >= budget.minimumTailSpeechSamples else {
            return .discard(0..<bufferLength)
        }
        return .commit(0..<bufferLength)
    }

    // MARK: - Stages

    /// A place a cut could go: after a speech range, inside the gap that
    /// follows it.
    private struct Candidate {
        /// Where the speech before the gap ends.
        let speechEnd: Int
        /// Silence after `speechEnd`, up to the next speech or the buffer end.
        let gap: Int
        /// Detected speech in the buffer up to and including this range.
        let speechSoFar: Int
        /// Where the committed range would end: padded into the gap, but never
        /// past its middle and never past the cap.
        let cutIndex: Int
    }

    /// One candidate per speech range that has any silence after it and ends
    /// within the cap, in buffer order.
    private static func cutCandidates(
        _ speech: [Range<Int>],
        sampleCount: Int,
        budget: LiveCutBudget
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var speechSoFar = 0
        for (index, range) in speech.enumerated() {
            speechSoFar += range.count
            let nextStart = index + 1 < speech.count ? speech[index + 1].lowerBound : sampleCount
            let gap = nextStart - range.upperBound
            guard gap > 0, range.upperBound <= budget.maximumSamples else { continue }
            let padding = min(
                LiveCutBudget.cutPaddingSamples,
                gap / 2,
                budget.maximumSamples - range.upperBound
            )
            candidates.append(Candidate(
                speechEnd: range.upperBound,
                gap: gap,
                speechSoFar: speechSoFar,
                cutIndex: range.upperBound + padding
            ))
        }
        return candidates
    }

    /// VAD segments as sample ranges, clamped to the buffer, ordered, and
    /// merged where they touch or overlap - the same normalisation
    /// `AudioChunker` applies, so both read the VAD the same way.
    private static func speechRanges(
        from segments: [WhisperVadSegment],
        sampleCount: Int,
        budget: LiveCutBudget
    ) -> [Range<Int>] {
        let raw = segments
            .map { segment -> Range<Int> in
                let start = min(max(0, budget.sampleIndex(centiseconds: segment.startCs)), sampleCount)
                let end = min(max(0, budget.sampleIndex(centiseconds: segment.endCs)), sampleCount)
                return start..<max(start, end)
            }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Int>] = []
        for range in raw {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
