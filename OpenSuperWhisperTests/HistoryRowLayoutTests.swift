import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The history row's responsive layout, as a pure decision.
///
/// `HistoryWidthTier` and `HistoryRowMetrics` exist so that "how does the row
/// change when the window is dragged" is a value a test can read, rather than a
/// scattering of `if` in a view body that only a screenshot can check. The
/// pixels are `HistoryRowRenderTests`' job; this file holds the arithmetic.
final class HistoryRowLayoutTests: XCTestCase {

    // MARK: - The threshold

    /// The window's own minimum is 400 pt and the list insets it further, so
    /// the narrowest real row must land in the compact tier - if it did not,
    /// the compact layout would exist and never be used.
    func testTheNarrowestWindowTheAppAllowsIsCompact() {
        let narrowestRow: CGFloat = 400 - 32
        XCTAssertEqual(HistoryWidthTier(width: narrowestRow), .compact)
    }

    func testTheTierFlipsExactlyAtTheThreshold() {
        let threshold = HistoryWidthTier.regularMinimumWidth
        XCTAssertEqual(HistoryWidthTier(width: threshold - 0.5), .compact)
        XCTAssertEqual(HistoryWidthTier(width: threshold), .regular,
                       "the threshold width itself is the first regular width")
        XCTAssertEqual(HistoryWidthTier(width: threshold + 0.5), .regular)
    }

    /// A width of zero is what a container reports before it has been laid out.
    /// It must not be read as "very wide".
    func testAnUnmeasuredContainerIsCompact() {
        XCTAssertEqual(HistoryWidthTier(width: 0), .compact)
        XCTAssertEqual(HistoryWidthTier(width: -10), .compact)
    }

    func testAWideWindowIsRegular() {
        XCTAssertEqual(HistoryWidthTier(width: 1200), .regular)
    }

    // MARK: - What each tier settles

    func testMetricsFollowTheWidthTheyAreBuiltFrom() {
        XCTAssertEqual(HistoryRowMetrics(width: 380).tier, .compact)
        XCTAssertEqual(HistoryRowMetrics(width: 900).tier, .regular)
        XCTAssertEqual(HistoryRowMetrics(width: 900), .regular)
        XCTAssertEqual(HistoryRowMetrics(width: 380), .compact)
    }

    /// The two tiers must actually differ in the three ways the row branches
    /// on. A metrics table whose tiers agreed would make the responsive layout
    /// a no-op that still passed a render test.
    func testTheTwoTiersDisagreeOnEveryLayoutDecision() {
        XCTAssertTrue(HistoryRowMetrics.compact.stacksMetadata)
        XCTAssertFalse(HistoryRowMetrics.regular.stacksMetadata)

        XCTAssertTrue(HistoryRowMetrics.compact.wrapsActionBarWhenTight)
        XCTAssertFalse(HistoryRowMetrics.regular.wrapsActionBarWhenTight)

        XCTAssertFalse(HistoryRowMetrics.compact.showsFullDateInFooter)
        XCTAssertTrue(HistoryRowMetrics.regular.showsFullDateInFooter)
    }

    /// The compact tier is the one that has to save room, so every one of its
    /// measurements is at most the regular tier's.
    func testCompactIsNeverRoomierThanRegular() {
        let compact = HistoryRowMetrics.compact
        let regular = HistoryRowMetrics.regular
        XCTAssertLessThan(compact.horizontalPadding, regular.horizontalPadding)
        XCTAssertLessThan(compact.verticalPadding, regular.verticalPadding)
        XCTAssertLessThanOrEqual(compact.sectionSpacing, regular.sectionSpacing)
        XCTAssertLessThanOrEqual(compact.actionSpacing, regular.actionSpacing)
        XCTAssertLessThanOrEqual(compact.actionIconSize, regular.actionIconSize)
        XCTAssertLessThanOrEqual(compact.actionHitTarget, regular.actionHitTarget)
    }

    /// A quick action is a small glyph among three others. Neither tier may
    /// shrink its hit target below something a pointer can land on.
    func testEveryTierKeepsAnActionHitTargetAPointerCanLandOn() {
        for tier in HistoryWidthTier.allCases {
            let metrics = HistoryRowMetrics.metrics(for: tier)
            XCTAssertGreaterThanOrEqual(
                metrics.actionHitTarget, 24,
                "\(tier) actions are too small to hit")
            XCTAssertGreaterThan(
                metrics.actionHitTarget, metrics.actionIconSize,
                "\(tier) has no padding around its action glyphs")
        }
    }

    /// The four actions plus their gaps have to fit across the narrowest row
    /// with the timestamp still beside them where the tier keeps them inline.
    func testTheActionBarFitsTheNarrowestRow() {
        let narrowestRow: CGFloat = 400 - 32
        let metrics = HistoryRowMetrics(width: narrowestRow)
        let actions = 4
        let barWidth = CGFloat(actions) * metrics.actionHitTarget
            + CGFloat(actions - 1) * metrics.actionSpacing
        let available = narrowestRow - 2 * metrics.horizontalPadding
        XCTAssertLessThan(barWidth, available,
                          "the collapsed action bar overflows the narrowest row")
    }

    /// The environment default is what a row rendered outside the list gets -
    /// a preview, a test, a future surface that forgets the reader. It has to
    /// be the tier that fits everywhere, not the one that needs the room.
    func testARowOutsideTheListDefaultsToCompact() {
        XCTAssertEqual(EnvironmentValues().historyRowMetrics, .compact)
    }

    // MARK: - Timestamps

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    /// `RelativeDateTimeFormatter` answers "in 0 seconds" for something that
    /// happened a moment ago: wrong tense, wrong direction.
    func testSomethingFromAMomentAgoReadsAsJustNow() {
        XCTAssertEqual(HistoryTimestamp.relative(for: noon, now: noon), "Just now")
        XCTAssertEqual(
            HistoryTimestamp.relative(for: noon, now: noon.addingTimeInterval(59)),
            "Just now")
    }

    func testOlderRecordingsGetARelativePhrase() {
        let phrase = HistoryTimestamp.relative(
            for: noon, now: noon.addingTimeInterval(60 * 60 * 3))
        XCTAssertNotEqual(phrase, "Just now")
        XCTAssertFalse(phrase.isEmpty)
    }

    /// A chip is one line and sized to its own text, so the phrase in it has to
    /// stay short whatever the elapsed time is.
    func testTheRelativePhraseStaysShortEnoughForAChip() {
        let elapsedTimes: [TimeInterval] = [90, 3_600, 86_400, 777_600, 34_560_000]
        for elapsed in elapsedTimes {
            let phrase = HistoryTimestamp.relative(
                for: noon, now: noon.addingTimeInterval(elapsed))
            XCTAssertLessThanOrEqual(
                phrase.count, 18,
                "“\(phrase)” is too long for the header chip")
        }
    }

    /// Today's rows drop the date: a list where every row repeats today's date
    /// is a list where the date is noise.
    func testTodaysRowsStateOnlyTheTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let sameDay = HistoryTimestamp.absolute(
            for: noon, now: noon.addingTimeInterval(60 * 60), calendar: calendar)
        let otherDay = HistoryTimestamp.absolute(
            for: noon, now: noon.addingTimeInterval(86_400 * 3), calendar: calendar)

        XCTAssertLessThan(
            sameDay.count, otherDay.count,
            "a row from today should be shorter than one from last week")
        XCTAssertFalse(sameDay.isEmpty)
    }
}

/// Which actions a history row offers, as the pure decision the card reads.
///
/// It is read three times - to draw the hover bar, to fill the context menu,
/// and to register the same actions with VoiceOver, which has no pointer to
/// hover with - so a mistake here is a mistake in three places at once. Getting
/// it wrong is not cosmetic: a row that offers to play audio it has not written
/// yet fails when pressed, and a queued row with no delete is a row the user
/// cannot get out of.
final class HistoryRowActionTests: XCTestCase {

    /// A finished recording with words in it is the only state where everything
    /// applies.
    func testAFinishedRowOffersAllSix() {
        XCTAssertEqual(
            HistoryRowActionKind.available(for: .completed, hasTranscript: true),
            [.play, .copy, .export, .fixWithAI, .regenerate, .delete])
    }

    /// "No speech detected" is a finished row with nothing in it. There is
    /// nothing for a model to fix and nothing to put in a document either -
    /// `TranscriptExport.document(for:)` refuses the same row on the way in.
    func testAFinishedRowWithNoWordsCanBeNeitherFixedNorExported() {
        XCTAssertEqual(
            HistoryRowActionKind.available(for: .completed, hasTranscript: false),
            [.play, .copy, .regenerate, .delete])
    }

    /// A row that is still running or that failed has no finished transcript, so
    /// it is never offered a document to write - the same rule that keeps "Fix
    /// with AI" off them.
    func testOnlyAFinishedRowWithWordsCanBeExported() {
        for status in [RecordingStatus.pending, .converting, .transcribing, .failed] {
            for hasTranscript in [false, true] {
                XCTAssertFalse(
                    HistoryRowActionKind.available(for: status, hasTranscript: hasTranscript)
                        .contains(.export),
                    "a \(status.rawValue) row offered an export it has nothing to write")
            }
        }
    }

    /// Nothing has been written yet, so there is nothing to play or copy - but
    /// the way out has to stay open.
    func testARunningRowOffersOnlyTheWayOut() {
        for status in [RecordingStatus.pending, .converting, .transcribing] {
            for hasTranscript in [false, true] {
                XCTAssertEqual(
                    HistoryRowActionKind.available(
                        for: status, hasTranscript: hasTranscript),
                    [.delete],
                    "a \(status.rawValue) row offered an action it cannot perform")
            }
        }
    }

    /// `DictationFailureOutcome` keeps the audio of a failed dictation exactly
    /// so the user can switch engine and press regenerate.
    ///
    /// It does not offer "Fix with AI", and that is the point of the second
    /// case: a failed row's "transcript" is the app's own failure message, so
    /// handing it to a model would be asking it to correct Kongweh's words.
    func testAFailedRowCanBeRetriedButNotFixed() {
        for hasTranscript in [false, true] {
            XCTAssertEqual(
                HistoryRowActionKind.available(
                    for: .failed, hasTranscript: hasTranscript),
                [.regenerate, .delete])
        }
    }

    /// Every state keeps delete, in every state, without exception.
    func testEveryRowCanBeDeleted() {
        for status in [
            RecordingStatus.pending, .converting, .transcribing, .completed, .failed,
        ] {
            XCTAssertTrue(
                HistoryRowActionKind.available(for: status, hasTranscript: true)
                    .contains(.delete),
                "a \(status.rawValue) row cannot be deleted")
        }
    }

    /// The two actions with a tooltip longer than their label. "Fix with AI"
    /// says nothing about what it fixes or where it runs, and "Export
    /// transcript" says nothing about the user choosing where it goes - which is
    /// the whole safety story of that press.
    func testTheTwoActionsThatNeedExplainingExplainThemselves() {
        let fix = HistoryRowActionKind.fixWithAI.help
        XCTAssertNotNil(fix)
        XCTAssertTrue(fix?.contains("this Mac") == true, "the tooltip must say where it runs")

        let export = HistoryRowActionKind.export.help
        XCTAssertNotNil(export)
        XCTAssertTrue(
            export?.contains("you choose") == true,
            "the tooltip must say the destination is the user's")

        for kind in HistoryRowActionKind.allCases where kind != .fixWithAI && kind != .export {
            XCTAssertNil(kind.help, "\(kind.rawValue) grew a tooltip its label already carries")
        }
    }

    /// A hover tooltip and a VoiceOver label are the same string on purpose:
    /// what a pointer user is told is what a VoiceOver user is told.
    func testEveryActionNamesItselfInBothStates() {
        for kind in HistoryRowActionKind.allCases {
            for isPlaying in [false, true] {
                XCTAssertFalse(
                    kind.label(isPlaying: isPlaying).isEmpty,
                    "\(kind.rawValue) has no label")
                XCTAssertFalse(
                    kind.symbolName(isPlaying: isPlaying).isEmpty,
                    "\(kind.rawValue) has no symbol")
            }
        }
    }

    /// Playback is one button with two meanings, and it has to say which.
    func testPlaybackSaysWhichWayItWillGo() {
        XCTAssertEqual(HistoryRowActionKind.play.label(isPlaying: false), "Play audio")
        XCTAssertEqual(HistoryRowActionKind.play.label(isPlaying: true), "Stop playback")
        XCTAssertNotEqual(
            HistoryRowActionKind.play.symbolName(isPlaying: false),
            HistoryRowActionKind.play.symbolName(isPlaying: true))
    }

    /// Colour never carries destructiveness on its own - the label says it too
    /// - but exactly one action is the destructive one.
    func testDeleteIsTheOnlyDestructiveAction() {
        let destructive = HistoryRowActionKind.allCases.filter(\.isDestructive)
        XCTAssertEqual(destructive, [.delete])
    }
}
