import Foundation
import XCTest
@testable import OpenSuperWhisper

/// Every row history stores carries a provenance from the moment it exists.
///
/// The migration deliberately leaves pre-feature rows NULL, so "Older
/// recording" is a claim about age: it asserts the row predates the feature.
/// A surface that stores a fresh row without assigning a kind mints that claim
/// falsely - the main-window record button did exactly that, so one screen
/// produced `.dictation` for a failed press and "Older recording" for a
/// successful one. The paths that build these rows run a live recorder and a
/// loaded engine and end at the real store, so the invariant is held where it
/// lives: at the construction site.
///
/// There is one now. `Recording.newRow` is the only way a new row is made
/// (`RecordingRowFactoryTests` scans for any other), and it takes the
/// provenance as a parameter with no default - so a caller that has not
/// decided what a row is does not compile, rather than storing a row that
/// says it is older than it is. What this file holds is that the parameter
/// stays required and that the factory writes it, in the source, because a
/// default of `.unknown` or `.dictation` added for convenience would put the
/// main-window bug back without failing anything else.
final class HistoryProvenanceCoverageTests: XCTestCase {

    func testTheFactoryRequiresAProvenanceAndStoresIt() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: repositoryRoot.appendingPathComponent("EchoForgeCore/History/Recording.swift"),
            encoding: .utf8)

        let signatureStart = try XCTUnwrap(
            text.range(of: "static func newRow("), "Recording.newRow is the row factory")
        let signatureEnd = try XCTUnwrap(
            text.range(of: ") -> Recording {", range: signatureStart.upperBound..<text.endIndex))
        let signature = text[signatureStart.upperBound..<signatureEnd.lowerBound]

        let provenance = try XCTUnwrap(
            signature.range(of: "provenance: RecordingProvenance"),
            "the factory takes the row's provenance")
        let rest = signature[provenance.upperBound...]
        let toNextParameter = rest.prefix { $0 != "," && $0 != "\n" }
        XCTAssertFalse(
            toNextParameter.contains("="),
            "provenance must have no default: a caller that has not decided what a row "
                + "is must not compile, or a fresh row reads back as 'Older recording'")

        let body = text[signatureEnd.upperBound...]
        let construction = try XCTUnwrap(body.range(of: "= Recording("))
        let stored = body[construction.upperBound...]
        XCTAssertTrue(
            stored.contains("row.provenance = provenance"),
            "the factory writes the provenance it was given onto the row")
    }

    /// The other half of "held at the construction site": every fresh row is
    /// stored with what it was given, and a `nil` kind is not among the
    /// options.
    func testARowFromTheFactoryNeverReadsBackAsAnOlderRecording() {
        let kinds: [RecordingProvenance] = [
            .dictation, .fileTranscription, .ask,
            .youTubeCommandOpened(summary: "Opened the newest video"),
            .selectionEdit(instruction: "make it formal"),
        ]
        for kind in kinds {
            let row = Recording.newRow(
                transcription: "", duration: 1, status: .completed, progress: 1,
                provenance: kind)
            XCTAssertEqual(row.provenance, kind)
            XCTAssertNotNil(row.provenanceKind, "a fresh row's kind is written, never NULL")
            XCTAssertNotEqual(row.provenance.kind, .unknown)
        }
    }
}
