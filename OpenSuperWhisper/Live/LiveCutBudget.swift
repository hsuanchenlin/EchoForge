import Foundation

/// The numbers one engine puts on where a live dictation may be cut into
/// utterances.
///
/// Live dictation decodes a recording while it is still being made: the
/// uncommitted audio is watched by the VAD, and whenever `LiveCutPolicy` finds
/// a pause it may commit everything before it as one utterance. Which pauses
/// qualify is what this type states, per engine, because the cost of a cut is
/// not the same everywhere: Whisper pays one ~0.5 s encode per utterance
/// however short it is and hallucinates on very short clips, so it wants long
/// utterances; the FluidAudio engines chunk under `AudioChunkBudget` and cost
/// proportionally, so they can afford finer cuts. Presets live in
/// `LiveCutBudget+Engines.swift`.
///
/// Every duration is stored in samples at `AudioChunkBudget.sampleRate`, the
/// shared PCM and VAD rate, so the policy and the VAD's segments count in the
/// same unit.
struct LiveCutBudget: Equatable {

    /// Shared PCM and VAD sample rate.
    static let sampleRate = AudioChunkBudget.sampleRate

    /// How far past the last speech sample a cut is placed, so the utterance
    /// keeps a little of the pause the way `SpeechSegmenter.speechOnlySamples`
    /// keeps 0.1 s of overlap after every segment. Never more than half the gap
    /// it is cut in, and never past the cap.
    static let cutPaddingSamples = 1_600 // 0.1 s

    /// Detected speech an utterance must hold before a pause is allowed to end
    /// it. Below this the policy keeps waiting for a later pause, because a
    /// short clip costs Whisper a whole encode and is where it hallucinates.
    let minimumSpeechSamples: Int

    /// Silence the VAD must report after a segment for it to count as a pause.
    /// The VAD splits segments on 100 ms already; this is the longer gap a
    /// person leaves between phrases, which is where a cut is invisible.
    let pauseSamples: Int

    /// Hard ceiling on the committed range. Reaching it forces a cut at the
    /// best silence the buffer has, overriding `minimumSpeechSamples` but never
    /// landing inside speech. For Whisper it keeps one utterance inside one
    /// 30 s window; for a chunked engine it is that engine's preferred chunk.
    let maximumSamples: Int

    /// When the cap forces a cut, the longest silence within this much of the
    /// cap is preferred over a longer one earlier, so the utterance stays long.
    let capSearchSamples: Int

    /// Detected speech the audio left at stop must hold to be decoded at all.
    /// Below it the tail is dropped as silence: the last fraction of a second
    /// after a pause is breath and key noise, and an engine handed it answers
    /// with hallucinated text.
    let minimumTailSpeechSamples: Int

    /// - Parameters:
    ///   - minimumSpeechSeconds: detected speech before a pause may end an
    ///     utterance.
    ///   - pauseSeconds: VAD silence that counts as a pause. At least twice the
    ///     cut padding, so a padded cut still sits inside the silence.
    ///   - maximumSeconds: the hard cap on one utterance. Must exceed the
    ///     minimum, or no pause could ever qualify.
    ///   - capSearchSeconds: the window before the cap a forced cut searches
    ///     first. Clamped to the cap.
    ///   - minimumTailSpeechSeconds: detected speech the tail needs to be
    ///     decoded rather than dropped.
    init(
        minimumSpeechSeconds: Double,
        pauseSeconds: Double,
        maximumSeconds: Double,
        capSearchSeconds: Double = 5.0,
        minimumTailSpeechSeconds: Double = 0.5
    ) {
        precondition(minimumSpeechSeconds > 0, "minimumSpeechSeconds must be positive")
        precondition(minimumTailSpeechSeconds >= 0, "minimumTailSpeechSeconds must not be negative")
        precondition(capSearchSeconds >= 0, "capSearchSeconds must not be negative")

        func samples(_ seconds: Double) -> Int {
            Int((seconds * Double(Self.sampleRate)).rounded())
        }

        minimumSpeechSamples = samples(minimumSpeechSeconds)
        pauseSamples = samples(pauseSeconds)
        maximumSamples = samples(maximumSeconds)
        capSearchSamples = min(samples(capSearchSeconds), maximumSamples)
        minimumTailSpeechSamples = samples(minimumTailSpeechSeconds)

        precondition(
            pauseSamples >= 2 * Self.cutPaddingSamples,
            "pauseSeconds must be at least twice the cut padding, or a padded cut can leave the silence"
        )
        precondition(
            maximumSamples > minimumSpeechSamples,
            "maximumSeconds must exceed minimumSpeechSeconds, or no pause could ever qualify"
        )
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
