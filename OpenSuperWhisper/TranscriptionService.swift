import Foundation
import FluidAudio

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

    /// False when no engine on this Mac can transcribe *right now*, which is what
    /// the main window's banner and the indicator's message are both driven by.
    ///
    /// "Right now" is the whole change: it used to mean "the engine the user
    /// selected can load", so the minutes between choosing a model and its
    /// download finishing were indistinguishable from having no engine at all.
    /// It now means the app has *something* to transcribe with - the chosen
    /// engine, the one used before it, or the weights that ship with the app -
    /// so it is false only when there is genuinely nothing.
    ///
    /// Refreshed from disk rather than remembered: the model caches can be
    /// deleted while the app is running.
    @Published private(set) var isEngineConfigured = true

    /// The engine dictation currently runs on, and the one the user chose. They
    /// differ while a newly chosen model is still being prepared; `selection`
    /// carries both plus the reason, and is what every status surface renders.
    @Published private(set) var selection: EngineSelection

    /// The model being fetched or compiled in the background, or `nil` when
    /// nothing is. Deliberately separate from `progress`, which is the
    /// *transcription* bar: the two overlap constantly now that preparation no
    /// longer blocks dictation, and a single bar would have to lie about one of
    /// them.
    @Published private(set) var modelPreparation: ModelPreparation?

    /// Why the last background preparation stopped short, for the status row's
    /// retry path. Cleared when a new attempt starts.
    @Published private(set) var preparationFailure: String?

    private final class TranscriptionTaskBox {
        let task: Task<StyledTranscript, Error>
        init(_ task: Task<StyledTranscript, Error>) { self.task = task }
    }

    private var currentEngine: TranscriptionEngine?
    private var currentEngineKind: EngineKind?
    private var loadGeneration = 0
    private var transcriptionTask: TranscriptionTaskBox? = nil
    private var isCancelled = false
    private var preparationTask: Task<Void, Never>?

    /// Which engine `preparationTask` is fetching. Separate from the task so a
    /// completion arriving after the user changed their mind can tell that it is
    /// stale rather than overwriting whatever replaced it.
    private var preparingEngine: EngineKind?
    private var languageObserver: NSObjectProtocol?

    /// What is downloaded, when a test needs to say rather than have it read off
    /// the machine running it.
    ///
    /// `reloadEngine` already takes an `availability` argument, but the path a
    /// transcription takes does not - it re-reads the disk on purpose, because
    /// caches can be deleted while the app is running. So the seam has to live on
    /// the service. Production never sets it.
    var availabilityOverride: EngineAvailability?

    init() {
        selection = EngineSelection(
            desired: AppPreferences.shared.selectedEngine,
            active: nil,
            activeWhisperModelPath: nil,
            interimReason: nil
        )
        loadEngine()

        // The interim tiers are language-aware - an engine that would return
        // fluent Mandarin for German is not a stand-in - so changing the
        // dictation language can change which engine is running.
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appPreferencesLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadEngine(allowModelDownload: false) }
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
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

    // MARK: - Choosing what to run on

    /// Recomputes which engine dictation runs on, from what is on disk.
    ///
    /// Read-only with respect to the user's choice: it never writes
    /// `selectedEngine` or `selectedWhisperModelPath`, so neither a fresh
    /// selection still waiting on its download nor a cache removed mid-session
    /// can overwrite what the user asked for. The only preference it writes is
    /// `lastReadyEngine`, and only once an engine has genuinely loaded.
    ///
    /// `availability` is overridable so tests can pin what is downloaded without
    /// depending on the machine running them; production callers take the `nil`
    /// default.
    private func resolveSelection(availability: EngineAvailability?) -> EngineSelection {
        let preferences = AppPreferences.shared
        let availability = availability
            ?? availabilityOverride
            ?? EngineAvailability.current(fluidAudioModelVersion: preferences.fluidAudioModelVersion)

        return EngineSelector.resolve(
            desired: preferences.selectedEngine,
            desiredWhisperModelPath: preferences.selectedWhisperModelPath,
            lastReady: preferences.lastReadyEngine,
            lastReadyWhisperModelPath: preferences.lastReadyWhisperModelPath,
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion,
            availability: availability
        )
    }

    private func loadEngine(allowModelDownload: Bool = true, availability: EngineAvailability? = nil) {
        let selection = resolveSelection(availability: availability)
        self.selection = selection
        isEngineConfigured = selection.canTranscribe

        guard let active = selection.active else {
            currentEngine = nil
            currentEngineKind = nil
            isLoading = false
            startPreparingDesiredEngineIfNeeded(allowModelDownload: allowModelDownload)
            return
        }

        // Already holding exactly this engine: nothing to load, but the desired
        // one may still need preparing.
        guard currentEngineKind != active || currentEngine == nil else {
            isLoading = false
            startPreparingDesiredEngineIfNeeded(allowModelDownload: allowModelDownload)
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        print("Loading engine: \(active)")

        // Deciding what to run on is pure and is exactly what the tests assert;
        // actually loading it can mean a 240 MB fetch from Hugging Face. A test
        // host pins `availability` to describe a Mac it is not running on, so
        // going on to load would download weights the machine genuinely does not
        // have. The decision above has already been published either way.
        guard !OpenSuperWhisperApp.isRunningTests else {
            isLoading = false
            return
        }

        isLoading = true

        Task.detached(priority: .userInitiated) {
            let engine = await active.makeEngine()

            do {
                try await engine.initialize()

                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.currentEngine = engine
                    self.currentEngineKind = active
                    self.isLoading = false
                    self.rememberReadyEngine(active)
                    // The selection is recomputed rather than assumed: the user
                    // may have chosen a different engine while this one loaded.
                    self.refreshSelection()
                    NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
                    print("Engine loaded: \(active)")
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }

        startPreparingDesiredEngineIfNeeded(allowModelDownload: allowModelDownload)
    }

    /// Records the engine that actually loaded, which is what a later launch
    /// falls back to while a newly chosen model downloads.
    ///
    /// Written only on a successful load, and to its own keys - never to
    /// `selectedEngine`. That separation is the guarantee that a fallback cannot
    /// become the user's choice by accident.
    private func rememberReadyEngine(_ engine: EngineKind) {
        let preferences = AppPreferences.shared
        preferences.lastReadyEngine = engine
        if engine == .whisper {
            preferences.lastReadyWhisperModelPath = selection.activeWhisperModelPath
                ?? preferences.selectedWhisperModelPath
        }
    }

    /// Recomputes which engine would be used, and publishes it, without loading
    /// anything.
    ///
    /// The two halves are separate on purpose. Deciding is pure and instant;
    /// loading can mean a 240 MB download and a minute of CoreML compilation. So
    /// this runs after a load or a download completes to keep the banner and the
    /// status row in step, and it is also what a test drives when it wants to
    /// assert the decision rather than pay for the load.
    func refreshSelection(availability: EngineAvailability? = nil) {
        selection = resolveSelection(availability: availability)
        isEngineConfigured = selection.canTranscribe
    }

    func reloadEngine(allowModelDownload: Bool = true, availability: EngineAvailability? = nil) {
        loadEngine(allowModelDownload: allowModelDownload, availability: availability)
    }

    // MARK: - Background preparation

    /// Fetches the desired engine's weights while the app carries on.
    ///
    /// This is what makes choosing a model non-modal: the work that used to
    /// happen inside the user's first dictation - a 240 or 653 MB download and a
    /// one-time Neural Engine compile of about a minute - runs here instead,
    /// with `EngineSelector` keeping dictation on whatever is already ready.
    ///
    /// `ModelLoadCoordinator` inside each engine collapses this with a download
    /// started from Settings or onboarding, so nothing is ever fetched twice.
    private func startPreparingDesiredEngineIfNeeded(allowModelDownload: Bool) {
        guard allowModelDownload else { return }

        // Whatever is being fetched, it is only worth fetching while it is still
        // what the user wants. Changing engines mid-download - or changing back
        // to one that is already ready - stops the old fetch rather than leaving
        // hundreds of megabytes of nobody's choice arriving in the background.
        let desired = selection.desired
        if let preparingEngine, preparingEngine != desired {
            stopPreparation()
        }

        guard selection.isDesiredEnginePending else {
            stopPreparation()
            return
        }
        guard EngineConfiguration.isPreparable(engine: desired) else { return }
        // Already fetching exactly this one; restarting would throw away progress.
        guard preparingEngine != desired else { return }
        // The same reason as in `loadEngine`: a test must not be able to start a
        // several-hundred-megabyte download of the developer's bandwidth.
        guard !OpenSuperWhisperApp.isRunningTests else { return }

        preparingEngine = desired
        preparationFailure = nil
        modelPreparation = ModelPreparation(engine: desired, stage: .preparing)
        // Survives a quit: `EngineConfiguration.recoverIfNeeded` reads this at
        // the next launch so an interrupted download is resumed rather than
        // treated as a stale selection and overwritten.
        AppPreferences.shared.pendingEnginePreparation = desired

        // The weak reference is resolved once, synchronously, rather than being
        // read again from inside the `Task`: a captured `weak var` read across a
        // concurrency boundary is an error under the Swift 6 language mode.
        let onProgress: DownloadUtils.ProgressHandler = { [weak self] progress in
            guard let service = self else { return }
            let stage = ModelPreparationStage.from(progress)
            Task { @MainActor in
                guard service.selection.desired == desired else { return }
                service.modelPreparation = ModelPreparation(engine: desired, stage: stage)
            }
        }

        preparationTask = Task { [weak self] in
            do {
                try await EngineWeightsPreparation.production.prepare(desired, progressHandler: onProgress)
                await MainActor.run {
                    // A newer preparation may have replaced this one while it
                    // ran; whatever it did to the published state stands.
                    guard let self, self.preparingEngine == desired else { return }
                    self.finishPreparation()
                    // Switching over is the point: the engine the user chose is
                    // ready, so the next dictation uses it without them asking
                    // again.
                    self.loadEngine()
                    NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.preparingEngine == desired else { return }
                    self.finishPreparation()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.preparingEngine == desired else { return }
                    self.finishPreparation()
                    self.preparationFailure = error.localizedDescription
                }
            }
        }
    }

    /// A preparation that ran to its end, one way or another.
    private func finishPreparation() {
        preparationTask = nil
        preparingEngine = nil
        modelPreparation = nil
        AppPreferences.shared.pendingEnginePreparation = nil
    }

    /// Abandons whatever is being fetched, if anything.
    ///
    /// It clears `pendingEnginePreparation` too: that marker exists to tell the
    /// next launch "this selection is still arriving", and once nothing is
    /// arriving it would only stop recovery repairing a configuration that
    /// genuinely cannot load.
    private func stopPreparation() {
        preparationTask?.cancel()
        finishPreparation()
    }

    /// Stops fetching the desired engine's weights, leaving the selection alone.
    ///
    /// The preference is deliberately untouched: the user asked for this engine
    /// and cancelling a download is not withdrawing that. The status row keeps
    /// naming it and offers to try again.
    func cancelDesiredEnginePreparation() {
        stopPreparation()
        preparationFailure = nil
    }

    /// The retry path behind the status row, and the one the main window's
    /// banner offers when nothing can transcribe.
    func retryPreparingDesiredEngine() {
        preparationFailure = nil
        loadEngine()
    }

    // MARK: - Transcribing

    private func engineForTranscription() async throws -> TranscriptionEngine {
        // Checked here rather than left to `initialize()` to fail: this is the
        // one point every transcription passes through, and the difference
        // between "nothing is set up" and "the engine did not load" is the
        // difference between an error the user can act on and one they cannot.
        //
        // Read-only, like `loadEngine()`: recovery that rewrites the stored
        // engine only runs at launch (`EngineConfiguration.recoverIfNeeded`). A
        // transcription attempted while the chosen engine is still downloading
        // now runs on the interim one rather than failing, and a Mac with
        // nothing at all still fails visibly and leaves the choice as made.
        refreshSelection()
        guard let active = selection.active else {
            throw TranscriptionError.engineNotConfigured
        }
        if currentEngineKind == active, let currentEngine { return currentEngine }

        let engine = await active.makeEngine()
        try await engine.initialize()
        currentEngine = engine
        currentEngineKind = active
        rememberReadyEngine(active)
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

    /// Transcribes one file and runs the whole post-processing pipeline over it.
    ///
    /// Returns `StyledTranscript` rather than a string because the callers store
    /// what they get: once a stage can rewrite the user's words, "the text" is
    /// two texts - what was said and what the app made of it - and a caller
    /// handed only the second one cannot keep the first. See
    /// `docs/text-post-processing.md`.
    func transcribeAudio(url: URL, settings: Settings) async throws -> StyledTranscript {
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

        // Resolved once, outside the task: reading a captured `weak var` from
        // inside concurrently-executing code is an error under the Swift 6
        // language mode. The task is stored on this object and cancelled with it,
        // so holding it for the length of one transcription creates no cycle that
        // outlives the work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let service = self else { throw CancellationError() }
            try Task.checkCancellation()

            let cancelled = await MainActor.run { service.isCancelled }

            guard !cancelled else {
                throw CancellationError()
            }

            let rawResult = try await engine.transcribeAudio(url: url, settings: settings)

            try Task.checkCancellation()

            // Single post-processing choke point: every engine and every caller
            // (live dictation, the file/drop queue, the in-window recorder)
            // passes through here, so they cannot drift apart.
            let processed = TextPostProcessor.process(rawResult, settings: settings)

            // The model-backed stages are last, are the only ones that can
            // fail, and return the deterministic text unchanged when they do.
            // Which of them runs is `SpokenIntentPipeline`'s decision: normally
            // the chosen style, and for a caller that asked for routing, a
            // spoken command instead.
            let styled = await SpokenIntentPipeline.apply(to: processed, settings: settings)
            let result = styled.final

            let finalCancelled = await MainActor.run { service.isCancelled }

            await MainActor.run {
                guard !service.isCancelled else { return }
                service.transcribedText = result
                service.progress = 1.0
            }

            guard !finalCancelled else {
                throw CancellationError()
            }

            return styled
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

    /// Nothing on this Mac can transcribe: no engine's weights are present, and
    /// there is neither a previously used model nor a bundled starter to stand
    /// in while the chosen one is fetched.
    ///
    /// Kept apart from `contextInitializationFailed` because it is the one
    /// failure the user can fix, and the only one worth a sentence of their
    /// attention rather than a console line.
    case engineNotConfigured

    /// The engine ran, and what came back is not a language it can transcribe.
    ///
    /// Only an engine that *cannot refuse* a language throws this: Paraformer
    /// takes no language parameter, so a non-Mandarin recording is not rejected
    /// by the model, it is mis-transcribed into fragments
    /// (`ParaformerLanguageGuard`). It is its own case rather than
    /// `processingFailed` because nothing failed technically - the fix is a
    /// different engine, the audio is perfectly good, and `DictationFailureOutcome`
    /// therefore keeps it.
    ///
    /// The two strings are carried rather than looked up so this stays engine-
    /// neutral: the wording belongs to whichever engine had to refuse, and the
    /// failure path only needs a sentence and a two-word form of it.
    case unsupportedSpokenLanguage(message: String, shortMessage: String)

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
        case .unsupportedSpokenLanguage(let message, _):
            return message
        }
    }
}
