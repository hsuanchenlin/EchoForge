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
/// lives: at the construction sites themselves.
final class HistoryProvenanceCoverageTests: XCTestCase {

    func testEveryStoredRecordingConstructionAssignsAProvenance() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var files: [(root: String, path: String)] = []
        for root in HistoryProvenancePrivacyTests.scannedSourceRoots {
            let sources = repositoryRoot.appendingPathComponent(root)
            guard let found = FileManager.default.enumerator(atPath: sources.path)?
                .allObjects as? [String]
            else {
                throw XCTSkip("Sources are not beside the tests: \(sources.path)")
            }
            files.append(contentsOf: found.map { (root, $0) })
        }

        var constructions = 0
        for (root, relative) in files where relative.hasSuffix(".swift") {
            let file = "\(root)/\(relative)"
            let text = try String(
                contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            var cursor = text.startIndex
            while let construction = text.range(
                of: "= Recording(", range: cursor..<text.endIndex)
            {
                constructions += 1
                cursor = construction.upperBound
                guard let store = text.range(
                    of: "addRecording", range: cursor..<text.endIndex)
                else {
                    XCTFail(
                        "\(file) constructs a Recording that nothing after it stores. "
                            + "If it is stored another way, teach this scan that way "
                            + "rather than letting rows reach history unscanned.")
                    continue
                }
                XCTAssertTrue(
                    text[construction.upperBound..<store.lowerBound]
                        .contains(".provenance ="),
                    "\(file) stores a Recording without assigning its provenance. "
                        + "A NULL kind reads back as .unknown and is shown as "
                        + "'Older recording', which asserts the row predates the "
                        + "feature - assign the kind before the row is stored.")
            }
        }

        XCTAssertGreaterThanOrEqual(
            constructions, 4,
            "The scan found fewer Recording construction sites than exist today, "
                + "so it is no longer scanning what it thinks it is.")
    }
}
