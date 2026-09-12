import Combine
import Foundation

/// Why a live session cannot stand for the recording, so the dictation is
/// decoded from the WAV the recorder wrote - exactly as it would have been
/// without the session.
///
/// Every reason is a fallback and none is an error the user sees: the audio is
/// intact on disk, the whole-file path is the one every release before this
/// took, and what the user loses is the seconds the live path would have saved.
enum LiveDictationFallbackReason: Equatable, CustomStringConvertible {
    /// The microphone could not be tapped: device busy, format refused, no
    /// input. The session never decoded anything.
    case tapUnavailable(String)
    /// An utterance - or the tail - did not decode. Whatever was committed is
    /// dropped, because a transcript with a hole in it is worse than a late one.
    case decodeFailed(String)
    /// The engine that would decode now is not the one this session started
    /// on: a model finished preparing, or the user's choice was carried out.
    /// Two engines' words joined into one transcript is not one transcript.
    case engineChanged
    /// The uncommitted audio outgrew the cap without the VAD finding a silence
    /// to cut in. Speech that long without a pause is rare; the WAV has it all.
    case bufferExceeded
    /// The session outlived `LiveDictationSession.maximumDuration`.
    case sessionTooLong
    /// `finish` or `cancel` named a session this one is not for.
    case notThisSession
    /// The session was cancelled before it was finished.
    case cancelled

    var description: String {
        switch self {
        case .tapUnavailable(let reason): return "the microphone could not be tapped (\(reason))"
        case .decodeFailed(let reason): return "an utterance did not decode (\(reason))"
        case .engineChanged: return "the engine changed during the recording"
        case .bufferExceeded: return "no pause was found before the buffer cap"
        case .sessionTooLong: return "the recording outlived the live session's limit"
        case .notThisSession: return "the session named is not this one"
        case .cancelled: return "the session was cancelled"
        }
    }
}

/// What `LiveDictationSession.finish` hands back.
enum LiveDictationOutcome: Equatable {
    /// Every utterance was decoded live; `raw` is the joined transcript, still
    /// to go through `TranscriptionService.finishTranscribed`. Empty when the
    /// VAD found no speech at all - the same answer a whole-file decode gives.
    case committed(raw: String)
    /// Decode the WAV whole instead.
    case fallback(LiveDictationFallbackReason)
}

enum LiveDictationState: Equatable {
    /// Tapping the microphone and decoding utterances as they end.
    case running
    /// The key went up; the last utterance is being decoded.
    case finishing
    /// The tap never started. The recording goes on without it.
    case unavailable(LiveDictationFallbackReason)
    /// The live path broke part-way. The recording goes on without it.
    case failed(LiveDictationFallbackReason)
    /// `finish` returned.
    case finished
    /// `cancel` was called; nothing is kept.
    case cancelled
}

/// The one thing a live session needs from `TranscriptionService`: decode this
/// file on the engine that is running, and say which engine that is.
///
/// A protocol so the session can be tested against a decoder that answers
/// instantly, throws on cue, or changes engine between two utterances.
protocol LiveUtteranceDecoding: AnyObject {
    /// The engine an utterance decodes on right now, or nil when none can.
    @MainActor var activeEngine: EngineKind? { get }

    /// The engine's raw text for one file, through the same frame every other
    /// transcription runs in - serialised, cancellable, and nothing after the
    /// engine.
    @MainActor func decodeRaw(url: URL, settings: Settings) async throws -> String
}

extension TranscriptionService: LiveUtteranceDecoding {
    var activeEngine: EngineKind? { selection.active }
}

/// The VAD a live session reads the uncommitted buffer with. A protocol so a
/// test can state where the speech is instead of synthesising speech.
protocol LiveSpeechSegmenting: AnyObject {
    func segments(in samples: [Float]) throws -> [WhisperVadSegment]
}

extension SpeechSegmenter: LiveSpeechSegmenting {}

/// Whether a dictation gets a live session at all, as one pure decision.
///
/// Four conditions, all of which have to hold, and the budget is the answer
/// because it is what the session is built around. The purpose rule is the
/// one that keeps ⌥A, ⌥S, ⌥E and ⌥Y exactly as they were; the engine rule is
/// what keeps the cloud engine at one request per dictation
/// (`LiveCutBudget.preset(for:)` has no budget for it); the timestamps rule
/// exists because whisper's timestamps are offsets into the file it was handed,
/// and an utterance's offsets are meaningless against the recording.
enum LiveDictationEligibility {
    static func budget(
        purpose: DictationPurpose,
        isEnabled: Bool,
        engine: EngineKind?,
        showTimestamps: Bool
    ) -> LiveCutBudget? {
        guard isEnabled, purpose == .dictation, !showTimestamps, let engine else { return nil }
        return LiveCutBudget.preset(for: engine)
    }
}

/// Decodes a dictation while it is still being recorded.
///
/// It owns the tap, the buffer, the poll, the cut policy, the joined
/// transcript and its own state, and `IndicatorViewModel` sees three calls and
/// one published value: `start`, `finish`, `cancel`, and `transcript`. Every
/// half-second it reads the uncommitted audio with the VAD, asks
/// `LiveCutPolicy` whether an utterance has ended, and if one has, writes it
/// out and decodes it on the engine the dictation would have been decoded on
/// anyway - inside `TranscriptionService`'s own frame, so it queues behind and
/// ahead of every other transcription exactly as a file does. The pieces are
/// joined by `CommittedTranscript`. When the key goes up, `finish` decodes only
/// what is left and hands back one raw transcript for the post-processing
/// pipeline to run over once.
///
/// Three rules hold the whole thing.
///
/// **Nothing is pasted early and nothing on screen is revised.** The session
/// publishes `transcript` - committed utterances only, growing and never
/// rewritten - and the paste happens once, at the end, after every stage of
/// `docs/text-post-processing.md`, because those stages run over whole texts
/// and the guard compares whole texts.
///
/// **Every failure is a fallback.** The recorder is still writing the WAV, so a
/// tap that will not start, an utterance that throws, an engine that changes,
/// a buffer that outgrows its cap or a session that runs too long all end the
/// same way: the published line is cleared first, the buffer is released, and
/// `finish` answers `.fallback` so the caller decodes the file whole. A live
/// session can make a dictation faster; it is never allowed to make one fail.
///
/// **It is bound to its `RecordingSession`.** `finish` and `cancel` name the
/// session they mean and are refused otherwise, the rule
/// `RecordingSessionClaim` states for the microphone itself, so no other key
/// can end or read this one's words.
///
/// `docs/live-dictation.md` is the whole story.
@MainActor
final class LiveDictationSession: ObservableObject {

    /// How often the uncommitted buffer is read. Half a second is well inside
    /// the ~1.5 s a user expects between a pause and the words appearing, and
    /// coarse enough that the VAD is not the thing keeping the CPU warm.
    static let pollInterval: TimeInterval = 0.5

    /// After this the session gives up and the WAV is decoded whole. Nobody
    /// dictates for half an hour into one paste; a recording that long is a
    /// meeting, and it is not what this path is for.
    static let maximumDuration: TimeInterval = 30 * 60

    /// How much uncommitted audio, in units of the engine's cap, is allowed to
    /// pile up before the session gives up. The policy never cuts inside
    /// speech, so an unbroken stretch this long has no pause in it at all.
    static let bufferCapMultiplier = 2

    /// The claim this session belongs to.
    let recordingSession: RecordingSession

    /// The engine every utterance is decoded on. A change is a fallback.
    let engine: EngineKind

    /// The settings every utterance is decoded with - the prompt, the terms,
    /// the language - resolved once at the start, and what the caller finishes
    /// the joined transcript with, so the decodes and the post-processing read
    /// one snapshot of the user's preferences.
    let settings: Settings

    @Published private(set) var state: LiveDictationState = .running

    /// What has been decoded so far, or nil when nothing has - and nil again
    /// the moment the session falls back, so a capsule following it never shows
    /// words the whole-file decode is about to replace.
    @Published private(set) var transcript: PartialTranscript?

    private let budget: LiveCutBudget
    private let tap: LiveAudioTapping
    private let decoder: LiveUtteranceDecoding
    private let segmenter: LiveSpeechSegmenting
    private let now: () -> Date
    private let stopTail: TimeInterval
    private let pollInterval: TimeInterval?
    private let utteranceDirectory: URL

    private let buffer = LiveSampleBuffer()
    private var committed = CommittedTranscript()
    private var startedAt: Date?
    private var pollTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var isPolling = false

    /// The production session for a dictation that qualifies, or nil for one
    /// that stays on the whole-file path.
    ///
    /// `settings` is what the dictation is going to be finished with; the
    /// session keeps it so the utterances are decoded with the same prompt and
    /// language the joined text is later processed under.
    static func make(
        for recordingSession: RecordingSession,
        purpose: DictationPurpose,
        settings: Settings,
        service: TranscriptionService,
        preferences: AppPreferences = .shared
    ) -> LiveDictationSession? {
        guard let engine = service.activeEngine,
              let budget = LiveDictationEligibility.budget(
                  purpose: purpose,
                  isEnabled: preferences.liveTranscriptionEnabled,
                  engine: engine,
                  showTimestamps: settings.showTimestamps)
        else { return nil }
        return LiveDictationSession(
            recordingSession: recordingSession,
            engine: engine,
            budget: budget,
            settings: settings,
            tap: LiveAudioTap(),
            decoder: service,
            segmenter: Self.sharedSegmenter)
    }

    /// One VAD for every live session. Sessions are sequential - there is one
    /// microphone claim at a time and one poll in flight per session - so the
    /// model is loaded once rather than once per dictation.
    private static let sharedSegmenter = SpeechSegmenter()

    /// - Parameters:
    ///   - stopTail: how long after `finish` the tap keeps listening before it
    ///     stops - `AudioRecorder.stopTailDuration`, so the live path hears the
    ///     same end of the last word the WAV does.
    ///   - pollInterval: how often the buffer is read once `start` has returned.
    ///     `nil` means the caller polls, which is what a test does.
    init(
        recordingSession: RecordingSession,
        engine: EngineKind,
        budget: LiveCutBudget,
        settings: Settings,
        tap: LiveAudioTapping,
        decoder: LiveUtteranceDecoding,
        segmenter: LiveSpeechSegmenting,
        now: @escaping () -> Date = Date.init,
        stopTail: TimeInterval = AudioRecorder.stopTailDuration,
        pollInterval: TimeInterval? = LiveDictationSession.pollInterval,
        utteranceDirectory: URL = LiveUtteranceFile.directory
    ) {
        self.recordingSession = recordingSession
        self.engine = engine
        self.budget = budget
        self.settings = settings
        self.tap = tap
        self.decoder = decoder
        self.segmenter = segmenter
        self.now = now
        self.stopTail = stopTail
        self.pollInterval = pollInterval
        self.utteranceDirectory = utteranceDirectory
    }

    // MARK: - Lifecycle

    /// Opens the tap and starts polling. Returns once the tap is running or has
    /// refused; a refusal leaves the session `.unavailable` and the dictation
    /// on the whole-file path.
    ///
    /// The tap is started off the main actor: pinning the device and starting
    /// an `AVAudioEngine` cost CoreAudio round-trips, and this runs at the
    /// press, during the overlay's appear animation.
    func start() async {
        guard state == .running, startedAt == nil else { return }
        startedAt = now()

        let tap = self.tap
        let buffer = self.buffer
        let result = await Task.detached(priority: .userInitiated) {
            Result { try tap.start(onFrames: { buffer.append($0) }) }
        }.value
        // Cancelled or failed while the tap was opening: the tap is stopped by
        // whichever transition did it, and a late success must not revive it.
        guard state == .running else {
            if case .success = result { Task.detached { tap.stop() } }
            return
        }
        if case .failure(let error) = result {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print("Live dictation unavailable: \(reason)")
            state = .unavailable(.tapUnavailable(reason))
            return
        }

        guard let pollInterval else { return }
        pollTask = Task { [weak self] in
            while let self, self.state == .running {
                let sleeper = Task {
                    _ = try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
                self.sleeper = sleeper
                await sleeper.value
                self.sleeper = nil
                guard self.state == .running else { break }
                await self.poll()
            }
        }
    }

    /// Stops listening, decodes what is left, and answers with the transcript
    /// or with the reason the WAV has to be decoded instead.
    func finish(_ session: RecordingSession) async -> LiveDictationOutcome {
        guard session == recordingSession else { return .fallback(.notThisSession) }
        switch state {
        case .unavailable(let reason), .failed(let reason):
            return .fallback(reason)
        case .cancelled:
            return .fallback(.cancelled)
        case .finished, .finishing:
            return .fallback(.notThisSession)
        case .running:
            break
        }
        state = .finishing

        // The same tail the recorder keeps: the end of the last word is
        // released together with the key.
        if stopTail > 0 {
            try? await Task.sleep(nanoseconds: UInt64(stopTail * 1_000_000_000))
        }
        let tap = self.tap
        await Task.detached { tap.stop() }.value

        // Let the loop finish the step it is in - which may be a decode - and
        // exit; a step that is only sleeping is woken now rather than in half a
        // second, since this wait is the wait after the key goes up.
        sleeper?.cancel()
        await pollTask?.value
        pollTask = nil

        // Cancelled, or failed inside that last step.
        switch state {
        case .failed(let reason): return .fallback(reason)
        case .cancelled: return .fallback(.cancelled)
        case .finishing: break
        case .running, .unavailable, .finished: return .fallback(.notThisSession)
        }

        let tail = buffer.drain()
        if !tail.isEmpty {
            do {
                let segments = try await segments(in: tail)
                if case .commit(let range) = LiveCutPolicy.tail(
                    segments: segments, bufferLength: tail.count, budget: budget)
                {
                    try await decode(Array(tail[range]))
                }
            } catch {
                fail(.decodeFailed(Self.describe(error)))
                return .fallback(.decodeFailed(Self.describe(error)))
            }
        }

        guard state == .finishing else {
            if case .failed(let reason) = state { return .fallback(reason) }
            return .fallback(.cancelled)
        }
        state = .finished
        return .committed(raw: committed.text)
    }

    /// Discards everything: the buffer, the committed text, and the tap.
    /// Refused for any other session.
    func cancel(_ session: RecordingSession) {
        guard session == recordingSession else { return }
        guard state == .running || state == .finishing else { return }
        state = .cancelled
        teardown()
    }

    // MARK: - The poll

    /// One reading of the uncommitted buffer. Public so a test can drive the
    /// session without a timer; in production the loop `start` launches calls
    /// it every `pollInterval`. Never runs two at once.
    func poll() async {
        guard state == .running, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        if let startedAt, now().timeIntervalSince(startedAt) > Self.maximumDuration {
            fail(.sessionTooLong)
            return
        }
        guard decoder.activeEngine == engine else {
            fail(.engineChanged)
            return
        }

        let snapshot = buffer.snapshot()
        guard !snapshot.isEmpty else { return }
        guard snapshot.count <= Self.bufferCapMultiplier * budget.maximumSamples else {
            fail(.bufferExceeded)
            return
        }

        let segments: [WhisperVadSegment]
        do {
            segments = try await self.segments(in: snapshot)
        } catch {
            fail(.decodeFailed(Self.describe(error)))
            return
        }
        guard state == .running else { return }

        switch LiveCutPolicy.cut(segments: segments, bufferLength: snapshot.count, budget: budget) {
        case .wait:
            return
        case .discard(let range):
            buffer.drop(range.count)
        case .commit(let range):
            // Released before the decode rather than after: the tap keeps
            // appending, and the range is a prefix, so what comes out of the
            // front is exactly what went into the utterance.
            let utterance = Array(snapshot[range])
            buffer.drop(range.count)
            do {
                try await decode(utterance)
            } catch {
                fail(.decodeFailed(Self.describe(error)))
            }
        }
    }

    // MARK: - Stages

    /// Writes one utterance out, decodes it, and appends what came back. The
    /// file is removed either way. A result arriving after the session was
    /// cancelled or failed is dropped, not appended.
    private func decode(_ samples: [Float]) async throws {
        let directory = utteranceDirectory
        let url = try await Task.detached(priority: .userInitiated) {
            try LiveUtteranceFile.write(samples, in: directory)
        }.value
        defer { try? FileManager.default.removeItem(at: url) }

        let raw = try await decoder.decodeRaw(url: url, settings: settings)

        guard state == .running || state == .finishing else { return }
        guard committed.append(raw), let kept = CommittedTranscript.kept(raw) else { return }
        transcript = PartialTranscript(
            text: committed.text, segment: kept, segmentCount: committed.utterances.count)
    }

    /// The VAD, off the main actor: half a minute of audio is a few
    /// milliseconds of model, which is still not the main thread's to spend
    /// twice a second.
    private func segments(in samples: [Float]) async throws -> [WhisperVadSegment] {
        let segmenter = self.segmenter
        return try await Task.detached(priority: .userInitiated) {
            try segmenter.segments(in: samples)
        }.value
    }

    private func fail(_ reason: LiveDictationFallbackReason) {
        guard state == .running || state == .finishing else { return }
        print("Live dictation: falling back to the whole-file decode - \(reason)")
        state = .failed(reason)
        teardown()
    }

    /// Clears the line, drops the audio and the words, stops the tap. The order
    /// matters only for the line: nil is published before anything else so a
    /// capsule following the session shows nothing the fallback might contradict.
    ///
    /// The tap is stopped here and now rather than on a detached task, unlike
    /// in `finish`: a cancel or a fallback is not on the path to a paste, and a
    /// caller that has just cancelled must be able to rely on the microphone
    /// being let go before it does anything else.
    private func teardown() {
        transcript = nil
        committed = CommittedTranscript()
        buffer.clear()
        sleeper?.cancel()
        tap.stop()
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// The uncommitted audio, appended from the audio thread and read from the
/// main actor. A lock rather than an actor because the appender must not
/// suspend and must not allocate more than it has to.
final class LiveSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ frames: [Float]) {
        lock.lock()
        samples.append(contentsOf: frames)
        lock.unlock()
    }

    /// A copy of everything uncommitted.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Releases the first `count` samples - a prefix, which is all the policy
    /// ever commits.
    func drop(_ count: Int) {
        lock.lock()
        samples.removeFirst(min(count, samples.count))
        lock.unlock()
    }

    /// Takes everything and leaves the buffer empty.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples = []
        return taken
    }

    func clear() {
        lock.lock()
        samples = []
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}
