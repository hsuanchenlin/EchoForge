import Foundation
import SwiftUI

/// Everything the channel picker *decides*: what is listed, what is highlighted,
/// and what each key does.
///
/// Separated from the panel the way `AskPanelViewModel` is, and for the same
/// reason: the half that matters here is keyboard behaviour, and keyboard
/// behaviour tested through a real window is keyboard behaviour that is only
/// tested on a machine with a window server and the focus in the right place.
/// Every key the picker answers to is a method on this type.
///
/// It can produce exactly one kind of answer - one of the `YouTubeChannel`
/// values it was given - or nothing. There is no path from anything typed into
/// the filter field to a channel that was not in `request.suggestions`, which is
/// the allowlist rule restated at the last surface that touches it.
@MainActor
final class YouTubeChannelPickerViewModel: ObservableObject {

    /// What was heard and what may be chosen. Fixed for the life of the panel.
    let request: YouTubeChannelPickerRequest

    /// What the user has typed to narrow the list.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refresh()
        }
    }

    /// The rows on screen, in order.
    @Published private(set) var rows: [YouTubeChannelSuggestion] = []

    /// Which row Return would choose, or nil when the filter matches nothing.
    ///
    /// An index into `rows` rather than a channel id, because it is a position
    /// in a list the arrow keys move through - and it is republished on every
    /// change to that list, so it can never point past the end.
    @Published private(set) var highlighted: Int?

    /// Called with the user's choice, or with nil when they cancelled. Set by
    /// whoever presented the panel; invoked exactly once.
    var onFinish: ((YouTubeChannel?) -> Void)?

    private var hasFinished = false

    init(request: YouTubeChannelPickerRequest) {
        self.request = request
        rows = request.suggestions
        highlighted = request.suggestions.isEmpty ? nil : request.initialHighlight
    }

    /// The channel Return would open right now, or nil when nothing is
    /// highlighted.
    var highlightedChannel: YouTubeChannel? {
        guard let highlighted, rows.indices.contains(highlighted) else { return nil }
        return rows[highlighted].channel
    }

    /// What the list says when the filter matches nothing.
    ///
    /// A sentence rather than an empty box: the user is looking at their own
    /// list and has just made it disappear, and "nothing here matches what you
    /// typed" is the only reading of that which does not look like a bug.
    var emptyMessage: String? {
        guard rows.isEmpty else { return nil }
        return "None of your channels match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. Clear the box to see them all."
    }

    // MARK: - Keys

    /// Down arrow. Wraps to the top, the way every list in macOS does.
    func highlightNext() { moveHighlight(by: 1) }

    /// Up arrow.
    func highlightPrevious() { moveHighlight(by: -1) }

    /// Points at a row directly, which is what a click and a VoiceOver focus
    /// both do. Out-of-range is ignored rather than clamped: a caller asking for
    /// a row that is not there has a stale list, and moving the highlight
    /// somewhere it did not ask for would be worse than leaving it.
    func highlight(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        highlighted = index
    }

    private func moveHighlight(by offset: Int) {
        guard !rows.isEmpty else {
            highlighted = nil
            return
        }
        guard let current = highlighted else {
            highlighted = offset > 0 ? 0 : rows.count - 1
            return
        }
        let next = (current + offset + rows.count) % rows.count
        highlighted = next
    }

    /// Return. Opens the highlighted channel, or does nothing when the filter
    /// left no row to open - a Return that opened *something* out of an empty
    /// list is the one thing this panel must never do.
    func commit() {
        guard let channel = highlightedChannel else { return }
        finish(with: channel)
    }

    /// Chooses one row directly - a double-click, or Return on a focused row.
    /// The channel must be one of the ones offered; anything else is ignored.
    func choose(_ channel: YouTubeChannel) {
        guard rows.contains(where: { $0.channel == channel })
            || request.suggestions.contains(where: { $0.channel == channel })
        else { return }
        finish(with: channel)
    }

    /// Escape, a click outside, or the window closing. Opens nothing.
    func cancel() { finish(with: nil) }

    private func finish(with channel: YouTubeChannel?) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish?(channel)
    }

    // MARK: - The list

    private func refresh() {
        // Which row was highlighted is kept across a keystroke where it can be:
        // typing another letter should not move the selection off the row the
        // user was already on if that row is still listed.
        let previous = highlightedChannel
        rows = YouTubeChannelSuggestions.filter(request.suggestions, matching: query)
        if let previous, let index = rows.firstIndex(where: { $0.channel == previous }) {
            highlighted = index
        } else {
            highlighted = rows.isEmpty ? nil : 0
        }
    }
}

/// The accessibility identifiers the picker's elements carry.
///
/// Named in one place so a UI test and the view cannot drift apart, and so the
/// strings are greppable from either side. They are identifiers rather than
/// labels: what VoiceOver reads is built from the channel's own name.
enum YouTubeChannelPickerAccessibility {
    static let panel = "youtube.channel.picker"
    static let heardPhrase = "youtube.channel.picker.heard"
    static let prompt = "youtube.channel.picker.prompt"
    static let filterField = "youtube.channel.picker.filter"
    static let list = "youtube.channel.picker.list"
    static let emptyMessage = "youtube.channel.picker.empty"
    static let cancelButton = "youtube.channel.picker.cancel"
    static let openButton = "youtube.channel.picker.open"

    /// One row's identifier, which a test uses to find a specific channel.
    static func row(_ channel: YouTubeChannel) -> String {
        "youtube.channel.picker.row.\(channel.id.uuidString)"
    }
}
