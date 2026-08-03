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

    /// False when no engine on this Mac can transcribe, which is what the main
    /// window's banner and the indicator's message are both driven by.
    ///
    /// Refreshed from disk rather than remembered: the model caches can be
    /// deleted while the app is running.
    @Published private(set) var isEngineConfigured = true

    private final class TranscriptionTaskBox {
        let task: Task<String, Error>
        init(_ task: Task<String, Error>) { self.task = task }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var currentEngineKind: EngineKind?
    private var loadGeneration = 0
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
    
    /// Whether the stored engine can load right now, given what is actually
    /// downloaded. Read-only: it never writes `AppPreferences`, unlike
    /// `EngineConfiguration.recoverIfNeeded()` - so neither a load triggered by
    /// a just-picked, not-yet-downloaded Settings selection nor a transcription
    /// attempted against one silently overwrites the user's choice with a
    /// recovery guess.
    private func isSelectedEngineConfigured(_ selectedEngine: EngineKind, availability: EngineAvailability) -> Bool {
        EngineConfiguration.isConfigured(
            engine: selectedEngine,
            whisperModelPath: AppPreferences.shared.selectedWhisperModelPath,
            availability: availability
        )
    }

    /// `availability` is overridable so tests can pin what recovery would have
    /// found without depending on which engines happen to be downloaded on the
    /// machine running them; production callers always take the `nil` default.
    private func loadEngine(allowModelDownload: Bool = true, availability: EngineAvailability? = nil) {
        let selectedEngine = AppPreferences.shared.selectedEngine
        let availability = availability
            ?? EngineAvailability.current(fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
        isEngineConfigured = isSelectedEngineConfigured(selectedEngine, availability: availability)
        guard isEngineConfigured else {
            currentEngine = nil
            currentEngineKind = nil
            isLoading = false
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        print("Loading engine: \(selectedEngine)")

        if !allowModelDownload, selectedEngine.isSingleModelDownloaded == false {
            currentEngine = nil
            currentEngineKind = nil
            isLoading = false
            return
        }
        
        isLoading = true
        
        Task.detached(priority: .userInitiated) {
            let engine = await selectedEngine.makeEngine()

            do {
                try await engine.initialize()

                await MainActor.run {
                    guard self.loadGeneration == generation,
                        AppPreferences.shared.selectedEngine == selectedEngine
                    else { return }
                    self.currentEngine = engine
                    self.currentEngineKind = selectedEngine
                    self.isLoading = false
                    NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
                    print("Engine loaded: \(selectedEngine)")
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }
    }
    
    func reloadEngine(allowModelDownload: Bool = true, availability: EngineAvailability? = nil) {
        loadEngine(allowModelDownload: allowModelDownload, availability: availability)
    }

    private func engineForTranscription() async throws -> TranscriptionEngine {
        // Checked here rather than left to `initialize()` to fail: this is the
        // one point every transcription passes through, and the difference
        // between "no engine is set up" and "the engine did not load" is the
        // difference between an error the user can act on and one they cannot.
        //
        // Read-only, like `loadEngine()`: recovery that rewrites the stored
        // engine only runs at launch (`EngineConfiguration.recoverIfNeeded`). A
        // transcription attempted against a fresh, not-yet-downloaded selection
        // - or a cache removed while the app was running - must not silently
        // fall back onto a different engine; it fails visibly and leaves the
        // user's choice exactly as they made it.
        let selectedEngine = AppPreferences.shared.selectedEngine
        let availability = EngineAvailability.current(fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
        isEngineConfigured = isSelectedEngineConfigured(selectedEngine, availability: availability)
        guard isEngineConfigured else {
            throw TranscriptionError.engineNotConfigured
        }
        if currentEngineKind == selectedEngine, let currentEngine { return currentEngine }

        let engine = await selectedEngine.makeEngine()
        try await engine.initialize()
        guard AppPreferences.shared.selectedEngine == selectedEngine else {
            throw TranscriptionError.contextInitializationFailed
        }
        currentEngine = engine
        currentEngineKind = selectedEngine
        NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
        return engine
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
        
        let engine = try await engineForTranscription()
        
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

extension Notification.Name {
    static let engineModelStateChanged = Notification.Name("engineModelStateChanged")
}

enum TranscriptionError: LocalizedError, Equatable {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed

    /// Nothing on this Mac can transcribe: no engine's weights are present, or
    /// the stored Whisper model has been deleted and no other engine is there
    /// to recover onto.
    ///
    /// Kept apart from `contextInitializationFailed` because it is the one
    /// failure the user can fix, and the only one worth a sentence of their
    /// attention rather than a console line.
    case engineNotConfigured

    /// `LocalizedError` so the failure reaches the user as an instruction
    /// rather than as "OpenSuperWhisper.TranscriptionError error 0" - the queue
    /// has always shown `localizedDescription` on a failed recording, which
    /// until now said nothing anyone could act on.
    var errorDescription: String? {
        switch self {
        case .engineNotConfigured:
            return EngineConfiguration.unavailableMessage
        case .contextInitializationFailed:
            return "The transcription engine could not be loaded."
        case .audioConversionFailed:
            return "The audio could not be read."
        case .processingFailed:
            return "The audio could not be transcribed."
        }
    }
}
