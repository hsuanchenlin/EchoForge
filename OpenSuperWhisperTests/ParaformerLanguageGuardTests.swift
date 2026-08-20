import XCTest

@testable import OpenSuperWhisper

/// The check that stops Paraformer's non-Mandarin output reaching the user's
/// document, and what the user is told when it fires.
///
/// The failure being prevented is not a crash: it is a dictation that arrives.
/// Paraformer takes no language parameter and refuses nothing, so English spoken
/// into it used to be pasted into whatever the user was typing in, as the
/// tokeniser's own sub-word units - `@@` markers included
/// (`docs/upstream-issues.md`).
///
/// Two rules carry it, and they are tested apart on purpose. The `@@` rule is
/// the obvious one and it is also the fragile one: it depends on an upstream
/// defect that may be fixed, and on the model happening to emit fragments rather
/// than whole Latin words. So every predominantly-English case that would be
/// caught by `@@` has a twin **without** `@@` in it, and the Latin-share rule
/// has to catch that twin on its own. A change that makes the guard depend on
/// the markers alone fails here rather than in a user's editor. The
/// mostly-Mandarin case with one marked English word has no such twin and
/// cannot: with the marker stripped its Latin share is one the guard accepts by
/// design, which the guard's own doc states as the bilingual gap.
///
/// Nothing here downloads weights or touches the model: the guard is a pure
/// function over a string.
final class ParaformerLanguageGuardTests: XCTestCase {

    // MARK: - Rule 1: raw BPE continuation markers

    /// What the model actually returns for English, fragments and all.
    func testTranscriptWithBpeMarkersIsRejected() {
        let english = "how@@ ever the mee@@ ting is on tues@@ day"

        XCTAssertEqual(ParaformerLanguageGuard.rejection(in: english), .bpeFragments)
    }

    /// Presence, not proportion. A recording that was mostly Mandarin with one
    /// English sentence in it is still a transcript with tokeniser internals in
    /// it, and pasting the Mandarin plus the fragments is not a better outcome
    /// than saying so.
    func testASingleMarkerInAnOtherwiseMandarinTranscriptIsRejected() {
        let mixed = "今天的會議紀錄已經整理好了請大家過目並且回覆意見sched@@ ule"

        XCTAssertEqual(ParaformerLanguageGuard.rejection(in: mixed), .bpeFragments)
    }

    // MARK: - Rule 2: the same cases with no marker to find

    /// The masking case, and the reason the guard is not just a `contains("@@")`
    /// call: the model also returns whole Latin words. Nothing here carries a
    /// marker, and all of it has to be refused anyway.
    func testEnglishWithoutAnyMarkerIsStillRejected() {
        let cases = [
            "the meeting is on tuesday afternoon",
            "please send me the report before friday",
            "SHIPPING ADDRESS CONFIRMED",
            "Zürich Genève Lausanne Neuchâtel",
        ]

        for text in cases {
            XCTAssertFalse(text.contains("@@"), "this fixture must not be catchable by the marker rule")
            XCTAssertEqual(
                ParaformerLanguageGuard.rejection(in: text), .latinScript,
                "unmarked Latin output reached the user: \(text)")
        }
    }

    /// The `@@` rule removed from the equation entirely: strip the markers out of
    /// the model's own English output and the guard must still refuse it. This is
    /// what happens the day the upstream detokenising defect is fixed and the
    /// output becomes tidy English rather than fragments.
    func testStrippingTheMarkersDoesNotGetEnglishPastTheGuard() {
        let withMarkers = "how@@ ever the mee@@ ting is on tues@@ day"
        let detokenised = withMarkers.replacingOccurrences(of: "@@ ", with: "")

        XCTAssertEqual(ParaformerLanguageGuard.rejection(in: withMarkers), .bpeFragments)
        XCTAssertEqual(
            ParaformerLanguageGuard.rejection(in: detokenised), .latinScript,
            "with the markers gone the transcript is still English: \(detokenised)")
    }

    // MARK: - What must get through

    /// The engine's whole job. A Mandarin transcript is what this model is for
    /// and the guard must be invisible to it.
    func testMandarinIsAccepted() {
        let cases = [
            "今天天氣很好我們去公園散步吧",
            "语音识别技术在过去十年里有了很大的进步",
            "三点二十分开会",
        ]

        for text in cases {
            XCTAssertNil(
                ParaformerLanguageGuard.rejection(in: text),
                "a Mandarin transcript was refused: \(text)")
        }
    }

    /// Mandarin quoting a product name, an acronym or a spelled-out address is
    /// still Mandarin. This is the false positive the share test is tuned to
    /// avoid, and it is a realistic dictation rather than a contrived one.
    func testMandarinContainingLatinWordsIsAccepted() {
        let cases = [
            "我用Google搜尋了這個問題",
            "請把PDF和PPT一起寄給我",
            "我的帳號是abcdefg你記一下",
        ]

        for text in cases {
            XCTAssertNil(
                ParaformerLanguageGuard.rejection(in: text),
                "Mandarin quoting Latin was refused: \(text)")
        }
    }

    /// Below the evidence line the guard says nothing. A handful of letters is
    /// not a language, and condemning it would refuse "OK啦" and its neighbours.
    func testTooLittleTextIsNotJudged() {
        for text in ["OK", "PDF", "你好", "", "   ", "abcdefg"] {
            XCTAssertNil(
                ParaformerLanguageGuard.rejection(in: text),
                "a \(text.count)-character transcript is not evidence of a language: \(text)")
        }
    }

    /// The two ends of the evidence rule, stated as the numbers they are, so
    /// moving `minimumLetters` is a deliberate act rather than a side effect.
    func testTheEvidenceThresholdIsWhereItSaysItIs() {
        let short = String(repeating: "a", count: ParaformerLanguageGuard.minimumLetters - 1)
        let long = String(repeating: "a", count: ParaformerLanguageGuard.minimumLetters)

        XCTAssertNil(ParaformerLanguageGuard.rejection(in: short))
        XCTAssertEqual(ParaformerLanguageGuard.rejection(in: long), .latinScript)
    }

    /// Digits and punctuation are not evidence of a script either way, so they
    /// must not push a transcript over the line on their own.
    func testDigitsAndPunctuationDoNotCountAsEvidence() {
        XCTAssertNil(ParaformerLanguageGuard.rejection(in: "2026 3 20 1250 ...!?"))
    }

    /// The share rule, at the boundary. Four Latin letters to one Han character
    /// is exactly four fifths and stays; five to one is over and goes.
    func testTheShareRuleNeedsAClearMajorityOfLatin() {
        XCTAssertNil(
            ParaformerLanguageGuard.rejection(in: "abcdefghijkl中中中"),
            "12 of 15 letters is exactly the threshold and must not be refused")
        XCTAssertEqual(
            ParaformerLanguageGuard.rejection(in: "abcdefghijklm中中"), .latinScript,
            "13 of 15 letters is over the threshold")
    }

    // MARK: - What the user is told, and what happens to their audio

    /// The copy has three jobs: name the constraint, say the recording is safe,
    /// and point at the way out. All three are obligations rather than style, so
    /// they are asserted rather than left to review.
    func testTheMessageNamesTheConstraintTheAudioAndTheWayOut() {
        let message = ParaformerLanguageGuard.message

        XCTAssertTrue(message.contains("Paraformer"), message)
        XCTAssertTrue(message.contains("Mandarin only"), message)
        XCTAssertTrue(
            message.lowercased().contains("kept"),
            "the user has to be told their audio survived, or they will re-record: \(message)")
        XCTAssertTrue(
            message.contains("Settings → Model"),
            "the message must point at the pane that changes engine: \(message)")
        XCTAssertTrue(
            message.lowercased().contains("engine shortcut"),
            "the shortcut is the other way out and the faster one: \(message)")
        XCTAssertTrue(
            message.lowercased().contains("regenerate"),
            "switching engine alone does not transcribe the kept recording: \(message)")
    }

    /// The shortcut is named as a thing, never as a key. The binding belongs to
    /// the user and `EngineShortcutHint` is the one surface that reads which one
    /// is in force; a sentence naming ⌥M is wrong for everybody who moved it.
    func testTheMessageDoesNotHardcodeAShortcutKey() {
        XCTAssertFalse(
            ParaformerLanguageGuard.message.contains("⌥"),
            "only EngineShortcutHint may state a binding, because only it reads the real one")
    }

    /// The two-word form exists because the indicator card is 200 pt wide and
    /// the capsule is smaller. `CloudRequestError.shortMessage` sets the length
    /// this has to live within.
    func testTheShortMessageFitsTheOverlaysItIsFor() {
        let short = ParaformerLanguageGuard.shortMessage

        XCTAssertFalse(short.isEmpty)
        XCTAssertLessThanOrEqual(
            short.count, EngineConfiguration.unavailableShortMessage.count + 8,
            "the card truncates it: \(short)")
        XCTAssertLessThan(
            short.count, ParaformerLanguageGuard.message.count,
            "the short form is not shorter than the sentence it stands in for")
        XCTAssertTrue(short.contains("Mandarin"), "the two words have to name the language: \(short)")
    }

    /// The failure carries its own copy, so the error a user meets and the
    /// wording above cannot drift apart.
    func testTheFailureCarriesTheGuardsOwnCopy() {
        XCTAssertEqual(
            ParaformerLanguageGuard.failure,
            .unsupportedSpokenLanguage(
                message: ParaformerLanguageGuard.message,
                shortMessage: ParaformerLanguageGuard.shortMessage))
        XCTAssertEqual(
            ParaformerLanguageGuard.failure.errorDescription, ParaformerLanguageGuard.message,
            "the queue shows localizedDescription on a failed recording")
    }

    /// The point of the whole exercise: a refused dictation **keeps the audio**.
    /// The engine is a choice the user can change in one press, and the same
    /// recording transcribes perfectly on another engine - deleting it would be
    /// the app throwing away work over a setting.
    func testARefusedDictationKeepsTheRecording() {
        let outcome = DictationFailureOutcome.forError(ParaformerLanguageGuard.failure)

        XCTAssertEqual(
            outcome,
            .keep(
                reason: ParaformerLanguageGuard.message,
                indicatorState: .wrongLanguage(ParaformerLanguageGuard.shortMessage)))
    }

    /// It must not be mistaken for "no engine set up". Every setting is correct
    /// here, and sending this user to the Models pane to fix something that is
    /// not broken is the app misdirecting them.
    func testItIsNotReportedAsAConfigurationProblem() {
        XCTAssertFalse(EngineConfiguration.isNotConfigured(ParaformerLanguageGuard.failure))

        let outcome = DictationFailureOutcome.forError(ParaformerLanguageGuard.failure)
        XCTAssertNotEqual(
            outcome,
            .keep(
                reason: EngineConfiguration.unavailableMessage, indicatorState: .noEngine))
    }

    /// The failures that still discard, so this case cannot quietly become the
    /// rule for everything.
    func testOrdinaryFailuresStillDiscardTheAudio() {
        XCTAssertEqual(DictationFailureOutcome.forError(TranscriptionError.processingFailed), .discard)
        XCTAssertEqual(
            DictationFailureOutcome.forError(TranscriptionError.contextInitializationFailed), .discard)
    }
}
