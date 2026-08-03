import XCTest
import FluidAudio

@testable import OpenSuperWhisper

/// The weights a build can ship with, and the bootstrap that puts them where the
/// engine already looks.
///
/// These run entirely against temporary directories. The real cache is several
/// hundred megabytes of the developer's own downloads and this is not the place
/// to be writing into it.
final class StarterModelTests: XCTestCase {

    private var root: URL!
    private var bundled: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starter-model-tests-\(UUID().uuidString)", isDirectory: true)
        bundled = root.appendingPathComponent("bundled", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var entries: [String] { StarterModel.requiredEntries }

    private func writePayload(into directory: URL, entries: [String]? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries ?? self.entries {
            let url = directory.appendingPathComponent(entry)
            if entry.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: url.appendingPathComponent("coremldata.bin"))
            } else {
                try Data("[]".utf8).write(to: url)
            }
        }
    }

    private func install() -> StarterModel.InstallOutcome {
        StarterModel.installIfNeeded(
            bundledDirectory: bundled,
            cacheDirectory: cache,
            requiredEntries: entries
        )
    }

    // MARK: - The list of files

    /// `StarterModel` must not hold its own opinion about which files the engine
    /// needs: the engine picks the encoder precision, and a starter staged
    /// against the wrong one would install weights that never load.
    func testTheRequiredEntriesAreTheOnesTheEngineActuallyLoads() throws {
        try writePayload(into: cache)

        XCTAssertTrue(
            SenseVoiceModels.modelsExist(at: cache, precision: .int8),
            "the entries StarterModel installs are not what SenseVoiceModels checks for: \(entries)"
        )
        XCTAssertEqual(StarterModel.requiredEntries, SenseVoiceEngine.requiredCacheEntries)
    }

    /// The packaging script names the same files in shell. A drift between the
    /// two would produce a build that ships weights the app cannot load.
    func testThePackagingScriptStagesExactlyTheseEntries() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Scripts/package_starter_model.sh"),
            encoding: .utf8
        )

        for entry in entries {
            XCTAssertTrue(
                script.contains("\"\(entry)\""),
                "Scripts/package_starter_model.sh does not stage \(entry)"
            )
        }
        XCTAssertTrue(
            script.contains("\"\(StarterModel.cacheDirectory.lastPathComponent)\""),
            "the script must install into the cache folder the engine reads"
        )
    }

    // MARK: - Bootstrap

    func testABundledStarterIsCopiedIntoTheModelCache() throws {
        try writePayload(into: bundled)

        XCTAssertEqual(install(), .installed)
        XCTAssertTrue(SenseVoiceModels.modelsExist(at: cache, precision: .int8))
    }

    /// A build packaged without the weights is the normal case - CI and every
    /// developer checkout - and must behave exactly as the app did before.
    func testABuildWithNoStarterInstallsNothing() {
        XCTAssertEqual(
            StarterModel.installIfNeeded(
                bundledDirectory: nil,
                cacheDirectory: cache,
                requiredEntries: entries
            ),
            .notBundled
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    /// The bootstrap runs at every launch, so it has to be idempotent and it has
    /// to be cheap the second time.
    func testASecondLaunchDoesNotCopyAgain() throws {
        try writePayload(into: bundled)
        XCTAssertEqual(install(), .installed)

        XCTAssertEqual(install(), .alreadyInstalled)
    }

    /// A cache the user paid 240 MB of bandwidth for is never replaced by the
    /// bundled copy - not least because it may be a newer or different variant.
    func testAnExistingCacheIsNeverOverwritten() throws {
        try writePayload(into: bundled)
        try writePayload(into: cache)
        let marker = cache.appendingPathComponent("vocab.json")
        try Data("[\"downloaded\"]".utf8).write(to: marker)

        XCTAssertEqual(install(), .alreadyInstalled)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "[\"downloaded\"]")
    }

    /// A packaging mistake is reported as one. Left to surface later it would be
    /// a load failure minutes into someone's first dictation.
    func testAnIncompleteStarterIsRejectedRatherThanHalfInstalled() throws {
        try writePayload(into: bundled, entries: [entries[0]])

        XCTAssertEqual(install(), .incomplete(missing: Array(entries.dropFirst())))
        XCTAssertFalse(SenseVoiceModels.modelsExist(at: cache, precision: .int8))
    }

    /// The install target is the cache the engine already downloads into - not a
    /// second copy the engine would have to learn about. Once installed, the
    /// starter is indistinguishable from a finished download.
    func testTheStarterInstallsIntoTheEnginesOwnCacheDirectory() {
        XCTAssertEqual(StarterModel.cacheDirectory, SenseVoiceEngine.modelCacheDirectory)
        XCTAssertEqual(StarterModel.cacheDirectory.lastPathComponent, "sensevoice-small")
    }

    /// Which engine the weights belong to, asserted because two places have to
    /// agree about it: the selector that falls back to it, and the catalog copy
    /// that says where it came from.
    func testTheStarterIsTheEngineTheAppRecommendsForChinese() {
        XCTAssertEqual(StarterModel.engine, EngineSelector.starterEngine)
        XCTAssertEqual(StarterModel.engine, EngineKind.defaultChineseDictation)
    }
}

/// What the app tells the user about where a model came from.
///
/// The sentence is a licence artefact, not decoration:
/// `docs/speech-model-attribution.md` records that the app used to state it
/// bundled no weights at all, and a build that ships them cannot keep saying so.
final class StarterModelProvenanceTests: XCTestCase {

    func testABuildWithoutTheStarterSaysNothingIsBundled() {
        XCTAssertEqual(
            EngineCatalog.provenanceLine(for: .sensevoice, isBundled: false),
            "Downloaded to your Mac, not bundled with the app."
        )
    }

    func testABuildWithTheStarterSaysItShipsWithTheApp() {
        let line = EngineCatalog.provenanceLine(for: StarterModel.engine, isBundled: true)

        XCTAssertTrue(line.contains("Included with this build"), line)
        XCTAssertTrue(line.contains("licence"), "the bundled claim has to point at the licence it is made under")
        XCTAssertFalse(line.contains("not bundled"), line)
    }

    /// Only the starter engine ships. Paraformer's 653 MB are still downloaded,
    /// and a build that bundles one model must not imply it bundles both.
    func testOtherEnginesStillSayTheyAreDownloaded() {
        XCTAssertEqual(
            EngineCatalog.provenanceLine(for: .paraformer, isBundled: true),
            "Downloaded to your Mac, not bundled with the app."
        )
    }
}
