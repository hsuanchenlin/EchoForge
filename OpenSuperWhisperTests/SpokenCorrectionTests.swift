import XCTest

@testable import OpenSuperWhisper

/// The clause boundary the whole correction feature turns on.
final class TranscriptClausesTests: XCTestCase {

    /// The partition claim: whatever the transcript is, the clauses concatenate
    /// back to it. Everything else in this feature rests on it, because it is
    /// what lets an edit remove one clause and leave every other byte alone.
    func testClausesAlwaysRebuildTheTranscriptExactly() {
        let transcripts = [
            "",
            "hello",
            "hello, world",
            "Send it Friday, scratch that, Monday.",
            "Really?!  Yes.",
            "Version 3.5 costs $4.99, e.g. today",
            "line one\nline two",
            "我們星期五出貨，說錯了，星期一。",
            "trailing space ",
            "   leading space",
            "...",
            "a\t\tb",
            "emoji 🎉, and more",
        ]
        for transcript in transcripts {
            XCTAssertEqual(
                TranscriptClauses.join(TranscriptClauses.split(transcript)), transcript,
                "\"\(transcript)\" did not survive a split and join")
        }
    }

    func testADecimalPointDoesNotEndAClause() {
        let clauses = TranscriptClauses.split("Version 3.5 shipped")
        XCTAssertEqual(clauses.map(\.text), ["Version 3.5 shipped"])
    }

    func testFullWidthPunctuationEndsAClauseWithNoSpaceAfterIt() {
        let clauses = TranscriptClauses.split("我們開會，然後吃飯。")
        XCTAssertEqual(clauses.map(\.text), ["我們開會", "然後吃飯"])
    }

    func testDoubledPunctuationIsOneTerminator() {
        let clauses = TranscriptClauses.split("Really?! Yes")
        XCTAssertEqual(clauses.map(\.text), ["Really", "Yes"])
    }

    func testOnlySentencePunctuationEndsASentence() {
        let clauses = TranscriptClauses.split("one, two. three")
        XCTAssertEqual(clauses.map(\.endsSentence), [false, true, false])
    }
}

/// The grammar tables, and the bilingual obligation they carry.
final class SpokenCorrectionGrammarTests: XCTestCase {

    /// Every CJK spelling has to be listed in both scripts.
    ///
    /// `ChineseScriptNormalizer` rewrites a transcript into the user's chosen
    /// script before this stage sees it, so a Simplified speaker whose output is
    /// Traditional says 「删掉那句」 and this table is handed 「刪掉那句」. A
    /// spelling whose converted form is missing turns that correction back into
    /// dictation and pastes it. `SpokenIntentGrammar` carries the same rule for
    /// the same reason.
    func testEveryChineseTriggerIsListedInBothScripts() {
        let keys = Set(SpokenCorrectionGrammar.triggers.map { $0.phrase })
        for trigger in SpokenCorrectionGrammar.triggers
        where !trigger.phrase.contains(where: \.isCased) {
            for variant in [ChineseScriptVariant.traditional, .simplified] {
                let converted = HanCharacterTransform.transform(to: variant)
                    .applied(to: trigger.phrase)
                XCTAssertTrue(
                    keys.contains(converted),
                    "\(trigger.phrase) converts to \(converted), which is not in the table")
            }
        }
    }

    /// A trigger is only ever the whole of a clause, and folding must not make
    /// two different commands collide.
    func testNoTwoTriggersFoldToTheSameKey() {
        var seen: [String: String] = [:]
        for trigger in SpokenCorrectionGrammar.triggers {
            if let existing = seen[trigger.key] {
                XCTFail("\"\(existing)\" and \"\(trigger.phrase)\" fold to the same key")
            }
            seen[trigger.key] = trigger.phrase
        }
    }

    func testCasingAndInnerSpacingDoNotDecideWhetherATriggerIsHeard() {
        for spelling in ["Scratch that", "SCRATCH THAT", "scratch  that", " scratch that "] {
            XCTAssertEqual(
                SpokenCorrectionGrammar.trigger(forClause: spelling)?.kind, .deletePhrase,
                "\"\(spelling)\" was not recognised")
        }
    }

    func testAChineseTriggerIsHeardWhetherOrNotTheEngineSpacedIt() {
        XCTAssertEqual(
            SpokenCorrectionGrammar.trigger(forClause: "刪掉 那句")?.kind, .deleteSentence)
    }

    /// Latin triggers are not compared with spaces removed, or "start over"
    /// would match inside a word an engine ran together.
    func testALatinTriggerIsNotMatchedWithItsSpacesRemoved() {
        XCTAssertNil(SpokenCorrectionGrammar.trigger(forClause: "startover"))
    }

    /// No hesitation sound may be a word in any language this app transcribes:
    /// removing one has to be incapable of changing what was said.
    func testHesitationSoundsAreSoundsRatherThanWords() {
        for sound in SpokenCorrectionGrammar.hesitationSounds {
            XCTAssertTrue(
                sound.allSatisfy { $0.isASCII && $0.isLetter },
                "\(sound) is not a plain hesitation sound")
            XCTAssertLessThanOrEqual(sound.count, 4, "\(sound) is long enough to be a word")
        }
    }
}

/// The reducer itself.
final class SpokenCorrectorTests: XCTestCase {

    private let on = SpokenCorrectionOptions(isEnabled: true, removesFillerWords: false)
    private let withFillers = SpokenCorrectionOptions(isEnabled: true, removesFillerWords: true)

    private func corrected(_ text: String, _ options: SpokenCorrectionOptions? = nil) -> String {
        SpokenCorrector.apply(to: text, options: options ?? on).text
    }

    // MARK: - Off

    func testTheStageIsANoOpWhenItIsOff() {
        let transcript = "Send it Friday, scratch that, Monday."
        XCTAssertEqual(corrected(transcript, .disabled), transcript)
        XCTAssertFalse(
            SpokenCorrector.apply(to: transcript, options: .disabled).didCorrect)
    }

    /// The property the whole design rests on: a dictation with no correction in
    /// it comes back byte for byte, spacing and punctuation included.
    func testADictationWithNoCorrectionComesBackByteForByte() {
        let transcripts = [
            "Ship the release on Friday.",
            "I want to scratch that itch.",
            "Please delete that file when you get a chance.",
            "我們星期五出貨，然後開會。",
            "  odd   spacing   survives  ",
            "Version 3.5, e.g. the one from Tuesday",
        ]
        for transcript in transcripts {
            XCTAssertEqual(corrected(transcript), transcript, "\"\(transcript)\" was modified")
        }
    }

    // MARK: - Deleting a phrase

    func testScratchThatDropsTheClauseBeforeIt() {
        XCTAssertEqual(corrected("Send it Friday, scratch that, Monday."), "Monday.")
    }

    func testOnlyTheClauseBeforeItGoes() {
        XCTAssertEqual(
            corrected("I bought apples, oranges, scratch that, pears."),
            "I bought apples, pears.")
    }

    func testEveryPhraseDeleteSpellingBehavesTheSameWay() {
        for spelling in ["scratch that", "delete that", "strike that", "never mind", "nevermind"] {
            XCTAssertEqual(
                corrected("we ship Friday, \(spelling), Monday"), "Monday",
                "\"\(spelling)\" did not delete the clause before it")
        }
    }

    func testTheTriggerItselfNeverSurvives() {
        XCTAssertEqual(corrected("we ship Friday, scratch that"), "")
    }

    /// The false positive this feature exists to avoid. A trigger inside a
    /// sentence is words, not a command.
    func testATriggerInsideASentenceIsDictation() {
        let sentences = [
            "I want to scratch that itch.",
            "Could you delete that when you have a moment?",
            "We should start over on the design, but not today.",
            "Please never mind the mess.",
            "他說錯了地方。",
        ]
        for sentence in sentences {
            XCTAssertEqual(corrected(sentence), sentence, "\"\(sentence)\" was edited")
        }
    }

    /// Nothing to delete means nothing is deleted, and the words stay so the
    /// user can see what the app heard.
    func testATriggerWithNothingBeforeItIsLeftVerbatim() {
        let result = SpokenCorrector.apply(to: "Scratch that, we ship Monday.", options: on)
        XCTAssertEqual(result.text, "Scratch that, we ship Monday.")
        XCTAssertFalse(result.didCorrect)
        XCTAssertEqual(result.refusals.map(\.reason), [.nothingToDelete])
    }

    func testCorrectionsApplyLeftToRight() {
        XCTAssertEqual(
            corrected("Friday, scratch that, Saturday, scratch that, Sunday"), "Sunday")
    }

    // MARK: - Deleting a sentence

    func testDeleteTheLastSentenceGoesBackToTheFullStop() {
        XCTAssertEqual(
            corrected("Hello there. We ship Friday, and it rains. Delete the last sentence."),
            "Hello there.")
    }

    func testDeleteTheLastSentenceWithOneSentenceClearsIt() {
        XCTAssertEqual(corrected("We ship Friday, and it rains. Delete that sentence."), "")
    }

    func testAChineseSentenceDeleteWorksOnFullWidthPunctuation() {
        XCTAssertEqual(
            corrected("你好。我們星期五出貨，然後開會。刪掉上一句。"), "你好。")
    }

    // MARK: - Replacing

    func testReplaceRewritesTheMostRecentOccurrence() {
        XCTAssertEqual(
            corrected("We ship on Friday, replace Friday with Monday"),
            "We ship on Monday")
    }

    func testChangeXToYIsTheSameCommand() {
        XCTAssertEqual(
            corrected("The meeting is at three, change three to four"),
            "The meeting is at four")
    }

    func testReplaceMatchesRegardlessOfCase() {
        XCTAssertEqual(
            corrected("We ship on FRIDAY, replace friday with Monday"),
            "We ship on Monday")
    }

    func testReplaceEditsTheLastOccurrenceOnly() {
        XCTAssertEqual(
            corrected("Friday, then Friday again, replace Friday with Monday"),
            "Friday, then Monday again")
    }

    func testAChineseReplacementWorks() {
        XCTAssertEqual(
            corrected("我們星期五出貨，把星期五改成星期一"), "我們星期一出貨")
    }

    func testAReplacementWhoseTargetWasNeverSaidIsLeftVerbatim() {
        let result = SpokenCorrector.apply(
            to: "We ship on Friday, replace Tuesday with Monday", options: on)
        XCTAssertEqual(result.text, "We ship on Friday, replace Tuesday with Monday")
        XCTAssertEqual(result.refusals.map(\.reason), [.textNotFound])
    }

    /// Both halves are required, which is what keeps ordinary sentences out.
    func testAnIncompleteReplacementIsDictation() {
        for sentence in [
            "Please replace the battery",
            "We need to change to a bigger room",
            "Replace with something else",
        ] {
            XCTAssertEqual(corrected(sentence), sentence, "\"\(sentence)\" was treated as a command")
        }
    }

    /// The verb has to be the verb, not the front of a longer word.
    func testAWordStartingWithTheVerbIsNotACommand() {
        XCTAssertEqual(
            corrected("The replacement landed with the release"),
            "The replacement landed with the release")
    }

    // MARK: - Starting over

    func testStartOverDropsEverythingBeforeIt() {
        XCTAssertEqual(
            corrected("This is all wrong, start over, here is the real message"),
            "here is the real message")
    }

    func testStartOverAtTheEndClearsTheDictation() {
        XCTAssertEqual(corrected("This is all wrong. Start over."), "")
    }

    func testChineseStartOver() {
        XCTAssertEqual(corrected("這樣不對，重新開始，我們明天再說"), "我們明天再說")
    }

    // MARK: - Fillers

    func testHesitationSoundsAreRemovedOnlyWhenAskedFor() {
        XCTAssertEqual(corrected("So um we ship on Friday"), "So um we ship on Friday")
        XCTAssertEqual(corrected("So um we ship on Friday", withFillers), "So we ship on Friday")
    }

    func testAClauseThatIsNothingButAFillerGoesWithItsPunctuation() {
        XCTAssertEqual(corrected("It's, like, complicated", withFillers), "It's complicated")
        XCTAssertEqual(corrected("Um, we ship on Friday", withFillers), "we ship on Friday")
    }

    /// The other half of that rule: a filler word that is carrying meaning is
    /// never touched, because it is not standing on its own.
    func testAFillerWordInsideAClauseKeepsItsMeaning() {
        XCTAssertEqual(corrected("I like this design", withFillers), "I like this design")
        XCTAssertEqual(
            corrected("You know the answer already", withFillers), "You know the answer already")
    }

    func testAQuotedHesitationIsNotRemoved() {
        XCTAssertEqual(
            corrected("He wrote \"um\" on the board", withFillers),
            "He wrote \"um\" on the board")
        XCTAssertEqual(
            corrected("The token is `uh` in the parser", withFillers),
            "The token is `uh` in the parser")
    }

    /// An apostrophe inside a word is not a quotation mark. Two of them in one
    /// sentence would otherwise hold everything between them out of the pruning
    /// the user asked for.
    func testAnApostropheDoesNotOpenAQuotation() {
        XCTAssertEqual(
            corrected("Don't say um, it's fine", withFillers), "Don't say it's fine")
    }

    /// A hesitation that ended a clause took the speaker's pause with it:
    /// "we should um, ship on Friday" is one thought, and leaving the comma
    /// would punctuate it as two.
    func testAHesitationAtTheEndOfAClauseTakesItsCommaWithIt() {
        XCTAssertEqual(
            corrected("we should um, ship on Friday", withFillers), "we should ship on Friday")
    }

    /// But a full stop is the speaker's, not the hesitation's.
    func testAFullStopAfterAHesitationStays() {
        XCTAssertEqual(
            corrected("That is all uh. We ship Friday.", withFillers),
            "That is all. We ship Friday.")
    }

    func testFillerPruningLeavesTheRestOfTheClauseSpacedTheSameWay() {
        XCTAssertEqual(corrected("we uh ship uh on Friday", withFillers), "we ship on Friday")
    }

    // MARK: - What the stage reports

    func testEveryOperationSaysWhatItRemoved() {
        let result = SpokenCorrector.apply(
            to: "We ship Friday, scratch that, Monday", options: on)
        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.kind, .deletePhrase)
        XCTAssertEqual(result.operations.first?.trigger, "scratch that")
        XCTAssertTrue(result.operations.first?.removed.contains("We ship Friday") == true)
    }

    func testAReplacementReportsBothSides() {
        let result = SpokenCorrector.apply(
            to: "We ship on Friday, replace Friday with Monday", options: on)
        XCTAssertEqual(result.operations.first?.removed, "Friday")
        XCTAssertEqual(result.operations.first?.inserted, "Monday")
    }
}
