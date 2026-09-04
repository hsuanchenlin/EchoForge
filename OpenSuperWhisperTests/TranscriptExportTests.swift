import XCTest

@testable import OpenSuperWhisper

/// What an Export press writes, and what it refuses to write.
///
/// The serialiser is pure, so all of this runs without a save panel or a disk.
/// The two halves it holds are the two ways this feature could hurt somebody: a
/// document that renders as something other than what was said, and a document
/// carrying something the user was never shown.
final class TranscriptExportTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let english = Locale(identifier: "en_US")

    // MARK: - What becomes a document

    func testACompletedRowWithWordsBecomesADocument() throws {
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: "Ship the release notes."),
            calendar: calendar, locale: english))

        XCTAssertEqual(document.transcript, "Ship the release notes.")
        XCTAssertEqual(document.provenance, "Dictation")
        XCTAssertNil(document.original)
        XCTAssertFalse(document.wasCorrectedByAI)
    }

    /// Missing transcript text is a refusal, not an empty file. The action bar
    /// applies the same rule on the way in; this is the other half of it.
    func testARowWithNoWordsIsRefusedRatherThanExportedEmpty() {
        for transcription in ["", "   ", "\n\n"] {
            XCTAssertNil(
                TranscriptExport.document(for: recording(transcription: transcription)),
                "“\(transcription)” is not a transcript to export")
        }
    }

    func testAnUnfinishedOrFailedRowIsRefused() {
        for status in [RecordingStatus.pending, .converting, .transcribing, .failed] {
            XCTAssertNil(
                TranscriptExport.document(
                    for: recording(transcription: "some words", status: status)),
                "\(status) has no finished transcript to export")
        }
    }

    /// The card's "Show original" disclosure is a fact about the row, so the
    /// file carries it - and carries it only when the card does.
    func testTheOriginalIsCarriedExactlyWhenTheCardShowsOne() throws {
        var restyled = recording(transcription: "Please review the pull request.")
        restyled.rawTranscription = "plz review the PR"
        let withOriginal = try XCTUnwrap(TranscriptExport.document(for: restyled))
        XCTAssertEqual(withOriginal.original, "plz review the PR")

        var identical = recording(transcription: "unchanged")
        identical.rawTranscription = "unchanged"
        XCTAssertNil(
            try XCTUnwrap(TranscriptExport.document(for: identical)).original,
            "A raw copy equal to the transcript is not an original the card shows.")

        var empty = recording(transcription: "words")
        empty.rawTranscription = ""
        XCTAssertNil(try XCTUnwrap(TranscriptExport.document(for: empty)).original)
    }

    func testTheProvenanceSentenceIsCarriedWhenTheBadgeHasOne() throws {
        var row = recording(transcription: "Vali101")
        row.provenance = .youTubeCommandNotOpened(
            reason: .channelUnknown,
            message: "No allowlisted YouTube channel answers to “Vali101”.")
        let document = try XCTUnwrap(TranscriptExport.document(for: row))

        XCTAssertEqual(document.provenance, "YouTube command - not opened")
        XCTAssertEqual(
            document.detail, "No allowlisted YouTube channel answers to “Vali101”.")
    }

    func testTheAIPolishedChipIsCarried() throws {
        var row = recording(transcription: "corrected words")
        row.aiCorrectedAt = Date(timeIntervalSince1970: 1_756_000_000)
        XCTAssertTrue(try XCTUnwrap(TranscriptExport.document(for: row)).wasCorrectedByAI)
    }

    // MARK: - Privacy

    /// The document states only what the card states. A file the user is about
    /// to mail to somebody must not carry the row's identifier, the internal
    /// audio file name, or the layout of their disk.
    func testTheDocumentCarriesNothingTheCardDoesNotShow() throws {
        var row = recording(transcription: "the interview")
        row = Recording(
            id: row.id, timestamp: row.timestamp,
            fileName: "2E7B1C90-DEAD-BEEF-1234-000000000000.wav",
            transcription: row.transcription, duration: row.duration, status: row.status,
            progress: row.progress,
            sourceFileURL: "/Users/someone/Documents/Confidential Client/interview.m4a")
        row.provenance = .fileTranscription

        let document = try XCTUnwrap(
            TranscriptExport.document(for: row, calendar: calendar, locale: english))

        for format in TranscriptExport.Format.allCases {
            let text = TranscriptExport.text(for: document, format: format)
            XCTAssertFalse(
                text.contains(row.id.uuidString), "\(format) leaked the row identifier")
            XCTAssertFalse(text.contains("DEAD-BEEF"), "\(format) leaked the audio file name")
            XCTAssertFalse(
                text.contains("/Users/someone"), "\(format) leaked a path on the user's disk")
            XCTAssertFalse(
                text.contains("Confidential Client"),
                "\(format) leaked a folder the card never showed")
        }
    }

    // MARK: - Markdown

    func testTheMarkdownCarriesEveryFactTheCardShows() throws {
        var row = recording(transcription: "Ship the release notes.")
        row.rawTranscription = "ship the release notes"
        row.aiCorrectedAt = Date(timeIntervalSince1970: 1_756_000_000)
        row.provenance = .selectionEdit(instruction: "make it shorter")

        let document = try XCTUnwrap(
            TranscriptExport.document(for: row, calendar: calendar, locale: english))
        let markdown = TranscriptExport.markdown(for: document)

        XCTAssertTrue(markdown.hasPrefix("# Transcript\n"))
        XCTAssertTrue(markdown.contains("- **Recorded:** "))
        XCTAssertTrue(markdown.contains("- **Source:** Voice edit"))
        XCTAssertTrue(markdown.contains("- **Details:** make it shorter"))
        XCTAssertTrue(markdown.contains("- **Fixed with AI:** yes"))
        XCTAssertTrue(markdown.contains("Ship the release notes."))
        XCTAssertTrue(markdown.contains("## Original transcript"))
        XCTAssertTrue(markdown.contains("ship the release notes"))
        XCTAssertTrue(markdown.hasSuffix("\n"))
    }

    func testAFieldWithNoValueLeavesNoEmptyLine() throws {
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: "plain"), calendar: calendar, locale: english))
        let markdown = TranscriptExport.markdown(for: document)

        XCTAssertFalse(markdown.contains("**Details:**"))
        XCTAssertFalse(markdown.contains("**Fixed with AI:**"))
        XCTAssertFalse(markdown.contains("## Original transcript"))
    }

    // MARK: - Special characters

    /// The load-bearing one. A dictation is arbitrary text, so it will
    /// eventually contain Markdown syntax - and a document that rendered those
    /// as somebody's headings, bullets and tables would be showing the user
    /// something other than what they said.
    func testMarkdownSyntaxInATranscriptStaysTheWordsThatWereSaid() throws {
        let spoken = "# Not a heading\n* not a bullet\n| a | table |\n--- \n**not bold** _or this_"
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: spoken), calendar: calendar, locale: english))
        let markdown = TranscriptExport.markdown(for: document)

        XCTAssertTrue(
            markdown.contains(spoken),
            "Every character the user said must survive verbatim.")
        // Inside a fence, so a reader shows them rather than interpreting them.
        let body = try XCTUnwrap(markdown.range(of: spoken))
        let before = markdown[markdown.startIndex..<body.lowerBound]
        XCTAssertTrue(before.contains("```text\n"), "The transcript must be fenced.")
    }

    /// A dictation about code contains backticks, and a three-backtick fence
    /// around a three-backtick run closes early - leaving the rest of the user's
    /// words outside the block and rendered as Markdown.
    func testAFenceGrowsPastTheBackticksInTheTranscript() throws {
        let spoken = "Use ``` for a fence and ```` for a longer one."
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: spoken), calendar: calendar, locale: english))
        let markdown = TranscriptExport.markdown(for: document)

        XCTAssertTrue(markdown.contains("`````text\n"), "The fence must outrun the longest run.")
        XCTAssertTrue(markdown.contains(spoken))
    }

    func testNewlinesInTheTranscriptSurviveBothFormats() throws {
        let spoken = "First line.\nSecond line.\n\nFourth line."
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: spoken), calendar: calendar, locale: english))

        for format in TranscriptExport.Format.allCases {
            XCTAssertTrue(
                TranscriptExport.text(for: document, format: format).contains(spoken),
                "\(format) must keep the line breaks the user dictated")
        }
    }

    /// A field line is one line. A stored sentence carrying a newline would
    /// otherwise run the rest of itself out of the list it is a bullet in.
    func testANewlineInAFieldIsFlattenedWhileTheTranscriptKeepsIts() throws {
        var row = recording(transcription: "line one\nline two")
        row.provenance = .selectionEdit(instruction: "shorten\nthis")
        let document = try XCTUnwrap(TranscriptExport.document(for: row))
        let markdown = TranscriptExport.markdown(for: document)

        XCTAssertTrue(markdown.contains("- **Details:** shorten this"))
        XCTAssertTrue(markdown.contains("line one\nline two"))
    }

    func testNonLatinTextAndTypographySurviveVerbatim() throws {
        let spoken = "把 PR 開到 feature/login 再 @James - “quoted”, 100% done."
        let document = try XCTUnwrap(TranscriptExport.document(
            for: recording(transcription: spoken), calendar: calendar, locale: english))

        for format in TranscriptExport.Format.allCases {
            XCTAssertTrue(TranscriptExport.text(for: document, format: format).contains(spoken))
        }
    }

    // MARK: - Plain text

    func testThePlainTextCarriesTheSameFactsWithNoMarkup() throws {
        var row = recording(transcription: "Ship it.")
        row.rawTranscription = "ship it"
        let document = try XCTUnwrap(
            TranscriptExport.document(for: row, calendar: calendar, locale: english))
        let text = TranscriptExport.plainText(for: document)

        XCTAssertTrue(text.contains("Recorded: "))
        XCTAssertTrue(text.contains("Source: Dictation"))
        XCTAssertTrue(text.contains("Ship it."))
        XCTAssertTrue(text.contains("--- Original transcript ---"))
        XCTAssertFalse(text.contains("```"), "Plain text carries no fences.")
        XCTAssertFalse(text.contains("# "), "Plain text carries no headings.")
    }

    // MARK: - The suggested name

    /// The date first, so a folder of exports sorts usefully by name. And
    /// nothing from the transcript: the first words of a dictation are exactly
    /// what a user would not want on a file name in a Finder window behind them.
    func testTheSuggestedNameIsTheDateAndTheKind() {
        var row = recording(
            transcription: "Something private about the acquisition",
            at: Date(timeIntervalSince1970: 1_772_616_600))
        row.provenance = .dictation

        let name = TranscriptExport.suggestedFileName(
            for: row, format: .markdown, calendar: calendar)

        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertTrue(name.hasPrefix("2026-03-04"))
        XCTAssertTrue(name.contains("Dictation"))
        XCTAssertFalse(name.contains("acquisition"))
    }

    /// A file name cannot carry a path separator, and the two command labels
    /// carry a dash that reads oddly in one.
    func testTheSuggestedNameIsUsableAsAFileName() {
        for kind in RecordingProvenanceKind.allCases {
            var row = recording(transcription: "words")
            row.provenanceKind = kind.rawValue
            for format in TranscriptExport.Format.allCases {
                let name = TranscriptExport.suggestedFileName(
                    for: row, format: format, calendar: calendar)
                XCTAssertFalse(name.contains("/"), "\(kind) produced a path separator")
                XCTAssertFalse(name.contains(":"), "\(kind) produced a colon")
                XCTAssertTrue(name.hasSuffix(".\(format.fileExtension)"))
            }
        }
    }

    func testBothFormatsAreOffered() {
        XCTAssertEqual(TranscriptExport.Format.markdown.fileExtension, "md")
        XCTAssertEqual(TranscriptExport.Format.plainText.fileExtension, "txt")
        for format in TranscriptExport.Format.allCases {
            XCTAssertFalse(format.label.isEmpty)
        }
    }

    /// Two and no more: the save panel's format control is built from this list,
    /// so a third case would be a format offered with no serialiser behind it.
    func testTheOfferedFormatsAreMarkdownAndPlainTextInThatOrder() {
        XCTAssertEqual(TranscriptExport.Format.allCases, [.markdown, .plainText])
        XCTAssertTrue(TranscriptExport.Format.markdown.label.contains(".md"))
        XCTAssertTrue(TranscriptExport.Format.plainText.label.contains(".txt"))
        XCTAssertNotEqual(
            TranscriptExport.Format.markdown.contentType,
            TranscriptExport.Format.plainText.contentType,
            "the panel would show one entry twice")
    }

    // MARK: - The destination

    func testAFileNameDeclaresTheFormatItIsWrittenIn() {
        XCTAssertEqual(TranscriptExport.Format(fileExtension: "md"), .markdown)
        XCTAssertEqual(TranscriptExport.Format(fileExtension: "MD"), .markdown)
        XCTAssertEqual(TranscriptExport.Format(fileExtension: "markdown"), .markdown)
        XCTAssertEqual(TranscriptExport.Format(fileExtension: "txt"), .plainText)
        XCTAssertEqual(TranscriptExport.Format(fileExtension: "TXT"), .plainText)
        XCTAssertNil(TranscriptExport.Format(fileExtension: ""))
        XCTAssertNil(TranscriptExport.Format(fileExtension: "rtf"))
    }

    /// The extension and the body can never disagree: whichever of the two the
    /// user actually settled on, the destination carries one answer.
    func testTheDestinationAlwaysAgreesWithTheNameItIsWrittenUnder() {
        let folder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)

        for format in TranscriptExport.Format.allCases {
            // A name that declares a format is the last word on it.
            for named in TranscriptExport.Format.allCases {
                let destination = TranscriptExport.destination(
                    for: folder.appendingPathComponent("notes.\(named.fileExtension)"),
                    chosenFormat: format)
                XCTAssertEqual(destination.format, named)
                XCTAssertEqual(destination.url.lastPathComponent, "notes.\(named.fileExtension)")
            }

            // A bare name takes the chosen format, and its extension.
            let bare = TranscriptExport.destination(
                for: folder.appendingPathComponent("notes"), chosenFormat: format)
            XCTAssertEqual(bare.format, format)
            XCTAssertEqual(bare.url.lastPathComponent, "notes.\(format.fileExtension)")

            // A name declaring something this app does not write is not written
            // into: the format that is actually being written is appended.
            let foreign = TranscriptExport.destination(
                for: folder.appendingPathComponent("notes.rtf"), chosenFormat: format)
            XCTAssertEqual(foreign.format, format)
            XCTAssertEqual(foreign.url.pathExtension, format.fileExtension)
        }
    }

    /// Whatever a destination resolves to, the body it names is the body that is
    /// written - the property the two halves above exist for.
    func testEveryDestinationsFormatIsTheOneItsExtensionNames() throws {
        let document = try XCTUnwrap(
            TranscriptExport.document(for: recording(transcription: "Ship it.")))

        for candidate in ["notes", "notes.md", "notes.txt", "notes.rtf"] {
            for chosen in TranscriptExport.Format.allCases {
                let destination = TranscriptExport.destination(
                    for: URL(fileURLWithPath: "/tmp/\(candidate)"), chosenFormat: chosen)
                let text = TranscriptExport.text(for: document, format: destination.format)
                XCTAssertEqual(
                    TranscriptExport.Format(fileExtension: destination.url.pathExtension),
                    destination.format,
                    "\(candidate) under \(chosen)")
                XCTAssertEqual(
                    text.contains("# Transcript"), destination.format == .markdown,
                    "\(candidate) under \(chosen) wrote the wrong body")
            }
        }
    }

    // MARK: - Helpers

    private func recording(
        transcription: String,
        status: RecordingStatus = .completed,
        at timestamp: Date = Date(timeIntervalSince1970: 1_772_616_600)
    ) -> Recording {
        var row = Recording(
            id: UUID(),
            timestamp: timestamp,
            fileName: "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 12.0,
            status: status,
            progress: status == .completed ? 1.0 : 0.3,
            sourceFileURL: nil
        )
        row.provenance = .dictation
        return row
    }
}
