import XCTest
@testable import OpenSuperWhisper

/// Pins the promise the rewriting stage makes: it either improves a transcript
/// or leaves it exactly as it was.
///
/// Every way it can go wrong is tested here against an injected rewriter rather
/// than a real model, because the failures are the point and a model cannot be
/// asked to produce them on demand - and because the Mac running these tests
/// may have no on-device model at all.
final class StyleRewriteServiceTests: XCTestCase {

    // MARK: - Test doubles

    private struct FixedRewriter: StyleRewriting {
        let output: String
        func rewrite(_ request: StyleRewriteRequest) async throws -> String { output }
    }

    private struct FailingRewriter: StyleRewriting {
        struct Failure: LocalizedError {
            var errorDescription: String? { "the model ran out of context" }
        }
        func rewrite(_ request: StyleRewriteRequest) async throws -> String { throw Failure() }
    }

    private struct SlowRewriter: StyleRewriting {
        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }
    }

    /// Blocks the thread for real time instead of suspending on `Task.sleep`,
    /// the way a closed-source model call might. `SlowRewriter` above cannot
    /// stand in for this: `Task.sleep` reacts to cancellation almost
    /// instantly, so it would pass even a timeout that only pretends to be
    /// enforced. This is what `testKeepsTheTranscriptWhenTheRewriteIgnoresCancellation`
    /// needs to catch a race that waits for the loser to finish.
    private struct NonCancellingSlowRewriter: StyleRewriting {
        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            Thread.sleep(forTimeInterval: 1.0)
            return "too late"
        }
    }

    /// Records what it was asked, so the prompt wiring can be asserted.
    private actor RecordingRewriter: StyleRewriting {
        private(set) var request: StyleRewriteRequest?

        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            self.request = request
            return request.text
        }
    }

    // MARK: - Helpers

    private func configuration(
        enabled: Bool = true, styleID: String = "polish", customPrompt: String = ""
    ) -> StyleRewriteConfiguration {
        StyleRewriteConfiguration.resolve(
            isEnabled: enabled, storedStyleID: styleID, customPrompt: customPrompt
        )
    }

    private func apply(
        _ processed: ProcessedText,
        configuration: StyleRewriteConfiguration,
        languageCode: String = "en",
        availability: StyleRewriteAvailability = .available,
        rewriter: StyleRewriting?,
        budgetOverride: TimeInterval? = nil
    ) async -> StyledTranscript {
        await StyleRewriteService.apply(
            to: processed,
            configuration: configuration,
            languageCode: languageCode,
            availability: availability,
            rewriter: rewriter,
            budgetOverride: budgetOverride
        )
    }

    // MARK: - The stage does not run

    func testDoesNothingWhenRewritingIsDisabled() async {
        let processed = ProcessedText(raw: "raw text", final: "corrected text")

        let result = await apply(
            processed,
            configuration: configuration(enabled: false),
            rewriter: FixedRewriter(output: "rewritten text")
        )

        XCTAssertEqual(result.final, "corrected text")
        XCTAssertEqual(result.status, .notRequested)
    }

    /// The custom style with nothing written in it is not a rewrite waiting to
    /// happen; it is a transcript that must be left alone.
    func testDoesNothingWhenTheCustomStyleHasNoPrompt() async {
        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(styleID: StyleRewriteStyle.customID, customPrompt: "   "),
            rewriter: FixedRewriter(output: "We ship on Friday.")
        )

        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .notRequested)
    }

    func testDoesNothingWhenTheMacCannotRewrite() async {
        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(),
            availability: .appleIntelligenceOff,
            rewriter: nil
        )

        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .unavailable(.appleIntelligenceOff))
    }

    /// Availability and the rewriter are resolved separately, so the stage must
    /// also survive them disagreeing.
    func testDoesNothingWhenThereIsNoRewriterDespiteAvailability() async {
        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(),
            availability: .available,
            rewriter: nil
        )

        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .unavailable(.modelNotReady))
    }

    func testDoesNothingWhenThereIsNoText() async {
        let result = await apply(
            .unchanged("   "),
            configuration: configuration(),
            rewriter: FixedRewriter(output: "something")
        )

        XCTAssertEqual(result.final, "   ")
        XCTAssertEqual(result.status, .nothingToRewrite)
    }

    func testDoesNotOfferAnOverlongTranscriptToTheModel() async {
        let long = String(repeating: "a", count: StyleRewriteService.maximumTranscriptCharacters + 1)

        let result = await apply(
            .unchanged(long),
            configuration: configuration(),
            rewriter: FixedRewriter(output: "short")
        )

        XCTAssertEqual(result.final, long)
        XCTAssertEqual(result.status, .transcriptTooLong)
    }

    // MARK: - The stage runs

    func testUsesARewriteThatPassesTheGuard() async {
        let processed = ProcessedText(raw: "um we ship on friday", final: "um we ship on friday")

        let result = await apply(
            processed,
            configuration: configuration(),
            rewriter: FixedRewriter(output: "We ship on Friday.")
        )

        XCTAssertEqual(result.final, "We ship on Friday.")
        XCTAssertEqual(result.transcript, "um we ship on friday")
        XCTAssertEqual(result.raw, "um we ship on friday")
        XCTAssertEqual(result.status, .applied(styleID: "polish"))
    }

    func testKeepsTheTranscriptWhenTheGuardRejectsTheRewrite() async {
        let result = await apply(
            .unchanged("the budget is 2500 for the quarter"),
            configuration: configuration(),
            rewriter: FixedRewriter(output: "The budget is 3500 for the quarter.")
        )

        XCTAssertEqual(result.final, "the budget is 2500 for the quarter")
        XCTAssertEqual(result.status, .rejected(.numbersChanged))
    }

    func testKeepsTheTranscriptWhenTheModelFails() async {
        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(),
            rewriter: FailingRewriter()
        )

        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .failed("the model ran out of context"))
    }

    func testKeepsTheTranscriptWhenTheRewriteMissesItsDeadline() async {
        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(),
            rewriter: SlowRewriter(),
            budgetOverride: 0.2
        )

        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .timedOut)
    }

    /// The deadline has to hold even against a rewriter that never checks
    /// `Task.isCancelled` - a race that returns only once the loser finishes
    /// would pass `testKeepsTheTranscriptWhenTheRewriteMissesItsDeadline`
    /// above and still block dictation for as long as the model actually
    /// took.
    func testKeepsTheTranscriptWhenTheRewriteIgnoresCancellation() async {
        let started = Date()

        let result = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(),
            rewriter: NonCancellingSlowRewriter(),
            budgetOverride: 0.2
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertEqual(result.final, "we ship on friday")
        XCTAssertEqual(result.status, .timedOut)
    }

    /// The dictionary's corrections outrank the rewrite, on every path.
    func testKeepsTheTranscriptWhenTheRewriteLosesADictionaryTerm() async {
        let processed = ProcessedText(
            raw: "we deploy with k8s",
            final: "we deploy with Kubernetes",
            mustSurviveTokens: ["Kubernetes"]
        )

        let result = await apply(
            processed,
            configuration: configuration(),
            rewriter: FixedRewriter(output: "We deploy with containers.")
        )

        XCTAssertEqual(result.final, "we deploy with Kubernetes")
        XCTAssertEqual(result.status, .rejected(.termLost("Kubernetes")))
    }

    // MARK: - What the rewriter is asked

    func testSendsTheSelectedPresetsInstruction() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(styleID: "formal"),
            rewriter: rewriter
        )

        let expected = StyleRewriteCatalog.style(id: "formal")?.instructions.english
        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.instruction, expected)
    }

    func testSendsTheUsersOwnPromptForTheCustomStyle() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            .unchanged("we ship on friday"),
            configuration: configuration(
                styleID: StyleRewriteStyle.customID,
                customPrompt: "  Rewrite this as a haiku.  "
            ),
            rewriter: rewriter
        )

        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.instruction, "Rewrite this as a haiku.")
    }

    // MARK: - Chinese dictation

    /// The reported bug, at the level the user meets it: Chinese dictation, a
    /// style selected, and no rewrite ever arrives. What the model returned was
    /// an English translation, because the style instruction it was given was
    /// written in English.
    func testEveryStyleAsksForAChineseRewriteInChinese() async {
        let transcript = "那個我們這個禮拜五要出貨嗯預算大概是 2500 塊"

        for style in StyleRewriteCatalog.styles where !style.isCustom {
            let rewriter = RecordingRewriter()

            _ = await apply(
                .unchanged(transcript),
                configuration: configuration(styleID: style.id),
                languageCode: "zh",
                rewriter: rewriter
            )

            let recorded = await rewriter.request
            XCTAssertEqual(recorded?.language, .chinese(.traditional), style.id)
            XCTAssertEqual(recorded?.instruction, style.instructions.traditionalChinese, style.id)
        }
    }

    func testAsksInSimplifiedChineseForSimplifiedDictation() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            .unchanged("那个我们这个礼拜五要出货嗯预算大概是 2500 块"),
            configuration: configuration(styleID: "formal"),
            languageCode: "zh",
            rewriter: rewriter
        )

        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.language, .chinese(.simplified))
        XCTAssertEqual(
            recorded?.instruction, StyleRewriteCatalog.style(id: "formal")?.instructions.simplifiedChinese
        )
    }

    /// A custom prompt is typed in English by users who dictate in Chinese, so
    /// it is the one instruction the app cannot write for them - it wraps it
    /// instead.
    func testWrapsAnEnglishCustomPromptForChineseDictation() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            .unchanged("那個我們這個禮拜五要出貨嗯預算大概是 2500 塊"),
            configuration: configuration(
                styleID: StyleRewriteStyle.customID,
                customPrompt: "Rewrite this as a short message to a colleague."
            ),
            languageCode: "zh",
            rewriter: rewriter
        )

        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.language, .chinese(.traditional))
        XCTAssertTrue(
            recorded?.instruction.contains("Rewrite this as a short message to a colleague.") == true
        )
        XCTAssertTrue(recorded?.instruction.contains("必須是中文") == true)
    }

    /// A user who leaves the language on Chinese and dictates a sentence of
    /// English gets the English instruction, because the transcript is what
    /// decides.
    func testAsksInEnglishForEnglishDictationEvenWhenTheLanguageIsChinese() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            .unchanged("um we ship on friday and the budget is the same"),
            configuration: configuration(styleID: "formal"),
            languageCode: "zh",
            rewriter: rewriter
        )

        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.language, .other)
        XCTAssertEqual(
            recorded?.instruction, StyleRewriteCatalog.style(id: "formal")?.instructions.english
        )
    }

    func testUsesAChineseRewriteThatPassesTheGuard() async {
        let result = await apply(
            .unchanged("那個我們這個禮拜五要出貨嗯預算大概是 2500 塊"),
            configuration: configuration(),
            languageCode: "zh",
            rewriter: FixedRewriter(output: "我們這個禮拜五要出貨，預算大概是 2500 塊。")
        )

        XCTAssertEqual(result.final, "我們這個禮拜五要出貨，預算大概是 2500 塊。")
        XCTAssertEqual(result.status, .applied(styleID: "polish"))
    }

    /// What the user actually saw before the fix: the rewrite came back in
    /// English and was thrown away, so dictation behaved as if rewriting were
    /// switched off.
    func testKeepsTheTranscriptWhenAChineseRewriteComesBackInEnglish() async {
        let result = await apply(
            .unchanged("那個我們這個禮拜五要出貨嗯預算大概是 2500 塊"),
            configuration: configuration(styleID: "formal"),
            languageCode: "zh",
            rewriter: FixedRewriter(
                output: "We are scheduled to ship on Friday. The budget is approximately 2500."
            )
        )

        XCTAssertEqual(result.final, "那個我們這個禮拜五要出貨嗯預算大概是 2500 塊")
        XCTAssertEqual(result.status, .rejected(.scriptChanged))
    }

    func testKeepsTheTranscriptWhenARewriteConvertsTheUsersScript() async {
        let result = await apply(
            .unchanged("那个我们这个礼拜五要出货嗯预算大概是 2500 块"),
            configuration: configuration(),
            languageCode: "zh",
            rewriter: FixedRewriter(output: "我們這個禮拜五要出貨，預算大概是 2500 塊。")
        )

        XCTAssertEqual(result.final, "那个我们这个礼拜五要出货嗯预算大概是 2500 块")
        XCTAssertEqual(result.status, .rejected(.chineseVariantChanged))
    }

    /// The model is given the deterministic pipeline's output, not the engine's
    /// raw text - otherwise it would undo the dictionary's corrections.
    func testSendsTheCorrectedTranscriptRatherThanTheRawOne() async {
        let rewriter = RecordingRewriter()

        _ = await apply(
            ProcessedText(raw: "we deploy with k8s", final: "we deploy with Kubernetes"),
            configuration: configuration(),
            rewriter: rewriter
        )

        let recorded = await rewriter.request
        XCTAssertEqual(recorded?.text, "we deploy with Kubernetes")
    }

    // MARK: - What history keeps

    func testKeepsTheEnginesOwnWordsWhenTheTextWasRewritten() async {
        let result = await apply(
            ProcessedText(raw: "um we ship on friday", final: "um we ship on friday"),
            configuration: configuration(),
            rewriter: FixedRewriter(output: "We ship on Friday.")
        )

        XCTAssertEqual(result.originalWorthKeeping, "um we ship on friday")
    }

    func testKeepsNoSecondCopyWhenNothingChangedTheText() async {
        let result = await apply(
            .unchanged("We ship on Friday."),
            configuration: configuration(enabled: false),
            rewriter: nil
        )

        XCTAssertNil(result.originalWorthKeeping)
    }

    /// The deterministic stages alone are enough to make the original worth
    /// keeping: rewriting is not the only thing that changes the text.
    func testKeepsTheEnginesOwnWordsWhenOnlyTheDictionaryChangedThem() async {
        let result = await apply(
            ProcessedText(raw: "we deploy with k8s", final: "we deploy with Kubernetes"),
            configuration: configuration(enabled: false),
            rewriter: nil
        )

        XCTAssertEqual(result.originalWorthKeeping, "we deploy with k8s")
    }

    // MARK: - Budget

    func testBudgetGrowsWithLengthAndIsCapped() {
        let short = StyleRewriteBudget.seconds(forCharacterCount: 20)
        let long = StyleRewriteBudget.seconds(forCharacterCount: 2000)

        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(long, StyleRewriteBudget.ceiling)
        XCTAssertEqual(
            StyleRewriteBudget.seconds(forCharacterCount: 100_000), StyleRewriteBudget.ceiling
        )
    }
}
