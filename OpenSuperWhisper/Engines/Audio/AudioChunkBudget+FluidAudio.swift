import Foundation

/// Budgets for the FluidAudio CoreML models, measured rather than read off the
/// library's config constants - which mislead badly here.
///
/// Verified against FluidAudio 0.15.4 (`b9d43724`, the pin this app carries) by
/// binary-searching the accepted `waveform` input length on the real compiled
/// models. The constraint identifiers are the ones the runtime report uses.
extension AudioChunkBudget {

    /// **C2.** Below 3,200 samples the shared CoreML preprocessor throws
    /// `"Size (N) of dimension (1) is not in allowed range (3200..480000)"`.
    static let fluidAudioMinimumSeconds = 0.2

    /// **C1.** 480,000 samples. Above it the same preprocessor throws. This is
    /// the real ceiling for *both* models: `SenseVoiceConfig.maxFrames = 1800`
    /// (~108 s) and `ParaformerConfig.decoderEncFrames = 512` (~30.7 s) are
    /// unreachable from the audio path, so do not design around them.
    static let fluidAudioMaximumSeconds = 30.0

    /// Paraformer-large-zh.
    ///
    /// **C3.** The binding limit is not duration, it is the decoder's fixed
    /// `[1, 128, 8404]` output shape: `ParaformerManager` clamps to 128 tokens
    /// with no log and no error. On dense Mandarin that binds at roughly 18-21 s,
    /// well before the 30 s ceiling, and the truncated output degenerates into
    /// repetition - a measured 35.8 % CER on a 28.1 s clip that dropped to 0.53 %
    /// once the same clip was chunked. So the budget is deliberately conservative:
    /// 128 tokens at a 9 tokens/s planning rate gives ~14.2 s, and 14 s chunks
    /// are what was verified on that fixture.
    static let paraformerZh = AudioChunkBudget(
        minimumSeconds: fluidAudioMinimumSeconds,
        maximumSeconds: fluidAudioMaximumSeconds,
        preferredSeconds: fluidAudioMaximumSeconds,
        tokenBudget: 128,
        tokensPerSecond: 9.0
    )

    /// SenseVoice-Small.
    ///
    /// No silent token clamp, so the only limit is the input ceiling and chunks
    /// can be much longer - fewer seams, and every blind cut costs about
    /// +0.5 pp CER. Kept strictly below 30 s so rounding at a boundary can never
    /// produce an input the preprocessor rejects.
    static let senseVoiceSmall = AudioChunkBudget(
        minimumSeconds: fluidAudioMinimumSeconds,
        maximumSeconds: fluidAudioMaximumSeconds,
        preferredSeconds: 28.0
    )
}
