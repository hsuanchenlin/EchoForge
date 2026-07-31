import AVFoundation
import XCTest
@testable import OpenSuperWhisper

/// The F3/F4/F6/F8 regressions against the real SenseVoice weights rather than a
/// fake that reproduces their limits.
///
/// Opt-in, and skipped by default: the first run downloads ~240 MB from Hugging
/// Face and then pays a one-time Neural Engine compile of about 90 s, which does
/// not belong in an ordinary test run. It exists because the unit tests are only
/// as good as the belief that the real model still behaves the way they model
/// it - in particular that `textNorm` still couples punctuation to inverse text
/// normalisation, which is a decode flag that fails *silently* in the direction
/// of shipping an unpunctuated engine. This is what re-checks that after a
/// FluidAudio bump.
///
/// The fixtures are not committed (the directory is gitignored): four are
/// synthesized or generated locally, and the fifth set is public upstream audio
/// that is cheaper to fetch than to carry. Generating them is the whole opt-in -
/// no environment variable, which xcodebuild does not forward to a hosted macOS
/// test bundle anyway:
///
/// ```sh
/// mkdir -p OpenSuperWhisperTests/Fixtures/sensevoice && cd $_
/// cat > sensevoice-script.txt <<'EOF'
/// 语音识别技术在过去十年里取得了很大的进步。在中文场景下，模型不仅需要处理普通话，还要面对各种各样的口音和方言，
/// 这对训练数据的覆盖面提出了更高的要求。除此之外，实时性也是一个关键指标，很多应用场景要求系统在用户说完话之后的
/// 几百毫秒之内就给出结果。最后一句话是一个特别的标记句：如果你能看到这句话，说明整段音频都被完整地识别了。
/// EOF
/// say -v Tingting -f sensevoice-script.txt -o sensevoice-long.wav --file-format=WAVE --data-format=LEI16@16000   # 36.0 s
/// echo '我们下午三点二十分在北京西站见面，这张机票花了一千两百五十块钱，会议定在二零二六年七月三十号。' \
///   | say -v Tingting -o sensevoice-itn.wav --file-format=WAVE --data-format=LEI16@16000              # 10.8 s
/// # The five public example clips from the upstream model card (28-58 KB each):
/// for lang in zh yue en ja ko; do
///   curl -sL -o $lang.mp3 \
///     https://huggingface.co/FunAudioLLM/SenseVoiceSmall/resolve/main/example/$lang.mp3
///   afconvert -f WAVE -d LEI16@16000 -c 1 $lang.mp3 hf_$lang.wav
/// done
/// ```
///
/// Silence is not a fixture - the test writes it, because a file of zeros is
/// easier to generate than to describe.
final class SenseVoiceEngineIntegrationTests: XCTestCase {

    /// The Mandarin script's closing marker sentence. A truncating engine loses
    /// it; the whole point of F3 is that this survives 36 s of audio.
    private let marker = "说明整段音频都被完整地识别了"

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sensevoice")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = fixturesDirectory.appendingPathComponent(name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Generate \(url.path) to run the SenseVoice model integration tests - see this file's comment"
        )
        return url
    }

    /// Guards the tests that need weights but no recorded audio, so an ordinary
    /// test run on a machine with no fixtures never triggers a 240 MB download.
    private func skipUnlessFixturesExist() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixturesDirectory.path),
            "Generate \(fixturesDirectory.path) to run the SenseVoice model integration tests"
        )
    }

    private func transcribe(_ url: URL, language: String = "zh") async throws -> (text: String, progress: [Float]) {
        let engine = SenseVoiceEngine()
        var progress: [Float] = []
        engine.onProgressUpdate = { progress.append($0) }

        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded)

        var settings = Settings()
        settings.selectedLanguage = language
        return (try await engine.transcribeAudio(url: url, settings: settings), progress)
    }

    // MARK: - F3: long audio survives the 30 s ceiling

    /// 36 s is past the ceiling, where a single call throws
    /// `"Size (…) of dimension (1) is not in allowed range (3200..480000)"`.
    func testLongRecordingIsTranscribedWholeRatherThanFailing() async throws {
        let (text, progress) = try await transcribe(try fixture("sensevoice-long.wav"))

        XCTAssertTrue(
            text.contains(marker),
            "the closing marker sentence is missing, so the tail of the recording was lost: \(text)"
        )
        XCTAssertGreaterThan(text.count, 140, "the script is 151 characters: \(text)")
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertGreaterThan(progress.count, 3, "progress must move per chunk, not once at each end")
    }

    /// The seams are the price of chunking, and they must not be spaces: this is
    /// Mandarin, which does not separate words.
    func testTheJoinedTranscriptHasNoInventedSpaces() async throws {
        let (text, _) = try await transcribe(try fixture("sensevoice-long.wav"))

        XCTAssertFalse(text.contains(" "), "a space between chunks is text the user did not say: \(text)")
        XCTAssertFalse(text.contains("\n"))
    }

    // MARK: - F4 / C6 / C7: the textNorm contract

    /// The engine's own output has to be punctuated. `SenseVoiceConfig`'s
    /// default is `15` - no punctuation, no ITN - and `SenseVoiceManager.load()`
    /// hardcodes it, so this is the assertion that catches the whole engine
    /// being silently downgraded to the thing Paraformer already does.
    func testTheEngineProducesPunctuationAndArabicNumerals() async throws {
        let (text, _) = try await transcribe(try fixture("sensevoice-itn.wav"))

        XCTAssertTrue(
            text.contains("，") || text.contains("。"),
            "no punctuation means textNorm reverted to FluidAudio's default: \(text)"
        )
        for expected in ["3点20分", "1250", "2026年7月30号"] where !text.contains(expected) {
            XCTFail("inverse text normalisation did not produce \(expected): \(text)")
        }
    }

    /// The coupling itself, checked directly against the model: `14` is the only
    /// value that punctuates, and `15` punctuates nothing. If a FluidAudio bump
    /// ever separates the two, this fails and the fixed `textNorm` becomes a
    /// choice worth revisiting.
    func testPunctuationAndInverseTextNormalisationAreOneSwitch() async throws {
        let url = try fixture("sensevoice-itn.wav")
        let decoded = try await PCMAudioLoader.loadSamples(from: url)
        let samples = try XCTUnwrap(decoded)
        let factory = try await SenseVoiceEngine.loadFluidAudioModels()

        let withItn = try await factory
            .makeTranscriber(SenseVoiceModelOptions(language: .zh, textNorm: SenseVoiceEngine.textNorm))
            .transcribe(audio: samples)
        let withoutItn = try await factory
            .makeTranscriber(SenseVoiceModelOptions(language: .zh, textNorm: 15))
            .transcribe(audio: samples)

        XCTAssertTrue(withItn.contains("，") || withItn.contains("。"), "textNorm 14 must punctuate: \(withItn)")
        XCTAssertTrue(withItn.contains("1250"), "textNorm 14 must normalise numerals: \(withItn)")

        XCTAssertFalse(withoutItn.contains("，"), "textNorm 15 produces no punctuation at all: \(withoutItn)")
        XCTAssertFalse(withoutItn.contains("。"), "textNorm 15 produces no punctuation at all: \(withoutItn)")
        XCTAssertTrue(
            withoutItn.contains("一千两百五十"),
            "textNorm 15 must leave Chinese numerals alone - it is the same switch: \(withoutItn)"
        )
    }

    // MARK: - F6 / C5: the silence gate

    /// The model has no no-speech gate: 30 s of zeros transcribes as `我.`. The
    /// VAD in front of it is the only thing standing between a silent recording
    /// and invented text.
    func testDigitalSilenceIsAnEmptyTranscript() async throws {
        try skipUnlessFixturesExist()
        let url = try writeSilence(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }

        let (text, progress) = try await transcribe(url)

        XCTAssertEqual(text, "", "silence must not be transcribed as speech: \(text)")
        XCTAssertEqual(progress.last, 1.0, "an empty transcript must not leave the bar hanging")
    }

    // MARK: - F8: the public clips, one per supported language

    /// The claim this engine is chosen on - Mandarin plus four more languages -
    /// against upstream's own example audio.
    func testEachSupportedLanguageIsTranscribedInItsOwnScript() async throws {
        // Each expectation is a fragment that is distinctive of the language and
        // stable across runs. Deliberately not the whole transcript: the opening
        // of the Mandarin clip is heard as either 开放时间 or its homophone
        // 开饭时间, and pinning a homophone would fail for no reason worth acting on.
        //
        // Cantonese is the one that matters most: Paraformer answers this clip
        // with plausible-looking but wrong Mandarin, and only SenseVoice keeps
        // 唔 and 嘅.
        let expectations: [(file: String, language: String, contains: String)] = [
            ("hf_zh.wav", "zh", "时间早上9点至下午5点"),
            ("hf_yue.wav", "yue", "唔"),
            ("hf_en.wav", "en", "gold"),
            ("hf_ja.wav", "ja", "弁当"),
            ("hf_ko.wav", "ko", "생각"),
        ]

        for expectation in expectations {
            let url = try fixture(expectation.file)
            let (text, _) = try await transcribe(url, language: expectation.language)

            XCTAssertTrue(
                text.contains(expectation.contains),
                "\(expectation.language): expected \(expectation.contains) in \(text)"
            )
        }
    }

    /// Auto-detect is the app's fallback for any language with no embedding, so
    /// it has to work on the language the app is mainly for.
    func testMandarinIsTranscribedWithoutBeingToldTheLanguage() async throws {
        let (text, _) = try await transcribe(try fixture("hf_zh.wav"), language: "auto")

        XCTAssertTrue(text.contains("时间早上9点"), "auto-detect lost the Mandarin clip: \(text)")
        XCTAssertTrue(text.hasSuffix("。"), "auto-detect must still punctuate: \(text)")
    }

    // MARK: - Helpers

    /// 16 kHz mono zeros, written where the engine's ordinary decode path can
    /// pick them up.
    private func writeSilence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-silence-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
