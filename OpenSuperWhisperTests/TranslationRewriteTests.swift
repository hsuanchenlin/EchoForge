import XCTest
@testable import OpenSuperWhisper

/// The spoken `Translate to …` command: the one shape that is allowed to change
/// the language the user's words are written in, and everything the guard still
/// refuses it.
final class TranslationRewriteTests: XCTestCase {

    private let spanish = SpokenTranslationTarget(languageCode: "es")

    private func processed(_ text: String, mustSurvive: [String] = []) -> ProcessedText {
        ProcessedText(raw: text, final: text, mustSurviveTokens: mustSurvive)
    }

    // MARK: - The one rule that is relaxed

    /// Every other shape rejects this, and has to: a rewrite coming back in
    /// another language is the failure `StyleRewriteGuard` was written for.
    func testOnlyTheTranslatingShapeMayChangeLanguage() {
        for shape in [StyleRewriteShape.preserving, .condensing, .restructuring] {
            XCTAssertFalse(shape.mayChangeLanguage, "\(shape)")
            XCTAssertEqual(
                StyleRewriteGuard.check(
                    candidate: "The meeting is at three.",
                    transcript: "會議是三點開始。",
                    mustSurvive: [],
                    shape: shape
                ).rejection,
                .scriptChanged,
                "\(shape)"
            )
        }

        XCTAssertTrue(StyleRewriteShape.translating.mayChangeLanguage)
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "The meeting is at three.",
                transcript: "會議是三點開始。",
                mustSurvive: [],
                shape: .translating
            ).acceptedText,
            "The meeting is at three."
        )
    }

    /// The Chinese variant check goes with it, and for the same reason: a
    /// translation into Simplified Chinese is Simplified Chinese on purpose.
    func testTranslatingMayCrossTheChineseVariants() {
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "会议是三点开始。",
                transcript: "會議是三點開始。",
                mustSurvive: [],
                shape: .translating
            ).acceptedText,
            "会议是三点开始。"
        )
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "会议是三点开始。",
                transcript: "會議是三點開始。",
                mustSurvive: [],
                shape: .preserving
            ).rejection,
            .chineseVariantChanged
        )
    }

    // MARK: - Everything the guard still refuses

    func testATranslationMayNotInventOrChangeANumber() {
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "The meeting is at four.",
                transcript: "會議是 3 點開始。",
                mustSurvive: [],
                shape: .translating
            ).rejection,
            .numbersChanged
        )
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "The meeting is at 3.",
                transcript: "會議是 3 點開始。",
                mustSurvive: [],
                shape: .translating
            ).acceptedText,
            "The meeting is at 3."
        )
    }

    func testATranslationMayNotDropACurrencySymbol() {
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "It costs 40.",
                transcript: "要 $40。",
                mustSurvive: [],
                shape: .translating
            ).rejection,
            .symbolsLost
        )
    }

    func testATranslationMayNotAnswerTheUserInstead() {
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: "I'm sorry, I cannot translate that.",
                transcript: "會議是三點開始，請準時到。",
                mustSurvive: [],
                shape: .translating
            ).rejection,
            .modelAddressedTheUser
        )
    }

    /// Wide, because the same sentence is several times as many characters in
    /// English as in Chinese - but not unbounded, because a model that starts
    /// explaining itself still has to be caught.
    func testTheLengthBoundIsWideEnoughForRealTranslationAndNoWider() {
        let transcript = "會議三點開始。"
        XCTAssertNotNil(
            StyleRewriteGuard.check(
                candidate: "The meeting starts at three o'clock in the afternoon.",
                transcript: transcript,
                mustSurvive: [],
                shape: .translating
            ).acceptedText
        )
        XCTAssertEqual(
            StyleRewriteGuard.check(
                candidate: String(repeating: "The meeting starts at three. ", count: 20),
                transcript: transcript,
                mustSurvive: [],
                shape: .translating
            ).rejection,
            .tooLong
        )
    }

    // MARK: - Which language the model is asked in

    /// The target decides, not the transcript - the mirror image of the
    /// rewriting stage's rule, and it rests on the same measured behaviour: the
    /// model answers in the language it was addressed in.
    func testTheTargetDecidesWhichLanguageTheModelIsAskedIn() {
        XCTAssertEqual(TranslationPrompt.language(for: spanish), .other)
        XCTAssertEqual(
            TranslationPrompt.language(
                for: SpokenTranslationTarget(languageCode: "zh", chineseVariant: .simplified)
            ),
            .chinese(.simplified)
        )
        XCTAssertEqual(
            TranslationPrompt.language(
                for: SpokenTranslationTarget(languageCode: "zh", chineseVariant: .traditional)
            ),
            .chinese(.traditional)
        )
    }

    /// Whatever language it is written in, the instruction has to name the
    /// target - it is the only place the model is told where the text is going.
    func testEveryInstructionNamesItsTarget() {
        for target in [
            spanish,
            SpokenTranslationTarget(languageCode: "en"),
            SpokenTranslationTarget(languageCode: "zh", chineseVariant: .traditional),
            SpokenTranslationTarget(languageCode: "zh", chineseVariant: .simplified),
        ] {
            let language = TranslationPrompt.language(for: target)
            XCTAssertTrue(
                TranslationPrompt.instruction(for: target, language: language)
                    .contains(target.displayName),
                target.displayName
            )
            XCTAssertTrue(
                TranslationPrompt.instructions(for: target, language: language)
                    .contains(target.displayName),
                target.displayName
            )
        }
    }

    /// The rewriting stage's session rules say "never translate it", so a
    /// translation must not inherit them.
    func testATranslationRequestCarriesItsOwnSessionRules() async {
        let recorder = RecordingRewriter(output: "El equipo se reúne a las tres.")
        _ = await TranslationRewrite.apply(
            to: processed("El equipo se reúne a las tres."),
            body: "The team meets at three.",
            target: spanish,
            availability: .available,
            rewriter: recorder
        )

        guard let request = recorder.request else {
            return XCTFail("the rewriter was never asked")
        }
        XCTAssertEqual(
            request.sessionInstructions,
            TranslationPrompt.instructions(for: spanish, language: .other)
        )
        XCTAssertNotEqual(
            request.sessionInstructions,
            StyleRewritePrompt.instructions(language: .other, languageCode: "es")
        )
        XCTAssertTrue(request.prompt.contains(StyleRewritePrompt.openingDelimiter))
        XCTAssertTrue(request.prompt.contains("The team meets at three."))
    }

    // MARK: - What the user gets

    func testAnAcceptedTranslationReplacesTheBodyAndNamesTheTarget() async {
        let styled = await TranslationRewrite.apply(
            to: processed("Translate to Spanish: the team meets at three."),
            body: "the team meets at three.",
            target: spanish,
            availability: .available,
            rewriter: FixedRewriter("el equipo se reúne a las tres.")
        )

        XCTAssertEqual(styled.final, "el equipo se reúne a las tres.")
        XCTAssertEqual(styled.status, .applied(styleID: TranslationRewrite.styleID))
        XCTAssertEqual(styled.intent, .translated(spanish))
        // History keeps what was actually said, command and all.
        XCTAssertEqual(styled.raw, "Translate to Spanish: the team meets at three.")
        XCTAssertEqual(styled.originalWorthKeeping, styled.raw)
    }

    /// The stage's contract: it can translate the text or leave it alone, and
    /// "alone" means the body - never the spoken command, which nobody wants
    /// pasted into their document.
    func testEveryFailureLeavesTheUserWithTheBodyAndNotTheCommand() async {
        let cases: [(String, StyleRewriteAvailability, StyleRewriting?)] = [
            ("no model on this Mac", .deviceNotEligible, FixedRewriter("unused")),
            ("model vanished between checks", .available, nil),
        ]
        for (name, availability, rewriter) in cases {
            let styled = await TranslationRewrite.apply(
                to: processed("Translate to Spanish: the team meets at three."),
                body: "the team meets at three.",
                target: spanish,
                availability: availability,
                rewriter: rewriter
            )
            XCTAssertEqual(styled.final, "the team meets at three.", name)
            XCTAssertFalse(styled.status.didRewrite, name)
            XCTAssertEqual(styled.intent, .translated(spanish), name)
        }
    }

    /// A failed translation explains itself as translation: the user spoke
    /// "Translate to …", and being told about rewriting - the other feature on
    /// the same model - reads as the wrong feature failing. The rewriting
    /// wording itself must not move; `StyleRewriteServiceTests` and
    /// `StyleRewriteCatalogTests` pin it.
    func testAnUnavailableTranslationIsExplainedAsTranslationNotRewriting() async {
        let styled = await TranslationRewrite.apply(
            to: processed("Translate to Spanish: the team meets at three."),
            body: "the team meets at three.",
            target: spanish,
            availability: .unsupportedSystem,
            rewriter: nil
        )

        XCTAssertEqual(
            styled.statusExplanation,
            StyleRewriteAvailability.unsupportedSystem.explanation(for: .translation)
        )
        XCTAssertEqual(styled.statusExplanation?.contains("Translation"), true)
        XCTAssertEqual(styled.statusExplanation?.contains("Rewriting"), false)
        XCTAssertEqual(
            StyleRewriteStatus.unavailable(.unsupportedSystem).explanation,
            StyleRewriteAvailability.unsupportedSystem.explanation(for: .rewriting)
        )
    }

    func testARefusedTranslationKeepsTheBodyAndSaysWhy() async {
        let styled = await TranslationRewrite.apply(
            to: processed("the team meets at 3."),
            body: "the team meets at 3.",
            target: spanish,
            availability: .available,
            rewriter: FixedRewriter("el equipo se reúne a las 4.")
        )

        XCTAssertEqual(styled.final, "the team meets at 3.")
        XCTAssertEqual(styled.status, .rejected(.numbersChanged))
    }

    /// The budget is a hard ceiling even against a model that never returns.
    func testTheDeadlineHolds() async {
        let started = Date()
        let styled = await TranslationRewrite.apply(
            to: processed("the team meets at three."),
            body: "the team meets at three.",
            target: spanish,
            availability: .available,
            rewriter: NeverReturnsRewriter(),
            budgetOverride: 0.1
        )

        XCTAssertEqual(styled.status, .timedOut)
        XCTAssertEqual(styled.final, "the team meets at three.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testANothingToTranslateBodyIsNotSentToTheModel() async {
        let recorder = RecordingRewriter(output: "unused")
        let styled = await TranslationRewrite.apply(
            to: processed("Translate to Spanish:"),
            body: "   ",
            target: spanish,
            availability: .available,
            rewriter: recorder
        )

        XCTAssertEqual(styled.status, .nothingToRewrite)
        XCTAssertNil(recorder.request)
    }

    // MARK: - Which Chinese comes back

    /// The model is instructed in the target's own variant and still drifts,
    /// which is the same reason `ChineseScriptNormalizer` exists one stage
    /// earlier. A translation into Chinese is written in the Chinese that was
    /// asked for, deterministically.
    func testAChineseTranslationComesBackInTheVariantThatWasAskedFor() async {
        let simplified = await TranslationRewrite.apply(
            to: processed("Translate to Simplified Chinese: the team meets at three."),
            body: "the team meets at three.",
            target: SpokenTranslationTarget(languageCode: "zh", chineseVariant: .simplified),
            availability: .available,
            // A model that answered in the wrong variant, which is the observed
            // failure rather than a hypothetical one.
            rewriter: FixedRewriter("團隊三點開會。")
        )
        XCTAssertEqual(simplified.final, "团队三点开会。")

        let traditional = await TranslationRewrite.apply(
            to: processed("Translate to Traditional Chinese: the team meets at three."),
            body: "the team meets at three.",
            target: SpokenTranslationTarget(languageCode: "zh", chineseVariant: .traditional),
            availability: .available,
            rewriter: FixedRewriter("团队三点开会。")
        )
        XCTAssertEqual(traditional.final, "團隊三點開會。")
    }

    /// A translation into Cantonese is written in Traditional, the same as the
    /// instruction it was asked with.
    func testACantoneseTranslationComesBackTraditional() async {
        let styled = await TranslationRewrite.apply(
            to: processed("Translate to Cantonese: the team meets at three."),
            body: "the team meets at three.",
            target: SpokenTranslationTarget(languageCode: "yue"),
            availability: .available,
            rewriter: FixedRewriter("团队三点开会。")
        )
        XCTAssertEqual(styled.final, "團隊三點開會。")
    }

    /// Only Chinese. Every other target is written exactly as the model wrote
    /// it - there is no script to normalize, and touching it would be this
    /// stage editing a translation it cannot read.
    func testATranslationIntoAnotherLanguageIsNotTouched() async {
        let styled = await TranslationRewrite.apply(
            to: processed("Translate to Spanish: the team meets at three."),
            body: "the team meets at three.",
            target: spanish,
            availability: .available,
            rewriter: FixedRewriter("el equipo se reúne a las tres.")
        )
        XCTAssertEqual(styled.final, "el equipo se reúne a las tres.")
    }

    /// A failed translation is the body the user actually said, and the
    /// conversion runs only on what the guard accepted - so nothing on the
    /// failure path is rewritten either.
    func testARefusedChineseTranslationLeavesTheBodyExactlyAsItWas() async {
        let styled = await TranslationRewrite.apply(
            to: processed("翻譯成簡體中文：團隊 3 點開會。"),
            body: "團隊 3 點開會。",
            target: SpokenTranslationTarget(languageCode: "zh", chineseVariant: .simplified),
            availability: .available,
            // Changes a number, so the guard refuses it.
            rewriter: FixedRewriter("团队 4 点开会。")
        )

        XCTAssertEqual(styled.status, .rejected(.numbersChanged))
        XCTAssertEqual(styled.final, "團隊 3 點開會。")
    }

    // MARK: - Stub rewriters

    private struct FixedRewriter: StyleRewriting {
        let output: String
        init(_ output: String) { self.output = output }
        func rewrite(_ request: StyleRewriteRequest) async throws -> String { output }
    }

    private final class RecordingRewriter: StyleRewriting, @unchecked Sendable {
        private let lock = NSLock()
        private let output: String
        private var recorded: StyleRewriteRequest?

        init(output: String) { self.output = output }

        var request: StyleRewriteRequest? {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            lock.lock()
            recorded = request
            lock.unlock()
            return output
        }
    }

    private struct NeverReturnsRewriter: StyleRewriting {
        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return "far too late"
        }
    }
}
