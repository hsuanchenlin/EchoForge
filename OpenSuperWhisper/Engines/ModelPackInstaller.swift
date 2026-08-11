import Foundation

/// What one pack install did.
enum ModelPackInstallOutcome: Equatable {
    /// The cache already holds everything the engine needs. Nothing is
    /// downloaded and nothing is overwritten - a model the user already paid
    /// hundreds of megabytes of bandwidth for always wins over a fresh copy of
    /// the same thing. This is also what makes the whole design safe for
    /// existing users: an app that gets thinner does not touch what is already
    /// installed.
    case alreadyInstalled

    case installed(ModelPack)
}

enum ModelPackInstallError: LocalizedError, Equatable {
    case checksumMismatch(expected: String, found: String)
    case archiveCouldNotBeRead(String)
    case incompleteAfterExtraction(missing: [String])

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let expected, let found):
            return "The model download does not match its published checksum "
                + "(\(found.prefix(12))… instead of \(expected.prefix(12))…). It was discarded."
        case .archiveCouldNotBeRead(let detail):
            return "The model download could not be unpacked. \(detail)"
        case .incompleteAfterExtraction(let missing):
            return "The model download is missing \(missing.joined(separator: ", ")). It was discarded."
        }
    }
}

/// Which pack, if any, provides an engine's weights.
///
/// Answers `nil` for every engine `ModelPacks.json` does not list, and that is
/// the point: an unlisted engine downloads weights the way it always did, so
/// publishing the asset and naming it there is what switches an engine over and
/// nothing else. SenseVoice is listed; every other engine is not, and Paraformer
/// cannot be until `docs/speech-model-attribution.md` says so.
/// `EngineWeightsPreparation` is the one production caller - every path that
/// fetches weights goes through it.
enum ModelPackCatalog {
    static func pack(for engine: EngineKind, in packs: [ModelPack] = ModelPackManifest.bundled()) -> ModelPack? {
        packs.first { $0.engine == engine }
    }
}

/// Installing a pack, behind a protocol.
///
/// It exists so `EngineWeightsPreparation` - which decides *whether* a pack is
/// used at all, and what happens when one fails - can be driven without a
/// network and without several hundred megabytes of anyone's bandwidth.
/// `ModelPackInstaller` is the only production conformer.
protocol ModelPackInstalling {
    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ModelPackInstallOutcome
}

extension ModelPackInstaller: ModelPackInstalling {}

/// Installs a model pack into the cache the engine already loads from.
///
/// Three rules, each inherited deliberately from `StarterModel`, which learned
/// them the hard way:
///
/// - **An existing cache is never overwritten.** The check happens before
///   anything is downloaded, so a user with the model already pays nothing.
/// - **A partial install is never left behind.** A cache holding some of the
///   entries is worse than an empty one: the engine finds files, fails to load
///   them, and there is nothing to download because everything "exists".
/// - **A failure leaves the app able to fall back.** Nothing here is required
///   for the app to work; if it throws, the engine's own downloader is still
///   there.
///
/// The archive format is `.tar.gz` and the contents are one directory named
/// exactly as the cache folder. That was measured rather than assumed: a
/// `.mlmodelc` round-trips through tar byte for byte and CoreML loads the
/// extracted copy - see `docs/model-packs.md`.
struct ModelPackInstaller {
    /// Where the engine caches live. Injected so a test never writes several
    /// hundred megabytes into the developer's real Application Support.
    let cacheRoot: URL
    let fileManager: FileManager
    let commandRunner: CommandRunning
    let downloader: ResumableFileDownloading

    init(
        cacheRoot: URL,
        fileManager: FileManager = .default,
        commandRunner: CommandRunning = SystemCommandRunner(),
        downloader: ResumableFileDownloading = ResumableFileDownloader()
    ) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.downloader = downloader
    }

    func cacheDirectory(for pack: ModelPack) -> URL {
        cacheRoot.appendingPathComponent(pack.cacheFolder, isDirectory: true)
    }

    /// Whether the engine would already find everything it needs.
    func isInstalled(_ pack: ModelPack) -> Bool {
        let directory = cacheDirectory(for: pack)
        return pack.entries.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The receipt beside the cache, recording which pack put it there. Not load
    /// bearing for loading the model - the engine looks for its files and
    /// nothing else - but it is what tells "installed from pack 1.0.0" apart
    /// from "downloaded by the engine itself" when a pack is superseded.
    func installedReceipt(for pack: ModelPack) -> ModelPackReceipt? {
        let url = receiptURL(for: pack)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelPackReceipt.self, from: data)
    }

    @discardableResult
    func install(
        _ pack: ModelPack,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> ModelPackInstallOutcome {
        guard !isInstalled(pack) else { return .alreadyInstalled }

        let archive = try await downloader.download(
            from: pack.url,
            declaredBytes: pack.sizeInBytes,
            key: "pack-\(pack.id)-\(pack.version)",
            familyPrefix: "pack-\(pack.id)-",
            progress: progress
        )

        let digest = try FileDigest.sha256(of: archive.file)
        guard digest == pack.sha256 else {
            downloader.discard(key: archive.key)
            throw ModelPackInstallError.checksumMismatch(expected: pack.sha256, found: digest)
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("EchoForgeModelPack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // `tar` rather than a Swift archiver: it is what produced the pack, it
        // is on every Mac, and `.mlmodelc` is a directory of several files whose
        // round trip through it was measured rather than assumed.
        let extraction = try commandRunner.run(
            "/usr/bin/tar",
            ["-xzf", archive.file.path, "-C", staging.path]
        )
        guard extraction.status == 0 else {
            throw ModelPackInstallError.archiveCouldNotBeRead(extraction.output)
        }

        let extracted = staging.appendingPathComponent(pack.cacheFolder, isDirectory: true)
        let missing = pack.entries.filter {
            !fileManager.fileExists(atPath: extracted.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw ModelPackInstallError.incompleteAfterExtraction(missing: missing)
        }

        try installEntries(from: extracted, of: pack)

        // Only now that the cache is complete are the downloaded bytes of no
        // further use.
        downloader.discard(key: archive.key)
        return .installed(pack)
    }

    // MARK: - Private

    private func receiptURL(for pack: ModelPack) -> URL {
        cacheDirectory(for: pack).appendingPathComponent("echoforge-pack.json")
    }

    /// Moves each entry into the cache, and takes the whole lot back out again
    /// if any of them fails. The alternative - a cache with three of four
    /// entries - is the failure `StarterModel` documents as worse than none.
    private func installEntries(from extracted: URL, of pack: ModelPack) throws {
        let destination = cacheDirectory(for: pack)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var written: [URL] = []
        do {
            for entry in pack.entries {
                let target = destination.appendingPathComponent(entry)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                // Through a temporary name in the destination directory, so a
                // crash or a full disk leaves no half-written `.mlmodelc` that
                // the engine would later treat as present.
                let scratch = destination.appendingPathComponent(".\(entry).incoming-\(UUID().uuidString)")
                try fileManager.moveItem(at: extracted.appendingPathComponent(entry), to: scratch)
                try fileManager.moveItem(at: scratch, to: target)
                written.append(target)
            }
            let receipt = ModelPackReceipt(id: pack.id, version: pack.version, entries: pack.entries)
            if let data = try? JSONEncoder().encode(receipt) {
                try? data.write(to: receiptURL(for: pack), options: .atomic)
            }
        } catch {
            written.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
    }
}

/// What a pack install left behind, so a later one can tell what is already
/// there and where it came from.
struct ModelPackReceipt: Codable, Equatable {
    let id: String
    let version: String
    let entries: [String]
}
