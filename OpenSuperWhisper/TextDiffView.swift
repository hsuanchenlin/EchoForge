import SwiftUI

/// One transcript rendered against what a later stage made of it: the words
/// that were dropped are struck through and muted, everything else reads as the
/// text the user actually got.
///
/// The comparison itself is `TextDiffUtil`; this is only its styling, kept in
/// one place because the Settings preview and the history row must not drift
/// into showing the same thing two different ways.
struct TextDiffView: View {
    let segments: [TextDiffSegment]
    var font: Font = .system(size: 12)

    init(segments: [TextDiffSegment], font: Font = .system(size: 12)) {
        self.segments = segments
        self.font = font
    }

    /// Compares the two texts as the view is created.
    ///
    /// Convenient where the pair changes about as often as the view does. A
    /// list row is not that: it rebuilds on hover, and comparing a long
    /// transcript every time would be felt. Those callers compare once and pass
    /// ``segments``.
    init(original: String, revised: String, font: Font = .system(size: 12)) {
        self.init(
            segments: TextDiffUtil.compare(original: original, revised: revised), font: font
        )
    }

    var body: some View {
        Text(Self.attributedText(for: segments))
            .font(font)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The segments as one styled string.
    ///
    /// One attributed string rather than a stack of views so the comparison
    /// wraps as a paragraph - a removed word has to sit inline where it was
    /// said, not on a line of its own.
    static func attributedText(for segments: [TextDiffSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .removed:
                piece.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid)
                piece.swiftUI.foregroundColor = .secondary
            case .unchanged, .inserted:
                // Insertions read normally on purpose: what the style added is
                // part of the result the user is judging, and marking that up
                // as well would leave nothing on the row rendered plainly.
                piece.swiftUI.foregroundColor = .primary
            }
            result.append(piece)
        }
        return result
    }
}

/// The one sentence that makes a comparison legible to someone seeing it for
/// the first time.
struct TextDiffLegend: View {
    var body: some View {
        // Deliberately says "post-processing" rather than naming the rewrite:
        // the same comparison is shown in history, where the difference can
        // just as easily be the terms dictionary or CJK spacing.
        Label("Struck-through words were dropped or replaced by post-processing.",
              systemImage: "strikethrough")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
