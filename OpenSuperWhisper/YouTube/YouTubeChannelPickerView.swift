import SwiftUI

/// The channel picker's card: what was heard, a box to narrow the list with, and
/// the user's own channels.
///
/// It draws what `YouTubeChannelPickerViewModel` decides and decides nothing
/// itself - including which key does what, which is the view model's so it can
/// be tested without a window. The keys reach it through
/// `YouTubeChannelPickerWindowController`.
///
/// The list can only ever contain channels the user typed into Settings. There
/// is no field here that names a channel, no place to paste a URL and nothing
/// that searches: the recovery this panel offers is *choosing*, and choosing
/// from a fixed list is what keeps the allowlist the allowlist.
struct YouTubeChannelPickerView: View {

    // MARK: - Geometry

    /// Geometry shared with the window controller. The window is larger than the
    /// card because the card draws its own shadow - the same constraint
    /// `AskPanelView` documents.
    ///
    /// The card's height follows **how many channels the user has**, which is
    /// the one thing about this panel that is not the same for everybody: a
    /// fixed height sized for a long list leaves somebody with two channels
    /// looking at a card that is mostly empty. Everything but the list is pinned
    /// to an explicit height, so the total is arithmetic rather than a
    /// measurement - a hosting view left to size itself shrinks the window to
    /// the card and the window bounds then clip the shadow.
    ///
    /// It is computed from the channels the panel was *given*, not from the rows
    /// currently on screen, so typing in the filter narrows the list without the
    /// window resizing under the user's hands.
    static let cardWidth: CGFloat = 420
    static let shadowMargin: CGFloat = 24

    /// Every row is the same height, which a keyboard list wants anyway: it is
    /// what makes "one press moves one row" true in pixels as well as in the
    /// model, and what lets the card's height be arithmetic.
    static let rowHeight: CGFloat = 40
    static let listPadding: CGFloat = 8
    /// Room for two rows even with one channel, so the "nothing matches" message
    /// has somewhere to be and the card does not become a strip.
    static let minimumRows = 2
    /// Past this the list scrolls. Six rows is about as far as the eye reads
    /// down a list without losing the top of it.
    static let maximumRows = 6

    /// Header, filter box, action row and the three dividers between them. Each
    /// is pinned to this height in the layout below.
    static let headerHeight: CGFloat = 118
    static let filterHeight: CGFloat = 38
    static let actionsHeight: CGFloat = 48
    static let chromeHeight = headerHeight + filterHeight + actionsHeight + 3

    static func listHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, minimumRows), maximumRows)
        return CGFloat(rows) * rowHeight + listPadding * 2
    }

    static func cardSize(rowCount: Int) -> CGSize {
        CGSize(width: cardWidth, height: chromeHeight + listHeight(rowCount: rowCount))
    }

    static func windowSize(rowCount: Int) -> CGSize {
        let card = cardSize(rowCount: rowCount)
        return CGSize(
            width: card.width + shadowMargin * 2,
            height: card.height + shadowMargin * 2
        )
    }

    private var cardSize: CGSize { Self.cardSize(rowCount: viewModel.request.suggestions.count) }
    private var windowSize: CGSize {
        Self.windowSize(rowCount: viewModel.request.suggestions.count)
    }

    @ObservedObject var viewModel: YouTubeChannelPickerViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        card
            .frame(width: cardSize.width, height: cardSize.height)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Material.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.22),
                        radius: 18,
                        y: 6
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(width: windowSize.width, height: windowSize.height)
            .accessibilityIdentifier(YouTubeChannelPickerAccessibility.panel)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Choose a YouTube channel")
            .onAppear { isFieldFocused = true }
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            filter
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            actions
        }
    }

    // MARK: - Header

    /// What was heard, said back verbatim.
    ///
    /// The single most useful thing on this card: a user whose command opened
    /// nothing usually cannot tell whether the engine misheard them or their
    /// list is missing a spelling, and the phrase in quotation marks answers
    /// that before they read anything else.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("YouTube channel")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("Nothing opened yet")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    }
            }

            Text("Heard “\(viewModel.request.spokenName)”")
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityIdentifier(YouTubeChannelPickerAccessibility.heardPhrase)
                .accessibilityLabel("Heard \(viewModel.request.spokenName)")

            // Three lines is the pinned height the card's arithmetic assumes,
            // and enough for the longest of these sentences - the ambiguous one,
            // which names the rows that collided.
            Text(viewModel.request.prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(YouTubeChannelPickerAccessibility.prompt)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: Self.headerHeight)
    }

    // MARK: - Type to filter

    private var filter: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Filter your channels", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFieldFocused)
                .accessibilityIdentifier(YouTubeChannelPickerAccessibility.filterField)
                .accessibilityLabel("Filter your channels")
                .accessibilityHint("Up and down arrows move through the list, Return opens the highlighted channel, Escape opens nothing.")
        }
        .padding(.horizontal, 16)
        .frame(height: Self.filterHeight)
    }

    // MARK: - The list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, at: index)
                            .id(row.id)
                    }
                    if let message = viewModel.emptyMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                            .accessibilityIdentifier(
                                YouTubeChannelPickerAccessibility.emptyMessage)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, Self.listPadding)
            }
            // The arrow keys are the primary way through this list, so the
            // highlighted row has to come to the user rather than the other way
            // round - a keyboard-first picker that scrolls only on a drag is one
            // whose selection can be somewhere the user cannot see.
            .onChange(of: viewModel.highlighted) { _, highlighted in
                guard let highlighted, viewModel.rows.indices.contains(highlighted) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.rows[highlighted].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(YouTubeChannelPickerAccessibility.list)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your YouTube channels")
    }

    private func rowView(_ row: YouTubeChannelSuggestion, at index: Int) -> some View {
        let isHighlighted = viewModel.highlighted == index
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.channel.displayName)
                    .font(.system(size: 13, weight: isHighlighted ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = subtitle(for: row) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // A hint beside a row the user still has to choose, never a
            // decision: the ranking put this row first and a keystroke is what
            // makes it the answer.
            if row.isSuggested && viewModel.query.isEmpty {
                Text("Closest match")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule(style: .continuous).fill(Color.accentColor.opacity(0.12))
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight - 2, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.choose(row.channel) }
        .onHover { hovering in
            guard hovering else { return }
            viewModel.highlight(index)
        }
        .accessibilityIdentifier(YouTubeChannelPickerAccessibility.row(row.channel))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { viewModel.choose(row.channel) }
    }

    /// The second line of a row: the stored spelling that is closest to the
    /// phrase, when it is not the display name already on the first line.
    private func subtitle(for row: YouTubeChannelSuggestion) -> String? {
        let matched = row.matchedSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matched.isEmpty, matched != row.channel.displayName else { return nil }
        return "Also said as “\(matched)”"
    }

    private func accessibilityLabel(for row: YouTubeChannelSuggestion) -> String {
        var label = row.channel.displayName
        if let subtitle = subtitle(for: row) { label += ", \(subtitle)" }
        if row.isSuggested && viewModel.query.isEmpty { label += ", closest match" }
        return label
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Text("↑↓ to move · Return to open · Esc to cancel")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Cancel") { viewModel.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(YouTubeChannelPickerAccessibility.cancelButton)
            Button("Open") { viewModel.commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.highlightedChannel == nil)
                .accessibilityIdentifier(YouTubeChannelPickerAccessibility.openButton)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.actionsHeight)
    }
}
