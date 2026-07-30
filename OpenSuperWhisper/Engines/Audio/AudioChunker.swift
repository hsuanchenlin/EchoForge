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
    private static func split(_ range: Range<Int>, budget: AudioChunkBudget) -> [Range<Int>] {
        guard range.count > budget.preferredSamples else { return [range] }

        let parts = (range.count + budget.preferredSamples - 1) / budget.preferredSamples
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
        var chunks: [AudioChunk] = []
        chunks.reserveCapacity(ranges.count)

        for (index, range) in ranges.enumerated() {
            let lowerLimit = index == 0 ? 0 : ranges[index - 1].upperBound
            let upperLimit = index == ranges.count - 1 ? samples.count : ranges[index + 1].lowerBound

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

            var chunkSamples = Array(samples[start..<end])
            if chunkSamples.count < budget.minimumSamples {
                chunkSamples.append(
                    contentsOf: repeatElement(0, count: budget.minimumSamples - chunkSamples.count)
                )
            }

            chunks.append(AudioChunk(samples: chunkSamples, range: start..<end))
        }
        return chunks
    }
}
