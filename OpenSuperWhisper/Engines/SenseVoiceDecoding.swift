import Accelerate
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Greedy CTC decode of SenseVoice's encoder output, owned by the app.
///
/// Why this exists instead of `SenseVoiceManager.transcribe`: the pinned manager
/// decodes fp16 logits through a boxed `NSNumber` per element, which dominates a
/// transcription's wall time (see `docs/upstream-issues.md`). This is the same
/// vDSP argmax fix upstream later wrote on main, kept byte-compatible with the
/// pinned manager's output.
///
/// The decode semantics are the pinned manager's, exactly: per-frame argmax
/// over the first `validFrames` frames, drop blank 0, collapse repeats
/// (`prev` updates on every frame, so a blank re-arms a repeat), SentencePiece
/// detokenise via FluidAudio's public `decodeCtcTokenIds`, then strip the
/// `<|lang|><|emo|><|event|><|itn|>` meta tags.
enum SenseVoiceGreedyDecode {

    /// Argmax token id per frame for the first `frames` frames.
    ///
    /// Reads each row through the tensor's real stride rather than assuming
    /// `t * vocab`: CoreML pads ANE tensor rows for alignment, and scanning
    /// the padding slots would read uninitialised memory into the argmax.
    /// fp16 storage is widened to fp32 in one vImage pass. Addressed as
    /// `UInt16` bit patterns rather than `Float16` so the code does not lean
    /// on a type with platform availability quirks.
    static func argmaxPerFrame(logits: MLMultiArray, frames: Int) -> [Int] {
        let vocab = logits.shape[2].intValue
        let rowStride = logits.strides[1].intValue

        func argmaxRows(_ base: UnsafePointer<Float>) -> [Int] {
            var ids: [Int] = []
            ids.reserveCapacity(frames)
            for t in 0..<frames {
                var bestValue: Float = 0
                var bestIndex = vDSP_Length(0)
                vDSP_maxvi(base + t * rowStride, 1, &bestValue, &bestIndex, vDSP_Length(vocab))
                ids.append(Int(bestIndex))
            }
            return ids
        }

        switch logits.dataType {
        case .float32:
            return argmaxRows(logits.dataPointer.assumingMemoryBound(to: Float.self))
        case .float16:
            let count = frames * rowStride
            let source = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            var widened = [Float](repeating: 0, count: count)
            return widened.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source),
                    height: 1, width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<UInt16>.size)
                var dst = vImage_Buffer(
                    data: destination.baseAddress!,
                    height: 1, width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<Float>.size)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
                return argmaxRows(destination.baseAddress!)
            }
        default:
            // The encoder emits fp16 (int8/fp16 weights) or fp32; anything else
            // is new upstream behaviour. Fall back to the pinned manager's
            // element-wise reads - slow, but a dictation must never crash over a
            // tensor layout.
            var ids: [Int] = []
            ids.reserveCapacity(frames)
            for t in 0..<frames {
                var best = 0
                var bestValue = logits[[0, t as NSNumber, 0]].floatValue
                for v in 1..<vocab {
                    let x = logits[[0, t as NSNumber, v as NSNumber]].floatValue
                    if x > bestValue {
                        bestValue = x
                        best = v
                    }
                }
                ids.append(best)
            }
            return ids
        }
    }

    /// The full decode: argmax, CTC collapse, detokenise, strip meta tags.
    static func transcript(logits: MLMultiArray, validFrames: Int, vocabulary: [Int: String]) -> String {
        let frames = min(validFrames, logits.shape[1].intValue)
        var ids: [Int] = []
        var previous = -1
        for best in argmaxPerFrame(logits: logits, frames: frames) {
            if best != SenseVoiceConfig.blankId, best != previous { ids.append(best) }
            previous = best
        }
        return decodeCtcTokenIds(ids, vocabulary: vocabulary)
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One configured SenseVoice pipeline over already-loaded weights: the same
/// three stages as FluidAudio's `SenseVoiceManager` (preprocessor on CPU,
/// encoder on the Neural Engine, host-side greedy CTC), with the decode done
/// by `SenseVoiceGreedyDecode` instead of the boxed-subscript loop.
///
/// Conforms to the engine's existing seam, so `SenseVoiceEngine`'s chunking,
/// progress, cancellation and transcript joining are untouched.
final class SenseVoiceCoreMLTranscriber: SenseVoiceTranscribing {
    private let models: SenseVoiceModels
    private let language: Int32
    private let textNorm: Int32

    init(models: SenseVoiceModels, language: Int32, textNorm: Int32) {
        self.models = models
        self.language = language
        self.textNorm = textNorm
    }

    func transcribe(audio: [Float]) async throws -> String {
        let features = try runPreprocessor(audio: audio)
        let (logits, validFrames) = try runEncoder(features: features)
        return SenseVoiceGreedyDecode.transcript(
            logits: logits, validFrames: validFrames, vocabulary: models.vocabulary)
    }

    // MARK: - The two model stages

    /// waveform [1, N] (scaled to int16 range) → features [1, T, 560].
    private func runPreprocessor(audio: [Float]) throws -> MLMultiArray {
        let waveform = try MLMultiArray(shape: [1, audio.count as NSNumber], dataType: .float32)
        let pointer = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        let scale = SenseVoiceConfig.waveformScale
        for i in 0..<audio.count { pointer[i] = audio[i] * scale }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["waveform": MLFeatureValue(multiArray: waveform)])
        let output = try models.preprocessor.prediction(from: input)
        guard let features = output.featureValue(for: "features")?.multiArrayValue else {
            throw ASRError.processingFailed("SenseVoice preprocessor produced no `features`")
        }
        return features
    }

    /// features [1, T, 560] → (ctc_logits [1, bucket+4, V], validFrames = 4 + T).
    private func runEncoder(features: MLMultiArray) throws -> (MLMultiArray, Int) {
        let dim = SenseVoiceConfig.featureDim
        let t = min(features.shape[1].intValue, SenseVoiceConfig.maxFrames)
        let bucket = SenseVoiceConfig.pickBucket(forFrames: t)

        // Zero-padded [1, bucket, 560] with the first T feature frames copied in.
        let speech = try MLMultiArray(
            shape: [1, bucket as NSNumber, dim as NSNumber], dataType: .float32)
        let speechPointer = speech.dataPointer.assumingMemoryBound(to: Float.self)
        let dstStride = speech.strides[1].intValue
        memset(speechPointer, 0, speech.strides[0].intValue * MemoryLayout<Float>.size)

        let srcStride = features.strides[1].intValue
        if features.dataType == .float32 {
            let srcPointer = features.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<t {
                memcpy(speechPointer + i * dstStride, srcPointer + i * srcStride, dim * MemoryLayout<Float>.size)
            }
        } else {
            for i in 0..<t {
                for v in 0..<dim {
                    speechPointer[i * dstStride + v] = features[i * srcStride + v].floatValue
                }
            }
        }

        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: t)
        let languageInput = try MLMultiArray(shape: [1], dataType: .int32)
        languageInput[0] = NSNumber(value: language)
        let textNormInput = try MLMultiArray(shape: [1], dataType: .int32)
        textNormInput[0] = NSNumber(value: textNorm)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: lengths),
            "language": MLFeatureValue(multiArray: languageInput),
            "textnorm": MLFeatureValue(multiArray: textNormInput),
        ])
        let output = try models.encoder.prediction(from: input)
        guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw ASRError.processingFailed("SenseVoice encoder produced no `ctc_logits`")
        }
        return (logits, SenseVoiceConfig.numQueryTokens + t)
    }
}
