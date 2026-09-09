import XCTest

@testable import OpenSuperWhisper

/// Where the correction stage sits in the pipeline, and the two gates in front
/// of it.
///
/// The reducer's own behaviour is `SpokenCorrectorTests`. This file is about
/// everything around it: which callers reach it, what the transcript stage
/// hands it, and what it hands back.
@MainActor
final class SpokenCorrectionPipelineTests: IsolatedPreferencesTestCase {

    private func settings(
        purpose: DictationPurpose = .dictation,
        correcting: Bool,
        enabled: Bool,
        fillers: Bool = false
    ) -> Settings {
        let prefs = AppPreferences.shared
        prefs.spokenCorrectionsEnabled = enabled
        prefs.fillerWordRemovalEnabled = fillers
        prefs.whisperLanguage = "en"
        prefs.safeCorrectionEnabled = true
        return Settings(purpose: purpose, correctsSpokenEdits: correcting)
    }

    // MARK: - The two gates

    /// The caller-side gate. Everything that is not live dictation - a dropped
    /// file, a queued recording, a regenerate from history, the Ask panel's own
    /// follow-up - takes the plain path, so a recording of somebody saying
    /// "scratch that" is transcribed rather than edited.
    func testACallerThatDidNotAskForCorrectionsNeverGetsThem() {
        let transcript = "We ship Friday, scratch that, Monday."
        let settings = settings(correcting: false, enabled: true)

        XCTAssertFalse(settings.spokenCorrections.isEnabled)
        XCTAssertEqual(TextPostProcessor.process(transcript, settings: settings, terms: []).final, transcript)
    }

    /// The user-side gate, off by default.
    func testTheStageIsOffUntilTheUserSwitchesItOn() {
        XCTAssertFalse(AppPreferences.shared.spokenCorrectionsEnabled)
        XCTAssertFalse(AppPreferences.shared.fillerWordRemovalEnabled)

        let transcript = "We ship Friday, scratch that, Monday."
        let settings = settings(correcting: true, enabled: false)
        XCTAssertEqual(TextPostProcessor.process(transcript, settings: settings, terms: []).final, transcript)
    }

    func testLiveDictationWithTheSettingOnIsCorrected() {
        let settings = settings(correcting: true, enabled: true)
        XCTAssertEqual(
            TextPostProcessor.process(
                "We ship Friday, scratch that, Monday.", settings: settings, terms: []
            ).final,
            "Monday.")
    }

    /// A ⌥E instruction is the instruction. "Replace Friday with Monday" spoken
    /// into voice edit has to reach `SelectionEditRewrite` intact, and a command
    /// capture's words are a channel name.
    func testAPurposeThatIsNotDictationIsNeverCorrected() {
        for purpose in [DictationPurpose.selectionEdit, .youTubeCommand] {
            let settings = settings(purpose: purpose, correcting: true, enabled: true)
            XCTAssertFalse(
                settings.spokenCorrections.isEnabled, "\(purpose) reached the correction stage")
            XCTAssertEqual(
                TextPostProcessor.process(
                    "replace Friday with Monday", settings: settings, terms: []
                ).final,
                "replace Friday with Monday")
        }
    }

    func testFillerPruningRidesOnTheMasterToggle() {
        XCTAssertFalse(
            settings(correcting: true, enabled: false, fillers: true)
                .spokenCorrections.removesFillerWords)
        XCTAssertTrue(
            settings(correcting: true, enabled: true, fillers: true)
                .spokenCorrections.removesFillerWords)
    }

    // MARK: - What the transcript stage keeps

    /// The uncorrected transcript is never the thing that gets lost: `raw` is
    /// what the engine returned, which is what `Recording.rawTranscription`
    /// stores and what History's "Show original" and Compare read.
    func testTheEnginesOwnWordsSurviveTheCorrection() {
        let transcript = "We ship Friday, scratch that, Monday."
        let processed = TextPostProcessor.process(
            transcript, settings: settings(correcting: true, enabled: true), terms: [])

        XCTAssertEqual(processed.raw, transcript)
        XCTAssertEqual(processed.final, "Monday.")
        XCTAssertTrue(processed.wasModified)

        let styled = StyledTranscript.unrewritten(processed, status: .notRequested)
        XCTAssertEqual(styled.originalWorthKeeping, transcript)
    }

    func testTheTypedOperationsTravelWithTheText() {
        let processed = TextPostProcessor.process(
            "We ship Friday, scratch that, Monday.",
            settings: settings(correcting: true, enabled: true), terms: [])

        XCTAssertEqual(processed.corrections?.operations.map(\.kind), [.deletePhrase])
    }

    /// Nothing is carried when the stage did not run, so a caller cannot mistake
    /// "no corrections were made" for "corrections were considered".
    func testNothingIsCarriedWhenTheStageDidNotRun() {
        let processed = TextPostProcessor.process(
            "We ship Friday.", settings: settings(correcting: false, enabled: true), terms: [])
        XCTAssertNil(processed.corrections)
    }

    // MARK: - Order against the dictionary

    /// The dictionary runs on what survived, not on what was said.
    ///
    /// The other order is not a preference: `PersonalTermsCorrector` hands back
    /// character ranges the CJK spacing pass holds out, and an edit made after
    /// that would move the text under them.
    func testTheDictionaryIsAppliedToTheTextThatSurvived() {
        let term = PersonalTerm(kind: .preferredSpelling, match: "kubernetes", replacement: "Kubernetes")
        let processed = TextPostProcessor.process(
            "we deploy with docker, scratch that, we deploy with kubernetes",
            settings: settings(correcting: true, enabled: true),
            terms: [term])

        XCTAssertEqual(processed.final, "we deploy with Kubernetes")
        XCTAssertEqual(processed.mustSurviveTokens, ["Kubernetes"])
    }

    /// And the dictionary cannot manufacture a trigger: a term that writes out
    /// "scratch that" is spliced in after the reducer has already run.
    func testADictionaryEntryCannotBecomeATrigger() {
        let term = PersonalTerm(kind: .replacement, match: "sctch tht", replacement: "scratch that")
        let processed = TextPostProcessor.process(
            "we ship Friday, sctch tht, Monday",
            settings: settings(correcting: true, enabled: true),
            terms: [term])

        XCTAssertEqual(processed.final, "we ship Friday, scratch that, Monday")
    }
}
