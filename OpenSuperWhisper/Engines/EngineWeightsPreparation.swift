import Foundation
import FluidAudio

/// Where one engine keeps the weights it loads, as the two halves a pack has to
/// agree with.
///
/// A pack installs into the directory the engine already downloads into - that
/// is what makes an installed pack indistinguishable from a finished download,
/// and what keeps `isModelDownloaded`, Settings' badges and "delete the cache to
/// re-download" working with no knowledge of packs at all. The agreement has to
/// be checkable rather than assumed: a pack claiming `sensevoice` while naming
/// some other cache folder would install weights into a sibling directory
/// nothing ever reads, and the engine would then download them all over again.
struct EngineModelCache: Equatable {
    /// The models directory the engine's folder sits in, which is what a pack is
    /// installed relative to. Deliberately the *parent*: a pack carries its own
    /// folder name, and `ModelPackManifest` has already checked that name is one
    /// path component.
    let root: URL

    /// The engine's cache directory name, exactly as its own downloader creates
    /// it.
    let folderName: String

    /// What has to be in that folder before the engine will load, where the
    /// engine publishes a single authority for it. `nil` where it does not, in
    /// which case the pack's own entry list is all there is to check against.
    let requiredEntries: [String]?

    var directory: URL { root.appendingPathComponent(folderName, isDirectory: true) }

    init(directory: URL, requiredEntries: [String]?) {
        self.root = directory.deletingLastPathComponent()
        self.folderName = directory.lastPathComponent
        self.requiredEntries = requiredEntries
    }

    /// Switched exhaustively, so a new engine has to say where its weights live
    /// before a pack can ever be listed for it.
    static func of(_ engine: EngineKind) -> EngineModelCache? {
        switch engine {
        case .sensevoice:
            return EngineModelCache(
                directory: SenseVoiceEngine.modelCacheDirectory,
                // The engine is the authority on which files count - it is the
                // one that knows which encoder precision it loads.
                requiredEntries: SenseVoiceEngine.requiredCacheEntries
            )
        case .paraformer:
            return EngineModelCache(directory: ParaformerEngine.modelCacheDirectory, requiredEntries: nil)
        case .whisper, .fluidaudio:
            // Neither is one cache directory a pack could name: Whisper loads a
            // model file the user chooses, and Parakeet picks between model
            // versions with a cache each.
            return nil
        }
    }
}

/// How an engine's weights are to be fetched, as a value rather than a branch
/// buried in the download path.
///
/// Pure and exhaustive for the same reason `EngineSelector` is: this is the
/// decision that says whether verified bytes or unverified ones reach the
/// directory CoreML loads from, and it is worth being able to assert without a
/// network.
enum ModelPackSelection: Equatable {
    /// A pack is published for this engine and every rule it has to satisfy
    /// holds. It is what runs.
    case install(ModelPack, into: EngineModelCache)

    /// No usable pack, so the engine fetches its own weights as it always has.
    case downloadThroughEngine(reason: Reason)

    enum Reason: Equatable {
        /// No pack this build may install is listed for the engine - it is
        /// unlisted, or its pack needs a newer app - so its download is exactly
        /// what it always was.
        case noPackIsPublished

        /// Whisper and Parakeet: no single cache directory a pack could fill.
        case engineHasNoPackableCache

        /// A packaging mistake, and the one that would otherwise be invisible:
        /// the weights would install into a directory the engine never reads and
        /// the download would happen anyway, minus the disk space.
        case packNamesADifferentCacheFolder(String)

        /// The pack cannot populate the cache on its own, so installing it would
        /// leave exactly the half-filled cache `ModelPackInstaller` exists to
        /// prevent - the engine finds files, fails to load them, and there is
        /// nothing to download because everything "exists".
        case packIsMissingEntriesTheEngineNeeds([String])
    }

    /// The decision, for one engine. `cache` is passed in rather than looked up
    /// here so this stays a function of its arguments - the caller knows where
    /// the engine's weights live, and a test can say.
    static func of(
        _ engine: EngineKind,
        in packs: [ModelPack],
        cache: EngineModelCache?
    ) -> ModelPackSelection {
        guard let pack = ModelPackCatalog.pack(for: engine, in: packs) else {
            return .downloadThroughEngine(reason: .noPackIsPublished)
        }
        guard let cache else {
            return .downloadThroughEngine(reason: .engineHasNoPackableCache)
        }
        guard pack.cacheFolder == cache.folderName else {
            return .downloadThroughEngine(reason: .packNamesADifferentCacheFolder(pack.cacheFolder))
        }
        if let required = cache.requiredEntries {
            let missing = required.filter { !pack.entries.contains($0) }
            guard missing.isEmpty else {
                return .downloadThroughEngine(reason: .packIsMissingEntriesTheEngineNeeds(missing))
            }
        }
        return .install(pack, into: cache)
    }
}

/// The one place "make this engine's weights ready" turns into fetched bytes.
///
/// Two routes end here and they are deliberately not peers. A **model pack** is
/// the checked one: an allow-listed GitHub release URL, a published SHA-256, a
/// size bound, a resumable transfer and an atomic install into the directory the
/// engine already loads from. The engine's own downloader is the unchecked one
/// this app inherited - Hugging Face, no digest, no host rule, no version of its
/// own - and it stays, because it is what works when no pack is published for
/// the engine, which is still every engine but SenseVoice.
///
/// So the rule this type exists to keep: **when a usable pack is listed for an
/// engine, the pack installer is what runs.** No caller may reach an engine's
/// own downloader for weights a pack could have verified, which is why all three
/// production callers - background preparation in `TranscriptionService`,
/// Settings, and onboarding - come through here and none of them calls
/// `prepareModels` itself. `EngineWeightsPreparationTests` holds both halves,
/// including a source scan for the second.
///
/// Three consequences are worth stating because each once looked like a
/// simplification:
///
/// - **The engine's own preparation still runs afterwards, always.** Fetching
///   the bytes is half of preparing a model; the Neural Engine compile is the
///   other half and only the engine can pay it. With the cache populated that
///   call downloads nothing - FluidAudio checks the files exist and goes
///   straight to loading - so a pack turns a download plus a compile into a
///   verified download plus the same compile.
/// - **A pack that fails is a fallback, not a dead end.** The installer's third
///   rule: nothing here is required for the app to work. Bad bytes are
///   discarded and never reach the cache, and what runs instead is the same
///   download the app would have done had no pack been listed at all - so the
///   fallback weakens nothing that was not already the status quo.
/// - **A cancellation is not a failure.** The user asked for it to stop, so it
///   stops; falling back would turn "cancel" into "start a different, larger
///   download". A cancelled transfer does not surface as one error type:
///   `URLSession` reports its cancelled task as `URLError(.cancelled)` while
///   the stall watchdog's poll throws `CancellationError`, and which escapes
///   the task group first is timing. `prepare` reads both as cancellation and
///   checks once more before any download starts, so the rule holds by
///   construction rather than by winning that race.
struct EngineWeightsPreparation {
    /// How an engine fetches its own weights. Injected so the decision above can
    /// be driven in a test without several hundred megabytes of anyone's
    /// bandwidth.
    typealias EngineDownload = @Sendable (EngineKind, @escaping DownloadUtils.ProgressHandler) async throws -> Void

    /// How a pack is installed into one engine's cache. Injected for the same
    /// reason, and so a test never writes several hundred megabytes into the
    /// developer's real Application Support.
    typealias Installing = @Sendable (EngineModelCache) -> ModelPackInstalling

    /// The packs this build may install. Empty is a working state - see
    /// `ModelPackManifest.bundled`.
    let packs: [ModelPack]

    /// Where each engine keeps its weights. Injected together with the installer
    /// so a test can point the whole install at a throwaway directory.
    let cacheFor: @Sendable (EngineKind) -> EngineModelCache?

    let makeInstaller: Installing

    let download: EngineDownload

    /// The production preparer: the list that ships inside the app, the engines'
    /// own caches, the real installer, and each engine's own downloader.
    static var production: EngineWeightsPreparation {
        EngineWeightsPreparation(
            packs: ModelPackManifest.bundled(),
            cacheFor: EngineModelCache.of,
            makeInstaller: { ModelPackInstaller(cacheRoot: $0.root) },
            download: downloadThroughEngine
        )
    }

    /// Fetches whatever the engine is missing and leaves it ready to load.
    func prepare(_ engine: EngineKind, progressHandler: @escaping DownloadUtils.ProgressHandler) async throws {
        if case .install(let pack, let cache) = ModelPackSelection.of(engine, in: packs, cache: cacheFor(engine)) {
            do {
                let outcome = try await makeInstaller(cache).install(
                    pack,
                    progress: { progressHandler(Self.engineProgress(from: $0)) }
                )
                if case .alreadyInstalled = outcome {
                    // The user already has these weights, by pack or by
                    // download, and they are never replaced.
                    print("Model pack \(pack.id): the cache already holds it.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                print("Model pack \(pack.id) could not be installed (\(error.localizedDescription)); "
                    + "falling back to \(engine.rawValue)'s own download.")
            }
        }

        try Task.checkCancellation()
        try await download(engine, progressHandler)
    }

    /// A pack's byte counts, on the scale the rest of the app already reads.
    ///
    /// FluidAudio scales its own byte progress by `downloadShareOfOverallProgress`
    /// and spends the remainder on the compile, and all three surfaces here are
    /// written for that convention. Reporting a pack download on the same scale
    /// is what keeps them honest without teaching any of them a second one: the
    /// bar fills to half while bytes move and finishes during the compile,
    /// exactly as it does for a download the engine did itself.
    static func engineProgress(from progress: DownloadProgress) -> DownloadUtils.DownloadProgress {
        DownloadUtils.DownloadProgress(
            fractionCompleted: progress.fraction * downloadShareOfOverallProgress,
            phase: .downloading(completedFiles: 0, totalFiles: 1)
        )
    }

    /// The one place each engine says how it fetches its own weights. Switched
    /// exhaustively so a new engine has to answer.
    static func downloadThroughEngine(
        _ engine: EngineKind,
        progressHandler: @escaping DownloadUtils.ProgressHandler
    ) async throws {
        switch engine {
        case .sensevoice:
            try await SenseVoiceEngine.prepareModels(progressHandler: progressHandler)
        case .paraformer:
            try await ParaformerEngine.prepareModels(progressHandler: progressHandler)
        case .fluidaudio:
            let stored = await MainActor.run { AppPreferences.shared.fluidAudioModelVersion }
            let version: AsrModelVersion = stored == "v2" ? .v2 : .v3
            _ = try await AsrModels.downloadAndLoad(version: version, progressHandler: progressHandler)
        case .whisper:
            // Unreachable from every caller: `EngineConfiguration.isPreparable`
            // says Whisper needs a model file the app cannot choose on the
            // user's behalf, and Settings and onboarding both guard on the
            // engine having a single download before they get here.
            throw TranscriptionError.engineNotConfigured
        }
    }
}
