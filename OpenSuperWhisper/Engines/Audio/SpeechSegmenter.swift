import Foundation

/// The bundled Silero VAD, as an engine-neutral service.
///
/// Every engine needs it for the same two reasons: no engine in the app has a
/// no-speech gate of its own (silence is transcribed as hallucinated text), and
/// chunk boundaries must fall in detected silence or words get cut in half.
///
/// The VAD context is created lazily and kept for the lifetime of the instance,
/// so hold one per engine rather than one per transcription - loading the model
/// on every call is the expensive mistake here.
final class SpeechSegmenter {

    /// Silero VAD model shipped in the app bundle.
    static let vadModelPath = Bundle(for: SpeechSegmenter.self)
        .path(forResource: "ggml-silero-v5.1.2", ofType: "bin")

    private var vadContext: MyWhisperVadContext?

    /// Speech segments in `samples`, in centiseconds of that audio. An empty
    /// result means "no speech": callers must return an empty transcript rather
    /// than hand the audio to an engine anyway.
    func segments(in samples: [Float]) throws -> [WhisperVadSegment] {
        if vadContext == nil {
            guard let path = Self.vadModelPath,
                  let vad = MyWhisperVadContext(modelPath: path) else {
                throw TranscriptionError.contextInitializationFailed
            }
            vadContext = vad
        }
        guard let segments = vadContext?.speechSegments(in: samples) else {
            throw TranscriptionError.processingFailed
        }
        return segments
    }

    /// Keeps only speech, mirroring upstream whisper_full VAD stitching:
    /// each segment (already padded by the VAD) gets 0.1s of the following
    /// audio as overlap and segments are separated by 0.1s of silence, so the
    /// decoder still sees natural pauses between phrases.
    ///
    /// This is the Whisper-shaped use of the VAD: one stitched buffer, because
    /// whisper decodes arbitrarily long audio in one call. Engines with an input
    /// ceiling want `AudioChunker` instead, which keeps the segments apart.
    static func speechOnlySamples(from samples: [Float], segments: [WhisperVadSegment]) -> [Float] {
        let samplesPerCs = 160 // 16 kHz / 100
        let overlapSamples = 1600 // 0.1 s
        let gapSamples = 1600 // 0.1 s

        var result = [Float]()
        for (index, segment) in segments.enumerated() {
            let start = min(max(0, Int(segment.startCs) * samplesPerCs), samples.count)
            var end = min(Int(segment.endCs) * samplesPerCs, samples.count)
            if index < segments.count - 1 {
                end = min(end + overlapSamples, samples.count)
            }
            guard end > start else { continue }

            result.append(contentsOf: samples[start..<end])
            if index < segments.count - 1 {
                result.append(contentsOf: repeatElement(0, count: gapSamples))
            }
        }
        return result
    }
}
