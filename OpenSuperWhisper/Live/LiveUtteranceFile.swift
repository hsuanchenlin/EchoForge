import AVFoundation
import Foundation

/// One utterance, written out the way `AudioRecorder` writes a recording, so an
/// engine decodes it exactly as it would decode the whole file.
///
/// A file rather than a buffer because that is the one input every engine
/// takes (`TranscriptionEngine.transcribeAudio(url:)`), and matching the
/// recorder's format - 16 kHz, mono, 16-bit integer PCM - rather than writing
/// the floats directly, so the samples an utterance is decoded from carry the
/// same quantisation the whole-file decode would see. The files are short-lived:
/// written, decoded, removed. They go into the recorder's own temporary
/// directory so one left behind by a crash is swept with the rest after 24 h.
enum LiveUtteranceFile {

    /// Where utterance files go. The recorder's temporary directory, which is
    /// created at launch and cleaned of stale files.
    static var directory: URL { AudioRecorder.temporaryRecordingsDirectory }

    /// The recorder's settings, byte for byte.
    static let fileSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: PCMAudioLoader.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
    ]

    /// Writes `samples` as a WAV at a fresh URL in `directory` and returns it.
    static func write(_ samples: [Float], in directory: URL = LiveUtteranceFile.directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("live-\(UUID().uuidString).wav")
        try write(samples, to: url)
        return url
    }

    static func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: PCMAudioLoader.sampleRate,
            channels: 1, interleaved: false)
        else {
            throw TranscriptionError.audioConversionFailed
        }
        let file = try AVAudioFile(
            forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else {
            throw TranscriptionError.audioConversionFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { source in
                channel[0].update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}
