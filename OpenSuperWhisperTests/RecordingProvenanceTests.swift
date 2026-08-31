import XCTest
@testable import OpenSuperWhisper

/// What each row of history says it is.
///
/// The feature exists because four different things used to leave the same row
/// behind: words typed into another app, a question sent to the Ask panel, a
/// command that opened a video, and a command that opened nothing. These pin
/// that each one is now written down, that it is written down *correctly*, and
/// that a row nobody wrote a provenance for is called what it is rather than
/// guessed at.
final class RecordingProvenanceTests: XCTestCase {

    private let channel = YouTubeChannel(
        displayName: "Veritasium", channelID: "UCHnyfMqiRRG1u-2MsSQLbXA")

    // MARK: - Storage

    func testEveryKindSurvivesTheThreeColumns() {
        let cases: [RecordingProvenance] = [
            .unknown,
            .dictation,
            .fileTranscription,
            .ask,
            .youTubeCommandOpened(summary: "Opened “A video” from Veritasium in Chrome."),
            .youTubeCommandNotOpened(
                reason: .channelUnknown, message: "No allowlisted YouTube channel answers to that."),
            .selectionEdit(instruction: "make it concise bullet points"),
        ]

        for provenance in cases {
            let (kind, reason, detail) = provenance.columns
            XCTAssertEqual(
                RecordingProvenance.stored(kind: kind, reason: reason, detail: detail),
                provenance,
                "\(provenance) did not survive its own columns"
            )
        }
    }

    /// The migration writes nothing into existing rows, so this is what every
    /// recording made before the feature existed reads back as.
    func testNothingStoredIsAnOlderRecordingRatherThanAGuess() {
        XCTAssertEqual(
            RecordingProvenance.stored(kind: nil, reason: nil, detail: nil), .unknown)
        XCTAssertEqual(RecordingProvenanceKind.unknown.label, "Older recording")
    }

    /// A database written by a newer build. Saying "older recording" about a
    /// kind this build cannot describe is honest; inventing one is not.
    func testAKindThisBuildDoesNotKnowIsUnknownRatherThanMislabelled() {
        XCTAssertEqual(
            RecordingProvenance.stored(kind: "somethingLater", reason: nil, detail: "x"),
            .unknown)
    }

    /// A refusal with no class stored cannot be described, and "not opened, and
    /// I cannot say why" is worse than saying the row predates the answer.
    func testARefusalWithNoReasonStoredFallsBackToUnknown() {
        XCTAssertEqual(
            RecordingProvenance.stored(
                kind: RecordingProvenanceKind.youTubeCommandNotOpened.rawValue,
                reason: nil, detail: "nothing was opened"),
            .unknown)
        XCTAssertEqual(
            RecordingProvenance.stored(
                kind: RecordingProvenanceKind.youTubeCommandNotOpened.rawValue,
                reason: "aReasonFromTheFuture", detail: "nothing was opened"),
            .unknown)
    }

    /// These strings are in every user's database. Renaming one relabels rows
    /// they already have, so the list is pinned rather than derived.
    func testTheStoredKindStringsAreStable() {
        XCTAssertEqual(
            Set(RecordingProvenanceKind.allCases.map(\.rawValue)),
            ["unknown", "dictation", "fileTranscription", "ask",
             "youTubeCommandOpened", "youTubeCommandNotOpened", "selectionEdit"]
        )
    }

    func testEveryRefusalReasonHasAStableSlugAndShortLabel() {
        for reason in YouTubeCommandRefusal.allCases {
            XCTAssertEqual(YouTubeCommandRefusal(rawValue: reason.rawValue), reason)
            XCTAssertFalse(reason.shortLabel.isEmpty, "\(reason) has nothing to show")
        }
    }

    // MARK: - What each routing class writes

    func testOrdinaryDictationIsFiledAsDictationAndCarriesNoDetail() {
        let provenance = SpokenIntentOutcome.dictation.provenance
        XCTAssertEqual(provenance, .dictation)
        XCTAssertNil(provenance.detail)
        XCTAssertFalse(provenance.isYouTubeCommand)
    }

    /// A translation and a snippet are dictation: they are text, and they are
    /// inserted. The label describes what happened to the user's words, not
    /// which stage produced them.
    func testTheOtherTextOutcomesAreFiledAsDictation() {
        XCTAssertEqual(
            SpokenIntentOutcome.snippet(keyword: "signoff").provenance, .dictation)
        XCTAssertEqual(
            SpokenIntentOutcome.translated(
                SpokenTranslationTarget(languageCode: "es")).provenance,
            .dictation)
    }

    func testAVoiceEditStoresTheSpokenInstructionAsTheDetail() {
        let provenance = RecordingProvenance.selectionEdit(
            instruction: "make it concise bullet points")
        XCTAssertEqual(provenance.kind, .selectionEdit)
        XCTAssertEqual(provenance.kind.label, "Voice edit")
        XCTAssertEqual(provenance.detail, "make it concise bullet points")
        XCTAssertFalse(provenance.isYouTubeCommand)

        let columns = provenance.columns
        XCTAssertEqual(
            RecordingProvenance.stored(
                kind: columns.kind, reason: columns.reason, detail: columns.detail),
            provenance
        )
    }

    func testAQuestionIsFiledAsAskAndIsNotADictation() {
        let provenance = SpokenIntentOutcome.ask(query: "what is the capital of France?").provenance
        XCTAssertEqual(provenance, .ask)
        XCTAssertEqual(provenance.kind.label, "Ask")
        // The question itself is the transcript, which history already holds.
        // The label does not repeat it.
        XCTAssertNil(provenance.detail)
    }

    /// The provisional value, written with the words. It says "not opened",
    /// because at that moment nothing has been - and if the app never gets to
    /// replace it, that is the true thing to have recorded.
    func testACommandThatHasNotRunYetIsRecordedAsNotOpened() {
        let provenance = SpokenIntentOutcome
            .openLatestVideo(.allowlisted(channel, matchedBy: .spokenName))
            .provenance

        XCTAssertEqual(provenance.kind, .youTubeCommandNotOpened)
        XCTAssertEqual(provenance.refusal, .didNotFinish)
        XCTAssertTrue(provenance.isYouTubeCommand)
    }

    /// Everything but an allowlisted channel is already decided before anything
    /// is fetched, so the row is correct the instant it appears.
    func testARefusedCommandIsFinalBeforeAnythingIsFetched() {
        let unknown = SpokenIntentOutcome
            .openLatestVideo(.unknown(spoken: "Some Channel")).provenance
        XCTAssertEqual(unknown.refusal, .channelUnknown)
        XCTAssertEqual(try XCTUnwrap(unknown.detail).contains("Some Channel"), true)

        let ambiguous = SpokenIntentOutcome
            .openLatestVideo(.ambiguous(spoken: "v", matches: ["A", "B"])).provenance
        XCTAssertEqual(ambiguous.refusal, .channelAmbiguous)

        let disabled = SpokenIntentOutcome
            .openLatestVideo(.disabled(spoken: "Veritasium")).provenance
        XCTAssertEqual(disabled.refusal, .commandDisabled)
        XCTAssertEqual(try XCTUnwrap(disabled.detail).contains("Settings"), true)
    }

    /// The marker was said and no channel was. That is a different thing to
    /// tell somebody than "that channel is not in your list", so it is a
    /// different class.
    func testAMarkerWithNothingBehindItIsRecognitionRatherThanAnUnknownChannel() {
        let provenance = SpokenIntentOutcome
            .openLatestVideo(.unknown(spoken: "   ")).provenance
        XCTAssertEqual(provenance.refusal, .notRecognised)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("shortcut"), true)
    }

    // MARK: - What a finished command writes

    func testAnOpenedCommandRecordsWhatWasOpened() {
        let report = YouTubeLatestVideoReport.opened(
            channel: "Veritasium", title: "Why Trees Are Not Trees", match: .spokenName)

        let provenance = RecordingProvenance.command(report)

        XCTAssertEqual(provenance.kind, .youTubeCommandOpened)
        XCTAssertEqual(provenance.kind.label, "YouTube command - opened")
        let detail = try? XCTUnwrap(provenance.detail)
        XCTAssertEqual(detail?.contains("Veritasium"), true)
        XCTAssertEqual(detail?.contains("Why Trees Are Not Trees"), true)
        XCTAssertNil(provenance.refusal)
    }

    func testEveryWayACommandCanFailIsRecordedAsItsOwnClass() {
        let expected: [(YouTubeLatestVideoReport, YouTubeCommandRefusal)] = [
            (.refused(reason: .commandDisabled, message: "off", shortMessage: "off"),
             .commandDisabled),
            (.refused(reason: .channelUnknown, message: "unknown", shortMessage: "unknown"),
             .channelUnknown),
            (.refused(reason: .channelAmbiguous, message: "two", shortMessage: "two"),
             .channelAmbiguous),
            (.refused(reason: .channelIDUnusable, message: "id", shortMessage: "id"),
             .channelIDUnusable),
            (.refused(reason: .feedUnavailable, message: "offline", shortMessage: "offline"),
             .feedUnavailable),
            (.refused(reason: .feedUnusable, message: "no video", shortMessage: "no video"),
             .feedUnusable),
            (.refused(reason: .browserUnavailable, message: "chrome", shortMessage: "chrome"),
             .browserUnavailable),
        ]

        for (report, reason) in expected {
            XCTAssertEqual(RecordingProvenance.command(report).refusal, reason)
            XCTAssertEqual(RecordingProvenance.command(report).kind, .youTubeCommandNotOpened)
        }
    }

    /// The feed's six failures collapse into two classes on purpose - a lookup
    /// that never happened, and a feed that carried nothing - because those are
    /// the two different things the user does about it. The sentence beside the
    /// class still says which of the six it was.
    func testTheFeedFailuresKeepTheirSentenceWhileSharingAClass() {
        XCTAssertEqual(YouTubeFeedError.unreachable.refusal, .feedUnavailable)
        XCTAssertEqual(YouTubeFeedError.httpStatus(404).refusal, .feedUnavailable)
        XCTAssertEqual(YouTubeFeedError.malformed.refusal, .feedUnusable)
        XCTAssertEqual(YouTubeFeedError.tooLarge.refusal, .feedUnusable)
        XCTAssertEqual(YouTubeFeedError.noEntries.refusal, .feedUnusable)
        XCTAssertEqual(YouTubeFeedError.noUsableVideo.refusal, .feedUnusable)

        let provenance = RecordingProvenance.command(
            .refused(
                reason: YouTubeFeedError.httpStatus(404).refusal,
                message: YouTubeFeedError.httpStatus(404).errorDescription ?? "",
                shortMessage: YouTubeFeedError.httpStatus(404).shortMessage))
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("404"), true)
    }

    // MARK: - The on-device fallback, disclosed

    /// Off, unavailable and rejected all leave the same refusal behind, which is
    /// correct and, on its own, invisible. History says which it was.
    func testTheModelFallbackIsDisclosedOnARefusal() {
        let report = YouTubeLatestVideoReport.refused(
            reason: .channelUnknown, message: "No allowlisted channel answers to that.",
            shortMessage: "Channel not in your list")

        let off = RecordingProvenance.command(report, modelMatch: .off)
        XCTAssertEqual(try XCTUnwrap(off.detail).contains("switched off"), true)

        let unavailable = RecordingProvenance.command(report, modelMatch: .unavailable)
        XCTAssertEqual(try XCTUnwrap(unavailable.detail).contains("could not run"), true)

        let rejected = RecordingProvenance.command(report, modelMatch: .rejected)
        XCTAssertEqual(try XCTUnwrap(rejected.detail).contains("did not recognise"), true)

        // The refusal itself is untouched by any of them: the fallback fails
        // closed, and disclosing it must not change what happened.
        for attempt in [YouTubeChannelModelMatchAttempt.off, .unavailable, .rejected] {
            XCTAssertEqual(
                RecordingProvenance.command(report, modelMatch: attempt).refusal,
                .channelUnknown)
        }
    }

    func testNothingIsDisclosedWhenNoFallbackWasInvolved() {
        XCTAssertNil(YouTubeChannelModelMatchAttempt.notNeeded.disclosure)
        // A match the model made is disclosed by the match itself, which can
        // also quote the phrase it was given.
        XCTAssertNil(YouTubeChannelModelMatchAttempt.matched.disclosure)
        XCTAssertNotNil(
            YouTubeChannelMatchSource.model(spoken: "vera tasium").disclosure)
    }

    func testAMatchTheModelMadeIsDisclosedOnTheOpenedRow() {
        let provenance = RecordingProvenance.command(
            .opened(channel: "Veritasium", title: "A video",
                    match: .model(spoken: "vera tasium")),
            modelMatch: .matched)

        XCTAssertEqual(provenance.kind, .youTubeCommandOpened)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("on-device model"), true)
    }

    // MARK: - Presses that never reached the command at all

    func testACommandCaptureTheEngineWasTooBusyForSaysSo() {
        let provenance = RecordingProvenance.queued(for: .youTubeCommand)
        XCTAssertEqual(provenance.refusal, .engineBusy)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("Nothing was opened"), true)

        // A dictation whose audio was queued is a transcription, not a command.
        XCTAssertEqual(
            RecordingProvenance.queued(for: .dictation), .fileTranscription)
    }

    /// Regenerating from History re-transcribes and never re-runs the command,
    /// so the row keeps what that press did and loses the sentence quoting the
    /// transcript it is about to stop having.
    func testRegeneratingACommandRowKeepsItsClassAndDropsTheStaleQuote() {
        let original = RecordingProvenance.youTubeCommandNotOpened(
            reason: .channelUnknown,
            message: "No allowlisted YouTube channel answers to “Vali101”.")

        let after = original.reTranscribed()

        XCTAssertEqual(after.refusal, .channelUnknown)
        XCTAssertEqual(after.kind, .youTubeCommandNotOpened)
        let detail = try? XCTUnwrap(after.detail)
        XCTAssertEqual(detail?.contains("Vali101"), false)
        XCTAssertEqual(detail?.contains("not run again"), true)
    }

    /// Every other kind is unchanged, including a command that opened: the video
    /// did open, and re-transcribing the words does not un-open it.
    func testRegeneratingAnyOtherRowChangesNothing() {
        for provenance: RecordingProvenance in [
            .unknown, .dictation, .fileTranscription, .ask,
            .youTubeCommandOpened(summary: "Opened “A video” from Veritasium in Chrome."),
            .selectionEdit(instruction: "make it concise"),
        ] {
            XCTAssertEqual(provenance.reTranscribed(), provenance)
        }
    }

    func testACommandCaptureThatCouldNotBeTranscribedSaysSo() {
        let provenance = RecordingProvenance.notTranscribed(
            for: .youTubeCommand, reason: "No transcription engine is ready.")
        XCTAssertEqual(provenance.refusal, .notTranscribed)
        XCTAssertEqual(
            try XCTUnwrap(provenance.detail).contains("No transcription engine is ready."), true)

        XCTAssertEqual(
            RecordingProvenance.notTranscribed(for: .dictation, reason: "whatever"), .dictation)

        let edit = RecordingProvenance.notTranscribed(
            for: .selectionEdit, reason: "No transcription engine is ready.")
        XCTAssertEqual(edit.kind, .selectionEdit)
        XCTAssertEqual(
            try XCTUnwrap(edit.detail).contains("No transcription engine is ready."), true)
    }

    func testAQueuedVoiceEditSaysTheEditNeverRan() {
        let provenance = RecordingProvenance.queued(for: .selectionEdit)
        XCTAssertEqual(provenance.kind, .selectionEdit)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("never ran"), true)
    }
}
