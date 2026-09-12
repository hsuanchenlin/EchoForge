import Foundation

/// The cut budget each engine dictates live under.
///
/// The Whisper numbers come from timing the pinned whisper.cpp with the app's
/// own parameters on `ggml-large-v3-turbo`: every utterance costs one ~0.54 s
/// encode of a 30 s window regardless of how much of it is speech, so live
/// decoding performs about as many encodes as the whole-file decode only if
/// utterances are long - hence the 8 s floor and the 28 s cap, one utterance
/// per window. The FluidAudio engines have no window to fill: they chunk under
/// `AudioChunkBudget` and cost proportionally, so a 3 s floor is affordable and
/// the cap is the chunk length the engine already prefers.
extension LiveCutBudget {

    /// The budget for `engine`, or `nil` for one that never dictates live.
    ///
    /// Live decoding sends audio to the engine while the microphone is still
    /// open, which for the cloud engine would mean a request per pause - and
    /// that engine is never chosen for the user (`EngineKind.usesCloudProvider`),
    /// so it is never cut for them either.
    static func preset(for engine: EngineKind) -> LiveCutBudget? {
        switch engine {
        case .whisper:
            return .whisper
        case .fluidaudio:
            return .parakeet
        case .sensevoice:
            return .senseVoiceSmall
        case .paraformer:
            return .paraformerZh
        case .cloud:
            return nil
        }
    }

    /// whisper.cpp, any model. Measured: one encode per 30 s window whatever
    /// its content, plus one more for language detection on `auto`, so short
    /// utterances would multiply the work rather than move it earlier.
    static let whisper = LiveCutBudget(
        minimumSpeechSeconds: 8.0,
        pauseSeconds: 0.7,
        maximumSeconds: 28.0
    )

    /// Parakeet takes a whole file and chunks inside FluidAudio, so nothing
    /// here is an input ceiling; the cap only bounds how much audio the last
    /// utterance can hold - which is the wait after the key goes up - and 28 s
    /// keeps it inside the same window the other engines are held to.
    static let parakeet = LiveCutBudget(
        minimumSpeechSeconds: 3.0,
        pauseSeconds: 0.6,
        maximumSeconds: 28.0
    )

    /// SenseVoice-Small: the cap is the chunk it already prefers, so an
    /// utterance decodes as one chunk.
    static let senseVoiceSmall = LiveCutBudget(
        minimumSpeechSeconds: 3.0,
        pauseSeconds: 0.6,
        maximumSeconds: AudioChunkBudget.senseVoiceSmall.preferredSeconds
    )

    /// Paraformer-large-zh: the cap is the ~14 s its silent 128-token clamp
    /// allows (`AudioChunkBudget.paraformerZh`), so an utterance never needs a
    /// second chunk.
    static let paraformerZh = LiveCutBudget(
        minimumSpeechSeconds: 3.0,
        pauseSeconds: 0.6,
        maximumSeconds: AudioChunkBudget.paraformerZh.preferredSeconds
    )
}

extension AudioChunkBudget {
    /// `preferredSamples` as a duration, for a live budget capped at one chunk.
    var preferredSeconds: Double {
        seconds(samples: preferredSamples)
    }
}
