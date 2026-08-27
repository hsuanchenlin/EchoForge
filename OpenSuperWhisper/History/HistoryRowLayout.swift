import SwiftUI

/// How wide the history list is, as the only two answers a row's layout has.
///
/// A history row carries four independent things - what produced it, when, how
/// long it was, and the words themselves - plus a bar of actions. At the width
/// the window opens at there is no room to put those on one line, and at the
/// width a user drags it to there is far too much room to keep stacking them.
/// So the row has two layouts and this is the value that picks between them.
///
/// It is a tier rather than a set of continuous measurements on purpose: two
/// layouts can each be designed, rendered and asserted on, where a formula over
/// the width can only be eyeballed. `HistoryRowLayoutTests` pins the threshold
/// and `HistoryRowRenderTests` draws both sides of it.
enum HistoryWidthTier: String, CaseIterable, Sendable {
    /// The window at or near the minimum `ContentView` allows (400 pt), and any
    /// narrower list inside it. Metadata stacks under the label, the transcript
    /// takes the full width, and the actions collapse into their own bar.
    case compact
    /// Anything the user has widened. Metadata sits inline beside the label as
    /// chips and the actions align to the trailing edge of the footer.
    case regular

    /// The one threshold in the feature, in points of *list* width - what a row
    /// is actually offered, not what the window measures.
    ///
    /// 480 pt is where the badge, a relative timestamp and a duration pill stop
    /// fitting on one line together at the largest dynamic type this row is
    /// designed for; below it they are stacked rather than truncated, because a
    /// truncated timestamp tells the user nothing at all.
    static let regularMinimumWidth: CGFloat = 480

    init(width: CGFloat) {
        self = width >= Self.regularMinimumWidth ? .regular : .compact
    }
}

/// Every measurement that differs by tier, in one value.
///
/// Deliberately a plain `struct` of numbers and booleans rather than a set of
/// `if tier == .compact` branches scattered through the view: the row asks this
/// for a tier-dependent number, and a test asks it for the same number. Fixed
/// measurements shared by both tiers stay with the component they style.
struct HistoryRowMetrics: Equatable, Sendable {
    let tier: HistoryWidthTier

    /// Inset from the card's edge to its content.
    let horizontalPadding: CGFloat
    /// Inset from the card's top and bottom edges to its content.
    let verticalPadding: CGFloat
    /// The card's corner radius.
    let cornerRadius: CGFloat
    /// Gap between the row's stacked sections (header, body, footer).
    let sectionSpacing: CGFloat
    /// Gap between the quick-action buttons.
    let actionSpacing: CGFloat
    /// Point size of a quick-action glyph.
    let actionIconSize: CGFloat
    /// Edge length of a quick-action's hit target. Never below 24 pt, which is
    /// the smallest square a pointer can be expected to land on.
    let actionHitTarget: CGFloat

    /// Whether the timestamp and duration chips stack under the provenance
    /// badge (compact) or sit inline beside it (regular).
    let stacksMetadata: Bool
    /// Whether the quick actions may drop to a bar of their own under the
    /// footer when the footer cannot hold them beside the timestamp.
    ///
    /// Only the compact tier does. At a width where the footer already carries
    /// a timestamp and, mid-regeneration, a progress strip, four buttons are
    /// what pushes it over - and a wrapped bar is the one arrangement that
    /// neither truncates the timestamp nor runs the buttons off the edge. The
    /// regular tier has the room, so its actions always stay on the footer row
    /// where the eye expects them.
    let wrapsActionBarWhenTight: Bool
    /// Whether the footer states the date in full. The compact tier leans on
    /// the relative chip in the header and shows only the clock time, because a
    /// full date and a relative phrase saying the same thing twice is what ate
    /// the width in the first place.
    let showsFullDateInFooter: Bool

    static let compact = HistoryRowMetrics(
        tier: .compact,
        horizontalPadding: 12,
        verticalPadding: 10,
        cornerRadius: 12,
        sectionSpacing: 8,
        actionSpacing: 4,
        actionIconSize: 13,
        actionHitTarget: 26,
        stacksMetadata: true,
        wrapsActionBarWhenTight: true,
        showsFullDateInFooter: false
    )

    static let regular = HistoryRowMetrics(
        tier: .regular,
        horizontalPadding: 16,
        verticalPadding: 14,
        cornerRadius: 14,
        sectionSpacing: 10,
        actionSpacing: 6,
        actionIconSize: 14,
        actionHitTarget: 28,
        stacksMetadata: false,
        wrapsActionBarWhenTight: false,
        showsFullDateInFooter: true
    )

    static func metrics(for tier: HistoryWidthTier) -> HistoryRowMetrics {
        switch tier {
        case .compact: return .compact
        case .regular: return .regular
        }
    }

    /// The metrics for a list of this width, in one step.
    init(width: CGFloat) {
        self = Self.metrics(for: HistoryWidthTier(width: width))
    }

    private init(
        tier: HistoryWidthTier,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        cornerRadius: CGFloat,
        sectionSpacing: CGFloat,
        actionSpacing: CGFloat,
        actionIconSize: CGFloat,
        actionHitTarget: CGFloat,
        stacksMetadata: Bool,
        wrapsActionBarWhenTight: Bool,
        showsFullDateInFooter: Bool
    ) {
        self.tier = tier
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
        self.sectionSpacing = sectionSpacing
        self.actionSpacing = actionSpacing
        self.actionIconSize = actionIconSize
        self.actionHitTarget = actionHitTarget
        self.stacksMetadata = stacksMetadata
        self.wrapsActionBarWhenTight = wrapsActionBarWhenTight
        self.showsFullDateInFooter = showsFullDateInFooter
    }
}

// MARK: - Reaching the rows

private struct HistoryRowMetricsKey: EnvironmentKey {
    /// The window's own minimum, so a row rendered outside the list - a
    /// preview, a test - lays itself out the way the narrowest real one does.
    static let defaultValue = HistoryRowMetrics.compact
}

extension EnvironmentValues {
    var historyRowMetrics: HistoryRowMetrics {
        get { self[HistoryRowMetricsKey.self] }
        set { self[HistoryRowMetricsKey.self] = newValue }
    }
}

/// The width of the list, measured once at the list and published to every row.
///
/// Measured *here* rather than in each row because a `GeometryReader` inside a
/// `LazyVStack` row reports the width its own height ends up depending on, and
/// a row whose height feeds back into its layout is how a history list starts
/// jittering as it scrolls. One reader above the list has no such loop.
private struct HistoryListWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reads this container's width and hands every row inside it the metrics
    /// for that width.
    func historyRowMetricsForContainerWidth() -> some View {
        modifier(HistoryRowMetricsReader())
    }
}

private struct HistoryRowMetricsReader: ViewModifier {
    @State private var tier: HistoryWidthTier = .compact

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HistoryListWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(HistoryListWidthKey.self) { width in
                let next = HistoryWidthTier(width: width)
                guard next != tier else { return }
                tier = next
            }
            .environment(\.historyRowMetrics, HistoryRowMetrics.metrics(for: tier))
    }
}

// MARK: - Timestamps

/// The two ways a row states when it happened.
///
/// Both are pure functions of a date and a "now" so a test can state what the
/// row says without waiting for the clock, and both are locale-formatted rather
/// than hand-assembled.
enum HistoryTimestamp {
    /// The short phrase in the header chip - "2 min ago", "yesterday".
    ///
    /// Anything inside a minute reads as "Just now": `RelativeDateTimeFormatter`
    /// answers "in 0 seconds" for a recording that finished a moment ago, which
    /// is both wrong about the direction and wrong about the tense.
    static func relative(for date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0, elapsed < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The exact moment, for the footer. Today's recordings drop the date,
    /// because a list where every row repeats today's date is a list where the
    /// date is noise.
    static func absolute(
        for date: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

// MARK: - Actions

/// The four things a history row can do to itself, as a decision separate from
/// the buttons that carry it.
///
/// Which actions a row offers depends only on its status, and getting that
/// wrong is not a cosmetic bug: a play button on a recording that has not been
/// written yet, or a missing delete on a row stuck in the queue, is the user
/// unable to get out of a state. So the decision is a pure function here, and
/// `RecordingRow` reads it twice - once to draw the hover bar, once to register
/// the same actions with VoiceOver, which has no pointer to hover with.
enum HistoryRowActionKind: String, CaseIterable, Sendable {
    case play
    case copy
    case regenerate
    case delete

    /// What a row in this state offers, in the order the bar draws them.
    ///
    /// A row that is still queued or running has no audio to play and no
    /// transcript to copy, and a row that failed has no audio worth playing -
    /// but both keep delete, which is the way out, and a failed row keeps
    /// regenerate, which is the way forward. `DictationFailureOutcome` keeps
    /// the recording precisely so that second press is possible.
    static func available(for status: RecordingStatus) -> [HistoryRowActionKind] {
        switch status {
        case .pending, .converting, .transcribing:
            return [.delete]
        case .failed:
            return [.regenerate, .delete]
        case .completed:
            return [.play, .copy, .regenerate, .delete]
        }
    }

    /// The VoiceOver label and the tooltip, which are deliberately the same
    /// string: what a pointer user is told on hover is what a VoiceOver user is
    /// told on focus.
    func label(isPlaying: Bool) -> String {
        switch self {
        case .play: return isPlaying ? "Stop playback" : "Play audio"
        case .copy: return "Copy transcription"
        case .regenerate: return "Regenerate transcription"
        case .delete: return "Delete recording"
        }
    }

    func symbolName(isPlaying: Bool) -> String {
        switch self {
        case .play: return isPlaying ? "stop.fill" : "play.fill"
        case .copy: return "doc.on.doc"
        case .regenerate: return "arrow.clockwise"
        case .delete: return "trash"
        }
    }

    /// Whether the action destroys something, which is what colours it under
    /// the pointer. Never the only signal - the label says it in words.
    var isDestructive: Bool { self == .delete }
}
