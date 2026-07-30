import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    
    private final class TranscriptionTaskBox {
        let task: Task<String, Error>
        init(_ task: Task<String, Error>) { self.task = task }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var transcriptionTask: TranscriptionTaskBox? = nil
    private var isCancelled = false
    
    init() {
        loadEngine()
    }
    
    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.task.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    private func loadEngine() {
        let selectedEngine = AppPreferences.shared.selectedEngine
        print("Loading engine: \(selectedEngine)")
        
        isLoading = true
        
        Task.detached(priority: .userInitiated) {
            let engine = await selectedEngine.makeEngine()

            do {
                try await engine.initialize()

                await MainActor.run {
                    self.currentEngine = engine
                    self.isLoading = false
                    print("Engine loaded: \(selectedEngine)")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }
    }
    
    func reloadEngine() {
        loadEngine()
    }

    /// Routes an engine's progress reports onto the published `progress`.
    ///
    /// Every engine is wired identically through `TranscriptionEngine`; there
    /// is deliberately no per-engine branch here. Updates arriving after a
    /// cancellation are dropped so a late callback cannot revive the bar.
    func observeProgress(of engine: TranscriptionEngine) {
        engine.onProgressUpdate = { [weak self] newProgress in
            Task { @MainActor in
                guard let self = self, !self.isCancelled else { return }
                self.progress = newProgress
            }
        }
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == .whisper {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // Serialize access to the engine: a whisper context must not process
        // two transcriptions concurrently (indicator flow and queue flow can
        // both reach this point due to async busy checks).
        while let existing = transcriptionTask {
            _ = try? await existing.task.value
            if transcriptionTask === existing {
                transcriptionTask = nil
            }
        }
        
        progress = 0.0
        conversionProgress = 0.0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""
        isCancelled = false
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }
        
        guard let engine = currentEngine else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        observeProgress(of: engine)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let rawResult = try await engine.transcribeAudio(url: url, settings: settings)

            try Task.checkCancellation()
            
            // Single post-processing choke point: every engine and every caller
            // (live dictation, the file/drop queue, the in-window recorder)
            // passes through here, so they cannot drift apart.
            let processed = TextPostProcessor.process(rawResult, settings: settings)
            let result = processed.final

            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }
            
            guard !finalCancelled else {
                throw CancellationError()
            }
            
            return result
        }
        
        transcriptionTask = TranscriptionTaskBox(task)
        
        do {
            return try await task.value
        } catch is CancellationError {
            isCancelled = true
            throw TranscriptionError.processingFailed
        }
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
