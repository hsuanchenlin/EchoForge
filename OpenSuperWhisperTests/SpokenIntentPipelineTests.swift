import XCTest
@testable import OpenSuperWhisper

/// Where the router is actually consulted, and where it deliberately is not.
///
/// The model-backed stages below this one skip themselves under
/// `OpenSuperWhisperApp.isRunningTests`, the same rule the engine loader
/// follows, so what these assert is the routing decision - which is the part
/// that decides whether a user's words are pasted at all.
final class SpokenIntentPipelineTests: IsolatedPreferencesTestCase {

    private func processed(_ text: String) -> ProcessedText {
        ProcessedText(raw: text, final: text)
    }

    // MARK: - The two conditions

    /// Off by default, like every other setting that changes what happens to
    /// the user's words.
    func testRoutingIsOffUntilTheUserSwitchesItOn() {
        XCTAssertFalse(AppPreferences.shared.spokenIntentsEnabled)
        XCTAssertFalse(Settings(routesSpokenIntents: true).routesSpokenIntents)
    }

    /// Both conditions have to hold. The preference alone is not enough,
    /// because only live dictation is a path where a spoken command means
    /// anything - a dropped file, a queued recording and the Ask panel's own
    /// follow-up all take the plain path.
    func testOnlyACallerThatAsksForRoutingGetsIt() {
        AppPreferences.shared.spokenIntentsEnabled = true

        XCTAssertTrue(Settings(routesSpokenIntents: true).routesSpokenIntents)
        XCTAssertFalse(Settings().routesSpokenIntents)
        XCTAssertFalse(Settings(routesSpokenIntents: false).routesSpokenIntents)
    }

    // MARK: - What the pipeline does with each reading

    func testAQuestionIsStrippedAndWithheldFromInsertion() async {
        AppPreferences.shared.spokenIntentsEnabled = true

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Ask: what is the capital of France?"),
            settings: Settings(routesSpokenIntents: true)
        )

        XCTAssertEqual(styled.intent, .ask(query: "what is the capital of France?"))
        XCTAssertFalse(styled.intent.insertsText)
        XCTAssertEqual(styled.final, "what is the capital of France?")
        // History still keeps what was said, spoken command and all.
        XCTAssertEqual(styled.raw, "Ask: what is the capital of France?")
    }

    func testATranslationCommandNamesItsTargetAndStillInserts() async {
        AppPreferences.shared.spokenIntentsEnabled = true

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Translate to Spanish: the team meets at three."),
            settings: Settings(routesSpokenIntents: true)
        )

        guard case .translated(let target) = styled.intent else {
            return XCTFail("expected a translation, got \(styled.intent)")
        }
        XCTAssertEqual(target.languageCode, "es")
        XCTAssertTrue(styled.intent.insertsText)
        // The model does not run under tests, so what is left is the body - and
        // the body, not the command, is what a failed translation must leave.
        XCTAssertEqual(styled.final, "the team meets at three.")
    }

    func testOrdinaryDictationIsUntouchedAndStillInserts() async {
        AppPreferences.shared.spokenIntentsEnabled = true

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Ship the release on Thursday."),
            settings: Settings(routesSpokenIntents: true)
        )

        XCTAssertEqual(styled.intent, .dictation)
        XCTAssertTrue(styled.intent.insertsText)
        XCTAssertEqual(styled.final, "Ship the release on Thursday.")
    }

    /// The failure this guards against is a queued file or a follow-up
    /// recording that happens to begin "Ask:" opening a panel nobody was
    /// looking at.
    func testACommandOnAnUnroutedPathIsPlainDictation() async {
        AppPreferences.shared.spokenIntentsEnabled = true

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Ask: what is the capital of France?"),
            settings: Settings()
        )

        XCTAssertEqual(styled.intent, .dictation)
        XCTAssertEqual(styled.final, "Ask: what is the capital of France?")
    }

    func testACommandIsPlainDictationWhileTheFeatureIsOff() async {
        let styled = await SpokenIntentPipeline.apply(
            to: processed("Ask: what is the capital of France?"),
            settings: Settings(routesSpokenIntents: true)
        )

        XCTAssertEqual(styled.intent, .dictation)
        XCTAssertEqual(styled.final, "Ask: what is the capital of France?")
    }

    // MARK: - Telling the capsule

    @MainActor
    func testTheCapsuleIsToldWhatTheRoutingDecided() async {
        AppPreferences.shared.spokenIntentsEnabled = true
        SpokenIntentActivity.shared.clear()
        XCTAssertNil(SpokenIntentActivity.shared.outcome)

        _ = await SpokenIntentPipeline.apply(
            to: processed("Ask: why"), settings: Settings(routesSpokenIntents: true)
        )
        XCTAssertEqual(SpokenIntentActivity.shared.outcome, .ask(query: "why"))

        _ = await SpokenIntentPipeline.apply(
            to: processed("hello there"), settings: Settings(routesSpokenIntents: true)
        )
        XCTAssertEqual(SpokenIntentActivity.shared.outcome, .dictation)

        SpokenIntentActivity.shared.clear()
    }
}
