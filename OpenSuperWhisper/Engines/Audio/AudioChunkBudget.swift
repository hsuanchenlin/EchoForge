import Foundation

/// The limits one engine puts on a single transcription call.
///
/// Engine-neutral by construction: nothing here knows which engine it describes.
/// Every number an engine cares about is a parameter, because the two limits
/// that matter are unrelated. An engine can have
///
/// - an **input** range - the sample counts its preprocessor accepts at all, and
/// - an **output** budget - how many tokens it will emit before it stops,
///
/// and the second can bind long before the first. Presets for the engines this
/// app is preparing for live in `AudioChunkBudget+FluidAudio.swift`.
struct AudioChunkBudget: Equatable {

    /// Shared PCM and VAD sample rate, derived from `PCMAudioLoader` so the two
    /// can never drift apart.
    static let sampleRate = Int(PCMAudioLoader.sampleRate)

    /// Hard floor. A chunk shorter than this is not a small chunk, it is an
    /// invalid input: FluidAudio's CoreML preprocessors throw on it.
    let minimumSamples: Int

    /// Hard ceiling. Never exceeded, whatever the preferred length says.
    let maximumSamples: Int

    /// Length the chunker aims for. Always within `minimumSamples...maximumSamples`.
    /// Boundaries are placed in VAD silence at or before this, so real chunks are
    /// usually shorter.
    let preferredSamples: Int

    /// - Parameters:
    ///   - minimumSeconds: shortest input the engine accepts.
    ///   - maximumSeconds: longest input the engine accepts.
    ///   - preferredSeconds: duration-derived chunk length to aim for.
    ///   - tokenBudget: output tokens the engine emits before it stops. Pass it
    ///     when the engine clamps *silently*, so the clamp becomes a chunking
    ///     constraint instead of truncated text.
    ///   - tokensPerSecond: planning speech rate used to turn `tokenBudget` into
    ///     a duration. Should be a fast-speaker rate, not an average one: the
    ///     cost of guessing high is a slightly shorter chunk, the cost of
    ///     guessing low is silently lost words.
    init(
        minimumSeconds: Double,
        maximumSeconds: Double,
        preferredSeconds: Double,
        tokenBudget: Int? = nil,
        tokensPerSecond: Double? = nil
    ) {
        precondition(minimumSeconds > 0, "minimumSeconds must be positive")
        precondition(maximumSeconds >= minimumSeconds, "maximumSeconds must not be below minimumSeconds")

        func samples(_ seconds: Double) -> Int {
            Int((seconds * Double(Self.sampleRate)).rounded())
        }

        self.minimumSamples = samples(minimumSeconds)
        self.maximumSamples = samples(maximumSeconds)

        var preferred = samples(preferredSeconds)
        if let tokenBudget, let tokensPerSecond, tokenBudget > 0, tokensPerSecond > 0 {
            preferred = min(preferred, samples(Double(tokenBudget) / tokensPerSecond))
        }
        self.preferredSamples = min(max(preferred, self.minimumSamples), self.maximumSamples)
    }

    /// Sample offset of a VAD segment boundary, which the VAD reports in
    /// centiseconds of the source audio.
    func sampleIndex(centiseconds: Int64) -> Int {
        Int(centiseconds) * Self.sampleRate / 100
    }

    func seconds(samples: Int) -> Double {
        Double(samples) / Double(Self.sampleRate)
    }
}
