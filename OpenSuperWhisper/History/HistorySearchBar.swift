import SwiftUI

/// The one row above the history list: the search field, the way out of a
/// search, and the kind filter.
///
/// Its own view rather than a block inside `ContentView` for the reason
/// `SettingsTabBar` is its own control - the three things on this row share a
/// width, and a surface that can only be seen by launching an app with
/// microphone and Accessibility grants is a surface nobody checks. Here it can
/// be drawn headlessly and read back (`HistorySearchRenderTests`), the way every
/// other piece of History already is.
///
/// It decides nothing. The phrase it reports is resolved by `HistorySearchQuery`
/// and answered in SQL by `RecordingStore`; what this owns is the wording, the
/// keyboard route in, and the labels a reader who cannot see it is given.
struct HistorySearchBar: View {
    @Binding var text: String
    @Binding var filter: HistoryProvenanceFilter
    /// Empties the field and puts the whole list back. Passed in rather than
    /// done here, because clearing also has to cancel a debounce this view knows
    /// nothing about.
    let clear: () -> Void
    /// Focus for the field, owned by the view that hosts the ⌘F shortcut.
    var focus: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var colorScheme

    /// What the field says it searches.
    ///
    /// Three words rather than "Search in transcriptions", because the search
    /// reaches three things and a placeholder naming only the first is a
    /// promise the feature under-delivers on: a user who never learns they can
    /// type "voice edit" or a date has a filter and a word search and nothing
    /// between them. See `docs/history-search-export.md`.
    static let placeholder = "Search transcripts, dates and kinds"

    static let accessibilityLabel = "Search history"
    static let accessibilityHint =
        "Finds words in a transcript, a kind such as Voice edit, or a date such as 2026-09-04"
    static let help = "Search the words, the kind of recording, and the date. ⌘F moves here."
    static let clearLabel = "Clear the search"

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            TextField(Self.placeholder, text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .focused(focus)
                .accessibilityLabel(Self.accessibilityLabel)
                .accessibilityHint(Self.accessibilityHint)
                .help(Self.help)

            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help(Self.clearLabel)
                .accessibilityLabel(Self.clearLabel)
            }

            Divider()
                .frame(height: 16)

            HistoryProvenanceFilterMenu(selection: $filter)
        }
        .padding(10)
        .background(
            // ⌘F, with no menu bar to hang it on. A button rather than an
            // `onKeyPress`: a key equivalent works whatever has focus inside the
            // window, which is the point of the shortcut - a user reading the
            // list reaches search without touching the mouse. Hidden from
            // VoiceOver, which reaches the field itself directly.
            Button(Self.accessibilityLabel) { focus.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .background(ThemePalette.panelSurface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
        )
        .cornerRadius(20)
    }
}

/// What the list says when a search or a filter admits nothing.
///
/// Separate from the "no recordings yet" panel beside it, and that separation is
/// the point: a filtered list that is empty must say it is *filtered*. "No
/// recordings yet" over a history full of recordings is the app telling the user
/// something untrue.
///
/// It carries exactly one action, because there is exactly one thing to do about
/// it, and the field's own ⓧ is at the top of a window the reader is not looking
/// at.
struct HistoryNoResultsView: View {
    let query: String
    let filter: HistoryProvenanceFilter
    let clear: () -> Void

    /// The sentence under the heading.
    ///
    /// A pure function of the two things that can be narrowing the list, so a
    /// test can state what an empty list says without drawing one. The filtered
    /// case names the filter and how to leave it; the unfiltered one names the
    /// phrase and what else a phrase can be.
    static func message(query: String, filter: HistoryProvenanceFilter) -> String {
        guard filter != .all else {
            return "Nothing matches “\(query)”. Search the words, a kind such as Voice edit, "
                + "or a date such as 2026-09-04."
        }
        let matching = query.isEmpty ? "" : " match that search"
        return "No “\(filter.title)” entries\(matching). Choose All to see everything."
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
                .padding(.top, 40)
                .accessibilityHidden(true)

            Text("No results found")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(Self.message(query: query, filter: filter))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .fixedSize(horizontal: false, vertical: true)

            if !query.isEmpty {
                Button("Clear search", action: clear)
                    .buttonStyle(.link)
                    .accessibilityHint("Shows every recording again")
            }
        }
        .frame(maxWidth: .infinity)
    }
}
