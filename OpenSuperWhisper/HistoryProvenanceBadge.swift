import SwiftUI

/// The pill at the top of a history row saying what produced it, and - for a
/// YouTube command - the sentence saying what became of it.
///
/// It is on **every** row, including ordinary dictation, and that is the point:
/// a label that appeared only on the interesting rows would leave the user
/// reading the absence of one, which is exactly the ambiguity this exists to
/// remove. See `docs/history-provenance.md`.
///
/// The refusal sentence is not behind a disclosure. A command that opened
/// nothing is the one row somebody came to History to read, and one more click
/// between them and the reason is the whole difference between a history and a
/// diagnosis.
struct HistoryProvenanceBadge: View {
    let provenance: RecordingProvenance
    /// Whether the sentence under the pill is drawn here.
    ///
    /// The history row now places that sentence itself, full width, under a
    /// header the pill shares with the metadata chips - a detail wrapping
    /// inside the pill's own column would be squeezed into whatever the chips
    /// left over. Everything else showing a badge still gets both halves, so
    /// this defaults to on and the pill remains complete on its own.
    var showsDetail: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: provenance.kind.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(provenance.kind.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(provenance.kind.accessibilityLabel)

            if showsDetail, let detail = provenance.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// Colour carries the same distinction the symbol does, never on its own:
    /// the two command outcomes already differ in shape and in wording, so a
    /// reader who sees no colour loses nothing.
    private var tint: Color {
        switch provenance.kind {
        case .youTubeCommandOpened: return .green
        case .youTubeCommandNotOpened: return .orange
        case .ask: return ThemePalette.iconAccent(colorScheme)
        case .dictation, .fileTranscription, .unknown: return .secondary
        }
    }
}

/// The control above the history list.
///
/// A menu rather than a segmented row because there are seven choices and the
/// window is 450 pt wide; the current choice is in the label, so the filter is
/// legible without opening it - a list that is silently filtered is a list that
/// looks empty for no reason.
struct HistoryProvenanceFilterMenu: View {
    @Binding var selection: HistoryProvenanceFilter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            ForEach(HistoryProvenanceFilter.allCases) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                Text(selection.menuLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundColor(selection == .all ? .secondary : ThemePalette.iconAccent(colorScheme))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only one kind of history entry")
        .accessibilityLabel("Filter history by kind")
        .accessibilityValue(selection.title)
    }
}
