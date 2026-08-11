import CoreML
import FluidAudio
import XCTest

@testable import OpenSuperWhisper

/// The decision: verified pack bytes, or the engine's own unverified download.
///
/// Pure, so every refusal can be asserted without a network - the same reason
/// `EngineSelectionTests` exists for the engine decision.
final class ModelPackSelectionTests: XCTestCase {

    private func pack(
        engine: EngineKind = .sensevoice,
        cacheFolder: String = "sensevoice-small",
        entries: [String] = SenseVoiceEngine.requiredCacheEntries
    ) -> ModelPack {
        ModelPack(
            id: "sensevoice-small",
            version: "1.0.0",
            engine: engine,
            cacheFolder: cacheFolder,
            entries: entries,
            sizeInBytes: 208_353_075,
            sha256: String(repeating: "a", count: 64),
            url: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/models/p.tar.gz")!,
            minimumAppVersion: nil
        )
    }

    private var senseVoiceCache: EngineModelCache {
        EngineModelCache(
            directory: URL(fileURLWithPath: "/tmp/Models/sensevoice-small", isDirectory: true),
            requiredEntries: SenseVoiceEngine.requiredCacheEntries
        )
    }

    /// The state every build is in until packs are actually published, and the
    /// one that keeps shipping the pack code inert.
    func testWithNoPackPublishedTheEngineDownloadsAsItAlwaysHas() {
        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [], cache: senseVoiceCache),
            .downloadThroughEngine(reason: .noPackIsPublished)
        )
    }

    /// The requirement this whole file exists for: a populated manifest routes
    /// the engine through the verified installer, not the legacy downloader.
    func testAPublishedPackIsWhatRuns() {
        let published = pack()

        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [published], cache: senseVoiceCache),
            .install(published, into: senseVoiceCache)
        )
    }

    /// A pack for one engine says nothing about another.
    func testAPackForAnotherEngineIsNotUsed() {
        XCTAssertEqual(
            ModelPackSelection.of(.paraformer, in: [pack()], cache: senseVoiceCache),
            .downloadThroughEngine(reason: .noPackIsPublished)
        )
    }

    /// The failure that would otherwise be invisible: the weights would land in
    /// a directory the engine never reads, and it would download them all over
    /// again having spent the disk space twice.
    func testAPackNamingACacheFolderTheEngineDoesNotUseIsRefused() {
        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [pack(cacheFolder: "somewhere-else")], cache: senseVoiceCache),
            .downloadThroughEngine(reason: .packNamesADifferentCacheFolder("somewhere-else"))
        )
    }

    /// Installing this pack would leave exactly the half-filled cache the
    /// installer exists to prevent: the engine finds files, fails to load them,
    /// and there is nothing to download because everything "exists".
    func testAPackThatCannotFillTheCacheOnItsOwnIsRefused() {
        let short = Array(SenseVoiceEngine.requiredCacheEntries.dropLast())
        let missing = [SenseVoiceEngine.requiredCacheEntries.last!]

        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [pack(entries: short)], cache: senseVoiceCache),
            .downloadThroughEngine(reason: .packIsMissingEntriesTheEngineNeeds(missing))
        )
    }

    /// Whisper loads a model file the user chooses and Parakeet picks between
    /// model versions, so neither is one cache directory a pack could fill.
    func testEnginesWithoutASinglePackableCacheTakeNoPack() {
        XCTAssertNil(EngineModelCache.of(.whisper))
        XCTAssertNil(EngineModelCache.of(.fluidaudio))
    }

    /// A pack installs into the directory the engine already downloads into -
    /// that is what makes an installed pack indistinguishable from a finished
    /// download, and what keeps `isModelDownloaded` and Settings' badges working
    /// with no knowledge of packs at all.
    func testAPackInstallsIntoTheDirectoryTheEngineAlreadyLoadsFrom() throws {
        let cache = try XCTUnwrap(EngineModelCache.of(.sensevoice))

        XCTAssertEqual(cache.directory.standardizedFileURL, SenseVoiceEngine.modelCacheDirectory.standardizedFileURL)
        XCTAssertEqual(cache.folderName, SenseVoiceEngine.modelCacheDirectory.lastPathComponent)
        XCTAssertEqual(cache.requiredEntries, SenseVoiceEngine.requiredCacheEntries)

        // The shipped packaging script names the pack after this folder, so the
        // two agreeing is what makes a published pack installable at all.
        XCTAssertEqual(cache.folderName, "sensevoice-small")
    }

    /// Paraformer publishes no single list of required files, so the pack's own
    /// entry list is all there is to check - which must not be read as "refuse
    /// every pack".
    func testAnEngineWithNoPublishedEntryListStillTakesAPack() {
        let cache = EngineModelCache(
            directory: URL(fileURLWithPath: "/tmp/Models/some-model", isDirectory: true),
            requiredEntries: nil
        )
        let published = pack(cacheFolder: "some-model", entries: ["weights.bin"])

        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [published], cache: cache),
            .install(published, into: cache)
        )
    }
}

/// Running that decision: what is downloaded, in what order, and what happens
/// when a pack fails.
final class EngineWeightsPreparationTests: XCTestCase {

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

    private var cache: EngineModelCache {
        EngineModelCache(
            directory: cacheRoot.appendingPathComponent("test-model", isDirectory: true),
            requiredEntries: ["weights.bin", "vocab.json"]
        )
    }

    /// Builds a real `.tar.gz` of a cache folder and the pack that describes it.
    /// Real `tar` rather than a stub: the archive format is part of what the
    /// production path does.
    private func makePack(
        corruptChecksum: Bool = false,
        alsoClaiming extraEntries: [String] = []
    ) throws -> (pack: ModelPack, archive: URL) {
        let entries = ["weights.bin": "weights", "vocab.json": "{}"]
        let source = workDirectory.appendingPathComponent("source/test-model", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in entries {
            try Data(contents.utf8).write(to: source.appendingPathComponent(name))
        }
        let archive = workDirectory.appendingPathComponent("test-model.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, "test-model"]
        try tar.run()
        tar.waitUntilExit()

        let pack = ModelPack(
            id: "test-model",
            version: "1.0.0",
            engine: .sensevoice,
            cacheFolder: "test-model",
            entries: ["weights.bin", "vocab.json"] + extraEntries,
            sizeInBytes: (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0,
            sha256: corruptChecksum ? String(repeating: "b", count: 64) : try FileDigest.sha256(of: archive),
            url: URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/models/t.tar.gz")!,
            minimumAppVersion: nil
        )
        return (pack, archive)
    }

    /// The real installer over a throwaway cache root and a file already on
    /// disk, so the production install path runs without a network.
    private func realInstaller(_ downloader: RecordingFileDownloader) -> EngineWeightsPreparation.Installing {
        let root = cacheRoot!
        return { _ in ModelPackInstaller(cacheRoot: root, downloader: downloader) }
    }

    private func preparation(
        packs: [ModelPack],
        installer: @escaping EngineWeightsPreparation.Installing,
        log: Log,
        cache: EngineModelCache? = nil
    ) -> EngineWeightsPreparation {
        let cache = cache ?? self.cache
        return EngineWeightsPreparation(
            packs: packs,
            cacheFor: { _ in cache },
            makeInstaller: installer,
            download: { engine, _ in log.record("download:\(engine.rawValue)") }
        )
    }

    /// Nothing published: the engine fetches its own weights exactly as before,
    /// and no installer is even constructed.
    func testWithoutAPackOnlyTheEnginesOwnDownloadRuns() async throws {
        let log = Log()

        try await preparation(
            packs: [],
            installer: { _ in log.record("installer-made"); return FailingInstaller() },
            log: log
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["download:sensevoice"])
    }

    /// The requirement stated as behaviour: with a pack listed, the verified
    /// installer runs *first*, and the engine's own step follows only to pay the
    /// Neural Engine compile the pack cannot.
    func testAPublishedPackIsInstalledBeforeTheEnginesOwnPreparation() async throws {
        let (pack, archive) = try makePack()
        let log = Log()
        let downloader = RecordingFileDownloader(file: archive, log: log)

        try await preparation(
            packs: [pack],
            installer: realInstaller(downloader),
            log: log
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["pack-download", "download:sensevoice"])
        for entry in pack.entries {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: cache.directory.appendingPathComponent(entry).path
                ),
                entry
            )
        }
    }

    /// The rule that makes a thinner app safe for people who already have the
    /// weights: an existing cache is checked *before* anything is fetched, and
    /// is never replaced. The engine's own step still runs, and with the cache
    /// populated it downloads nothing.
    func testAnExistingCacheIsNeitherDownloadedAgainNorOverwritten() async throws {
        let (pack, archive) = try makePack()
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        for entry in pack.entries {
            try Data("the user's own copy".utf8).write(to: cache.directory.appendingPathComponent(entry))
        }

        let log = Log()
        let downloader = RecordingFileDownloader(file: archive, log: log)

        try await preparation(
            packs: [pack],
            installer: realInstaller(downloader),
            log: log
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["download:sensevoice"], "an installed model must not cost the user a download")
        XCTAssertEqual(
            try String(contentsOf: cache.directory.appendingPathComponent("weights.bin"), encoding: .utf8),
            "the user's own copy"
        )
    }

    /// The installer's third rule, at the call site: a pack that fails leaves
    /// the app able to fall back. Bad bytes never reach the cache, and what runs
    /// instead is the same download the app would have done had no pack been
    /// listed at all.
    func testAPackThatFailsItsChecksumInstallsNothingAndFallsBack() async throws {
        let (pack, archive) = try makePack(corruptChecksum: true)
        let log = Log()
        let downloader = RecordingFileDownloader(file: archive, log: log)

        try await preparation(
            packs: [pack],
            installer: realInstaller(downloader),
            log: log
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["pack-download", "download:sensevoice"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.directory.path),
            "nothing may be left in the cache"
        )
        XCTAssertEqual(downloader.discarded, ["pack-test-model-1.0.0"], "bad bytes are not kept to be resumed")
    }

    /// An archive that unpacks but cannot fill the cache is caught after
    /// extraction and before anything is moved - a cache holding some of the
    /// entries is worse than an empty one, because the engine would then find
    /// files, fail to load them, and have nothing left to download.
    ///
    /// The archive here really is short of what the pack claims, so the check
    /// under test is the production one rather than a stub's opinion of it.
    func testAnIncompletePackLeavesNoFilesBehindAndStillFallsBack() async throws {
        let (pack, archive) = try makePack(alsoClaiming: ["encoder.mlmodelc"])
        let log = Log()
        let downloader = RecordingFileDownloader(file: archive, log: log)

        try await preparation(
            packs: [pack],
            installer: realInstaller(downloader),
            log: log
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["pack-download", "download:sensevoice"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent("weights.bin").path),
            "a partial cache is worse than none"
        )
    }

    /// Cancelling has to mean cancelling. Falling back here would turn "stop
    /// this download" into "start a different, larger one".
    func testACancelledPackInstallDoesNotStartADownload() async throws {
        let log = Log()
        let preparer = preparation(
            packs: [try makePack().pack],
            installer: { _ in CancellingInstaller() },
            log: log
        )

        do {
            try await preparer.prepare(.sensevoice, progressHandler: { _ in })
            XCTFail("a cancelled install must not be reported as success")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(log.entries, [])
    }

    /// The same rule for the other way a cancel surfaces: `URLSession` reports
    /// a cancelled transfer as `URLError(.cancelled)`, not `CancellationError`,
    /// and which of the two escapes the stall watchdog first is timing. Both
    /// must mean "stop" - and callers see one cancellation type either way.
    func testATransferCancelledThroughURLSessionDoesNotStartADownloadEither() async throws {
        let log = Log()
        let preparer = preparation(
            packs: [try makePack().pack],
            installer: { _ in URLSessionCancellingInstaller() },
            log: log
        )

        do {
            try await preparer.prepare(.sensevoice, progressHandler: { _ in })
            XCTFail("a cancelled install must not be reported as success")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(log.entries, [])
    }

    /// And for a cancel that surfaces as neither: a transfer that dies with an
    /// ordinary error on a task that was already cancelled. The error's type no
    /// longer decides - the cancellation check before the fallback does.
    func testAPackFailureOnACancelledTaskDoesNotStartADownload() async throws {
        let log = Log()
        let preparer = preparation(
            packs: [try makePack().pack],
            installer: { _ in FailingOnceCancelledInstaller() },
            log: log
        )

        let task = Task { try await preparer.prepare(.sensevoice, progressHandler: { _ in }) }
        task.cancel()

        do {
            try await task.value
            XCTFail("a cancelled preparation must not be reported as success")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(log.entries, [], "a cancelled task must not start a download on its way out")
    }

    /// Pack progress is reported on the scale FluidAudio already uses - bytes
    /// fill the first half, the compile the second - so the three surfaces that
    /// render it do not have to learn a second convention.
    func testPackProgressIsReportedOnTheScaleTheEnginesAlreadyUse() {
        let half = EngineWeightsPreparation.engineProgress(
            from: DownloadProgress(receivedBytes: 50, totalBytes: 100)
        )
        XCTAssertEqual(half.fractionCompleted, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ModelPreparationStage.from(half), .downloading(fraction: 0.5))

        let whole = EngineWeightsPreparation.engineProgress(
            from: DownloadProgress(receivedBytes: 100, totalBytes: 100)
        )
        XCTAssertEqual(whole.fractionCompleted, downloadShareOfOverallProgress, accuracy: 0.0001)
        XCTAssertEqual(
            ModelPreparationStage.from(whole), .downloading(fraction: 1.0),
            "a finished pack download must read as a finished download, not half of one"
        )
    }

    /// The invariant that cannot be expressed as a type: no production caller
    /// may fetch weights straight from an engine, because that is exactly the
    /// bypass a published pack exists to close.
    ///
    /// A source scan rather than a behavioural test, because the failure guarded
    /// against is a future edit adding one line - and the honest way to catch
    /// that is to read the lines. Skipped rather than failed when the sources
    /// are not beside the tests.
    func testNoProductionCallerFetchesWeightsWithoutThePreparer() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        guard let files = FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String] else {
            throw XCTSkip("Sources are not beside the tests: \(sources.path)")
        }

        let seam = "Engines/EngineWeightsPreparation.swift"
        var scanned = 0
        for file in files where file.hasSuffix(".swift") && file != seam {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            scanned += 1
            XCTAssertFalse(
                text.contains(".prepareModels("),
                "\(file) prepares an engine's weights directly. Every path that fetches weights goes "
                    + "through EngineWeightsPreparation, which is what installs a published model pack "
                    + "instead of downloading the same weights unverified."
            )
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources, so it proved almost nothing")
    }

    // MARK: - On real weights

    /// The production path, end to end, on the model that is actually going to
    /// be published as a pack: pack the real staged weights, run the *preparer*
    /// (not the installer directly), and check that what lands in the cache is
    /// everything `SenseVoiceEngine` requires and that **CoreML loads it**.
    ///
    /// Byte-identical files would not be enough on their own - a lost extended
    /// attribute or permission bit could still break the load - so this loads
    /// it. An installed pack that CoreML refuses is a cache the engine can never
    /// load, and because `isModelDownloaded` only looks for the files there
    /// would be nothing left to re-download.
    ///
    /// Opt-in on locally staged weights, the same way the engine integration
    /// tests are: `Scripts/package_starter_model.sh --stage-from-cache` puts one
    /// at `StarterModel/sensevoice-small`. Without it the test says why it did
    /// nothing rather than failing on a machine that has never downloaded them.
    func testARealSenseVoicePackReachesTheEngineSCacheAndLoads() async throws {
        let staged = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StarterModel/sensevoice-small")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw XCTSkip(
                "No staged weights at \(staged.path). Run Scripts/package_starter_model.sh --stage-from-cache."
            )
        }

        // Packed by the same command the publishing script runs, so this is the
        // format that is actually published rather than one the test invented.
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

        // The decision the app makes for a real published pack, taken against
        // the real engine's cache layout rather than a fixture's.
        let engineCache = try XCTUnwrap(EngineModelCache.of(.sensevoice))
        XCTAssertEqual(
            ModelPackSelection.of(.sensevoice, in: [pack], cache: engineCache),
            .install(pack, into: engineCache),
            "the pack this repository publishes has to be the one the app installs"
        )

        // Run it into a throwaway cache root: a test must never write several
        // hundred megabytes into the developer's real Application Support. The
        // folder name and required entries are the engine's own, so only the
        // directory it sits in is a fixture.
        let log = Log()
        let downloader = RecordingFileDownloader(file: archive, log: log)
        try await preparation(
            packs: [pack],
            installer: realInstaller(downloader),
            log: log,
            cache: EngineModelCache(
                directory: cacheRoot.appendingPathComponent(engineCache.folderName, isDirectory: true),
                requiredEntries: engineCache.requiredEntries
            )
        ).prepare(.sensevoice, progressHandler: { _ in })

        XCTAssertEqual(log.entries, ["pack-download", "download:sensevoice"])

        let installed = cacheRoot.appendingPathComponent("sensevoice-small")
        for entry in SenseVoiceEngine.requiredCacheEntries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent(entry).path), entry)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(
            contentsOf: installed.appendingPathComponent("SenseVoiceSmall_int8.mlmodelc"),
            configuration: configuration
        )
        XCTAssertFalse(model.modelDescription.inputDescriptionsByName.isEmpty)
    }
}

/// What ran, in the order it ran. The ordering is the assertion in several of
/// these: "the pack was installed" and "the pack was installed *before* the
/// engine's own download" are different claims.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func record(_ entry: String) {
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }
}

/// Hands the real installer a file that is already on disk, so the production
/// install path runs without a network.
private final class RecordingFileDownloader: ResumableFileDownloading, @unchecked Sendable {
    private let file: URL
    private let log: Log
    private let lock = NSLock()
    private var _discarded: [String] = []

    init(file: URL, log: Log) {
        self.file = file
        self.log = log
    }

    var discarded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _discarded
    }

    func download(
        from url: URL,
        declaredBytes: Int64,
        key: String,
        familyPrefix: String?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> (file: URL, key: String) {
        log.record("pack-download")
        progress(DownloadProgress(receivedBytes: declaredBytes, totalBytes: declaredBytes))
        return (file, key)
    }

    func discard(key: String) {
        lock.lock()
        _discarded.append(key)
        lock.unlock()
    }
}

private struct FailingInstaller: ModelPackInstalling {
    var error: ModelPackInstallError = .archiveCouldNotBeRead("stub")

    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ModelPackInstallOutcome {
        throw error
    }
}

private struct CancellingInstaller: ModelPackInstalling {
    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ModelPackInstallOutcome {
        throw CancellationError()
    }
}

private struct URLSessionCancellingInstaller: ModelPackInstalling {
    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ModelPackInstallOutcome {
        throw URLError(.cancelled)
    }
}

/// Waits until the surrounding task is cancelled, then throws the kind of
/// ordinary error a dying transfer produces - the case where the error's type
/// says nothing about the cancellation.
private struct FailingOnceCancelledInstaller: ModelPackInstalling {
    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ModelPackInstallOutcome {
        while !Task.isCancelled {
            await Task.yield()
        }
        throw ModelPackInstallError.archiveCouldNotBeRead("the connection died mid-transfer")
    }
}
