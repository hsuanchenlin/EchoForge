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
/// There is one now. `Recording.newRow` is the only way a new row is made,
/// and it takes the provenance as a parameter with no default - so a caller
/// that has not decided what a row is does not compile, rather than storing a
/// row that says it is older than it is. What this file holds is that a row
/// the factory makes carries exactly the provenance it was given, for every
/// kind there is, and never reads back as an older recording.
final class HistoryProvenanceCoverageTests: XCTestCase {

    /// Held at the construction site: every fresh row is stored with what it
    /// was given, and a `nil` kind is not among the options.
    func testARowFromTheFactoryNeverReadsBackAsAnOlderRecording() {
        let kinds: [RecordingProvenance] = [
            .dictation, .fileTranscription, .ask,
            .youTubeCommandOpened(summary: "Opened the newest video"),
            .youTubeCommandNotOpened(reason: .notRecognised, message: "Nothing was heard"),
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
