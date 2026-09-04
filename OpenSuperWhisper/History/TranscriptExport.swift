import Foundation
import UniformTypeIdentifiers

/// One history row, written out as a document the user keeps.
///
/// History is the app's only durable surface, and until now the only way out of
/// it was the clipboard - which carries the words and loses every answer the
/// card gives about them: when it was said, what produced it, and what the
/// engine heard before post-processing. This turns a card into a file that
/// carries all four.
///
/// It is a **pure serialiser** and deliberately nothing else. It opens no panel,
/// touches no disk and reads no preference; `TranscriptExportCoordinator` does
/// all three. That split is what lets every rule below - what is included, what
/// is never included, how a transcript full of Markdown syntax is written - be
/// asserted without a file system.
///
/// Two rules carry what it writes. The document states **only what the card
/// already states**: the transcript, the original behind "Show original", the
/// timestamp in the footer, the provenance badge and its sentence, the duration
/// chip and the "AI Polished" chip. It never writes the row's `id`, its
/// `fileName`, the absolute `sourceFileURL` path, or anything else the user has
/// not been shown - a file the user is about to mail to somebody must not carry
/// the layout of their disk. And it writes the transcript **verbatim**: a
/// fenced block rather than escaped prose, so a dictation containing `#`, `*`,
/// `|` or a line of its own dashes comes back out of a Markdown reader as the
/// words that were said. See `docs/history-search-export.md`.
enum TranscriptExport {

    /// The formats a row can be written as.
    ///
    /// Markdown is the default because the card's own answers are structured -
    /// a heading, a handful of named fields and a body - and Markdown is the
    /// plainest way to keep that structure legible in a text editor. Plain text
    /// exists for the same reason the app pastes plain text: some destinations
    /// have no reader.
    enum Format: String, CaseIterable, Sendable {
        case markdown
        case plainText

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .plainText: return .plainText
            }
        }

        /// What the save panel's format control calls this.
        var label: String {
            switch self {
            case .markdown: return "Markdown (.md)"
            case .plainText: return "Plain Text (.txt)"
            }
        }
    }

    /// Everything about one row that a document may state.
    ///
    /// Built from a `Recording` in one place (`init(recording:now:calendar:)`)
    /// so the "only what the card shows" rule is a property of one initialiser
    /// rather than a habit spread across two serialisers - and so a test can
    /// state a document's contents without a database.
    struct Document: Equatable, Sendable {
        /// The words the row shows. Never empty in an exportable row.
        let transcript: String
        /// What the engine heard, when post-processing changed it - the same
        /// value the card's "Show original" disclosure holds, and nil when the
        /// card has no such disclosure.
        let original: String?
        /// The moment, spelled out in full. The footer abbreviates today's date
        /// away; a file that is going to outlive today must not.
        let timestamp: String
        /// The badge's label.
        let provenance: String
        /// The sentence under the badge, when there is one.
        ///
        /// Named for what it is rather than after the column it came from:
        /// `HistoryProvenancePrivacyTests` scans every source outside
        /// `RecordingProvenance` for the column names, and it is blunt on
        /// purpose. This value is read *through* `RecordingProvenance.detail`,
        /// which is exactly what that rule asks for.
        let detail: String?
        /// The duration chip.
        let duration: String
        /// Whether the "AI Polished" chip is on the card.
        let wasCorrectedByAI: Bool
    }

    // MARK: - Building one

    /// Reads a row into the document it may become.
    ///
    /// Returns nil for a row with nothing to export - one still in the queue,
    /// one that failed, or a completed row whose "transcript" is the empty
    /// string the card draws as "No speech detected". The action bar offers
    /// export from the same rule (`HistoryRowActionKind.available`), so a press
    /// that reaches here always has words behind it; this is the second half of
    /// that guarantee rather than a duplicate of it, and it is what makes a
    /// missing transcript a refusal instead of an empty file.
    static func document(
        for recording: Recording,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> Document? {
        guard recording.status == .completed else { return nil }
        let transcript = recording.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }

        let original = recording.rawTranscription.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != transcript else { return nil }
            return trimmed
        }

        return Document(
            transcript: transcript,
            original: original,
            timestamp: fullTimestamp(for: recording.timestamp, calendar: calendar, locale: locale),
            provenance: recording.provenance.kind.label,
            detail: recording.provenance.detail,
            duration: TextUtil.formatDuration(recording.duration),
            wasCorrectedByAI: recording.wasCorrectedByAI
        )
    }

    /// The date, in full, in the user's own region.
    ///
    /// `.long` date and `.short` time rather than the footer's `.medium`,
    /// because the footer is read beside the row above it and a file is read on
    /// its own, months later, possibly by somebody else.
    static func fullTimestamp(
        for date: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Writing one

    static func text(for document: Document, format: Format) -> String {
        switch format {
        case .markdown: return markdown(for: document)
        case .plainText: return plainText(for: document)
        }
    }

    /// The Markdown document.
    ///
    /// The transcript sits in a fenced block rather than in prose, and that is
    /// the load-bearing decision: a dictation is arbitrary text, so it will
    /// eventually contain a `#`, a `*`, a `|` or a line of dashes, and prose
    /// would render those as somebody else's headings, emphasis and tables. A
    /// fence shows the words. The fence itself is grown past the longest run of
    /// backticks in the text, which is what keeps a dictation *about* code from
    /// closing it early.
    static func markdown(for document: Document) -> String {
        var lines: [String] = []
        lines.append("# Transcript")
        lines.append("")
        lines.append("- **Recorded:** \(document.timestamp)")
        lines.append("- **Duration:** \(document.duration)")
        lines.append("- **Source:** \(document.provenance)")
        if let detail = document.detail, !detail.isEmpty {
            lines.append("- **Details:** \(inlined(detail))")
        }
        if document.wasCorrectedByAI {
            lines.append("- **Fixed with AI:** yes")
        }
        lines.append("")
        lines.append(fenced(document.transcript))

        if let original = document.original {
            lines.append("")
            lines.append("## Original transcript")
            lines.append("")
            lines.append(
                "What the transcription engine heard, before post-processing.")
            lines.append("")
            lines.append(fenced(original))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The plain-text document: the same facts, as a short header and the words.
    static func plainText(for document: Document) -> String {
        var lines: [String] = []
        lines.append("Recorded: \(document.timestamp)")
        lines.append("Duration: \(document.duration)")
        lines.append("Source: \(document.provenance)")
        if let detail = document.detail, !detail.isEmpty {
            lines.append("Details: \(inlined(detail))")
        }
        if document.wasCorrectedByAI {
            lines.append("Fixed with AI: yes")
        }
        lines.append("")
        lines.append(document.transcript)

        if let original = document.original {
            lines.append("")
            lines.append("--- Original transcript ---")
            lines.append("")
            lines.append(original)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Wraps text in a fence long enough to survive whatever backticks are in it.
    private static func fenced(_ text: String) -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// Flattens a value written into a one-line list item.
    ///
    /// A provenance sentence is a sentence, but a stored one can carry a
    /// newline, and a bullet that ran onto a second line would leave the rest of
    /// it outside the list. Only the field lines are treated this way; the
    /// transcript keeps every line break it was said with.
    private static func inlined(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - Naming one

    /// The name the save panel opens with.
    ///
    /// Built from the row's date and its kind, in that order, because a folder
    /// of exported transcripts sorts usefully by name that way. Nothing in it
    /// comes from the transcript: the first words of a dictation are exactly the
    /// kind of thing a user would not want written on a file name that shows up
    /// in a Finder window behind them.
    static func suggestedFileName(
        for recording: Recording, format: Format, calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: recording.timestamp)
        let kind = recording.provenance.kind.label
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        let squeezed = kind.split(separator: " ").joined(separator: " ")
        return "\(stamp) \(squeezed).\(format.fileExtension)"
    }
}
