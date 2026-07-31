import XCTest
@testable import OpenSuperWhisper

/// The same F2/F3 regressions as `ParaformerEngineTests`, but against the real
/// FluidAudio models rather than a fake that reproduces their limits.
///
/// Opt-in, and skipped by default: the first run downloads ~653 MB from Hugging
/// Face and then pays a one-time Neural Engine compile of about a minute, which
/// does not belong in an ordinary test run. It exists because a fake that models
/// the 128-token clamp is only as good as the belief that the real decoder still
/// behaves that way; this is what re-checks that belief after a FluidAudio bump.
///
/// The fixtures are synthesized speech, not committed (the directory is
/// gitignored) because they are cheaper to regenerate than to carry. Generating
/// them is the whole opt-in - no environment variable, which xcodebuild does not
/// forward to a hosted macOS test bundle anyway:
///
/// ```sh
/// mkdir -p OpenSuperWhisperTests/Fixtures/paraformer && cd $_
/// cat > script.txt <<'EOF'
/// 语音识别技术在过去十年里取得了很大的进步。在中文场景下，模型不仅需要处理普通话，还要面对各种各样的口音和方言，
/// 这对训练数据的覆盖面提出了更高的要求。除此之外，实时性也是一个关键指标，很多应用场景要求系统在用户说完话之后的
/// 几百毫秒之内就给出结果。最后一句话是一个特别的标记句：如果你能看到这句话，说明整段音频都被完整地识别了。
/// EOF
/// say -v Tingting        -f script.txt -o long.wav  --file-format=WAVE --data-format=LEI16@16000  # 36.0 s
/// say -v Tingting -r 300 -f script.txt -o dense.wav --file-format=WAVE --data-format=LEI16@16000  # 22.6 s
/// ```
///
/// The script is 151 characters of Mandarin, which is the point of both
/// fixtures: over the decoder's 128-token clamp either way, on one side of the
/// 30 s input ceiling and on the other.
final class ParaformerEngineIntegrationTests: XCTestCase {

    /// The script's closing marker sentence. A truncating engine loses it.
    private let marker = "说明整段音频都被完整地识别了"

    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/paraformer")
            .appendingPathComponent(name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Generate \(url.path) to run the Paraformer model integration tests - see this file's comment"
        )
        return url
    }

    private func transcribe(_ url: URL) async throws -> (text: String, progress: [Float]) {
        let engine = ParaformerEngine()
        var progress: [Float] = []
        engine.onProgressUpdate = { progress.append($0) }

        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded)

        let text = try await engine.transcribeAudio(url: url, settings: Settings())
        return (text, progress)
    }

    /// Longest common prefix of the tail with an earlier repetition of itself -
    /// the shape the clamped decoder degenerates into (`除此之外实时性` twice).
    private func assertNoRepeatedTail(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let characters = Array(text)
        guard characters.count >= 12 else { return }
        let tail = String(characters.suffix(6))
        XCTAssertFalse(
            String(characters.dropLast(6)).hasSuffix(tail),
            "the transcript ends in a repeated 6-character run, which is what an overrun decoder emits",
            file: file, line: line
        )
    }

    /// F3. 36 s is past the 30 s input ceiling, where a single call *throws*.
    func testLongRecordingIsTranscribedWholeRatherThanFailing() async throws {
        let (text, progress) = try await transcribe(try fixture("long.wav"))

        XCTAssertTrue(
            text.contains(marker),
            "the closing marker sentence is missing, so the tail of the recording was lost: \(text)"
        )
        XCTAssertGreaterThan(
            text.count, 140,
            "the script is 151 characters and one clamped call yields 127 - the gap between them is the whole test"
        )
        assertNoRepeatedTail(text)
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertGreaterThan(progress.count, 3, "progress must move per chunk, not once at each end")
    }

    /// F2. 22.6 s is *inside* the input ceiling, so nothing throws - this is the
    /// case the engine would silently get wrong if it only chunked on duration.
    func testDenseRecordingInsideTheCeilingIsNotSilentlyClamped() async throws {
        let (text, _) = try await transcribe(try fixture("dense.wav"))

        XCTAssertGreaterThan(text.count, 140, "127 characters means the 128-token clamp bound: \(text)")
        XCTAssertTrue(text.contains(marker), "the tail past the token clamp was dropped: \(text)")
        assertNoRepeatedTail(text)
    }

    /// C9/C5, cheaply: the engine claims Mandarin only, and the transcript of
    /// Mandarin speech is Mandarin - not the `@@`-laden BPE fragments the model
    /// returns when it is fed something else.
    func testTranscriptIsBareMandarinWithoutBpeMarkers() async throws {
        let (text, _) = try await transcribe(try fixture("dense.wav"))

        XCTAssertFalse(text.contains("@@"), "raw BPE continuation markers leaked into the transcript")
        XCTAssertFalse(text.contains(" "))
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
        XCTAssertGreaterThan(
            Double(han.count) / Double(max(1, text.unicodeScalars.count)), 0.9,
            "a Mandarin transcript that is under 90 % Han characters is not a Mandarin transcript: \(text)"
        )
    }
}
