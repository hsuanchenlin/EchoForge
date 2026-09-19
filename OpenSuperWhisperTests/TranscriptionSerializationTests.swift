import XCTest
@testable import OpenSuperWhisper

/// Two transcriptions never share the engine, and in particular never share it
/// across the engine load.
///
/// `runTranscription` waits for the frame in flight, then loads the engine,
/// then runs its work. The load is a suspension point, and the frame used to
/// be reserved only *after* it - the handle the loop waits on was a box around
/// the work task, and there was no task until the load returned. So a second
/// caller arriving during the load found nothing to wait on and ran beside the
/// first: an utterance decode from a live session beside a queued file, or the
/// queue's first item at launch beside the first dictation. The frame is now
/// reserved before the load, and these tests stand a second caller inside
/// that window and check that it waits.
@MainActor
final class TranscriptionSerializationTests: XCTestCase {

    private func makeService(_ engine: TranscriptionEngine) -> TranscriptionService {
        let service = TranscriptionService()
        service.engineOverride = engine
        return service
    }

    private var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("test_audio.m4a")
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private struct TimedOut: Error {}

    /// Starts a transcription call as its own task and hands back its outcome
    /// slot, for `value(of:)` to read with a deadline.
    private func start<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) -> Call<T> {
        let call = Call<T>()
        Task { @MainActor in
            do { call.record(.success(try await body())) } catch { call.record(.failure(error)) }
        }
        return call
    }

    /// The call's result, or `TimedOut`. Every caller these tests leave queued
    /// is released by the end of the test *if* the frame serialises them; when
    /// it does not, one of them is stranded at a gate nobody opens, and a plain
    /// `await` on its task would hang the run instead of failing the test - and
    /// so would racing that await inside a task group, which cannot finish
    /// until the stranded child does. Polling a slot is the one wait that can
    /// give up.
    private func value<T>(of call: Call<T>, within seconds: Double = 3) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while call.outcome == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let outcome = call.outcome else { throw TimedOut() }
        return try outcome.get()
    }

    /// A caller that arrives while the engine is still loading waits for the
    /// load *and* the work it was loaded for, and only then runs its own.
    ///
    /// This is the exact window: the first frame is suspended inside
    /// `prepare`, no work task exists yet, and the second caller reaches the
    /// serialisation loop. It used to find the engine free.
    func testACallerArrivingDuringEnginePreparationWaitsForTheWholeFrame() async throws {
        let engine = LoadGatedStubEngine(text: "first")
        let service = makeService(engine)

        let first = start { try await service.transcribeAudio(url: self.audioURL, settings: Settings()) }
        await waitUntil(engine.loadCount == 1)
        XCTAssertEqual(engine.transcribeCount, 0, "the first is still loading")

        let second = start { try await service.decodeRaw(url: self.audioURL, settings: Settings()) }
        await settle()
        XCTAssertEqual(engine.loadCount, 1, "the second must not start its own load beside the first")
        XCTAssertEqual(engine.transcribeCount, 0, "nor reach the engine while the first is loading")

        engine.releaseLoad()
        await waitUntil(engine.transcribeCount == 1)
        await settle()
        XCTAssertEqual(
            engine.transcribeCount, 1,
            "with the load done, the first runs and the second still waits behind it")

        engine.releaseTranscription()
        let firstResult = try await value(of: first)
        XCTAssertEqual(firstResult.final, "first")

        await waitUntil(engine.transcribeCount == 2)
        XCTAssertEqual(engine.transcribeCount, 2, "and then the second runs")
        engine.releaseTranscription()
        _ = try await value(of: second)
        XCTAssertEqual(engine.maxConcurrentTranscriptions, 1)
    }

    /// A cancel pressed while the engine is still loading cancels that
    /// transcription - its work never starts - and the caller queued behind it
    /// still waits for its frame to unwind and then runs.
    ///
    /// Before the load was inside the frame, there was nothing for the cancel
    /// to reach: the task box did not exist yet.
    func testACancelDuringEnginePreparationStopsThatFrameAndReleasesTheNext() async throws {
        let engine = LoadGatedStubEngine(text: "second")
        let service = makeService(engine)

        let first = start { try await service.transcribeAudio(url: self.audioURL, settings: Settings()) }
        await waitUntil(engine.loadCount == 1)
        XCTAssertTrue(service.isTranscribing, "the frame is in flight while the engine loads")

        service.cancelTranscription()
        XCTAssertTrue(service.isTranscribing, "cancelling does not free the engine before the load unwinds")

        let second = start { try await service.transcribeAudio(url: self.audioURL, settings: Settings()) }
        await settle()
        XCTAssertEqual(engine.transcribeCount, 0, "the second waits for the cancelled frame")

        engine.releaseLoad()
        do {
            _ = try await value(of: first)
            XCTFail("A transcription cancelled during its load must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .processingFailed)
        }

        await waitUntil(engine.transcribeCount == 1)
        XCTAssertEqual(engine.transcribeCount, 1, "the cancelled work never reached the engine; the second did")
        engine.releaseTranscription()
        let styled = try await value(of: second)
        XCTAssertEqual(styled.final, "second", "and a cancel of the first cannot reach the second")
    }

    /// A load that fails gives the frame back: the next caller is not held
    /// for ever behind a transcription that never ran.
    func testAPreparationThatThrowsReleasesTheFrame() async throws {
        let engine = LoadGatedStubEngine(text: "after the failure")
        engine.failNextLoad()
        let service = makeService(engine)

        engine.releaseLoad()
        do {
            _ = try await service.transcribeAudio(url: audioURL, settings: Settings())
            XCTFail("A load that throws must fail the transcription")
        } catch {
            XCTAssertEqual(engine.transcribeCount, 0)
        }

        let second = start { try await service.transcribeAudio(url: self.audioURL, settings: Settings()) }
        await waitUntil(engine.loadCount == 2)
        XCTAssertEqual(engine.loadCount, 2, "the next caller reaches the load rather than waiting on the failed frame")
        engine.releaseLoad()
        await waitUntil(engine.transcribeCount == 1)
        engine.releaseTranscription()
        let styled = try await value(of: second)
        XCTAssertEqual(styled.final, "after the failure")
        await waitUntil(!service.isTranscribing)
        XCTAssertFalse(service.isTranscribing)
    }

    /// Many callers started at once, with a load and work that both take
    /// time, run strictly one after another: never two on the engine, and
    /// every one of them completes.
    ///
    /// The gated tests above stand a caller in the one window that was open;
    /// this one throws callers at every window there is and checks the count.
    func testConcurrentCallersRunStrictlyOneAtATime() async throws {
        let engine = LoadGatedStubEngine(text: "…", loadDelay: 20_000_000, transcribeDelay: 5_000_000)
        engine.openEveryGate()
        let service = makeService(engine)
        let callers = 12

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<callers {
                group.addTask { @MainActor in
                    let call: Call<Bool>
                    if index.isMultiple(of: 2) {
                        call = self.start { (try? await service.transcribeAudio(url: self.audioURL, settings: Settings())) != nil }
                    } else {
                        call = self.start { (try? await service.decodeRaw(url: self.audioURL, settings: Settings())) != nil }
                    }
                    return (try? await self.value(of: call, within: 10)) ?? false
                }
            }
            var collected: [Bool] = []
            for await completed in group { collected.append(completed) }
            return collected
        }

        XCTAssertEqual(results.count, callers)
        XCTAssertTrue(results.allSatisfy { $0 }, "every caller completes")
        XCTAssertEqual(engine.loadCount, 1, "the engine is loaded once, inside the first frame")
        XCTAssertEqual(engine.transcribeCount, callers)
        XCTAssertEqual(engine.maxConcurrentTranscriptions, 1, "and never two at once")
        await waitUntil(!service.isTranscribing)
        XCTAssertFalse(service.isTranscribing)
    }
}

/// Where a started call's result lands, readable without awaiting the call.
private final class Call<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    var outcome: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    func record(_ outcome: Result<T, Error>) { lock.lock(); result = outcome; lock.unlock() }
}

/// A gate a stub waits at until the test opens it. Each `open` lets one
/// arrival through: the one waiting, or else the next one to arrive.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var pendingReleases = 0
    private var openForGood = false

    /// Lets everyone through from now on: for the test that wants the steps
    /// to take time rather than to stop.
    func openForever() {
        lock.lock()
        let released = waiting
        waiting = []
        openForGood = true
        lock.unlock()
        for waiter in released { waiter.resume() }
    }

    func open() {
        lock.lock()
        let waiter = waiting.isEmpty ? nil : waiting.removeFirst()
        if waiter == nil { pendingReleases += 1 }
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if openForGood {
                lock.unlock()
                continuation.resume()
            } else if pendingReleases > 0 {
                pendingReleases -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// An engine whose load waits until the test lets it - the shape of a real
/// engine, whose load is a detached task the frame suspends on - and whose
/// transcription waits likewise, and that counts how many transcriptions it
/// was ever inside at once.
private final class LoadGatedStubEngine: TranscriptionEngine, @unchecked Sendable {
    var isModelLoaded = false
    var engineName: String { "LoadGatedStub" }
    var onProgressUpdate: ((Float) -> Void)?

    private let text: String
    private let loadDelay: UInt64
    private let transcribeDelay: UInt64
    private let loadGate = Gate()
    private let transcribeGate = Gate()
    private let lock = NSLock()
    private var loads = 0
    private var transcriptions = 0
    private var inFlight = 0
    private var maxInFlight = 0
    private var shouldFailNextLoad = false

    /// `loadDelay` and `transcribeDelay` are what each step takes *after* its
    /// gate opens, for the test that opens every gate up front and wants the
    /// steps to still have length.
    init(text: String, loadDelay: UInt64 = 0, transcribeDelay: UInt64 = 0) {
        self.text = text
        self.loadDelay = loadDelay
        self.transcribeDelay = transcribeDelay
    }

    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
    var transcribeCount: Int { lock.lock(); defer { lock.unlock() }; return transcriptions }
    var maxConcurrentTranscriptions: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }

    func failNextLoad() { lock.lock(); shouldFailNextLoad = true; lock.unlock() }
    func releaseLoad() { loadGate.open() }
    func releaseTranscription() { transcribeGate.open() }
    func openEveryGate() { loadGate.openForever(); transcribeGate.openForever() }

    struct LoadFailed: Error {}

    func initialize() async throws {
        lock.lock()
        loads += 1
        let fail = shouldFailNextLoad
        shouldFailNextLoad = false
        lock.unlock()

        await loadGate.wait()
        if loadDelay > 0 { try? await Task.sleep(nanoseconds: loadDelay) }
        if fail { throw LoadFailed() }
        isModelLoaded = true
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        lock.lock()
        transcriptions += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()
        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        await transcribeGate.wait()
        if transcribeDelay > 0 { try? await Task.sleep(nanoseconds: transcribeDelay) }
        return text
    }

    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}
