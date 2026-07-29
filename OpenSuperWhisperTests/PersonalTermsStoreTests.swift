import XCTest
@testable import OpenSuperWhisper

/// Pins `terms.json` as a portable, hand-editable file.
///
/// The dictionary is meant to be copied, backed up and edited outside the app,
/// so what matters here is that a round trip is lossless, that a hand-written
/// file with only the essential fields works, and that a broken file degrades
/// to an empty dictionary instead of taking the app or the user's data with it.
final class PersonalTermsStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalTermsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("terms.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> PersonalTermsStore {
        PersonalTermsStore(fileURL: fileURL)
    }

    private func write(_ json: String) throws {
        try json.data(using: .utf8)!.write(to: fileURL)
    }

    // MARK: - Persistence round trips

    func testRoundTripPreservesEveryEntryKindAndField() throws {
        let terms = [
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群"),
            PersonalTerm(kind: .preferredSpelling, match: "台北", replacement: "臺北"),
            PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken", contextHint: "團隊"),
            PersonalTerm(kind: .protect, match: "useState", isEnabled: false)
        ]

        try makeStore().replaceAll(terms)
        let reloaded = makeStore()

        XCTAssertEqual(reloaded.terms, terms)
        XCTAssertNil(reloaded.loadFailure)
    }

    func testSavedFileIsPlainReadableJSON() throws {
        try makeStore().replaceAll([
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")
        ])

        let contents = try String(contentsOf: fileURL, encoding: .utf8)

        // Readable and editable by hand is the whole point of the format.
        XCTAssertTrue(contents.contains("\n"), "expected pretty-printed JSON")
        XCTAssertTrue(contents.contains("\"version\""))
        XCTAssertTrue(contents.contains("\"kind\" : \"replacement\""))
    }

    func testSavingWritesTheCurrentSchemaVersion() throws {
        try makeStore().replaceAll([PersonalTerm(kind: .protect, match: "恰恰好")])

        let document = try PersonalTermsStore.decode(Data(contentsOf: fileURL))

        XCTAssertEqual(document.version, PersonalTermsDocument.currentVersion)
    }

    func testReplaceAllOverwritesRatherThanAppends() throws {
        let store = makeStore()
        try store.replaceAll([PersonalTerm(kind: .protect, match: "useState")])
        try store.replaceAll([PersonalTerm(kind: .protect, match: "useEffect")])

        XCTAssertEqual(store.terms.map(\.match), ["useEffect"])
        XCTAssertEqual(makeStore().terms.map(\.match), ["useEffect"])
    }

    func testHandWrittenEntryWithOnlyEssentialFieldsLoads() throws {
        // No id, no enabled flag, no context hint: the minimum someone would
        // type into the file themselves.
        try write("""
        { "terms": [ { "kind": "name", "match": "張偉", "replacement": "張煒" } ] }
        """)

        let terms = makeStore().terms

        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].kind, .name)
        XCTAssertEqual(terms[0].replacement, "張煒")
        XCTAssertTrue(terms[0].isEnabled, "an entry without a flag should be applied")
        XCTAssertNil(terms[0].contextHint)
    }

    func testEmptyContextHintDecodesAsNoHint() throws {
        try write("""
        { "terms": [ { "kind": "replacement", "match": "在", "replacement": "再", "contextHint": "" } ] }
        """)

        XCTAssertNil(makeStore().terms[0].contextHint)
    }

    // MARK: - Missing and malformed files

    func testMissingFileIsAnEmptyDictionaryNotAnError() {
        let store = makeStore()

        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertNil(store.loadFailure, "starting with no file is the normal state, not a failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "reading must not create the file")
    }

    func testMalformedFileReportsFailureAndIsLeftOnDisk() throws {
        try write("{ this is not json")

        let store = makeStore()

        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertNotNil(store.loadFailure)
        // The user's file is their data; a parse failure must not destroy it.
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "{ this is not json")
    }

    func testUnreadableEntryIsSkippedWithoutLosingTheRest() throws {
        // "flavour" is not a kind this build knows, and the third entry has no
        // match at all. Neither may take the valid entries down with it.
        try write("""
        { "version": 1, "terms": [
          { "kind": "replacement", "match": "頂頂群", "replacement": "釘釘群" },
          { "kind": "flavour", "match": "???", "replacement": "!!!" },
          { "kind": "protect" },
          { "kind": "protect", "match": "useState" }
        ] }
        """)

        let store = makeStore()

        XCTAssertEqual(store.terms.map(\.match), ["頂頂群", "useState"])
        XCTAssertNil(store.loadFailure, "skipping one entry is not a file-level failure")
    }

    func testEmptyFileLoadsAsAnEmptyDictionary() throws {
        try write("{ \"version\": 1, \"terms\": [] }")

        let store = makeStore()

        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertNil(store.loadFailure)
    }

    func testSavingAfterAMalformedFileClearsTheFailure() throws {
        try write("not json")
        let store = makeStore()
        XCTAssertNotNil(store.loadFailure)

        try store.replaceAll([PersonalTerm(kind: .protect, match: "useState")])

        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(makeStore().terms.map(\.match), ["useState"])
    }

    func testReloadPicksUpAnExternalEdit() throws {
        let store = makeStore()
        XCTAssertTrue(store.terms.isEmpty)

        try write("""
        { "terms": [ { "kind": "preferredSpelling", "match": "k8s", "replacement": "Kubernetes" } ] }
        """)
        store.reload()

        XCTAssertEqual(store.terms.map(\.replacement), ["Kubernetes"])
    }

    func testSavingCreatesTheContainingDirectory() throws {
        fileURL = directory.appendingPathComponent("nested/deeper/terms.json")

        try makeStore().replaceAll([PersonalTerm(kind: .protect, match: "useState")])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Which entries the corrector is given

    func testActiveTermsExcludesDisabledAndIncompleteEntries() throws {
        try makeStore().replaceAll([
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群"),
            PersonalTerm(kind: .replacement, match: "台北", replacement: "", isEnabled: true),
            PersonalTerm(kind: .protect, match: "useState", isEnabled: false),
            PersonalTerm(kind: .protect, match: "恰恰好")
        ])

        let store = makeStore()

        XCTAssertEqual(store.terms.count, 4, "every entry stays in the file and the UI")
        XCTAssertEqual(store.activeTerms.map(\.match), ["頂頂群", "恰恰好"])
    }

    func testDefaultFileLivesBesideTheOtherApplicationSupportData() {
        let url = PersonalTermsStore.defaultFileURL

        // Global to the user and a sibling of the recordings database, so it
        // outlives any future style profile and any recording retention policy.
        XCTAssertEqual(url.lastPathComponent, "terms.json")
        XCTAssertEqual(
            url.deletingLastPathComponent().path,
            Recording.recordingsDirectory.deletingLastPathComponent().path
        )
    }
}
