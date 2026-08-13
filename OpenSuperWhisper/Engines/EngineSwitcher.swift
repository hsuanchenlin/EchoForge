import Combine
import Foundation

/// The engine shortcut: one press moves dictation to the next engine that is
/// ready, wrapping around, and says which one on screen.
///
/// It owns none of the rules. `EngineCycle` decides what a press amounts to,
/// `EngineSelectionCommand` carries the choice out - the same call the Settings
/// picker makes - and `EngineSwitchHUD` shows the result. What is left here is the
/// two things a pure function cannot do: read the machine, and wait.
///
/// **Waiting is the part worth reading.** A press during a dictation does not take
/// effect during that dictation. The words already spoken were spoken to a
/// particular model, the decode of a long recording can be seconds long, and
/// swapping the engine underneath it would either change what those words are
/// transcribed by or - worse - replace an engine object mid-decode. Nor is the
/// press refused: someone pressing it has usually just realised they are on the
/// wrong engine, and a dead key at that moment is the least helpful possible
/// answer. So the target is held, the overlay says it applies after this
/// dictation, and it is applied the moment nothing is in flight.
///
/// "In flight" deliberately spans the whole session rather than each of its parts.
/// Between the recorder stopping and the transcription starting every individual
/// flag is briefly false, and applying a switch in that gap would hand the words
/// just spoken to the new engine - which is the exact thing being avoided. The
/// indicator's session outlives that gap, so it is what is asked.
@MainActor
final class EngineSwitcher {
    static let shared = EngineSwitcher()

    /// The engine a deferred press is waiting to apply, or `nil` when nothing is
    /// waiting. A second press while one is pending advances from the pending
    /// engine, so two presses during one dictation move two places - the shortcut
    /// behaves the same whether or not a dictation happens to be running.
    private(set) var pendingEngine: EngineKind?

    private let preferences: AppPreferences
    private let availability: @MainActor () -> EngineAvailability
    private let isCloudSelectable: @MainActor () -> Bool
    private let isDictationInFlight: @MainActor () -> Bool
    private let apply: @MainActor (EngineKind) -> Void
    private let announce: @MainActor (EngineSwitchAnnouncement) -> Void
    private let activityChanges: @MainActor () -> AnyPublisher<Void, Never>

    private var activityObserver: AnyCancellable?
    private var selectionObserver: AnyCancellable?

    init(
        preferences: AppPreferences = .shared,
        availability: @escaping @MainActor () -> EngineAvailability = {
            EngineAvailability.current()
        },
        isCloudSelectable: @escaping @MainActor () -> Bool = {
            CloudAccess.isSelectable(.transcription)
        },
        isDictationInFlight: @escaping @MainActor () -> Bool = {
            EngineSwitcher.productionDictationIsInFlight()
        },
        apply: @escaping @MainActor (EngineKind) -> Void = { EngineSelectionCommand.select($0) },
        announce: @escaping @MainActor (EngineSwitchAnnouncement) -> Void = {
            EngineSwitchHUD.shared.show($0)
        },
        activityChanges: @escaping @MainActor () -> AnyPublisher<Void, Never> = {
            EngineSwitcher.productionActivityChanges()
        }
    ) {
        self.preferences = preferences
        self.availability = availability
        self.isCloudSelectable = isCloudSelectable
        self.isDictationInFlight = isDictationInFlight
        self.apply = apply
        self.announce = announce
        self.activityChanges = activityChanges
    }

    /// One press of the shortcut.
    ///
    /// Returns what it decided so the shortcut can be driven in a test without a
    /// window server; production ignores the value and reads the overlay.
    @discardableResult
    func advance() -> EngineSwitchOutcome {
        let cycle = EngineCycle.available(
            whisperModelPath: preferences.selectedWhisperModelPath,
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion,
            availability: availability(),
            isCloudSelectable: isCloudSelectable()
        )

        let outcome = EngineCycle.decide(
            // A pending press is where the user thinks they are, so a second press
            // continues from it rather than repeating the first one.
            current: pendingEngine ?? preferences.selectedEngine,
            cycle: cycle,
            isDictationInFlight: isDictationInFlight()
        )

        switch outcome {
        case .switched(let engine):
            pendingEngine = nil
            stopWaiting()
            apply(engine)
        case .deferred(let engine):
            pendingEngine = engine
            startWaiting()
        case .onlyOneEngine, .noEngineAvailable:
            break
        }

        announce(message(for: outcome))
        return outcome
    }

    /// Applies a deferred press once the dictation it was waiting on is over.
    ///
    /// Re-checked rather than replayed: the wait can be long enough for the pending
    /// engine to stop being usable - a cache deleted, a cloud key removed - and
    /// applying a target that is no longer in the cycle would land the user on an
    /// engine that cannot transcribe, which is the one thing this shortcut promises
    /// not to do.
    ///
    /// When that happens the press is carried out as though it had been made now:
    /// the user asked for a working engine, so they get the next one rather than an
    /// apology. Either way the overlay names what actually happened - it is the one
    /// thing they see, and announcing a switch that was not made would be worse
    /// than announcing nothing.
    func applyPendingIfIdle() {
        guard let pending = pendingEngine else {
            stopWaiting()
            return
        }
        guard !isDictationInFlight() else { return }

        pendingEngine = nil
        stopWaiting()

        let cycle = EngineCycle.available(
            whisperModelPath: preferences.selectedWhisperModelPath,
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion,
            availability: availability(),
            isCloudSelectable: isCloudSelectable()
        )

        // Announced even when the pending engine turns out to be the selected one
        // already - two presses during one dictation can come back to where they
        // started, and an overlay that promised an engine and then says nothing
        // about it is what looks broken.
        guard !cycle.contains(pending) else {
            apply(pending)
            announce(message(for: .switched(pending)))
            return
        }

        let outcome = EngineCycle.decide(
            current: preferences.selectedEngine,
            cycle: cycle,
            isDictationInFlight: false
        )
        if case .switched(let engine) = outcome {
            apply(engine)
        }
        announce(message(for: outcome))
    }

    private func message(for outcome: EngineSwitchOutcome) -> EngineSwitchAnnouncement {
        EngineSwitchMessage.announcement(
            for: outcome,
            whisperModelPath: preferences.selectedWhisperModelPath,
            cloudModel: preferences.cloudTranscriptionModel
        )
    }

    // MARK: - Waiting for the dictation to end

    /// Subscribed only while a press is pending, and dropped as soon as it is
    /// applied: this exists to notice one thing ending, not to watch every
    /// dictation the app ever runs.
    ///
    /// The second subscription is why a pending press cannot override a choice
    /// made after it. An engine picked in Settings or the Cloud pane while the
    /// press waits is the newer decision, so the press is dropped rather than
    /// applied over it - and a later press advances from that choice, not from
    /// the stale target. `.selectedEngineChanged` can only mean such a choice
    /// here: this switcher clears the pending press and both subscriptions
    /// before it ever calls `apply`, so its own selection is never heard.
    private func startWaiting() {
        guard activityObserver == nil else { return }
        activityObserver = activityChanges().sink { [weak self] _ in
            self?.applyPendingIfIdle()
        }
        selectionObserver = NotificationCenter.default
            .publisher(for: .selectedEngineChanged)
            .sink { [weak self] _ in self?.cancelPending() }
    }

    private func stopWaiting() {
        activityObserver = nil
        selectionObserver = nil
    }

    /// Dropped silently: the choice that cancels it was made in a visible pane,
    /// and a pill for a switch that was not made is what the overlay must never
    /// show.
    private func cancelPending() {
        pendingEngine = nil
        stopWaiting()
    }

    // MARK: - Reading the machine

    /// Whether a dictation is somewhere between its first frame of audio and its
    /// last word of text.
    ///
    /// The indicator's session is first because it is the only one of these that
    /// covers the whole of one - including the gap between the recording stopping
    /// and the transcription starting. The rest catch the dictations that never had
    /// an indicator: the main window's own recorder, and the queue that transcribes
    /// dropped files.
    static func productionDictationIsInFlight() -> Bool {
        IndicatorWindowManager.shared.viewModel != nil
            || TranscriptionService.shared.isTranscribing
            || TranscriptionQueue.shared.isProcessing
            || AudioRecorder.shared.isRecording
    }

    /// Every signal that a dictation may have just finished, as one publisher.
    ///
    /// Deliberately more than the state that decides it: each of these is a moment
    /// worth re-asking the question at, and `applyPendingIfIdle` re-checks
    /// everything anyway, so an extra wake-up costs one comparison.
    static func productionActivityChanges() -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .indicatorWindowDidHide)
                .map { _ in () }
                .eraseToAnyPublisher(),
            TranscriptionService.shared.$isTranscribing.map { _ in () }.eraseToAnyPublisher(),
            TranscriptionQueue.shared.$isProcessing.map { _ in () }.eraseToAnyPublisher(),
            AudioRecorder.shared.$isRecording.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }
}
