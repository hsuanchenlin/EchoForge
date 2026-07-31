import Foundation

/// The whole engine-facing audio path in one call: decode to 16 kHz mono PCM,
/// gate through the bundled VAD, cut into chunks the engine can accept.
///
/// Engines with an input ceiling should use this rather than composing the three
/// pieces themselves, because the composition has one mandatory step that is easy
/// to skip: silence must produce *no* chunks, not a padded one. Hold one instance
/// per engine so the VAD model is loaded once.
final class AudioChunkSource {

    private let segmenter: SpeechSegmenter

    init(segmenter: SpeechSegmenter = SpeechSegmenter()) {
        self.segmenter = segmenter
    }

    /// Chunks the audio at `url`. An empty result means the recording contained
    /// no speech, and the caller should return an empty transcript.
    func chunks(for url: URL, budget: AudioChunkBudget) async throws -> [AudioChunk] {
        guard let samples = try await PCMAudioLoader.loadSamples(from: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        return try chunks(for: samples, budget: budget)
    }

    /// Chunks already-decoded 16 kHz mono samples.
    func chunks(for samples: [Float], budget: AudioChunkBudget) throws -> [AudioChunk] {
        let segments = try segmenter.segments(in: samples)
        guard !segments.isEmpty else { return [] }
        return AudioChunker.chunks(from: samples, segments: segments, budget: budget)
    }
}
