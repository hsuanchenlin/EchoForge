import CoreML
import XCTest

@testable import OpenSuperWhisper

/// Reading the model pack list.
///
/// The same discipline as `UpdateCheckerTests`, and for the same reason: the end
/// of this path is writing files into a directory the app then loads model code
/// from. Every case here is a refusal.
final class ModelPackManifestTests: XCTestCase {

    private func document(
        id: String = "sensevoice-small",
        engine: String = "sensevoice",
        cacheFolder: String = "sensevoice-small",
        entries: [String] = ["SenseVoiceSmall_int8.mlmodelc", "vocab.json"],
        bytes: Int = 208_353_075,
        sha256: String = String(repeating: "a", count: 64),
        url: String = "https://github.com/hsuanchenlin/EchoForge/releases/download/models/pack.tar.gz",
        minimumAppVersion: String? = nil,
        schemaVersion: Int = 1
    ) -> Data {
        var pack: [String: Any] = [
            "id": id, "version": "1.0.0", "engine": engine, "cacheFolder": cacheFolder,
            "entries": entries, "bytes": bytes, "sha256": sha256, "url": url,
        ]
        if let minimumAppVersion { pack["minimumAppVersion"] = minimumAppVersion }
        return try! JSONSerialization.data(
            withJSONObject: ["schemaVersion": schemaVersion, "packs": [pack]]
        )
    }

    func testReadsAPack() throws {
        let packs = try ModelPackManifest.parse(document())

        XCTAssertEqual(packs.count, 1)
        XCTAssertEqual(packs[0].id, "sensevoice-small")
        XCTAssertEqual(packs[0].engine, .sensevoice)
        XCTAssertEqual(packs[0].cacheFolder, "sensevoice-small")
        XCTAssertEqual(packs[0].sizeInBytes, 208_353_075)
    }

    /// A newer document is refused rather than half-understood: a field this
    /// build ignores could be the one saying these weights are for a different
    /// encoder precision.
    func testRefusesASchemaItDoesNotUnderstand() {
        XCTAssertThrowsError(try ModelPackManifest.parse(document(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? ModelPackManifestError, .unsupportedSchema(2))
        }
    }

    /// The same rule as the disk image: HTTPS, a GitHub release host, under this
    /// repository. A pack from anywhere else is an arbitrary archive unpacked
    /// into the directory CoreML loads from.
    func testRefusesAPackHostedAnywhereElse() {
        for url in [
            "https://example.invalid/pack.tar.gz",
            "http://github.com/hsuanchenlin/EchoForge/releases/download/models/pack.tar.gz",
            "https://github.com/someone-else/EchoForge/releases/download/models/pack.tar.gz",
        ] {
            XCTAssertThrowsError(try ModelPackManifest.parse(document(url: url)), url)
        }
    }

    /// The check that stops a pack writing outside the cache it was given.
    func testRefusesEntriesThatAreNotOnePathComponent() {
        for entry in ["../../../bin/sh", "weights/../../escape", ".hidden", "a/b"] {
            XCTAssertThrowsError(try ModelPackManifest.parse(document(entries: [entry])), entry) { error in
                XCTAssertEqual(error as? ModelPackManifestError, .unsafeEntry(entry))
            }
        }
    }

    func testRefusesACacheFolderThatIsNotOnePathComponent() {
        XCTAssertThrowsError(try ModelPackManifest.parse(document(cacheFolder: "../elsewhere")))
    }

    func testRefusesAnythingThatIsNotASha256() {
        for digest in ["", "abc", String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try ModelPackManifest.parse(document(sha256: digest)), digest) { error in
                XCTAssertEqual(error as? ModelPackManifestError, .badChecksum("sensevoice-small"))
            }
        }
    }

    func testRefusesAnEngineThisBuildDoesNotHave() {
        XCTAssertThrowsError(try ModelPackManifest.parse(document(engine: "some-future-engine"))) { error in
            XCTAssertEqual(error as? ModelPackManifestError, .unknownEngine("some-future-engine"))
        }
    }

    func testRefusesAnImplausibleSize() {
        XCTAssertThrowsError(try ModelPackManifest.parse(document(bytes: 0)))
        XCTAssertThrowsError(try ModelPackManifest.parse(document(bytes: 5_000_000_000)))
    }

    func testRefusesADocumentThatIsNotJSON() {
        XCTAssertThrowsError(try ModelPackManifest.parse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ModelPackManifestError, .malformedDocument)
        }
    }

    func testEveryRefusalCarriesAReadableReason() {
        let errors: [ModelPackManifestError] = [
            .malformedDocument, .unsupportedSchema(2), .incompletePack("x"), .unknownEngine("x"),
            .unsafeEntry("x"), .untrustedHost("x"), .badChecksum("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }

    /// A pack for a newer app is left out rather than refused: one document
    /// listing packs for several app versions is the normal case.
    func testAPackNeedingANewerAppIsNotOffered() throws {
        let packs = try ModelPackManifest.parse(document(minimumAppVersion: "9.0.0"))

        XCTAssertEqual(ModelPackManifest.installable(packs, appVersion: AppVersion("0.6.0")).count, 0)
        XCTAssertEqual(ModelPackManifest.installable(packs, appVersion: AppVersion("9.0.0")).count, 1)
        XCTAssertEqual(ModelPackManifest.installable(packs, appVersion: AppVersion("9.1.0")).count, 1)
    }

    /// The list that ships inside the app has to be readable by the app that
    /// ships it - a malformed one would silently turn every pack off.
    func testTheShippedListParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/ModelPacks.json")
        let packs = try ModelPackManifest.parse(try Data(contentsOf: url))

        // Empty until packs are published, which is what keeps this change
        // inert: with no entries the app downloads weights exactly as before.
        XCTAssertTrue(packs.isEmpty, "publishing a pack means updating this test's expectation too")
    }
}

/// Installing a pack into the cache the engine loads from.
final class ModelPackInstallerTests: XCTestCase {

    private var workDirectory: URL!
    private var cacheRoot: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheRoot = workDirectory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    /// Builds a real `.tar.gz` of a fake cache folder and returns the pack that
    /// describes it. Real `tar` rather than a stub, because the archive format
    /// is part of what is under test.
    private func makePack(
        id: String = "test-model",
        entries: [String: String] = ["weights.bin": "weights", "vocab.json": "{}"],
        corruptChecksum: Bool = false
    ) throws -> (pack: ModelPack, archive: URL) {
        let source = workDirectory.appendingPathComponent("source/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in entries {
            try Data(contents.utf8).write(to: source.appendingPathComponent(name))
        }
        let archive = workDirectory.appendingPathComponent("\(id).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, id]
        try tar.run()
        tar.waitUntilExit()

        let digest = try FileDigest.sha256(of: archive)
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        let pack = ModelPack(
            id: id,
            version: "1.0.0",
            engine: .sensevoice,
            cacheFolder: id,
            entries: Array(entries.keys),
            sizeInBytes: size,
            sha256: corruptChecksum ? String(repeating: "b", count: 64) : digest,
            url: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/models/\(id).tar.gz")!,
            minimumAppVersion: nil
        )
        return (pack, archive)
    }

    private func installer(serving archive: URL) -> ModelPackInstaller {
        ModelPackInstaller(
            cacheRoot: cacheRoot,
            commandRunner: SystemCommandRunner(),
            downloader: StubFileDownloader(file: archive)
        )
    }

    func testInstallsThePackIntoTheEnginesOwnCache() async throws {
        let (pack, archive) = try makePack()

        let outcome = try await installer(serving: archive).install(pack)

        XCTAssertEqual(outcome, .installed(pack))
        for entry in pack.entries {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: cacheRoot.appendingPathComponent(pack.cacheFolder).appendingPathComponent(entry).path
                ),
                entry
            )
        }
    }

    /// The rule that makes a thinner app safe for people who already have the
    /// weights: a model the user paid hundreds of megabytes for is never
    /// replaced, and nothing is even downloaded.
    func testAnExistingCacheIsNeverOverwritten() async throws {
        let (pack, archive) = try makePack()
        let cache = cacheRoot.appendingPathComponent(pack.cacheFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for entry in pack.entries {
            try Data("the user's own copy".utf8).write(to: cache.appendingPathComponent(entry))
        }

        let downloader = StubFileDownloader(file: archive)
        let outcome = try await ModelPackInstaller(
            cacheRoot: cacheRoot, downloader: downloader
        ).install(pack)

        XCTAssertEqual(outcome, .alreadyInstalled)
        XCTAssertEqual(downloader.downloads, 0, "an installed model must not cost the user a download")
        XCTAssertEqual(
            try String(contentsOf: cache.appendingPathComponent(pack.entries[0]), encoding: .utf8),
            "the user's own copy"
        )
    }

    /// A cache holding some of the entries is worse than an empty one: the
    /// engine finds files, fails to load them, and there is nothing to download
    /// because everything "exists".
    func testAPackThatDoesNotMatchItsChecksumInstallsNothing() async throws {
        let (pack, archive) = try makePack(corruptChecksum: true)

        do {
            _ = try await installer(serving: archive).install(pack)
            XCTFail("a pack that fails its checksum must not be installed")
        } catch let error as ModelPackInstallError {
            guard case .checksumMismatch = error else { return XCTFail("got \(error)") }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(pack.cacheFolder).path),
            "nothing may be left in the cache"
        )
    }

    /// The archive is checked against what the engine needs *after* extraction,
    /// so a pack that is internally consistent but incomplete is caught before
    /// anything reaches the cache.
    func testAnArchiveMissingAnEntryTheEngineNeedsIsRefused() async throws {
        var (pack, archive) = try makePack(entries: ["weights.bin": "weights"])
        pack = ModelPack(
            id: pack.id, version: pack.version, engine: pack.engine, cacheFolder: pack.cacheFolder,
            entries: pack.entries + ["vocab.json"], sizeInBytes: pack.sizeInBytes,
            sha256: pack.sha256, url: pack.url, minimumAppVersion: nil
        )

        do {
            _ = try await installer(serving: archive).install(pack)
            XCTFail("an incomplete archive must not be installed")
        } catch let error as ModelPackInstallError {
            guard case .incompleteAfterExtraction(let missing) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(missing, ["vocab.json"])
        }

        let cache = cacheRoot.appendingPathComponent(pack.cacheFolder)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.appendingPathComponent("weights.bin").path),
            "a partial cache is worse than none"
        )
    }

    func testRecordsWhichPackPutTheWeightsThere() async throws {
        let (pack, archive) = try makePack()

        _ = try await installer(serving: archive).install(pack)

        let receipt = ModelPackInstaller(cacheRoot: cacheRoot).installedReceipt(for: pack)
        XCTAssertEqual(receipt?.id, pack.id)
        XCTAssertEqual(receipt?.version, "1.0.0")
    }

    /// Nothing in the app depends on a pack existing, so no pack is offered
    /// until one is published.
    func testNoPackIsOfferedUntilOneIsPublished() {
        XCTAssertNil(ModelPackCatalog.pack(for: .sensevoice, in: []))
    }

    // MARK: - On real weights

    /// The one measurement the whole pack format rests on: a `.mlmodelc` is a
    /// directory of several files, and it has to survive a tar round trip well
    /// enough that **CoreML still loads it**. Byte-identical files would not be
    /// enough on their own - a lost extended attribute or permission bit could
    /// still break the load - so this loads it.
    ///
    /// Opt-in on a locally staged model, the same way the engine integration
    /// tests work: `Scripts/package_starter_model.sh --stage-from-cache` puts
    /// one at `StarterModel/sensevoice-small`. Without it the test reports why
    /// it did nothing rather than failing on a machine that has never
    /// downloaded the weights.
    func testARealCompiledModelSurvivesThePackFormatAndStillLoads() async throws {
        let staged = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StarterModel/sensevoice-small")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw XCTSkip(
                "No staged weights at \(staged.path). Run Scripts/package_starter_model.sh --stage-from-cache."
            )
        }

        // Packed by the real script's own command, so this tests the format that
        // is actually published rather than one the test invented.
        let archive = workDirectory.appendingPathComponent("sensevoice-small.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", staged.deletingLastPathComponent().path, "sensevoice-small"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let pack = ModelPack(
            id: "sensevoice-small",
            version: "1.0.0",
            engine: .sensevoice,
            cacheFolder: "sensevoice-small",
            entries: SenseVoiceEngine.requiredCacheEntries,
            sizeInBytes: (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0,
            sha256: try FileDigest.sha256(of: archive),
            url: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/models/x.tar.gz")!,
            minimumAppVersion: nil
        )

        let outcome = try await installer(serving: archive).install(pack)
        XCTAssertEqual(outcome, .installed(pack))

        let installed = cacheRoot.appendingPathComponent("sensevoice-small")
        for entry in pack.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent(entry).path), entry)
        }

        // The assertion that matters. An installed pack that CoreML refuses is a
        // pack that installed a cache the engine can never load - and because
        // `isModelDownloaded` only looks for the files, there would be nothing
        // to re-download.
        let compiled = installed.appendingPathComponent("SenseVoiceSmall_int8.mlmodelc")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        XCTAssertFalse(model.modelDescription.inputDescriptionsByName.isEmpty)
    }
}

/// Hands the installer a file that is already on disk, so pack installation can
/// be driven without a network.
private final class StubFileDownloader: ResumableFileDownloading, @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var _downloads = 0
    private(set) var discarded: [String] = []

    init(file: URL) {
        self.file = file
    }

    var downloads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _downloads
    }

    func download(
        from url: URL,
        declaredBytes: Int64,
        key: String,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> (file: URL, key: String) {
        lock.lock()
        _downloads += 1
        lock.unlock()
        progress(DownloadProgress(receivedBytes: declaredBytes, totalBytes: declaredBytes))
        return (file, key)
    }

    func discard(key: String) {
        lock.lock()
        discarded.append(key)
        lock.unlock()
    }
}
