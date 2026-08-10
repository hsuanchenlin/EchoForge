import Foundation

/// Carries the progress handler across the whisper C progress callback, which
/// fires on whisper's own worker thread.
///
/// `@unchecked Sendable` is the honest annotation here: every stored property is
/// guarded by `lock`, so the instance can be handed to that callback and to the
/// main-queue hop that delivers each update.
private final class ProgressContext: @unchecked Sendable {
    private var _onProgress: ((Float) -> Void)?
    private var _lastReportedProgress: Float = 0.0
    private let lock = NSLock()

    var onProgress: ((Float) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onProgress
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onProgress = newValue
        }
    }

    var lastReportedProgress: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastReportedProgress
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastReportedProgress = newValue
        }
    }
}

class WhisperEngine: TranscriptionEngine {
    var engineName: String { "Whisper" }
    
    private var context: MyWhisperContext?
    /// Held for the engine's lifetime so the VAD model is loaded once, not once
    /// per transcription.
    private let segmenter = SpeechSegmenter()
    private let abortFlag = AbortFlag()
    private var progressContext: ProgressContext?
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        context != nil
    }
    
    func initialize() async throws {
        let modelPath = AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        let params = WhisperContextParams()
        // Load the model without a decoding state: a fresh whisper_state is
        // created per transcription, so recordings can share the model weights
        // while keeping their decoding context (prompt_past) fully isolated.
        context = MyWhisperContext.initFromFileNoState(path: modelPath, params: params)
        
        guard context != nil else {
            throw TranscriptionError.contextInitializationFailed
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        abortFlag.isSet = false
        
        // Setup progress context for callback
        progressContext = ProgressContext()
        progressContext?.onProgress = onProgressUpdate
        
        defer {
            progressContext = nil
        }
        
        // Notify conversion start (0-10% is conversion phase)
        onProgressUpdate?(0.05)
        
        guard let converted = try await PCMAudioLoader.loadSamples(from: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        // Conversion done, now processing
        onProgressUpdate?(0.10)
        
        try Task.checkCancellation()
        
        // VAD gate: whisper never sees non-speech audio, so silence cannot
        // produce hallucinated text and long pauses are not decoded at all.
        // (whisper_full_with_state has no built-in VAD path - params.vad works
        // only through whisper_full, which would share decoding state.)
        let speechSegments = try segmenter.segments(in: converted)
        if speechSegments.isEmpty {
            return ""
        }
        // Timestamps of the trimmed audio would not match the original file,
        // so trimming is applied only when timestamps are not requested.
        let samples = settings.showTimestamps
            ? converted
            : SpeechSegmenter.speechOnlySamples(from: converted, segments: speechSegments)
        
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        
        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        // Match whisper.cpp defaults: on temperature fallback the decoder samples
        // best_of candidates and keeps the most probable one; with 1 the fallback
        // degenerates to a single random sample on hard audio.
        params.greedyBestOf = 5
        // Each transcription runs on a fresh whisper_state (see below), so text
        // context flows between 30s windows within one recording (better
        // coherence, upstream default) but can never leak into the next one.
        params.noContext = false
        params.noTimestamps = !settings.showTimestamps
        params.suppressBlank = settings.suppressBlankAudio
        let isAutoDetect = settings.selectedLanguage == "auto"
        params.language = isAutoDetect ? nil : settings.selectedLanguage
        params.detectLanguage = false // means that it only detects the language and does not process the transcription
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
        // With noContext = false the initial prompt conditions only the first
        // 30s window; carrying it keeps the user's vocabulary effective for the
        // whole recording.
        params.carryInitialPrompt = params.initialPrompt != nil
        
        typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool
        let abortCallback: GGMLAbortCallback = { userData in
            guard let userData = userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isSet
        }
        
        // Progress callback: whisper reports 0-100%, we map to 10-95%
        // Note: callback is called from C code, we need to bridge to Swift safely
        typealias WhisperProgressCallback = @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void
        let progressCallback: WhisperProgressCallback = { _, _, progressPercent, userData in
            guard let userData = userData else { return }
            let ctx = Unmanaged<ProgressContext>.fromOpaque(userData).takeUnretainedValue()
            // Map whisper progress (0-100) to our range (10-95%)
            let normalizedProgress = 0.10 + (Float(progressPercent) / 100.0) * 0.85
            // Report every progress update for smooth animation
            if normalizedProgress > ctx.lastReportedProgress {
                ctx.lastReportedProgress = normalizedProgress
                DispatchQueue.main.async {
                    ctx.onProgress?(normalizedProgress)
                }
            }
        }
        
        let progressContextPtr = Unmanaged.passUnretained(progressContext!).toOpaque()
        params.progressCallback = progressCallback
        params.progressCallbackUserData = progressContextPtr
        
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }
        
        var cParams = params.toC()
        cParams.abort_callback = abortCallback
        cParams.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()
        
        try Task.checkCancellation()
        
        // Fresh decoding state per recording: isolates prompt_past between
        // recordings (a hallucination on silence cannot poison the next one).
        guard context.initState() else {
            throw TranscriptionError.contextInitializationFailed
        }
        defer {
            context.freeState()
        }
        
        guard context.full(samples: samples, params: &cParams) else {
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        var text = ""
        let nSegments = context.fullNSegments
        
        for i in 0..<nSegments {
            if i % 5 == 0 {
                try Task.checkCancellation()
            }
            
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            
            if settings.showTimestamps {
                let t0 = context.fullGetSegmentT0(iSegment: i)
                let t1 = context.fullGetSegmentT1(iSegment: i)
                text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
            }
            text += segmentText + "\n"
        }
        
        // Engine-specific cleanup only. Shared transcript post-processing is
        // applied once by TextPostProcessor, via TranscriptionService.
        return text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func cancelTranscription() {
        abortFlag.isSet = true
    }
    
    func getSupportedLanguages() -> [String] {
        return LanguageUtil.availableLanguages
    }
}
