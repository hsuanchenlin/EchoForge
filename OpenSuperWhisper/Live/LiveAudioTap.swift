import AVFoundation
import CoreAudio
import Foundation

/// The microphone's samples, as a live dictation reads them while
/// `AudioRecorder` is writing the same audio to disk.
///
/// A protocol so `LiveDictationSession` can be driven with synthetic frames:
/// everything the session decides - where to cut, what to decode, when to give
/// up - is a function of the samples it was handed, and none of it should need
/// an input device to assert.
protocol LiveAudioTapping: AnyObject {
    /// Starts delivering 16 kHz mono `Float` frames in -1...1 to `onFrames`,
    /// which is called on an arbitrary thread - the audio thread in production -
    /// and must return quickly. Throws when the input cannot be opened; a tap
    /// that threw delivers nothing and needs no `stop`.
    func start(onFrames: @escaping ([Float]) -> Void) throws

    /// Stops delivering. Safe to call more than once.
    func stop()
}

/// Why the microphone could not be tapped. Never shown to the user: the
/// dictation goes on recording, the whole-file decode still runs, and the one
/// consequence is that nothing appears on the capsule while they speak.
enum LiveAudioTapError: LocalizedError, Equatable {
    /// The input node reports no usable format - there is no input device, or
    /// it has not settled on one yet.
    case noInputDevice
    /// AVFoundation would not convert the device's format to the engines' one.
    case unsupportedFormat
    /// `AVAudioEngine` refused to start, with its own explanation.
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No audio input to tap."
        case .unsupportedFormat: return "The input format could not be converted to 16 kHz mono."
        case .engineFailed(let reason): return "The audio engine could not start: \(reason)"
        }
    }
}

/// The one hardware object in live dictation: an `AVAudioEngine` input tap on
/// the device the recorder chose, converted to the PCM every engine decodes.
///
/// It is **additive** to `AudioRecorder`. The recorder keeps writing the WAV
/// that history stores and that the whole-file fallback decodes; this is a
/// second client on the same input device, which macOS allows, and it owns no
/// file. Unifying both onto one engine is a later change with its own risk.
///
/// The device is pinned on the input unit rather than left to the system
/// default. `AudioRecorder` switches the system default to the chosen
/// microphone, but it does so on its own work queue after the press, and a tap
/// that started a few milliseconds earlier would open whatever the default was
/// before - so the tap names the same `AudioDeviceID` the recorder is about to
/// use. When that lookup fails the tap falls back to the default input, which
/// is what the recorder makes the chosen device anyway.
final class LiveAudioTap: LiveAudioTapping {

    /// Samples per input callback, in the device's own rate. About 85 ms at
    /// 48 kHz: small enough that a poll never waits long for audio it can hear,
    /// large enough that the conversion below is not called hundreds of times a
    /// second.
    static let bufferSize: AVAudioFrameCount = 4096

    private let engine = AVAudioEngine()
    private let deviceID: () -> AudioDeviceID?
    private let lock = NSLock()
    private var isRunning = false

    /// - Parameter deviceID: which input to tap, resolved at `start`, on the
    ///   thread `start` is called on. The default asks `MicrophoneService` for
    ///   the microphone the user chose - the same answer `AudioRecorder` records
    ///   from - which costs CoreAudio round-trips and is why `start` belongs off
    ///   the main thread.
    init(deviceID: @escaping () -> AudioDeviceID? = LiveAudioTap.chosenInputDevice) {
        self.deviceID = deviceID
    }

    /// The CoreAudio id of the microphone the user chose in Settings, or nil
    /// when there is none or it cannot be resolved.
    static func chosenInputDevice() -> AudioDeviceID? {
        guard let device = MicrophoneService.shared.getActiveMicrophone() else { return nil }
        return MicrophoneService.shared.getCoreAudioDeviceID(for: device)
    }

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let input = engine.inputNode
        if var device = deviceID(), let unit = input.audioUnit {
            // Best effort: a refusal leaves the tap on the system default input,
            // which the recorder switches to this very device.
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                print("Live dictation: could not pin the input device (\(status)); using the default input")
            }
        }

        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw LiveAudioTapError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: PCMAudioLoader.sampleRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw LiveAudioTapError.unsupportedFormat
        }

        // One converter for the whole tap, so its resampler carries its state
        // from one buffer to the next instead of re-priming on every callback.
        input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: sourceFormat) { buffer, _ in
            guard let frames = Self.convert(buffer, with: converter, to: targetFormat) else { return }
            onFrames(frames)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw LiveAudioTapError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// One input buffer, in the engines' format. Nil when the converter produced
    /// nothing - a resampler primes itself on the first buffer - or refused.
    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        // The converter pulls input through this block. It is handed the one
        // buffer once and told there is no more for now; the next callback
        // brings the next buffer.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
