import Combine
import Foundation

/// A five-second recording that is never kept.
///
/// The one thing a user cannot find out from any other surface: whether the
/// input they are on actually hears them. Every other microphone answer in the
/// app arrives *during* a dictation, when they are looking at another
/// application, and the diagnostics on the capsule are read in the corner of an
/// eye while talking.
///
/// Three rules carry it.
///
/// **It is the same microphone owner as everything else.** It goes through
/// `AudioRecorder.startRecording()`, so it takes the one `RecordingSession`
/// claim, can be refused while a dictation is in flight, and cannot start a
/// second capture behind one. Nothing here reaches CoreAudio on its own.
///
/// **The audio is discarded, always.** It ends with `cancelRecording`, which
/// deletes the file - so a microphone test leaves no `.wav`, no history row and
/// nothing for the retention policy to reason about. There is no path here that
/// keeps a recording, and that is deliberate: this measures a level, and audio
/// captured to measure a level is not something a user asked to store.
///
/// **The verdict is the shipped one.** It reads `MicrophoneSignalMonitor`, the
/// same thresholds and the same grace period the capsule uses, so a test that
/// says "Low signal" is telling the user what their dictation is going to look
/// like rather than running a second, kinder opinion.
@MainActor
final class MicrophoneTestViewModel: ObservableObject {

    /// How long the test runs. Long enough to say a sentence, short enough that
    /// nobody has to think about stopping it.
    static let duration: TimeInterval = 5

    enum State: Equatable {
        case idle
        /// Counting down. `remaining` is what the button says.
        case running(remaining: TimeInterval)
        /// Finished, with what was heard.
        case finished(MicrophoneSignal)
        /// Stopped by hand before the monitor had gathered enough to say
        /// anything. Its own case rather than a verdict, because there is no
        /// verdict - see `finish(with:)`.
        case tooShortToTell
        /// It never started. The microphone was held by a dictation, or
        /// CoreAudio refused it.
        case refused(String)
    }

    @Published private(set) var state: State = .idle

    /// The bars, on the 0…1 scale the capsule's meter draws.
    @Published private(set) var levels: [Float] = []

    /// What the signal is doing right now, live, so the user can move the
    /// microphone and watch it change rather than waiting five seconds to be
    /// told.
    @Published private(set) var signal: MicrophoneSignal = .measuring

    /// How many samples the strip holds. The same window the capsule keeps, so
    /// the two meters read alike.
    static let sampleCount = CapsuleHUDViewModel.waveformSampleCount

    private let recorder: AudioRecorder
    private var session: RecordingSession?
    private var monitor = MicrophoneSignalMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var countdown: Timer?
    private var endsAt: Date?

    init(recorder: AudioRecorder = .shared) {
        self.recorder = recorder
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start() {
        guard !isRunning else { return }

        monitor.reset()
        levels = []
        signal = .measuring

        guard let session = recorder.startRecording() else {
            // The claim is held by a dictation, the Ask panel or a voice edit.
            // Refused rather than queued: this is a diagnostic, and taking the
            // microphone off a recording that is capturing somebody's words to
            // run one would be worse than saying no.
            state = .refused("Something else is using the microphone. Try again in a moment.")
            return
        }
        self.session = session
        endsAt = Date().addingTimeInterval(Self.duration)
        state = .running(remaining: Self.duration)

        recorder.setLevelMonitoring(enabled: true)
        observe(session)
        scheduleCountdown()
    }

    /// Ends the test early, keeping whatever verdict has been reached.
    ///
    /// "Whatever has been reached" includes *nothing*: inside the monitor's
    /// grace interval there is no verdict yet, and this must not borrow the
    /// timer path's one - see `finish(with:)`.
    func stop() {
        guard isRunning else { return }
        finish(with: monitor.signal(at: Date()), ranToCompletion: false)
    }

    /// Gives the microphone back without leaving a verdict on screen - for a
    /// pane that is going away.
    func cancel() {
        guard isRunning else { return }
        teardown()
        state = .idle
    }

    // MARK: - Private

    private func observe(_ session: RecordingSession) {
        cancellables.removeAll()

        recorder.$inputLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.record(level)
            }
            .store(in: &cancellables)

        // A start can fail *after* the session was handed back - CoreAudio is
        // paid on the work queue - and it names the session it failed, because
        // five surfaces share this recorder and `@Published` replays. Acting on
        // somebody else's failure would end their dictation from here.
        recorder.$failedStart
            .receive(on: RunLoop.main)
            .sink { [weak self] failure in
                guard let self, let failure, failure.ends(session) else { return }
                self.teardown()
                self.state = .refused(failure.reason.message)
            }
            .store(in: &cancellables)
    }

    private func record(_ level: MicrophoneLevel) {
        guard isRunning else { return }
        let now = Date()
        monitor.record(level, at: now)
        signal = monitor.signal(at: now)

        levels.append(min(1, max(0, level.normalizedAverage)))
        if levels.count > Self.sampleCount {
            levels.removeFirst(levels.count - Self.sampleCount)
        }
    }

    private func scheduleCountdown() {
        countdown?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.05
        countdown = timer
    }

    private func tick() {
        guard isRunning, let endsAt else { return }
        let remaining = endsAt.timeIntervalSinceNow
        guard remaining > 0 else {
            finish(with: monitor.signal(at: Date()), ranToCompletion: true)
            return
        }
        state = .running(remaining: remaining)
    }

    /// - Parameter ranToCompletion: whether the test used its whole `duration`.
    ///   It is the difference between the two ways `.measuring` can arrive here,
    ///   and they mean opposite things.
    private func finish(with verdict: MicrophoneSignal, ranToCompletion: Bool) {
        teardown()

        guard verdict == .measuring else {
            state = .finished(verdict)
            return
        }

        // A test that ran its full five seconds and is still `.measuring` heard
        // nothing at all: five seconds is more than three times the grace
        // interval, so `.measuring` there is the pane declining to answer the
        // one question it was asked.
        //
        // An early Stop is the opposite. Inside the grace interval the monitor
        // has not looked at `loudestPeak` yet, so `.measuring` means "no
        // evidence", and reporting that as "No signal" tells somebody who just
        // spoke clearly to go and check an input that is fine. A diagnostic that
        // does that is worse than no diagnostic.
        state = ranToCompletion ? .finished(.noSignal) : .tooShortToTell
    }

    private func teardown() {
        countdown?.invalidate()
        countdown = nil
        endsAt = nil
        cancellables.removeAll()
        recorder.setLevelMonitoring(enabled: false)
        if let session {
            // Cancel, never stop: `cancelRecording` deletes the file. A test
            // must not leave audio on the disk.
            recorder.cancelRecording(session)
        }
        session = nil
    }
}
