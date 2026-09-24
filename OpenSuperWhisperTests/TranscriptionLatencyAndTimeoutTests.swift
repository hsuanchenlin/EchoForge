import AVFoundation
import XCTest
@testable import OpenSuperWhisper

/// The deadlines on a transcription, and what they cost when nothing is wrong.
///
/// A transcription used to wait on the engine for exactly as long as the engine
/// took - and a wedged decode or a deadlocked load never finishes, so the
/// serialisation frame it held was never released and every later transcription
/// queued behind it for the life of the process. That is the "transcription
/// takes forever" report: not a slow engine, a stuck one. The decode now runs
/// against `TranscriptionService.decodeTimeoutBudget` and the load against
/// `loadTimeout` (both via `AsyncDeadline`, the bound the rewriting stage and
/// the Ask panel already use), and what these tests pin is the shape of that
/// bound: a hung engine fails cleanly and lets go, and a working one is left
/// alone.
///
/// No model is loaded anywhere here. The engines are stubs whose load and
/// decode can be told to hang - which is the only faithful reproduction of a
/// hang there is, since a real hang is defined by never answering - and the
/// budgets are pinned through the service's overrides rather than waited out.
@MainActor
final class TranscriptionLatencyAndTimeoutTests: XCTestCase {

    private func makeService(_ engine: TranscriptionEngine) -> TranscriptionService {
        let service = TranscriptionService()
        service.engineOverride = engine
        return service
    }

    private var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("test_audio.m4a")
    }

    /// Post-processing kept deterministic and off the model: the deadlines
    /// under test are the engine's, and a rewrite stage that fell back after
    /// its own budget would be the only thing being measured.
    private func plainSettings() -> Settings {
        var settings = Settings()
        settings.styleRewrite = .disabled
        settings.useAsianAutocorrect = false
        settings.safeCorrectionEnabled = false
        return settings
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private struct TimedOut: Error {}

    /// Starts a transcription call as its own task and hands back its outcome
    /// slot - the same shape `TranscriptionSerializationTests` uses, for the
    /// same reason: when the frame does not let go, a plain `await` on the
    /// caller would hang the run instead of failing the test, and polling a
    /// slot is the one wait that can give up.
    private func start<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) -> Call<T> {
        let call = Call<T>()
        Task { @MainActor in
            do { call.record(.success(try await body())) } catch { call.record(.failure(error)) }
        }
        return call
    }

    private func value<T>(of call: Call<T>, within seconds: Double = 5) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while call.outcome == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let outcome = call.outcome else { throw TimedOut() }
        return try outcome.get()
    }

    // MARK: - The budget's shape

    /// Short audio gets the floor, long audio gets the factor, and the budget
    /// only ever grows: the bound has to be far above every legitimate decode
    /// and still finite, on every length of recording.
    func testTheDecodeBudgetScalesWithTheAudioAndNeverShrinksBelowTheFloor() {
        XCTAssertEqual(
            TranscriptionService.decodeTimeoutBudget(forAudioDuration: 0),
            TranscriptionService.decodeTimeoutFloor)
        XCTAssertEqual(
            TranscriptionService.decodeTimeoutBudget(forAudioDuration: 5),
            TranscriptionService.decodeTimeoutFloor,
            "a short utterance gets the floor, not 50 s")
        XCTAssertEqual(
            TranscriptionService.decodeTimeoutBudget(forAudioDuration: 30),
            30 * TranscriptionService.decodeTimeoutFactor)
        XCTAssertEqual(
            TranscriptionService.decodeTimeoutBudget(forAudioDuration: 60),
            60 * TranscriptionService.decodeTimeoutFactor)
        XCTAssertEqual(
            TranscriptionService.decodeTimeoutBudget(forAudioDuration: 3600),
            3600 * TranscriptionService.decodeTimeoutFactor,
            "an hour-long file gets an hour-proportioned budget, not the floor")

        var previous: TimeInterval = 0
        for seconds in stride(from: 0.0, through: 120.0, by: 0.5) {
            let budget = TranscriptionService.decodeTimeoutBudget(forAudioDuration: seconds)
            XCTAssertGreaterThanOrEqual(budget, previous, "the budget must be monotonic")
            previous = budget
        }
    }

    // MARK: - A hung decode

    /// The core of the report: an engine whose decode never answers - and does
    /// not answer cancellation either, which is what "wedged" means for a
    /// blocking C call - fails the transcription with a clean, named error in
    /// bounded time instead of holding it forever.
    func testADecodeThatNeverAnswersFailsInsteadOfHangingForever() async throws {
        let engine = DeadlineStubEngine(behaviour: .hangsDecode)
        let service = makeService(engine)
        service.decodeTimeoutOverride = 0.3
        let settings = plainSettings()

        let startedAt = Date()
        let call = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        await waitUntil(engine.decodeCount == 1)

        do {
            _ = try await value(of: call, within: 5)
            XCTFail("A hung decode must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .processingTimedOut)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt), 5,
            "the failure arrived in bounded time, bounded by the budget rather than by the engine")

        await waitUntil(!service.isTranscribing)
        XCTAssertFalse(service.isTranscribing, "the frame is released, so the service stops being busy")
        XCTAssertEqual(engine.cancelCount, 1, "the wedged engine is told to cancel, so a cooperative decode unwinds")
    }

    /// A decode that is cancelled by its deadline leaves the engine untrusted:
    /// the next transcription loads a fresh one rather than starting beside a
    /// decode that may still be inside the old context, and it succeeds.
    func testATimedOutDecodeDropsTheEngineAndTheNextTranscriptionReloads() async throws {
        let engine = DeadlineStubEngine(behaviour: .hangsDecode)
        let service = makeService(engine)
        service.decodeTimeoutOverride = 0.3
        let settings = plainSettings()

        let first = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        await waitUntil(engine.decodeCount == 1)
        _ = try? await value(of: first)
        XCTAssertEqual(engine.loadCount, 1)

        engine.setBehaviour(.ready)
        let second = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        let styled = try await value(of: second)

        XCTAssertEqual(styled.final, DeadlineStubEngine.text)
        XCTAssertEqual(engine.loadCount, 2, "the dropped engine is loaded again, not reused")
        XCTAssertEqual(engine.decodeCount, 2)
    }

    /// A caller queued behind the hung decode is the wedge that mattered: it
    /// used to wait on a frame that was never released. Now it waits out the
    /// hung frame's budget and then runs.
    func testACallerQueuedBehindAHungDecodeRunsOnceItTimesOut() async throws {
        let engine = DeadlineStubEngine(behaviour: .hangsDecode)
        let service = makeService(engine)
        service.decodeTimeoutOverride = 0.3
        let settings = plainSettings()

        let startedAt = Date()
        let first = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        await waitUntil(engine.decodeCount == 1)

        let second = start { try await service.decodeRaw(url: self.audioURL, settings: settings) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.decodeCount, 1, "the second caller waits behind the hung frame")

        // The first decode already captured its hanging behaviour. Arm the
        // engine for the queued call before the deadline releases that call,
        // so the test does not race the queued decode onto the old behaviour.
        engine.setBehaviour(.ready)
        _ = try? await value(of: first)

        // The first decode is abandoned, still inside the engine, so the
        // second decode does overlap it on this stub; what is asserted is that
        // the engine was dropped and freshly loaded first, which on a real
        // engine means a context the abandoned decode cannot be inside.
        let raw = try await value(of: second)
        XCTAssertEqual(raw.text, DeadlineStubEngine.text)
        XCTAssertEqual(engine.loadCount, 2)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt), 10,
            "a queue behind a hang is bounded by the budget, not by the hang")
    }

    // MARK: - A hung load

    /// A load that never answers - the cold-compile deadlock - fails the same
    /// way: the frame is released and the next transcription tries the load
    /// again rather than waiting on the dead one.
    func testAnEngineLoadThatNeverAnswersFailsAndReleasesTheFrame() async throws {
        let engine = DeadlineStubEngine(behaviour: .hangsLoad)
        let service = makeService(engine)
        service.loadTimeoutOverride = 0.3
        let settings = plainSettings()

        let first = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        await waitUntil(engine.loadCount == 1)

        do {
            _ = try await value(of: first, within: 5)
            XCTFail("A hung load must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .processingTimedOut)
        }
        await waitUntil(!service.isTranscribing)
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(engine.decodeCount, 0, "the decode never ran")

        engine.setBehaviour(.ready)
        let second = start { try await service.transcribeAudio(url: self.audioURL, settings: settings) }
        let styled = try await value(of: second)
        XCTAssertEqual(styled.final, DeadlineStubEngine.text)
        XCTAssertEqual(engine.loadCount, 2, "the retry loads again rather than waiting on the dead load")
    }

    /// Every caller that arrived while the load was wedged resolves: the first
    /// to the deadline, the rest to the retry. Nobody is left waiting on a
    /// frame whose load never finished, however many of them there are.
    func testConcurrentCallersBehindAHungLoadAllResolve() async throws {
        let engine = DeadlineStubEngine(behaviour: .hangsFirstLoad)
        let service = makeService(engine)
        service.loadTimeoutOverride = 0.3
        let callers = 6
        let settings = plainSettings()

        let startedAt = Date()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<callers {
                group.addTask { @MainActor in
                    let call = self.start {
                        try await service.transcribeAudio(url: self.audioURL, settings: settings)
                    }
                    do {
                        _ = try await self.value(of: call, within: 15)
                        return true
                    } catch is TimedOut {
                        return false
                    } catch {
                        // The first caller is expected to resolve by throwing
                        // processingTimedOut. Resolution, not success, is the
                        // invariant this concurrency test measures.
                        return true
                    }
                }
            }
            var collected: [Bool] = []
            for await resolved in group { collected.append(resolved) }
            return collected
        }

        XCTAssertEqual(results.count, callers)
        XCTAssertTrue(results.allSatisfy { $0 }, "every caller resolved, one way or the other")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 15)
        XCTAssertEqual(engine.decodeCount, callers - 1, "the caller whose load hung failed; the rest decoded")
        XCTAssertEqual(engine.maxConcurrentDecodes, 1, "and still never two decodes at once")
    }

    // MARK: - The boundary

    /// A decode that finishes inside its budget is untouched by the deadline:
    /// it returns its text, nothing is cancelled, and the engine is kept, so
    /// the next transcription does not pay a reload.
    func testADecodeInsideItsBudgetIsLeftAlone() async throws {
        let engine = DeadlineStubEngine(behaviour: .ready, decodeDelay: 100_000_000)
        let service = makeService(engine)
        service.decodeTimeoutOverride = 5
        let settings = plainSettings()

        let styled = try await service.transcribeAudio(url: audioURL, settings: settings)
        XCTAssertEqual(styled.final, DeadlineStubEngine.text)
        XCTAssertEqual(engine.cancelCount, 0)

        _ = try await service.transcribeAudio(url: audioURL, settings: settings)
        XCTAssertEqual(engine.loadCount, 1, "an engine that answered in time is not reloaded")
    }

    /// A timed-out dictation keeps its audio: the failure is transient, the
    /// recording is good, and the fix is to regenerate. This is the
    /// `DictationFailureOutcome` rule `EngineConfigurationTests` pins for the
    /// other keepable failures.
    func testATimedOutDictationKeepsTheRecording() {
        let outcome = DictationFailureOutcome.forError(TranscriptionError.processingTimedOut)
        guard case .keep(let reason, let notice) = outcome else {
            XCTFail("a timeout must keep the audio: \(outcome)")
            return
        }
        XCTAssertEqual(notice, .transcriptionTimedOut)
        XCTAssertEqual(reason, TranscriptionError.processingTimedOut.errorDescription)
        XCTAssertEqual(RecordingState(notice), .transcriptionTimedOut)
    }

    /// The failure reads as something the user can do, the rule every
    /// `TranscriptionError` is a `LocalizedError` for.
    func testTheTimeoutFailureReadsAsAnInstruction() {
        let description = TranscriptionError.processingTimedOut.localizedDescription
        XCTAssertFalse(description.contains("TranscriptionError"))
        XCTAssertTrue(description.contains("kept"), "the message must say the audio survived: \(description)")
        XCTAssertTrue(description.contains("egenerate"), "and what to do about it: \(description)")
    }

    // MARK: - Latency across durations

    /// What the pipeline itself costs over the decode, measured end to end on
    /// synthetic audio of the three sizes the report is about - a short
    /// utterance, a medium one, and a long one - with the decode cost made
    /// proportional to the audio so the wall time has something real to scale
    /// against.
    ///
    /// The bounds are deliberately loose. This is a regression check for
    /// *pathological* overhead - a serialization stall, an accidental quadratic,
    /// a deadline that fires on healthy work - in the tradition of
    /// `docs/dictation-latency.md`, whose micro-benchmarks were measured once
    /// and deliberately not committed as asserts. The real deadline is what the
    /// timeout tests above pin; this proves the deadline's budget dwarfs the
    /// measured cost on every size, so it cannot false-positive.
    func testTranscriptionLatencyAcrossAudioDurations() async throws {
        let cases: [(seconds: Double, label: String)] = [
            (5, "short utterance"),
            (30, "medium"),
            (60, "long"),
        ]

        for (seconds, label) in cases {
            let url = try writeTone(seconds: seconds)
            defer { try? FileManager.default.removeItem(at: url) }

            // The fixture has to be the length it claims to be, or the decode
            // cost and the budget below are both measuring nothing.
            let duration = await AudioUtil.audioDuration(url: url)
            XCTAssertEqual(duration, seconds, accuracy: 0.5, "\(label): the fixture's length")

            // A decode that costs 2% of realtime: 0.1 s, 0.6 s and 1.2 s.
            let engine = ProportionalStubEngine(factor: 0.02)
            let service = makeService(engine)
            let settings = plainSettings()

            let startedAt = Date()
            let styled = try await service.transcribeAudio(url: url, settings: settings)
            let wall = Date().timeIntervalSince(startedAt)

            XCTAssertEqual(styled.final, ProportionalStubEngine.text, "\(label): the decode returned")
            let simulatedDecode = seconds * engine.factor
            let overhead = wall - simulatedDecode
            print(String(
                format: "latency %@: %.0fs audio, wall %.2fs, decode %.2fs, overhead %.2fs, budget %.0fs",
                label, seconds, wall, simulatedDecode, overhead,
                TranscriptionService.decodeTimeoutBudget(forAudioDuration: duration)))

            XCTAssertLessThan(
                wall, max(10, simulatedDecode * 10),
                "\(label): end-to-end latency is within an order of magnitude of the decode itself")
            XCTAssertLessThan(
                overhead, 5,
                "\(label): the pipeline's own cost does not grow pathologically with the audio")
            XCTAssertGreaterThan(
                TranscriptionService.decodeTimeoutBudget(forAudioDuration: duration),
                wall * 10,
                "\(label): the deadline is an order of magnitude above healthy work, never inside it")
        }
    }

    /// 16 kHz mono tone, written where the decode path can pick it up - a tone
    /// rather than zeros so the file is audio-shaped, the same reason
    /// `SenseVoiceEngineIntegrationTests` synthesizes speech for its fixtures.
    private func writeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latency-\(Int(seconds))s-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                channel[i] = sin(2 * .pi * 220 * Float(i) / Float(format.sampleRate)) * 0.3
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// Where a started call's result lands, readable without awaiting the call.
private final class Call<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    var outcome: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    func record(_ outcome: Result<T, Error>) { lock.lock(); result = outcome; lock.unlock() }
}

/// An engine whose load and decode can each be told to hang - forever, and
/// deaf to cancellation, which is the only faithful shape a wedged engine has:
/// a blocking call that never returns is precisely what a deadline exists
/// for, since a cooperative hang is just a slow success.
private final class DeadlineStubEngine: TranscriptionEngine, @unchecked Sendable {
    static let text = "decoded"

    enum Behaviour {
        case ready
        /// Every load waits forever.
        case hangsLoad
        /// The first load waits forever; the retry answers.
        case hangsFirstLoad
        /// Every decode waits forever.
        case hangsDecode
    }

    var isModelLoaded = false
    var engineName: String { "DeadlineStub" }
    var onProgressUpdate: ((Float) -> Void)?

    private let decodeDelay: UInt64
    private let lock = NSLock()
    private var behaviour: Behaviour
    private var loads = 0
    private var decodes = 0
    private var cancels = 0
    private var inFlight = 0
    private var maxInFlight = 0

    init(behaviour: Behaviour, decodeDelay: UInt64 = 0) {
        self.behaviour = behaviour
        self.decodeDelay = decodeDelay
    }

    var loadCount: Int { lock.withLock { loads } }
    var decodeCount: Int { lock.withLock { decodes } }
    var cancelCount: Int { lock.withLock { cancels } }
    var maxConcurrentDecodes: Int { lock.withLock { maxInFlight } }

    func setBehaviour(_ behaviour: Behaviour) {
        lock.withLock { self.behaviour = behaviour }
    }

    /// A wait that never ends and never answers cancellation - the shape of a
    /// wedged blocking call. The task parking here is what `AsyncDeadline`
    /// abandons.
    private func hang() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    func initialize() async throws {
        let behaviour = lock.withLock {
            loads += 1
            let behaviour = self.behaviour
            if behaviour == .hangsFirstLoad { self.behaviour = .ready }
            return behaviour
        }

        if behaviour == .hangsLoad || behaviour == .hangsFirstLoad {
            await hang()
            return
        }
        isModelLoaded = true
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let behaviour = lock.withLock {
            decodes += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            return self.behaviour
        }
        defer {
            lock.withLock { inFlight -= 1 }
        }

        if behaviour == .hangsDecode {
            await hang()
        }
        if decodeDelay > 0 { try? await Task.sleep(nanoseconds: decodeDelay) }
        return Self.text
    }

    func cancelTranscription() {
        lock.withLock { cancels += 1 }
    }

    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}

/// An engine whose decode costs a fixed fraction of the audio's length, read
/// off the file it is handed the way the deadline reads it. The latency test
/// scales the audio; this is what scales against it.
private final class ProportionalStubEngine: TranscriptionEngine, @unchecked Sendable {
    static let text = "decoded"

    var isModelLoaded = true
    var engineName: String { "ProportionalStub" }
    var onProgressUpdate: ((Float) -> Void)?

    let factor: Double

    init(factor: Double) {
        self.factor = factor
    }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let duration = await AudioUtil.audioDuration(url: url)
        let nanoseconds = UInt64(duration * factor * 1_000_000_000)
        if nanoseconds > 0 { try? await Task.sleep(nanoseconds: nanoseconds) }
        return Self.text
    }

    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}
