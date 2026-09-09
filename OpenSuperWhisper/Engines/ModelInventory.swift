import Foundation
import FluidAudio

/// How much of the disk a directory of model weights is actually using.
///
/// Actual bytes rather than the advertised download size, because the two
/// disagree in both directions and the difference is the whole reason a user
/// opens this: a CoreML cache is larger on disk than the archive it arrived in
/// (the Neural Engine compile writes beside the weights), a half-finished
/// download is smaller, and a cache the user deleted from Finder is zero while
/// every "240 MB" label in the app goes on claiming otherwise.
enum DirectorySize {

    /// The bytes `url` and everything under it occupy, or 0 when it does not
    /// exist. Never throws: a missing model cache is a normal state, not an
    /// error, and a size that cannot be read is reported as the zero it is
    /// indistinguishable from at this resolution.
    static func bytes(of url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileBytes(of: url) }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += fileBytes(of: child)
        }
        return total
    }

    /// Allocated size where the filesystem reports one, falling back to logical
    /// size. Allocation is what the user gets back by deleting it.
    private static func fileBytes(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        guard values.isRegularFile == true else { return 0 }
        if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
        return Int64(values.fileSize ?? 0)
    }

    /// The same figure a user would read in Finder: decimal units, one decimal
    /// place, and "-" rather than "0 bytes" for something that is not installed.
    static func describe(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "None on disk" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// Whether an engine's weights are on this Mac, and whether they are enough.
///
/// Three states rather than a bool, because a cache directory that exists is not
/// the same claim as an engine that will load: an interrupted download leaves
/// bytes on the disk that no engine can use, and the app's "downloaded" badges
/// have always been the engine's own `modelsExist` check rather than the
/// directory's existence. Naming the difference is what lets the inventory offer
/// "Remove" for the half a download that is otherwise invisible.
enum ModelReadiness: Equatable {
    /// The engine's own check says it will load.
    case ready

    /// Bytes are on the disk but the engine's check says no. An interrupted
    /// download, or a cache something deleted files out of.
    case incomplete

    /// Nothing on the disk.
    case notInstalled

    /// Being fetched or compiled right now.
    case preparing(ModelPreparationStage)

    /// This engine has no weights to install at all - the cloud engine, whose
    /// model is the provider's.
    case noWeightsToInstall

    var isReady: Bool { self == .ready }

    /// The word the inventory row leads with.
    var label: String {
        switch self {
        case .ready: return "Ready"
        case .incomplete: return "Incomplete"
        case .notInstalled: return "Not installed"
        case .preparing(let stage):
            guard let percentage = stage.percentage else { return "Preparing" }
            return "Downloading \(percentage)%"
        case .noWeightsToInstall: return "No local weights"
        }
    }
}

/// One engine, as it exists on this Mac right now.
///
/// Everything user-facing on it is read from `EngineCatalog`, which owns every
/// word the app says about an engine; what this type adds is the two facts the
/// catalog cannot know - what is actually on the disk, and whether it loads.
struct ModelInventoryEntry: Equatable, Identifiable {
    let engine: EngineKind
    let readiness: ModelReadiness

    /// What the weights occupy now. Zero for an engine with nothing installed.
    let installedBytes: Int64

    /// What a cold machine downloads, in decimal MB, or `nil` for the engines
    /// whose weights are picked model by model and for the cloud engine.
    let expectedMegabytes: Int?

    /// Where the weights live, for Reveal and for Remove. `nil` when there is
    /// no single directory - the cloud engine has none.
    let cacheDirectories: [URL]

    var id: String { engine.rawValue }

    var outcome: String { EngineCatalog.entry(for: engine).outcome }
    var displayName: String { EngineCatalog.entry(for: engine).displayName }
    var character: String { EngineCatalog.entry(for: engine).character }

    /// Whether there is anything on the disk to delete.
    var hasBytesToRemove: Bool { installedBytes > 0 && !cacheDirectories.isEmpty }

    /// "Expected 240 MB · 268.4 MB on disk", or whichever half is known.
    var sizeSummary: String {
        var parts: [String] = []
        if let expectedMegabytes { parts.append("About \(expectedMegabytes) MB to download") }
        if installedBytes > 0 {
            parts.append("\(DirectorySize.describe(installedBytes)) on disk")
        } else if expectedMegabytes != nil {
            parts.append("nothing on disk yet")
        }
        return parts.joined(separator: " · ")
    }
}

/// Where each engine keeps weights, and how much of the disk they are using.
///
/// Deliberately a pure function of a snapshot plus two injected readers, for the
/// same reason `EngineSelector` is: the alternative is a view that can only be
/// checked by downloading 900 MB of models, and the cases worth checking -
/// a half-finished cache, a cache deleted behind the app's back - are the ones
/// nobody can produce on demand.
struct ModelInventory {

    /// Every directory an engine's weights can occupy.
    ///
    /// Switched exhaustively so a new engine has to say where its bytes are
    /// before it can appear in a disk total that claims to be complete. Parakeet
    /// has two, one per model version, and both count: a user who has tried both
    /// is paying for both.
    static func cacheDirectories(for engine: EngineKind) -> [URL] {
        switch engine {
        case .whisper:
            return [AppDataLocation.whisperModelsDirectory()]
        case .fluidaudio:
            return FluidAudioModelVersion.allCases.map(\.cacheDirectory)
        case .sensevoice:
            return [SenseVoiceEngine.modelCacheDirectory]
        case .paraformer:
            return [ParaformerEngine.modelCacheDirectory]
        case .cloud:
            // The model is the provider's. Nothing is downloaded, so nothing is
            // measured and nothing can be removed.
            return []
        }
    }

    /// What a cold machine downloads for this engine, or `nil` when the answer
    /// depends on which model the user picks.
    static func expectedMegabytes(for engine: EngineKind) -> Int? {
        EngineCatalog.entry(for: engine).download?.megabytes
    }

    /// The engines the inventory lists, in the order it lists them.
    ///
    /// The picker's order, so the two surfaces agree, plus the cloud engine at
    /// the end **only when this build has one** - it has no weights, but a user
    /// counting what is on their disk is entitled to see the one engine that
    /// puts nothing there, and to be reminded which one that is.
    static var listedEngines: [EngineKind] {
        CloudBuild.isCompiledIn ? EngineCatalog.pickerOrder + [.cloud] : EngineCatalog.pickerOrder
    }

    /// Measures every listed engine.
    ///
    /// - Parameters:
    ///   - availability: what the engines' own checks say will load. Passed in
    ///     rather than read here so the whole inventory is a function of a
    ///     snapshot.
    ///   - preparing: the model being fetched right now, if any.
    ///   - sizeOfDirectory: injected so a test can describe a disk it does not
    ///     have.
    static func measure(
        availability: EngineAvailability,
        preparing: ModelPreparation? = nil,
        engines: [EngineKind]? = nil,
        sizeOfDirectory: (URL) -> Int64 = { DirectorySize.bytes(of: $0) }
    ) -> [ModelInventoryEntry] {
        (engines ?? listedEngines).map { engine in
            let directories = cacheDirectories(for: engine)
            let bytes = directories.reduce(Int64(0)) { $0 + sizeOfDirectory($1) }
            return ModelInventoryEntry(
                engine: engine,
                readiness: readiness(
                    of: engine, bytes: bytes, availability: availability, preparing: preparing),
                installedBytes: bytes,
                expectedMegabytes: expectedMegabytes(for: engine),
                cacheDirectories: directories
            )
        }
    }

    static func readiness(
        of engine: EngineKind,
        bytes: Int64,
        availability: EngineAvailability,
        preparing: ModelPreparation?
    ) -> ModelReadiness {
        if let preparing, preparing.engine == engine { return .preparing(preparing.stage) }
        if engine.usesCloudProvider { return .noWeightsToInstall }
        if availability.isUsable(engine) { return .ready }
        return bytes > 0 ? .incomplete : .notInstalled
    }

    /// Everything the app's own models occupy, across every engine.
    static func totalBytes(_ entries: [ModelInventoryEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.installedBytes }
    }
}

/// The Parakeet model versions, and where each one caches.
///
/// A type rather than two string literals because the version is a *preference*
/// (`fluidAudioModelVersion`) that several places turn into an `AsrModelVersion`,
/// and the disk total has to cover both whether or not the user is on them.
enum FluidAudioModelVersion: String, CaseIterable {
    case v2
    case v3

    /// The stored preference, mapped the way every other reader maps it: an
    /// unrecognised value is v3, which is what `EngineAvailability` and
    /// `EngineWeightsPreparation` already do.
    static func stored(_ raw: String) -> FluidAudioModelVersion {
        raw == "v2" ? .v2 : .v3
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        }
    }

    /// Asked of FluidAudio rather than rebuilt from a slug, the same rule the
    /// two Chinese engines follow: **this project does not own these paths**.
    var cacheDirectory: URL { AsrModels.defaultCacheDirectory(for: asrVersion) }
}
