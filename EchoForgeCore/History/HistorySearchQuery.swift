import Foundation

/// What the user typed into the history search field, resolved into the three
/// things a row can be found by.
///
/// A pure value, for the same reason `HistoryProvenanceFilter` is one: history
/// is **paged**, so a search applied to the hundred rows that happen to be
/// loaded would silently hide every older row that matches - which is the
/// opposite of what somebody hunting for last month's dictation is asking for.
/// The search therefore has to run in SQL, and everything the SQL cannot see for
/// itself has to be decided here first.
///
/// Two of the three fall out of that. A row's transcript is a column, so a
/// substring match is the query's own job. But the words the card actually shows
/// for *when* and *what kind* are neither stored nor storable as text: the badge
/// says "Voice edit" where the column says `selectionEdit`, and the footer says
/// "Sep 4, 2026 at 3:12 PM" where the column holds an instant. So this type
/// resolves the typed phrase into the provenance kinds whose **on-screen label**
/// it names, and into the day, month or year it reads as - and
/// `RecordingStore.query(matching:searching:)` turns those into predicates the
/// database can answer.
///
/// What it deliberately does **not** reach is `fileName` and `sourceFileURL`.
/// The first is an internal `UUID.wav`; the second is an absolute path on the
/// user's disk, whose directory components have never been shown on a card and
/// whose match would be an accident of where they keep their files. See
/// `docs/history-search-export.md`.
struct HistorySearchQuery: Equatable, Sendable {

    /// The phrase with surrounding whitespace removed. Empty means "no search",
    /// and every caller treats that as the unfiltered list rather than as a
    /// query that matches nothing.
    let text: String

    /// The provenance kinds whose user-facing label the phrase names.
    ///
    /// Matched against what the card says (`label`, `accessibilityLabel`) rather
    /// than against the persisted raw value, because the raw value is a storage
    /// detail the user has never seen: typing "voice edit" has to find a
    /// `selectionEdit` row.
    ///
    /// Named for what it holds rather than after the column it is compared
    /// against, deliberately: `HistoryProvenancePrivacyTests` scans every source
    /// outside `RecordingProvenance` for the column names, and that scan is
    /// blunt on purpose. Nothing here writes a column - the kinds go into a
    /// `WHERE`, and only `RecordingProvenance` decides what a row stores.
    let matchedKinds: Set<RecordingProvenanceKind>

    /// Whether the phrase names the label rows with no provenance stored are
    /// shown under ("Older recording"). Its own flag because those rows hold
    /// NULL, and an `IN (…)` test is false for NULL in SQL - the same rule
    /// `HistoryProvenanceFilter.includesUnrecorded` exists for.
    let matchesUnrecordedProvenance: Bool

    /// The span of time the phrase reads as, or nil when it does not read as one.
    ///
    /// A day, a month or a year - never an instant, because nobody types a
    /// timestamp to the second and a search that demanded one would find
    /// nothing.
    let dateInterval: DateInterval?

    /// Whether this query selects nothing and the caller should show the whole
    /// list.
    var isEmpty: Bool { text.isEmpty }

    /// Resolves a typed phrase.
    ///
    /// `now`, `calendar` and `locale` are injected so a test can state what a
    /// phrase means without waiting for the clock or inheriting the developer's
    /// region.
    init(
        _ raw: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed

        guard !trimmed.isEmpty else {
            matchedKinds = []
            matchesUnrecordedProvenance = false
            dateInterval = nil
            return
        }

        var kinds: Set<RecordingProvenanceKind> = []
        for kind in RecordingProvenanceKind.allCases
        where Self.namesLabel(trimmed, of: kind) {
            kinds.insert(kind)
        }
        matchedKinds = kinds
        // `.unknown` is both a stored kind and the label every row written
        // before provenance existed is shown under, so naming it has to reach
        // both.
        matchesUnrecordedProvenance = kinds.contains(.unknown)
        dateInterval = HistoryDatePhrase.interval(
            for: trimmed, now: now, calendar: calendar, locale: locale)
    }

    /// Whether the phrase appears in any of the strings this kind is shown as.
    ///
    /// Substring rather than equality, so "youtube" finds both command outcomes
    /// and "edit" finds a voice edit - the same forgiveness the transcript match
    /// already gives. Diacritic-insensitive as well as case-insensitive, because
    /// the transcript match is, and a search that treated the badge more
    /// strictly than the words would be a difference the user cannot see.
    private static func namesLabel(_ phrase: String, of kind: RecordingProvenanceKind) -> Bool {
        [kind.label, kind.accessibilityLabel].contains { candidate in
            candidate.range(
                of: phrase, options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}

// MARK: - Dates

/// The phrases the history search reads as a span of time.
///
/// Deliberately a short, closed list rather than a natural-language parser. Two
/// of its entries are the formats the card itself prints - the footer's medium
/// date ("Sep 4, 2026") and the region's own short date ("9/4/26") - and the
/// rest are the unambiguous ones a person types into a search field: a year, a
/// year and month, or an ISO day. Anything else is left to the text match, which
/// is the honest outcome: a query this cannot read is not a date, and inventing
/// a range for it would quietly hide every row the words would have found.
///
/// Nothing here is relative. "Yesterday" is a word whose meaning depends on the
/// user's locale as much as on the clock, and a wrong guess about it would move
/// a search a day without saying so.
enum HistoryDatePhrase {

    /// The span a phrase names, or nil when it names none.
    static func interval(
        for phrase: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> DateInterval? {
        var calendar = calendar
        calendar.locale = locale

        if let day = parse(phrase, format: "yyyy-MM-dd", calendar: calendar, locale: locale) {
            return calendar.dateInterval(of: .day, for: day)
        }
        if let month = parse(phrase, format: "yyyy-MM", calendar: calendar, locale: locale) {
            return calendar.dateInterval(of: .month, for: month)
        }
        if let year = parseYear(phrase, calendar: calendar, now: now) {
            return year
        }
        for style in [DateFormatter.Style.medium, .short, .long] {
            if let day = parseLocalized(phrase, style: style, calendar: calendar, locale: locale) {
                return calendar.dateInterval(of: .day, for: day)
            }
        }
        return nil
    }

    /// A bare four-digit year.
    ///
    /// Bounded so a transcript full of numbers cannot turn into a date search:
    /// only years within a century either side of the present are read as one,
    /// which leaves "1080" and "2500" as the ordinary words they are.
    private static func parseYear(
        _ phrase: String, calendar: Calendar, now: Date
    ) -> DateInterval? {
        guard phrase.count == 4, let year = Int(phrase) else { return nil }
        let thisYear = calendar.component(.year, from: now)
        guard abs(year - thisYear) <= 100 else { return nil }
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let interval = calendar.dateInterval(of: .year, for: start)
        else { return nil }
        return interval
    }

    private static func parse(
        _ phrase: String, format: String, calendar: Calendar, locale: Locale
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // A fixed format is a machine format, so it is read with a fixed locale
        // - `en_US_POSIX` is what keeps "2026-09-04" meaning that day in every
        // region rather than being reinterpreted by a non-Gregorian calendar.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter.date(from: phrase)
    }

    private static func parseLocalized(
        _ phrase: String, style: DateFormatter.Style, calendar: Calendar, locale: Locale
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = style
        formatter.timeStyle = .none
        formatter.isLenient = false
        return formatter.date(from: phrase)
    }
}
