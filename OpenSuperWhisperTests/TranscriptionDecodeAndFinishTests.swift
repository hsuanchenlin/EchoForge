import XCTest
@testable import OpenSuperWhisper

/// `TranscriptionService.transcribeAudio` is two named halves - `decodeRaw`,
/// which is the engine and nothing after it, and `finish`, which is everything
/// after it - and this is what holds them to that.
///
/// The halves exist so that a caller can decode pieces of a dictation while the
/// microphone is still open and run the post-processing once over the joined
/// text; the rules here are what such a caller relies on and what the split
/// must not have changed for the callers that already exist.
@MainActor
final class TranscriptionDecodeAndFinishTests: XCTestCase {

    private func makeService(_ engine: TranscriptionEngine) -> TranscriptionService {
        let service = TranscriptionService()
        service.engineOverride = engine
        return service
    }

    private var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("test_audio.m4a")
    }

    /// Chinese dictation with the default Traditional output: the transcript
    /// stage has something visible to do to this text, so a stage that ran
    /// where it should not have is caught by the characters.
    private func chineseSettings() -> Settings {
        var settings = Settings()
        settings.selectedLanguage = "zh"
        settings.chineseOutputScript = .traditional
        settings.useAsianAutocorrect = false
        settings.safeCorrectionEnabled = false
        settings.styleRewrite = .disabled
        return settings
    }

    /// `decodeRaw` returns what the engine said, byte for byte: no script
    /// normalisation, no dictionary, no rewrite. A caller joining utterances
    /// has to be handed the machine's words, since the stages run once over
    /// the whole and never over a piece.
    func testDecodeRawReturnsTheEngineTextUntouched() async throws {
        let engine = GatedStubEngine(text: "简体 test")
        let service = makeService(engine)
        engine.release()

        let raw = try await service.decodeRaw(url: audioURL, settings: chineseSettings())

        XCTAssertEqual(raw, "简体 test")
    }

    /// `finish` is the transcript stage and the spoken-intent stage, in that
    /// order and nothing else, so the same text finished twice finishes the
    /// same way.
    func testFinishRunsThePostProcessingPipeline() async {
        let styled = await TranscriptionService.finish(raw: "简体 test", settings: chineseSettings())

        XCTAssertEqual(styled.raw, "简体 test", "the original survives beside the result")
        XCTAssertEqual(styled.final, "簡體 test", "and the transcript stage ran over it")
    }

    /// The composition is exact: transcribing a file is decoding it and then
    /// finishing what came out, with nothing between the two that either half
    /// does not do on its own.
    func testTranscribeAudioIsDecodeRawFollowedByFinish() async throws {
        let engine = GatedStubEngine(text: "简体 test")
        let service = makeService(engine)
        let settings = chineseSettings()

        engine.release()
        let composed = try await service.transcribeAudio(url: audioURL, settings: settings)
        engine.release()
        let raw = try await service.decodeRaw(url: audioURL, settings: settings)
        let finished = await TranscriptionService.finish(raw: raw, settings: settings)

        XCTAssertEqual(composed, finished)
        XCTAssertEqual(service.transcribedText, raw, "a decode publishes the raw text it returned")
    }

    /// A decode queues behind a whole-file transcription on the same engine, and
    /// a whole-file transcription queues behind a decode. One serialisation
    /// frame, not two, or two pieces of work reach one whisper context at once.
    func testDecodeRawSharesTheSerialisationWithWholeFileWork() async throws {
        let engine = GatedStubEngine(text: "first")
        let service = makeService(engine)

        let wholeFile = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning(count: 1)

        let decode = Task { try await service.decodeRaw(url: audioURL, settings: Settings()) }
        for _ in 0..<20 where engine.startCount == 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(engine.startCount, 1, "the decode must wait for the transcription to let go of the engine")

        engine.release()
        _ = try await wholeFile.value
        await engine.waitUntilRunning(count: 2)
        XCTAssertEqual(engine.startCount, 2, "and then run")

        let second = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        for _ in 0..<20 where engine.startCount == 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(engine.startCount, 2, "the reverse holds: whole-file work waits for a decode")

        engine.release()
        _ = try await decode.value
        engine.release()
        _ = try await second.value
        XCTAssertEqual(engine.startCount, 3)
    }

    /// A cancelled decode returns nothing and publishes nothing - the same
    /// answer `TranscriptionCancellationTests` holds `transcribeAudio` to, since
    /// they are one frame.
    func testACancelledDecodeProducesNoText() async {
        let engine = GatedStubEngine(text: "the words the user cancelled")
        let service = makeService(engine)

        let decode = Task { try await service.decodeRaw(url: audioURL, settings: Settings()) }
        await engine.waitUntilRunning(count: 1)
        XCTAssertTrue(service.isTranscribing, "a decode is a transcription as far as the busy check is concerned")
        service.cancelTranscription()
        engine.release()

        do {
            _ = try await decode.value
            XCTFail("A cancelled decode must not return text")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .processingFailed)
        }
        XCTAssertEqual(service.transcribedText, "")
    }
}

/// An engine that answers only when the test lets it, counting how many times it
/// was asked. A release given before the ask lets the next ask through at once.
private final class GatedStubEngine: TranscriptionEngine, @unchecked Sendable {
    var isModelLoaded = true
    var engineName: String { "GatedStub" }
    var onProgressUpdate: ((Float) -> Void)?

    private let text: String
    private let lock = NSLock()
    private var started = 0
    private var releases = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(text: String) { self.text = text }

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func waitUntilRunning(count: Int) async {
        for _ in 0..<400 where startCount < count {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Lets one ask through: the one waiting, or the next one to arrive.
    func release() {
        lock.lock()
        if waiting.isEmpty {
            releases += 1
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        lock.unlock()
        next.resume()
    }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started += 1
            if releases > 0 {
                releases -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
        return text
    }

    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { LanguageUtil.availableLanguages }
}
