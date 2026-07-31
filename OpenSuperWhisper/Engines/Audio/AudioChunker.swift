import Foundation

/// One engine-sized piece of audio.
struct AudioChunk: Equatable {

    /// 16 kHz mono samples to hand to the engine. Always inside the budget's
    /// `minimumSamples...maximumSamples` range.
    let samples: [Float]

    /// Where the chunk was cut from in the source audio. Zero padding, when the
    /// whole recording is shorter than the floor, is not part of the range, so
    /// `range.count` can be less than `samples.count`.
    let range: Range<Int>
}

/// Cuts VAD-segmented audio into chunks an engine with an input ceiling can
/// actually accept.
///
/// Three properties, in priority order:
///
/// 1. **Never invalid.** Every emitted chunk is within the budget's sample
///    range. An engine whose preprocessor throws outside `3200...480000` must
///    never be handed anything outside it - including the short remainder at
///    the end of a recording, which is the case that actually bites.
/// 2. **Never lossy.** The chunks cover every sample the VAD called speech.
///    Long audio is split, not truncated.
/// 3. **Cut in silence.** Boundaries are placed between VAD segments wherever
///    that is possible, because a blind cut through a word costs accuracy at
///    every seam.
enum AudioChunker {

    /// Chunks `samples` according to `segments`.
    ///
    /// Returns an empty array when the VAD found no speech. That is the whole
    /// silence gate: no engine in the app has a no-speech gate of its own, and
    /// padding silence up to the minimum length just buys hallucinated text.
    static func chunks(
        from samples: [Float],
        segments: [WhisperVadSegment],
        budget: AudioChunkBudget
    ) -> [AudioChunk] {
        let speech = speechRanges(from: segments, sampleCount: samples.count, budget: budget)
        guard !speech.isEmpty else { return [] }

        let packed = pack(speech, budget: budget)
        let bounded = packed.flatMap { split($0, budget: budget) }
        return materialize(bounded, from: samples, budget: budget)
    }

    // MARK: - Stages

    /// VAD segments as sample ranges, clamped to the audio, ordered, and merged
    /// where they touch or overlap.
    private static func speechRanges(
        from segments: [WhisperVadSegment],
        sampleCount: Int,
        budget: AudioChunkBudget
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

    /// Greedily groups consecutive speech ranges while the span they cover stays
    /// within the preferred length. The span includes the silence between the
    /// grouped segments, which is the point: that silence is what the engine
    /// hears as a pause, and the boundary between two groups falls inside a
    /// silence the VAD found rather than in the middle of speech.
    private static func pack(_ speech: [Range<Int>], budget: AudioChunkBudget) -> [Range<Int>] {
        var packed: [Range<Int>] = []
        var current: Range<Int>?

        for range in speech {
            if let open = current {
                let merged = open.lowerBound..<range.upperBound
                if merged.count <= budget.preferredSamples {
                    current = merged
                    continue
                }
                packed.append(open)
            }
            current = range
        }
        if let open = current { packed.append(open) }
        return packed
    }

    /// Splits a group the VAD gave us no seam inside - one uninterrupted stretch
    /// of speech longer than the preferred length - into equal parts.
    ///
    /// Equal, not "fill then remainder": a fixed-window cut leaves a tail that
    /// can fall under the engine's floor, which is exactly how a 44.8 s clip cut
    /// into 14 s windows produced a rejected 0.142 s remainder.
    ///
    /// The part count aims for `preferredSamples` but is clamped into the range
    /// that keeps every part inside `minimumSamples...maximumSamples`: this is
    /// also called by `materialize`'s merge fallback on a range that is already
    /// close to the floor, and dividing that further by `preferredSamples` alone
    /// can hand back a part under the floor - which `materialize` would then
    /// merge and re-split into the same too-short part forever.
    private static func split(_ range: Range<Int>, budget: AudioChunkBudget) -> [Range<Int>] {
        guard range.count > budget.preferredSamples else { return [range] }

        let idealParts = (range.count + budget.preferredSamples - 1) / budget.preferredSamples
        let minParts = (range.count + budget.maximumSamples - 1) / budget.maximumSamples
        let maxParts = max(1, range.count / budget.minimumSamples)
        let parts = max(minParts, min(idealParts, maxParts))

        let base = range.count / parts
        let remainder = range.count % parts

        var result: [Range<Int>] = []
        result.reserveCapacity(parts)
        var start = range.lowerBound
        for index in 0..<parts {
            let length = base + (index < remainder ? 1 : 0)
            result.append(start..<(start + length))
            start += length
        }
        return result
    }

    /// Copies the samples out, enforcing the floor and the ceiling.
    ///
    /// A range under the floor is first grown into the surrounding audio - real
    /// acoustic context, and better than padding - but never past a neighbouring
    /// chunk, so chunks stay disjoint and no word is transcribed twice. Only when
    /// the whole recording is shorter than the floor is the difference zero-padded.
    private static func materialize(
        _ ranges: [Range<Int>],
        from samples: [Float],
        budget: AudioChunkBudget
    ) -> [AudioChunk] {
        if samples.count < budget.minimumSamples {
            let range = 0..<samples.count
            var chunkSamples = Array(samples[range])
            chunkSamples.append(
                contentsOf: repeatElement(0, count: budget.minimumSamples - chunkSamples.count)
            )
            return [AudioChunk(samples: chunkSamples, range: range)]
        }

        var groups = ranges
        while true {
            let planned = planDisjointRanges(groups, sampleCount: samples.count, budget: budget)
            if let planned {
                return planned.map { range in
                    AudioChunk(samples: Array(samples[range]), range: range)
                }
            }

            guard groups.count > 1 else {
                preconditionFailure("A recording above the floor must admit one valid chunk")
            }

            let failure = firstUnallocatableRange(
                groups,
                sampleCount: samples.count,
                budget: budget
            )
            let left = failure == groups.count - 1 ? failure - 1 : failure
            let merged = groups[left].lowerBound..<groups[left + 1].upperBound
            groups.replaceSubrange(
                left...(left + 1),
                with: split(merged, budget: budget)
            )
        }
    }

    private static func planDisjointRanges(
        _ ranges: [Range<Int>],
        sampleCount: Int,
        budget: AudioChunkBudget
    ) -> [Range<Int>]? {
        var planned: [Range<Int>] = []
        planned.reserveCapacity(ranges.count)

        for (index, range) in ranges.enumerated() {
            let lowerLimit = planned.last?.upperBound ?? 0
            let upperLimit = index == ranges.count - 1 ? sampleCount : ranges[index + 1].lowerBound

            // The ceiling needs no clamp here, and must not have one: clamping
            // would drop audio, which is the failure this whole type exists to
            // prevent. `split` has already bounded every range by the preferred
            // length, which the budget keeps at or below the maximum, and the
            // growth below only ever fires on a range under the floor.
            var start = range.lowerBound
            var end = range.upperBound

            let deficit = budget.minimumSamples - (end - start)
            if deficit > 0 {
                end += min(deficit, max(0, upperLimit - end))
                let stillShort = budget.minimumSamples - (end - start)
                if stillShort > 0 {
                    start -= min(stillShort, max(0, start - lowerLimit))
                }
            }

            guard end - start >= budget.minimumSamples else { return nil }
            guard end - start <= budget.maximumSamples else { return nil }
            planned.append(start..<end)
        }
        return planned
    }

    private static func firstUnallocatableRange(
        _ ranges: [Range<Int>],
        sampleCount: Int,
        budget: AudioChunkBudget
    ) -> Int {
        var previousEnd = 0
        for (index, range) in ranges.enumerated() {
            let upperLimit = index == ranges.count - 1 ? sampleCount : ranges[index + 1].lowerBound
            var start = range.lowerBound
            var end = range.upperBound
            let deficit = budget.minimumSamples - range.count
            if deficit > 0 {
                end += min(deficit, max(0, upperLimit - end))
                start -= min(
                    budget.minimumSamples - (end - start),
                    max(0, start - previousEnd)
                )
            }
            if end - start < budget.minimumSamples { return index }
            previousEnd = end
        }
        preconditionFailure("Range planning failed without an unallocatable range")
    }
}
