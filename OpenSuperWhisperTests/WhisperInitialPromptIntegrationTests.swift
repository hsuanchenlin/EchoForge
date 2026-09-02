import XCTest

@testable import OpenSuperWhisper

/// The claim `WhisperInitialPromptTests` cannot make: that showing the decoder
/// the dictionary actually changes what it writes, against the real whisper
/// weights and the real tokenizer rather than a stand-in for either.
///
/// The unit tests model the composer with one token per character and a fake
/// dictionary. Both halves of the feature are only worth anything if the real
/// decoder is biased by the text they compose, and if the real tokenizer's
/// count is what the budget is measured in - a Han character is one to three
/// tokens, so a character cap silently overruns a Chinese dictionary and the
/// prompt is then cut from the front, taking the user's own typed text with it.
///
/// Opt-in and skipped by default, the way the SenseVoice and Paraformer
/// integration tests are: it needs whisper weights on the machine and a spoken
/// fixture, and it decodes real audio. Neither belongs in an ordinary run. The
/// fixture directory is gitignored; generate it with:
///
/// ```sh
/// mkdir -p OpenSuperWhisperTests/Fixtures/whisper-prompt && cd $_
/// # A product name no speech model has seen. Said twice, so a lucky decode of
/// # one occurrence is not the whole result.
/// echo 'We should ship Kongweh before the sprint review, and tag Kongweh in the release notes.' \
///   | say -v Samantha -o whisper-prompt-name.wav --file-format=WAVE --data-format=LEI16@16000
/// ```
///
/// The weights are whichever `ggml-*.bin` the machine already has in
/// `~/Library/Application Support/com.hsuanchenlin.EchoForge/whisper-models/`;
/// nothing here downloads one.
final class WhisperInitialPromptIntegrationTests: IsolatedPreferencesTestCase {

    /// The spelling the user wants and the recognizer has never seen.
    private let wantedName = "Kongweh"

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/whisper-prompt")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = fixturesDirectory.appendingPathComponent(name)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Generate \(url.path) to run the Whisper prompt integration tests - see this file's comment"
        )
        return url
    }

    /// A model the machine already has. Skipped rather than downloaded: these
    /// weights are 0.5-3 GB, and a test run that fetched them would be the one
    /// thing `AGENTS.md` says a test may never do.
    private func modelPath() throws -> String {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hsuanchenlin.EchoForge/whisper-models")
        let models = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .sorted() ?? []
        guard let model = models.last else {
            throw XCTSkip("Download a Whisper model to run these tests - none in \(directory.path)")
        }
        return directory.appendingPathComponent(model).path
    }

    /// Raw engine output: `transcribeAudio` returns what the decoder wrote,
    /// before any post-processing stage, which is exactly what this test needs
    /// to separate decode-time bias from the terms stage.
    private func transcribe(_ audio: URL, terms: [PersonalTerm]) async throws -> String {
        AppPreferences.shared.selectedWhisperModelPath = try modelPath()
        AppPreferences.shared.whisperLanguage = "en"
        AppPreferences.shared.safeCorrectionEnabled = true
        var settings = Settings()
        settings.initialPrompt = ""
        settings.personalTerms = terms

        let engine = WhisperEngine()
        try await engine.initialize()
        return try await engine.transcribeAudio(url: audio, settings: settings)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The decoder is actually biased

    /// A name the terms stage could not have rescued: the entry's `match` is
    /// text that appears nowhere, so `PersonalTermsCorrector` can do nothing
    /// with it. If the spelling reaches the transcript it is because the
    /// decoder wrote it, which is the whole point of the feature.
    func testTheDictionaryMakesTheDecoderWriteANameItOtherwiseMishears() async throws {
        let audio = try fixture("whisper-prompt-name.wav")

        let withoutDictionary = try await transcribe(audio, terms: [])
        let entry = PersonalTerm(
            kind: .name, match: "nothing in this recording says this", replacement: wantedName
        )
        let withDictionary = try await transcribe(audio, terms: [entry])

        XCTAssertFalse(
            withoutDictionary.contains(wantedName),
            "the recognizer already knows \(wantedName); pick a name it does not for this fixture"
        )
        XCTAssertTrue(
            withDictionary.contains(wantedName),
            "the decoder was shown \(wantedName) and still did not write it: \(withDictionary)"
        )
        // The terms stage is not what changed it: nothing matches that entry.
        var settings = Settings()
        settings.safeCorrectionEnabled = true
        settings.personalTerms = [entry]
        XCTAssertEqual(
            TextPostProcessor.process(withoutDictionary, settings: settings).final,
            withoutDictionary,
            "the post-process stage cannot rescue this mishearing, which is why the prompt must"
        )
    }

    // MARK: - The budget is the model's own tokens

    /// The cap is measured with the tokenizer the decoder uses. A Chinese
    /// dictionary is the case that proves it matters: the composed prompt is
    /// well inside the budget counted in tokens and would have been counted as
    /// far fewer "characters", so a character cap would have handed whisper.cpp
    /// a prompt longer than it carries - which it cuts from the front, taking
    /// the user's own typed prompt with it.
    func testTheBudgetIsMeasuredInTheModelsOwnTokensNotCharacters() throws {
        let path = try modelPath()
        let context = try XCTUnwrap(
            MyWhisperContext.initFromFileNoState(path: path, params: WhisperContextParams()),
            "Failed to load \(path)"
        )
        let terms = (0 ..< 200).map {
            PersonalTerm(kind: .name, match: "x\($0)", replacement: "陳映樺\($0)")
        }
        let composed = try XCTUnwrap(
            WhisperInitialPrompt.compose(
                userPrompt: "平台團隊的週會筆記。",
                terms: terms,
                tokenCount: { context.tokenCount(text: $0) }
            )
        )

        let tokens = context.tokenCount(text: composed)
        XCTAssertLessThanOrEqual(tokens, WhisperInitialPrompt.tokenBudget)
        XCTAssertLessThanOrEqual(tokens, WhisperInitialPrompt.carriedPromptTokenLimit)
        XCTAssertGreaterThan(
            tokens, composed.count,
            "this dictionary is Han-heavy, so a character count under-reports it - which is the "
                + "reason the budget is measured with the model's own tokenizer"
        )
        XCTAssertTrue(composed.hasPrefix("平台團隊的週會筆記。 陳映樺0, 陳映樺1"))
    }
}
