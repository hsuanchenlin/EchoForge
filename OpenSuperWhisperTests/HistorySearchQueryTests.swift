import XCTest

@testable import OpenSuperWhisper

/// What a typed phrase means, before any database sees it.
///
/// The pure half of history search. Everything here is a decision the SQL cannot
/// make for itself: the card says "Voice edit" where the column says
/// `selectionEdit`, and the footer says "Sep 4, 2026" where the column holds an
/// instant - so a search that only asked the columns would find neither.
final class HistorySearchQueryTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let posix = Locale(identifier: "en_US_POSIX")
    private let english = Locale(identifier: "en_US")

    private func query(_ raw: String, now: Date = Date()) -> HistorySearchQuery {
        HistorySearchQuery(raw, now: now, calendar: calendar, locale: english)
    }

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = posix
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    // MARK: - Emptiness

    func testAnEmptyPhraseIsNoSearchAtAll() {
        for raw in ["", "   ", "\n\t "] {
            let search = query(raw)
            XCTAssertTrue(search.isEmpty, "“\(raw)” must read as no search")
            XCTAssertEqual(search.text, "")
            XCTAssertTrue(search.matchedKinds.isEmpty)
            XCTAssertFalse(search.matchesUnrecordedProvenance)
            XCTAssertNil(search.dateInterval)
        }
    }

    /// The whitespace a user leaves after a pasted word must not become part of
    /// the pattern: `%hello %` finds nothing that `%hello%` would.
    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(query("  hello  ").text, "hello")
        XCTAssertFalse(query("  hello  ").isEmpty)
    }

    // MARK: - Provenance labels

    func testAKindIsFoundByTheLabelTheCardShows() {
        XCTAssertEqual(query("Voice edit").matchedKinds, [.selectionEdit])
        XCTAssertEqual(query("File transcription").matchedKinds, [.fileTranscription])
        XCTAssertEqual(query("Dictation").matchedKinds, [.dictation])
    }

    /// Case-insensitively, the same way the transcript match is: a search field
    /// that demanded the badge's own capitalisation would be a difference the
    /// user cannot see.
    func testLabelMatchingIgnoresCase() {
        for raw in ["voice edit", "VOICE EDIT", "Voice Edit", "vOiCe EdIt"] {
            XCTAssertEqual(
                query(raw).matchedKinds, [.selectionEdit],
                "“\(raw)” must find a voice edit")
        }
    }

    /// Substring, so a half-remembered word still lands - and so one phrase can
    /// reach both outcomes of the one feature that has two.
    func testAPartialPhraseFindsEveryKindItNames() {
        XCTAssertEqual(
            query("youtube").matchedKinds,
            [.youTubeCommandOpened, .youTubeCommandNotOpened])
        XCTAssertEqual(query("edit").matchedKinds, [.selectionEdit])
    }

    /// The stored raw value is a storage detail the user has never seen, and
    /// matching it would be an accident: nothing on screen says `selectionEdit`.
    func testTheStoredRawValueIsNotWhatIsMatched() {
        XCTAssertTrue(
            query("selectionEdit").matchedKinds.isEmpty,
            "The persisted discriminator is not a label the user has been shown.")
        XCTAssertTrue(query("youTubeCommandOpened").matchedKinds.isEmpty)
    }

    /// "Older recording" is the label for two different states - a row stored
    /// with `unknown` and a row stored before provenance existed at all, whose
    /// column is NULL - and both have to be reachable by the words on the badge.
    func testOlderRecordingReachesRowsWithNothingStored() {
        let search = query("Older recording")
        XCTAssertEqual(search.matchedKinds, [.unknown])
        XCTAssertTrue(
            search.matchesUnrecordedProvenance,
            "provenanceKind IN (…) is false for NULL, so this flag is the only way to that row.")
    }

    func testAnOrdinaryWordNamesNoKind() {
        XCTAssertTrue(query("hello").matchedKinds.isEmpty)
        XCTAssertFalse(query("hello").matchesUnrecordedProvenance)
    }

    // MARK: - Dates

    func testAnISODayIsThatDay() {
        let search = query("2026-09-04")
        let interval = try? XCTUnwrap(search.dateInterval)
        XCTAssertEqual(interval?.start, date("2026-09-04 00:00"))
        XCTAssertEqual(interval?.end, date("2026-09-05 00:00"))
    }

    func testAYearAndMonthIsThatMonth() {
        let search = query("2026-09")
        let interval = try? XCTUnwrap(search.dateInterval)
        XCTAssertEqual(interval?.start, date("2026-09-01 00:00"))
        XCTAssertEqual(interval?.end, date("2026-10-01 00:00"))
    }

    func testABareYearIsThatYear() {
        let search = query("2026", now: date("2026-09-04 12:00"))
        let interval = try? XCTUnwrap(search.dateInterval)
        XCTAssertEqual(interval?.start, date("2026-01-01 00:00"))
        XCTAssertEqual(interval?.end, date("2027-01-01 00:00"))
    }

    /// The format the card's own footer prints, which is the one a user is most
    /// likely to copy back into the field.
    func testTheDateTheFooterPrintsIsReadBack() {
        let search = query("Sep 4, 2026")
        let interval = try? XCTUnwrap(search.dateInterval)
        XCTAssertEqual(interval?.start, date("2026-09-04 00:00"))
        XCTAssertEqual(interval?.end, date("2026-09-05 00:00"))
    }

    /// A transcript full of numbers must not turn into a date search. Four
    /// digits are read as a year only within a century of now, which leaves the
    /// numbers people actually say as the words they are.
    func testAFourDigitNumberFarFromNowIsNotAYear() {
        let now = date("2026-09-04 12:00")
        XCTAssertNil(query("1080", now: now).dateInterval)
        XCTAssertNil(query("2500", now: now).dateInterval)
        XCTAssertNotNil(query("1990", now: now).dateInterval)
    }

    /// A phrase this cannot read is not a date. Guessing a range for it would
    /// quietly hide every row the words would have found.
    func testAPhraseThatIsNotADateCarriesNoInterval() {
        for raw in ["hello", "meeting notes", "2026-13-45", "the 4th"] {
            XCTAssertNil(query(raw).dateInterval, "“\(raw)” is not a date")
        }
    }

    /// A fixed format is a machine format: `2026-09-04` has to mean that day in
    /// every region, not be reinterpreted by the reader's own calendar.
    func testAnISODayMeansTheSameDayInAnotherRegion() {
        let german = HistorySearchQuery(
            "2026-09-04", calendar: calendar, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(german.dateInterval?.start, date("2026-09-04 00:00"))
    }

    // MARK: - Both at once

    /// A phrase can be a kind *and* nothing else, or words *and* nothing else -
    /// but the fields are independent, and the query keeps the text whatever
    /// else it resolved.
    func testTheTextSurvivesWhateverElseThePhraseResolvedTo() {
        let kind = query("Dictation")
        XCTAssertEqual(kind.text, "Dictation")
        let day = query("2026-09-04")
        XCTAssertEqual(day.text, "2026-09-04")
    }
}
