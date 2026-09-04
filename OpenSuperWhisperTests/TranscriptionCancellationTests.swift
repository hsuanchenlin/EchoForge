import XCTest
@testable import OpenSuperWhisper

/// What cancelling a transcription leaves behind.
///
/// The three rules asserted here were each broken by the same two lines:
/// `cancelTranscription` used to raise `isCancelled` and drop it again inside
/// one synchronous main-actor call, and to clear `transcriptionTask` and
/// `isTranscribing` while the engine was still unwinding.
@MainActor
final class TranscriptionCancellationTests: XCTestCase {

    private func makeService(_ engine: TranscriptionEngine) -> TranscriptionService {
        let service = TranscriptionService()
        service.engineOverride = engine
        return service
    }

    private var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("test_audio.m4a")
    }

    /// The engine finished, but the user had cancelled: the transcript must not
    /// come back to be pasted.
    ///
    /// It used to. Every `isCancelled` check inside the running task read the
    /// flag *after* `cancelTranscription` had already cleared it, so an engine
    /// that returned a moment too late was indistinguishable from one nobody
    /// had cancelled.
    func testAnEngineThatFinishesAfterCancellationProducesNoTranscript() async {
        let engine = SlowStubEngine(text: "the words the user cancelled")
        let service = makeService(engine)

        let transcription = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning()
        service.cancelTranscription()
        // The engine ignores cancellation, exactly as a backend that has already
        // committed to answering would.
        engine.finish()

        do {
            _ = try await transcription.value
            XCTFail("A cancelled transcription must not return a transcript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .processingFailed)
        }
        XCTAssertEqual(service.transcribedText, "", "Nothing cancelled may be published either")
    }

    /// Cancelling does not make the engine free, so it must not say that it has.
    ///
    /// `isTranscribing` is what `IndicatorViewModel.isTranscriptionBusy` reads
    /// to decide whether a press may start a dictation, and a whisper context
    /// must not be handed a second recording while the first is still inside
    /// `whisper_full`.
    func testTheServiceStaysBusyUntilCancelledWorkActuallyUnwinds() async {
        let engine = SlowStubEngine(text: "…")
        let service = makeService(engine)

        let transcription = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning()
        XCTAssertTrue(service.isTranscribing)

        service.cancelTranscription()
        XCTAssertTrue(
            service.isTranscribing,
            "Cancelling asks the engine to stop; it does not mean it has")

        engine.finish()
        _ = try? await transcription.value
        for _ in 0..<200 where service.isTranscribing {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(service.isTranscribing, "and it must clear once the work has unwound")
    }

    /// A dictation started right after a cancelled one runs *after* it, not
    /// beside it.
    ///
    /// The serialization loop in `transcribeAudio` is the only thing keeping two
    /// transcriptions off one engine, and cancelling used to clear the handle it
    /// waits on.
    func testADictationStartedAfterACancelDoesNotOverlapIt() async {
        let engine = SlowStubEngine(text: "first")
        let service = makeService(engine)

        let first = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning()
        service.cancelTranscription()

        let second = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        // Give the second every chance to start early.
        for _ in 0..<20 where engine.startCount == 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(
            engine.startCount, 1,
            "The second transcription must wait for the cancelled one to let go of the engine")

        engine.finish()
        _ = try? await first.value
        for _ in 0..<200 where engine.startCount == 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(engine.startCount, 2, "and then run")
        engine.finish()
        _ = try? await second.value
    }

    /// Cancelling with nothing in flight resets the bar and raises no flag that
    /// the next transcription would have to clear.
    func testCancellingWithNothingInFlightIsHarmless() async {
        let engine = SlowStubEngine(text: "done")
        let service = makeService(engine)

        service.cancelTranscription()
        XCTAssertEqual(service.progress, 0.0)

        let transcription = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning()
        engine.finish()
        let styled = try? await transcription.value
        XCTAssertEqual(styled?.final, "done", "A stale cancel must not swallow the next dictation")
    }
}

/// An engine that starts when it is asked and finishes when the test says so,
/// and that ignores cancellation - which is the case worth asserting, because a
/// backend that has already committed to answering behaves exactly this way.
private final class SlowStubEngine: TranscriptionEngine, @unchecked Sendable {
    var isModelLoaded = true
    var engineName: String { "SlowStub" }
    var onProgressUpdate: ((Float) -> Void)?

    private let text: String
    private let lock = NSLock()
    private var started = 0
    private var release: CheckedContinuation<Void, Never>?
    private var pendingRelease = false

    init(text: String) { self.text = text }

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func waitUntilRunning() async {
        for _ in 0..<400 where startCount == 0 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Lets the transcription in flight return.
    func finish() {
        lock.lock()
        let waiting = release
        release = nil
        if waiting == nil { pendingRelease = true }
        lock.unlock()
        waiting?.resume()
    }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        lock.lock()
        started += 1
        let alreadyReleased = pendingRelease
        pendingRelease = false
        lock.unlock()

        if !alreadyReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pendingRelease {
                    pendingRelease = false
                    lock.unlock()
                    continuation.resume()
                } else {
                    release = continuation
                    lock.unlock()
                }
            }
        }
        return text
    }

    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}
