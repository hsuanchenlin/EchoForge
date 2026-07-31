import Foundation
import AVFoundation

/// Decodes any audio file the app accepts into the one PCM format every engine
/// wants: 16 kHz, mono, `Float` samples in -1...1.
///
/// Engine-neutral on purpose. It used to live inside `WhisperEngine`, which
/// meant a second engine could only reuse it by depending on the first one.
enum PCMAudioLoader {

    /// The sample rate every engine in the app is fed at. Chunk budgets and VAD
    /// segment arithmetic are expressed against it.
    static let sampleRate: Double = 16000

    /// Decodes `fileURL` to 16 kHz mono float samples, or `nil` when the file
    /// decodes to nothing.
    static func loadSamples(from fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let (resolvedURL, isTempFile) = try resolveFileURL(fileURL)
            defer {
                if isTempFile { try? FileManager.default.removeItem(at: resolvedURL) }
            }
            let audioFile = try AVAudioFile(forReading: resolvedURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length

            guard let targetFormat = makeTargetFormat(channelCount: sourceFormat.channelCount) else {
                return nil
            }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate

            // Use parallel processing for large files (> 10 seconds of audio)
            // Benchmarked: 4 cores = +339%, 8 cores = +609% improvement
            let minFramesForParallel = AVAudioFramePosition(sourceFormat.sampleRate * 10)
            let workerCount = totalFrames > minFramesForParallel ? ProcessInfo.processInfo.activeProcessorCount : 1

            if workerCount == 1 {
                let result = try convertSegment(
                    fileURL: resolvedURL,
                    sourceFormat: sourceFormat,
                    targetFormat: targetFormat,
                    ratio: ratio,
                    startFrame: 0,
                    frameCount: totalFrames,
                    inputChunkSize: 1_048_576
                )
                return result.isEmpty ? nil : result
            }

            // Parallel processing: each worker converts its own frame range with an
            // independent converter (flushed at the end), results are concatenated in
            // worker order so no samples are lost or overwritten at boundaries.
            let framesPerWorker = totalFrames / AVAudioFramePosition(workerCount)
            // `AVAudioFormat` is not `Sendable`, so each worker rebuilds the pair it
            // needs from the file rather than capturing this scope's formats. The
            // conversion reopens the file anyway, so nothing is lost by doing so.
            let channelCount = sourceFormat.channelCount

            var segmentResults = await withTaskGroup(
                of: (Int, [Float]?).self,
                returning: [[Float]?].self
            ) { group in
                for workerIndex in 0..<workerCount {
                    let startFrame = AVAudioFramePosition(workerIndex) * framesPerWorker
                    let endFrame = workerIndex == workerCount - 1 ? totalFrames : startFrame + framesPerWorker

                    group.addTask {
                        guard let workerSource = try? AVAudioFile(forReading: resolvedURL).processingFormat,
                              let workerTarget = makeTargetFormat(channelCount: channelCount) else {
                            return (workerIndex, nil)
                        }

                        let segment = try? convertSegment(
                            fileURL: resolvedURL,
                            sourceFormat: workerSource,
                            targetFormat: workerTarget,
                            ratio: workerTarget.sampleRate / workerSource.sampleRate,
                            startFrame: startFrame,
                            frameCount: endFrame - startFrame,
                            inputChunkSize: 262_144
                        )
                        return (workerIndex, segment)
                    }
                }

                // Workers finish out of order; index them back into worker order so
                // the concatenation below stays gap-free.
                var collected = [[Float]?](repeating: nil, count: workerCount)
                for await (workerIndex, segment) in group {
                    collected[workerIndex] = segment
                }
                return collected
            }

            guard !segmentResults.contains(where: { $0 == nil }) else { return nil }

            // Release each segment right after it is appended, so the peak stays
            // near 1x of the total instead of holding both copies until the end.
            var result = [Float]()
            result.reserveCapacity(segmentResults.reduce(0) { $0 + ($1?.count ?? 0) })
            for index in segmentResults.indices {
                result.append(contentsOf: segmentResults[index]!)
                segmentResults[index] = nil
            }

            return result.isEmpty ? nil : result
        }.value
    }

    static func makeTargetFormat(channelCount: AVAudioChannelCount) -> AVAudioFormat? {
        guard channelCount > 0 else { return nil }

        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }

        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: channelLayout
        )
    }

    static func convertSegment(
        fileURL: URL,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        ratio: Double,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        inputChunkSize: AVAudioFrameCount
    ) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        audioFile.framePosition = startFrame

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        // Buffers hold Float32 per channel, so cap the chunk by bytes: a chunk sized
        // in frames alone balloons for multi-channel sources (8ch = 32 MB per buffer).
        let maxChunkBytes = 8 * 1024 * 1024
        let bytesPerFrame = Int(sourceFormat.channelCount) * MemoryLayout<Float>.size
        let chunkFrames = min(inputChunkSize, AVAudioFrameCount(max(maxChunkBytes / bytesPerFrame, 65536)))

        let outputChunkSize = AVAudioFrameCount(Double(chunkFrames) * ratio) + 256
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            throw TranscriptionError.audioConversionFailed
        }

        var result = [Float]()
        result.reserveCapacity(Int(Double(frameCount) * ratio) + 256)

        var framesRead: AVAudioFramePosition = 0

        while framesRead < frameCount {
            let framesToRead = min(AVAudioFrameCount(frameCount - framesRead), chunkFrames)
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)

            if inputBuffer.frameLength == 0 { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)

            var inputConsumed = false
            var convError: NSError?

            outputBuffer.frameLength = 0
            converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let convError = convError {
                throw convError
            }

            appendMixedSamples(from: outputBuffer, to: &result)
        }

        // Flush the resampler: without an .endOfStream pass its internal latency
        // (the last few milliseconds of audio) is silently dropped.
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            var convError: NSError?
            outputBuffer.frameLength = 0
            status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if convError != nil { break }
            appendMixedSamples(from: outputBuffer, to: &result)
        }

        return result
    }

    // MARK: - Private

    /// Some sources hand us an MPEG-4 container under a misleading extension,
    /// which `AVAudioFile` refuses to open. Copy it to a `.m4a` temp file first.
    private static func resolveFileURL(_ fileURL: URL) throws -> (URL, Bool) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count >= 12 else { return (fileURL, false) }

        let ext = fileURL.pathExtension.lowercased()

        let isMP4Header = data[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) // "ftyp"
        if isMP4Header && ext != "m4a" && ext != "mp4" && ext != "m4b" && ext != "aac" {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: fileURL, to: tmpURL)
            return (tmpURL, true)
        }

        return (fileURL, false)
    }

    private static func appendMixedSamples(from buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            output.append(contentsOf: mono)
            return
        }

        let activityThreshold: Float = 0.0001
        var activeChannels: [Int] = []
        activeChannels.reserveCapacity(channelCount)

        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            var energy: Float = 0
            for sample in channelSamples {
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms > activityThreshold {
                activeChannels.append(channel)
            }
        }

        if activeChannels.isEmpty {
            activeChannels = Array(0..<channelCount)
        }

        let normalization = 1.0 / Float(activeChannels.count)
        output.reserveCapacity(output.count + frameCount)

        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in activeChannels {
                mixed += channelData[channel][frame]
            }
            output.append(mixed * normalization)
        }
    }
}
