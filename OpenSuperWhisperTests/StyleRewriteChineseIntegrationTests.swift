import XCTest
@testable import OpenSuperWhisper

/// The Chinese rewriting fix against the real on-device model rather than an
/// injected rewriter.
///
/// It exists because everything this fix is made of is a claim about how the
/// shipping model behaves, and no unit test can check a claim like that: the
/// unit tests pin that a Chinese transcript is *asked for* in Chinese, in the
/// transcript's own variant, and this is what re-checks that doing so still
/// produces a Chinese rewrite after an OS update changes the model underneath
/// it.
///
/// What it caught, with English instructions, on macOS 26.5: "Formal Business"
/// translated Mandarin dictation into English on every run and "Casual Chat" on
/// most, and the guard then discarded both - so a Chinese user saw no rewrite at
/// all. With the Chinese instructions, every style came back in Chinese.
///
/// Opt-in and skipped by default, the same way the engine integration tests are,
/// and for the same two reasons: it needs hardware the test machine may not have
/// (macOS 26 with Apple Intelligence downloaded), and it asks a language model
/// several questions, which takes seconds and is not deterministic. It is opted
/// into by creating the marker file, which is inside the gitignored fixtures
/// directory:
///
/// ```sh
/// mkdir -p OpenSuperWhisperTests/Fixtures/style-rewrite
/// touch OpenSuperWhisperTests/Fixtures/style-rewrite/run-on-device-model
/// ```
///
/// No environment variable: xcodebuild does not forward one to a hosted macOS
/// test bundle.
final class StyleRewriteChineseIntegrationTests: XCTestCase {

    private static let traditionalTranscript = "那個我們這個禮拜五要出貨嗯然後就是那個預算大概是 2500 塊你看這樣可以嗎"
    private static let simplifiedTranscript = "那个我们这个礼拜五要出货嗯然后就是那个预算大概是 2500 块你看这样可以吗"

    private func rewriter() throws -> StyleRewriting {
        let marker = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/style-rewrite/run-on-device-model")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: marker.path),
            "Create \(marker.path) to run the on-device rewriting tests - see this file's comment"
        )
        let availability = StyleRewriterFactory.availability()
        try XCTSkipUnless(availability.canRun, availability.explanation)
        return try XCTUnwrap(StyleRewriterFactory.makeRewriter())
    }

    private func rewrite(
        _ transcript: String, styleID: String, customPrompt: String = ""
    ) async throws -> StyledTranscript {
        try await StyleRewriteService.apply(
            to: .unchanged(transcript),
            configuration: StyleRewriteConfiguration.resolve(
                isEnabled: true, storedStyleID: styleID, customPrompt: customPrompt
            ),
            languageCode: "zh",
            availability: .available,
            rewriter: rewriter(),
            // The default budget is tuned for a user waiting to paste. A test
            // that fails because the machine was busy would say nothing about
            // the model's language, which is the only thing being asked here.
            budgetOverride: 60
        )
    }

    /// The reported bug, style by style: every one of them has to come back as a
    /// rewrite rather than as the untouched transcript.
    func testEveryStyleRewritesTraditionalChineseInTraditionalChinese() async throws {
        for style in StyleRewriteCatalog.styles where !style.isCustom {
            let result = try await rewrite(Self.traditionalTranscript, styleID: style.id)

            XCTAssertTrue(
                result.status.didRewrite,
                "\(style.id): \(result.status.explanation ?? "no rewrite") - \(result.final)"
            )
            let signal = ChineseScriptVariant.signal(in: result.final)
            XCTAssertGreaterThan(signal.traditional, 0, "\(style.id): \(result.final)")
            XCTAssertEqual(signal.simplified, 0, "\(style.id): \(result.final)")
        }
    }

    func testEveryStyleRewritesSimplifiedChineseInSimplifiedChinese() async throws {
        for style in StyleRewriteCatalog.styles where !style.isCustom {
            let result = try await rewrite(Self.simplifiedTranscript, styleID: style.id)

            XCTAssertTrue(
                result.status.didRewrite,
                "\(style.id): \(result.status.explanation ?? "no rewrite") - \(result.final)"
            )
            let signal = ChineseScriptVariant.signal(in: result.final)
            XCTAssertGreaterThan(signal.simplified, 0, "\(style.id): \(result.final)")
            XCTAssertEqual(signal.traditional, 0, "\(style.id): \(result.final)")
        }
    }

    /// The prompt a Chinese-dictating user is most likely to write: their own,
    /// in English, because that is the language of the pane they type it into.
    func testAnEnglishCustomPromptStillRewritesChineseInChinese() async throws {
        let result = try await rewrite(
            Self.traditionalTranscript,
            styleID: StyleRewriteStyle.customID,
            customPrompt: "Rewrite this as a short message to a colleague."
        )

        XCTAssertTrue(
            result.status.didRewrite, result.status.explanation ?? "no rewrite"
        )
        XCTAssertEqual(ChineseScriptVariant.signal(in: result.final).simplified, 0, result.final)
    }

    /// The other half of the same rule: an English dictation with the language
    /// left on Chinese must still be rewritten in English.
    ///
    /// Deliberately without a figure in it. The model writes "2500" back as
    /// "$2,500" often enough that the guard's currency rule decides this test
    /// instead of its language, which is not what is being asked here.
    func testEnglishDictationIsStillRewrittenInEnglish() async throws {
        let result = try await rewrite(
            "um so I think we should ship the thing on friday and tell the rest of the team "
                + "before the weekend if that works for everyone",
            styleID: "formal"
        )

        XCTAssertTrue(result.status.didRewrite, result.status.explanation ?? "no rewrite")
        XCTAssertNil(ChineseScriptVariant.detected(in: result.final), result.final)
    }
}
