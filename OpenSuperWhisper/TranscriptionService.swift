import Foundation
import FluidAudio

@MainActor
final class EngineWeightUseCoordinator {
    static let shared = EngineWeightUseCoordinator()

    enum RemovalReservationResult: Equatable {
        case reserved
        case engineInUse
        case alreadyReserved
    }

    private var activeUses: [EngineKind: Int] = [:]
    private var removalReservations: Set<EngineKind> = []

    func beginUse(of engine: EngineKind) -> Bool {
        guard !removalReservations.contains(engine) else { return false }
        activeUses[engine, default: 0] += 1
        return true
    }

    func endUse(of engine: EngineKind) {
        guard let count = activeUses[engine] else { return }
        if count == 1 {
            activeUses.removeValue(forKey: engine)
        } else {
            activeUses[engine] = count - 1
        }
    }

    func reserveRemoval(of engine: EngineKind) -> RemovalReservationResult {
        guard activeUses[engine] == nil else { return .engineInUse }
        guard removalReservations.insert(engine).inserted else { return .alreadyReserved }
        return .reserved
    }

    func releaseRemoval(of engine: EngineKind) {
        removalReservations.remove(engine)
    }

    func isRemovalReserved(for engine: EngineKind) -> Bool {
        removalReservations.contains(engine)
    }
}

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""

    /// What the running engine has decoded so far, or nil when it has decoded
    /// nothing yet or cannot say.
    ///
    /// Nil is two different facts deliberately collapsed into one, because a
    /// surface can only do the same thing about both: this engine does not
    /// report partial output (`PartialTranscriptEmitting`), or it does and has
    /// not committed a segment yet. Either way there is nothing to show and
    /// progress is what the user gets, which is what every overlay did before
    /// this existed.
    ///
    /// Deliberately **not** merged into `progress`: they answer different
    /// questions and overlap routinely, the same separation transcription and
    /// model-preparation progress keep.
    @Published private(set) var partialTranscript: PartialTranscript?

    /// Whether the engine that would run now can report text before it finishes.
    ///
    /// Read once by a surface deciding what to draw, so "no partial output" is
    /// a property of the engine rather than a nil that might become non-nil at
    /// any moment.
    var supportsPartialTranscripts: Bool { currentEngine is PartialTranscriptEmitting }
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

    /// The transcription in flight: what the serialisation loop in
    /// `runTranscription` waits on, and what `cancelTranscription` cancels.
    ///
    /// A frame, not a task: it is created and stored *before* the frame's
    /// `prepare` step suspends, when there is no task yet, and released in the
    /// frame's own `defer`, so it spans the engine load as well as the work.
    /// It used to be a box around the work task alone, stored only once the
    /// task existed - and the engine load before it is a suspension point, so
    /// a second caller arriving during the load saw no task, passed the
    /// serialisation loop, and both ran on the engine at once: an utterance
    /// decode from a live session beside a queued file, or a queued file beside
    /// the first dictation of the session. `TranscriptionSerializationTests`
    /// holds the window shut.
    ///
    /// Type-erased because two shapes of work run inside one frame - a decode
    /// that returns the engine's raw text and a full transcription that returns
    /// a `StyledTranscript` - and the loop and `cancelTranscription` need only
    /// to wait on either and to cancel either. Main-actor isolated like the
    /// service that owns it, which is what lets it keep its waiters without a
    /// lock.
    @MainActor
    private final class TranscriptionFrame {
        private var cancelTask: (() -> Void)?
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Hands the frame its work, once `prepare` has produced what the work
        /// needs. A cancel that arrived while the frame was still preparing
        /// has already tagged its generation, and the work checks that before
        /// it starts.
        func bind<Result>(_ task: Task<Result, Error>) {
            cancelTask = { task.cancel() }
        }

        func cancel() {
            cancelTask?()
        }

        /// Lets every caller queued behind this frame go. Called from the
        /// frame's `defer`, so it runs whether `prepare` threw, the work threw
        /// or was cancelled, or it returned - a frame that was reserved is
        /// always released, and nobody waits on it for ever.
        func finish() {
            finished = true
            let released = waiters
            waiters = []
            for waiter in released { waiter.resume() }
        }

        /// Returns once `finish` has run. A waiter whose own task is cancelled
        /// keeps waiting, as it always has: letting it through early would put
        /// it on the engine beside the frame it was waiting for, and the work
        /// it runs next checks cancellation itself.
        func waitUntilFinished() async {
            guard !finished else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private var currentEngine: TranscriptionEngine?
    private var currentEngineKind: EngineKind?

    /// Which load of the engine is current. Advanced every time `loadEngine`
    /// decides to load again - another kind, or the same kind after nothing
    /// was loaded - so a load that finishes late can tell it has been
    /// superseded, and a live session can tell the engine under it is not the
    /// one it started on even when the kind is.
    private(set) var loadGeneration = 0
    private var transcriptionTask: TranscriptionFrame? = nil

    /// Which transcription the published state belongs to.
    ///
    /// The same device `loadGeneration` is, and for the same reason: a
    /// transcription's teardown runs a main-queue hop after the work ends, by
    /// which time a *different* transcription may own this object. Without the
    /// check, a cancelled one's teardown published `isTranscribing = false`
    /// over the live one - and the next press then read an idle service and
    /// started a second transcription on an engine that was still inside the
    /// first. The frame needs no such check: `runTranscription` releases it
    /// synchronously in its `defer`, by identity, before that hop.
    private var transcriptionGeneration = 0

    /// The generation `cancelTranscription` last stopped, or nil if none has
    /// been.
    ///
    /// A generation rather than a bool for the same reason the teardown is
    /// generation-checked, and it is the same bug one step further on: a single
    /// shared flag is written by a cancelled transcription's own `catch`, which
    /// runs a main-actor hop *after* the transcription that replaced it has
    /// already started - so cancelling one dictation cancelled the next one too,
    /// before its engine had been asked for a single sample.
    private var cancelledGeneration: Int?

    /// Whether that transcription was cancelled. A generation nobody cancelled
    /// is not cancelled, so there is no flag to reset when one starts.
    private func isCancelled(_ generation: Int) -> Bool {
        cancelledGeneration == generation
    }

    /// Whether the transcription in flight was cancelled.
    private var isCancelled: Bool { isCancelled(transcriptionGeneration) }
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

    /// The engine a transcription runs on, when a test needs to say rather than
    /// have one loaded off the machine running it.
    ///
    /// The same kind of seam as `availabilityOverride`, and it exists for the
    /// same reason: the decisions this class makes *around* a transcription -
    /// what cancelling leaves in flight, which teardown is allowed to clear the
    /// published state, whether two callers can reach the engine at once -
    /// are the part worth asserting, and every one of them sits behind a
    /// several-hundred-megabyte download otherwise. It is initialised once
    /// before its first transcription, as a real engine is, so a stub can be
    /// made to take as long to load as a real one does. Production never sets
    /// it.
    var engineOverride: TranscriptionEngine?

    /// How long one decode may take per second of audio, and the least a decode
    /// of any length may take, before it is declared hung.
    ///
    /// The budget scales with the recording because the legitimate cost does:
    /// the slowest warm decode this app has measured is well under realtime
    /// (`docs/dictation-latency.md`), so ten times the audio's length is far
    /// above any decode that is still working and far below the user's patience
    /// for one that is not. The floor keeps a two-second utterance from being
    /// declared hung twenty seconds in - a loaded machine or a first decode
    /// after a cold start costs that without anything being wrong.
    nonisolated static let decodeTimeoutFactor: TimeInterval = 10
    nonisolated static let decodeTimeoutFloor: TimeInterval = 120

    /// How long an engine load may take before it is declared hung.
    ///
    /// A cold load is a one-time Neural Engine compile measured at ~85 s, paid
    /// again after every ANE cache eviction; under load it has been observed
    /// past ten minutes. Fifteen minutes is above every load that still ends
    /// and below "the dictation key stopped answering", which is what a
    /// deadlocked load looks like from the keyboard: the frame is held, and
    /// every transcription queues behind it for the life of the process.
    nonisolated static let loadTimeout: TimeInterval = 900

    /// What one decode of `seconds` of audio may take. Pure, so the shape the
    /// tests pin is the shape production runs.
    nonisolated static func decodeTimeoutBudget(forAudioDuration seconds: TimeInterval) -> TimeInterval {
        max(decodeTimeoutFloor, seconds * decodeTimeoutFactor)
    }

    /// Test seams for the two deadlines above, the same kind of seam as
    /// `engineOverride`: the decisions around a timed-out transcription - that
    /// the frame is released, that the engine is dropped, that the failure is
    /// clean - are worth asserting without spending fifteen minutes per test.
    /// Production never sets them.
    var decodeTimeoutOverride: TimeInterval?
    var loadTimeoutOverride: TimeInterval?

    func reserveEngineForRemoval(
        _ engine: EngineKind
    ) -> EngineWeightUseCoordinator.RemovalReservationResult {
        EngineWeightUseCoordinator.shared.reserveRemoval(of: engine)
    }

    func releaseEngineRemovalReservation(_ engine: EngineKind) {
        EngineWeightUseCoordinator.shared.releaseRemoval(of: engine)
    }

    func isEngineReservedForRemoval(_ engine: EngineKind) -> Bool {
        EngineWeightUseCoordinator.shared.isRemovalReserved(for: engine)
    }

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

    /// Stops the transcription in flight, if there is one.
    ///
    /// Two things it deliberately does **not** do, both of which it used to.
    ///
    /// It does not un-cancel on the way out. It used to raise a shared
    /// `isCancelled` flag and drop it again inside one synchronous main-actor
    /// call, so every check of it in the running task read `false` and a
    /// transcription that happened to finish just as the user cancelled still
    /// published its text and still returned it to be pasted. What is recorded
    /// now is *which* transcription was cancelled (`cancelledGeneration`), which
    /// stands for as long as that transcription does and reaches no other.
    ///
    /// And it does not clear `transcriptionTask` or `isTranscribing`. Those two
    /// are the app's answer to "is the engine free", and cancelling does not
    /// make it free: a whisper context must not be handed a second recording
    /// while the first is still inside `whisper_full`, which is exactly what the
    /// serialization loop in `runTranscription` exists to prevent and exactly
    /// what clearing them here allowed - cancel, press again, two transcriptions
    /// on one context. The cancelled frame's own `defer` clears them when it
    /// actually unwinds, and the published half of that teardown is
    /// generation-checked so it can only ever clear its own.
    func cancelTranscription() {
        currentSegment = ""
        partialTranscript = nil
        progress = 0.0

        // `isTranscribing` spans the whole of `runTranscription`, as the frame
        // does, so either says whether there is anything to cancel. With
        // nothing in flight, raising the flag would only mute the next
        // transcription's progress until it reset it.
        guard isTranscribing else { return }

        cancelledGeneration = transcriptionGeneration
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
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
            do {
                let engine = try await self.initializeEngineForUse(active)

                await MainActor.run {
                    defer { EngineWeightUseCoordinator.shared.endUse(of: active) }
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
                    if EngineConfiguration.isNotConfigured(error) {
                        self.currentEngine = nil
                        self.currentEngineKind = nil
                        self.isEngineConfigured = false
                    }
                    print("Failed to load engine: \(error)")
                }
            }
        }

        startPreparingDesiredEngineIfNeeded(allowModelDownload: allowModelDownload)
    }

    func initializeEngineForUse(_ engineKind: EngineKind) async throws -> TranscriptionEngine {
        guard EngineWeightUseCoordinator.shared.beginUse(of: engineKind) else {
            throw TranscriptionError.engineNotConfigured
        }

        do {
            let engine = try await Task.detached(priority: .userInitiated) {
                let engine = await engineKind.makeEngine()
                try await engine.initialize()
                return engine
            }.value
            return engine
        } catch {
            EngineWeightUseCoordinator.shared.endUse(of: engineKind)
            throw error
        }
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
        guard !isEngineReservedForRemoval(desired) else { return }
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
        if let engineOverride {
            // Loaded the way a real engine is - once, before its first use,
            // and off the main actor - rather than handed over as it is, so
            // that a stub whose `initialize` waits can stand in the window a
            // real load opens, which is the window the serialisation frame is
            // there to shut. `currentEngine` is the same "already loaded"
            // memory the real path keeps.
            if currentEngine !== engineOverride {
                try await engineOverride.initialize()
                currentEngine = engineOverride
            }
            return engineOverride
        }
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
        guard !isEngineReservedForRemoval(active) else {
            throw TranscriptionError.engineNotConfigured
        }
        if currentEngineKind == active, let currentEngine { return currentEngine }

        let engine = try await initializeEngineForUse(active)
        currentEngine = engine
        currentEngineKind = active
        rememberReadyEngine(active)
        NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
        EngineWeightUseCoordinator.shared.endUse(of: active)
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

    /// Subscribes to the committed segments of an engine that has them, and
    /// unsubscribes from one that does not.
    ///
    /// The generation is checked on arrival for the reason every publish in this
    /// file checks it: whisper's callback fires on its own worker thread, so a
    /// segment can land a main-queue hop after a *different* transcription has
    /// taken the object over.
    private func observePartialTranscripts(
        of engine: TranscriptionEngine, generation: Int
    ) {
        guard let emitter = engine as? PartialTranscriptEmitting else { return }
        emitter.onPartialTranscript = { [weak self] partial in
            Task { @MainActor in
                guard let self,
                      self.transcriptionGeneration == generation,
                      !self.isCancelled(generation)
                else { return }
                self.partialTranscript = partial
                self.currentSegment = partial.segment
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
    ///
    /// It is the two halves below, `decodeRaw` and `finish`, composed inside
    /// **one** transcription frame rather than run as two: `isTranscribing`,
    /// the generation and the serialisation all span the post-processing as
    /// well as the decode. A cancel pressed while the capsule says the text is
    /// being polished must still produce no transcript, and a dictation pressed
    /// then must still wait its turn, so the frame is not allowed to end at the
    /// engine.
    func transcribeAudio(url: URL, settings: Settings) async throws -> StyledTranscript {
        let timeoutOverride = decodeTimeoutOverride
        return try await runEngineTranscription(publishing: { $0.final }) { engine in
            let raw = try await self.decodeWithDeadline(
                engine: engine, url: url, settings: settings,
                timeoutOverride: timeoutOverride, reporting: false)
            try Task.checkCancellation()
            return await Self.finish(raw: raw.text, settings: settings)
        }
    }

    /// Decodes one file to the engine's raw text and stops there: no
    /// post-processing, no rewriting, nothing routed.
    ///
    /// The same frame `transcribeAudio` runs in - serialised against every other
    /// transcription on the engine, its own generation, progress and committed
    /// segments published, cancellable - so a caller that decodes pieces of a
    /// dictation while the microphone is still open queues behind, and ahead
    /// of, whole-file work exactly as that work queues behind it. What it returns
    /// has been through no stage of `docs/text-post-processing.md`; `finish`
    /// is how it gets there.
    ///
    /// Beside the text it carries the language the decode ran in, from an
    /// engine that can say (`DecodeLanguageReporting`), which is how a live
    /// session learns what its first utterance was spoken in
    /// (`LiveLanguagePin`). An engine that cannot say reports nil.
    func decodeRaw(url: URL, settings: Settings) async throws -> RawDecode {
        let timeoutOverride = decodeTimeoutOverride
        return try await runEngineTranscription(publishing: { $0.text }) { engine in
            try await self.decodeWithDeadline(
                engine: engine, url: url, settings: settings,
                timeoutOverride: timeoutOverride, reporting: true)
        }
    }

    /// One engine decode, bounded so a hung engine fails the transcription
    /// instead of holding the serialisation frame - and with it every later
    /// transcription - for the life of the process.
    ///
    /// The budget scales with the audio's length (`decodeTimeoutBudget`), which
    /// is why the duration is read here rather than by the caller: off the main
    /// actor, inside the work that already suspends, and only when no test has
    /// pinned the budget.
    ///
    /// The deadline is `AsyncDeadline`, the same hard bound the rewriting stage
    /// and the Ask panel use, and for the same reason: the decode is a closed
    /// call (`whisper_full`, a CoreML prediction) whose cooperation cannot be
    /// assumed. A decode that outlives its budget loses the race; the loser is
    /// cancelled and abandoned, and `engineDeadlineExceeded` decides what that
    /// leaves behind.
    nonisolated private func decodeWithDeadline(
        engine: TranscriptionEngine,
        url: URL,
        settings: Settings,
        timeoutOverride: TimeInterval?,
        reporting: Bool
    ) async throws -> RawDecode {
        let budget: TimeInterval
        if let timeoutOverride {
            budget = timeoutOverride
        } else {
            budget = Self.decodeTimeoutBudget(forAudioDuration: await AudioUtil.audioDuration(url: url))
        }
        do {
            return try await AsyncDeadline.run(budget: budget) {
                if reporting, let reporter = engine as? DecodeLanguageReporting {
                    return try await reporter.transcribeAudioReportingLanguage(url: url, settings: settings)
                }
                return RawDecode(text: try await engine.transcribeAudio(url: url, settings: settings))
            }
        } catch is AsyncDeadline.Exceeded {
            await self.engineDeadlineExceeded(engine, budget: budget)
            throw TranscriptionError.processingTimedOut
        }
    }

    /// What a decode that outlived its budget leaves behind.
    ///
    /// The engine is told to cancel: whisper's abort flag unwinds `whisper_full`
    /// at its next check rather than letting it run to its end beside the next
    /// transcription. And the engine is then dropped, because a decode that
    /// ignored its deadline is not trusted with the next recording: the caller
    /// after this one loads a fresh engine rather than racing a decode that may
    /// still be inside the old one's context. The abandoned task holds its own
    /// reference, so the old engine lives exactly as long as its stuck decode
    /// and is never deallocated under it.
    private func engineDeadlineExceeded(_ engine: TranscriptionEngine, budget: TimeInterval) {
        print("Transcription exceeded its \(budget)s deadline; engine cancelled and unloaded: \(engine.engineName)")
        engine.cancelTranscription()
        guard currentEngine === engine else { return }
        currentEngine = nil
        currentEngineKind = nil
    }

    /// Runs the post-processing pipeline over a transcript that was decoded
    /// piece by piece - live dictation's joined utterances - inside the same
    /// frame `transcribeAudio` runs its own post-processing in.
    ///
    /// The frame is the point, not a convenience: `isTranscribing`, the
    /// generation and the serialisation span this call exactly as they span
    /// the second half of `transcribeAudio`, so a dictation pressed during the
    /// rewrite of live-decoded text still waits its turn, and every surface
    /// that asks "is the engine free" gets the same answer it would for a
    /// whole-file dictation. No engine is loaded or touched - the pieces were
    /// decoded already - which is what makes this frame different from the
    /// other two.
    func finishTranscribed(raw: String, settings: Settings) async throws -> StyledTranscript {
        try await runTranscription(publishing: { $0.final }, preparing: { _ in }) { _ in
            await Self.finish(raw: raw, settings: settings)
        }
    }

    /// Runs the whole post-processing pipeline over a raw transcript.
    ///
    /// Single post-processing choke point: every engine and every caller (live
    /// dictation, the file/drop queue, the in-window recorder) passes through
    /// here, so they cannot drift apart. The transcript stage is deterministic
    /// and cannot fail; the model-backed stages are last, are the only ones
    /// that can, and return the deterministic text unchanged when they do.
    /// Which of them runs is `SpokenIntentPipeline`'s decision: normally the
    /// chosen style, and for a caller that asked for routing, a spoken command
    /// instead.
    ///
    /// Off the main actor on purpose: it is called from inside the detached
    /// transcription task, and the transcript stage's string work belongs there
    /// rather than on the thread that draws the overlay.
    nonisolated static func finish(raw: String, settings: Settings) async -> StyledTranscript {
        let processed = TextPostProcessor.process(raw, settings: settings)
        return await SpokenIntentPipeline.apply(to: processed, settings: settings)
    }

    /// The frame for work that needs the engine: `runTranscription` with the
    /// engine loaded, and its progress and committed segments wired to the
    /// published state, before `work` is handed it.
    private func runEngineTranscription<Result: Sendable>(
        publishing text: @escaping @Sendable (Result) -> String,
        _ work: @escaping @Sendable (TranscriptionEngine) async throws -> Result
    ) async throws -> Result {
        let loadTimeout = loadTimeoutOverride ?? Self.loadTimeout
        return try await runTranscription(
            publishing: text,
            preparing: { generation in
                let engine = try await self.engineForTranscription(within: loadTimeout)
                self.observeProgress(of: engine)
                self.observePartialTranscripts(of: engine, generation: generation)
                return engine
            },
            work)
    }

    /// The engine, loaded if need be, with the load itself bounded.
    ///
    /// A load that never returns - a CoreML compile deadlocked, a coordinator
    /// wedge - used to hold the frame for the life of the process, which is
    /// "the dictation key stopped answering". The bound turns it into a clean
    /// failure: the frame's `defer` gives the engine slot back and the next
    /// transcription tries the load again. A load that completes after its
    /// deadline still lands as `currentEngine` - the answer arrived, merely
    /// late - so nothing about a slow-but-alive load is wasted.
    private func engineForTranscription(within budget: TimeInterval) async throws -> TranscriptionEngine {
        do {
            return try await AsyncDeadline.run(budget: budget) {
                EngineBox(engine: try await self.engineForTranscription())
            }.engine
        } catch is AsyncDeadline.Exceeded {
            print("Engine load exceeded its \(budget)s deadline")
            throw TranscriptionError.processingTimedOut
        }
    }

    /// `AsyncDeadline` hands its result across a task boundary, so the result
    /// must be `Sendable`; an engine is a class the protocol deliberately does
    /// not so constrain. The box asserts what holds here: the reference crosses
    /// between two main-actor hops and is never shared with the decode itself.
    private struct EngineBox: @unchecked Sendable {
        let engine: TranscriptionEngine
    }

    /// The frame every transcription runs in: waits for the engine to be free,
    /// takes the next generation, publishes the in-flight state, reserves the
    /// engine, runs `prepare` on the main actor and then `work` on a detached
    /// task that is cancelled with this object, and takes the state down again
    /// when - and only when - that work has actually unwound.
    ///
    /// `publishing` names what `transcribedText` shows for a result, since the
    /// frame does not know whether it ran a decode or a full transcription.
    /// `prepare` is what the work needs resolved inside the frame - the engine,
    /// for a decode; nothing, for post-processing alone - and runs after the
    /// generation is taken so a load that throws still tears its own frame down.
    ///
    /// The reservation is taken *before* `prepare`, not after it, and that
    /// order is the whole guarantee. `prepare` suspends - loading an engine is
    /// a detached task - and every caller that reaches the loop while it is
    /// suspended must find the frame already held, or it runs its work beside
    /// this one on the same engine.
    private func runTranscription<Context, Result: Sendable>(
        publishing text: @escaping @Sendable (Result) -> String,
        preparing prepare: @MainActor (_ generation: Int) async throws -> Context,
        _ work: @escaping @Sendable (Context) async throws -> Result
    ) async throws -> Result {
        // Serialize access to the engine: a whisper context must not process
        // two transcriptions concurrently (indicator flow and queue flow can
        // both reach this point due to async busy checks). A released frame
        // has already cleared itself, so after the wait this either finds
        // nothing or finds the frame of whoever was queued ahead and got in
        // first, and waits on that one in turn.
        while let existing = transcriptionTask {
            await existing.waitUntilFinished()
        }

        // Bumped **after** the wait above, not before it: the transcription this
        // one queued behind is still using its own generation to decide whose
        // teardown may publish.
        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        // Reserved here, synchronously with the bump, before anything below
        // can suspend. From this line until the `defer` runs, every other
        // caller waits.
        let frame = TranscriptionFrame()
        transcriptionTask = frame

        progress = 0.0
        conversionProgress = 0.0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""
        // Cleared per transcription rather than left to replay: `@Published`
        // hands a fresh subscriber the previous dictation's last segment, which
        // is somebody else's words on this one's overlay.
        partialTranscript = nil

        defer {
            // The reservation is given back synchronously, on every exit - a
            // `prepare` that threw, a load that was cancelled, work that
            // failed - because a frame that stayed reserved would hold every
            // later transcription for the life of the process. Nobody can
            // have replaced it while it was held, since the loop above does
            // not pass a held frame; the identity check only keeps that true
            // by construction rather than by assumption.
            frame.finish()
            if transcriptionTask === frame {
                transcriptionTask = nil
            }

            Task { @MainActor in
                // Only the transcription that is still the current one may take
                // the published state down with it. See `transcriptionGeneration`.
                guard self.transcriptionGeneration == generation else { return }
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                self.partialTranscript = nil
                if !self.isCancelled(generation) {
                    self.progress = 1.0
                }
            }
        }

        let context = try await prepare(generation)

        // Resolved once, outside the task: reading a captured `weak var` from
        // inside concurrently-executing code is an error under the Swift 6
        // language mode. The task is stored on this object and cancelled with it,
        // so holding it for the length of one transcription creates no cycle that
        // outlives the work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let service = self else { throw CancellationError() }
            try Task.checkCancellation()

            let cancelled = await MainActor.run { service.isCancelled(generation) }

            guard !cancelled else {
                throw CancellationError()
            }

            let result = try await work(context)

            try Task.checkCancellation()

            // Read and published in one main-actor hop, so a cancel cannot land
            // between "may I publish" and "did I": what was published is what
            // is returned to be pasted, and a cancelled result is neither.
            let published = await MainActor.run { () -> Bool in
                guard !service.isCancelled(generation) else { return false }
                service.transcribedText = text(result)
                service.progress = 1.0
                return true
            }

            guard published else {
                throw CancellationError()
            }

            return result
        }

        frame.bind(task)

        do {
            return try await task.value
        } catch is CancellationError {
            // Its own generation, never the current one: by the time this runs
            // the next dictation may already have started.
            cancelledGeneration = generation
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

    /// The engine - or its load - outlived the time a transcription of this
    /// audio may take (`decodeTimeoutBudget`, `loadTimeout`).
    ///
    /// Its own case because it says nothing about the audio and nothing about
    /// the setup: the decode was stopped, not disproven, and the same recording
    /// transcribes on a retry once the engine is reloaded. `DictationFailureOutcome`
    /// therefore keeps the audio, as it does for a cloud failure - the one
    /// thing a timeout must never be is indistinguishable from the app having
    /// hung, which is the failure it exists to retire.
    case processingTimedOut

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
        case .processingTimedOut:
            return "Transcription took too long and was stopped. Your recording was kept - regenerate it from History to try again."
        case .unsupportedSpokenLanguage(let message, _):
            return message
        }
    }
}
