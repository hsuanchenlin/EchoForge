import Foundation

/// The speech model a build can ship with, so a fresh install can dictate before
/// it has downloaded anything.
///
/// Two constraints shape all of this. The weights are large and third-party, so
/// they are never committed to this repository - the release operator supplies
/// the artifact at package time and `Scripts/package_starter_model.sh` puts it
/// in the app bundle (`docs/starter-model.md`). And a build packaged *without*
/// the artifact has to keep working exactly as before, because that is what CI
/// and every developer checkout are: every entry point here answers "not
/// bundled" rather than failing.
///
/// The install target is deliberately the normal FluidAudio cache the engine
/// already downloads into, not a second location the engine would have to learn
/// about. So the starter is indistinguishable from a completed download the
/// moment it is in place: `SenseVoiceEngine.isModelDownloaded` becomes true, the
/// Settings row shows its usual downloaded badge, and deleting the cache falls
/// back to downloading exactly as it always did.
enum StarterModel {

    /// The engine the bundled weights belong to.
    static var engine: EngineKind { EngineSelector.starterEngine }

    /// The folder in the app bundle's `Resources` that the packaging script
    /// writes into. Inside it is one directory per engine cache, named exactly
    /// as the cache is, so installing is a folder-to-folder copy.
    static let bundleFolderName = "StarterModel"

    /// What the copy has to produce for the engine to consider the model
    /// present. Asked of the engine rather than listed here: it is the one that
    /// knows which encoder precision it loads and therefore which files count.
    static var requiredEntries: [String] { SenseVoiceEngine.requiredCacheEntries }

    /// Where the weights end up. The engine's own cache, unchanged.
    static var cacheDirectory: URL { SenseVoiceEngine.modelCacheDirectory }

    /// Whether the weights are usable right now - by any route, bundled or
    /// downloaded. This is the question the rest of the app asks.
    static var isInstalled: Bool { SenseVoiceEngine.isModelDownloaded }

    /// Whether *this build* carries the weights, as opposed to being able to
    /// download them. It changes what the app may claim about where the model
    /// came from - see `EngineCatalog.provenanceLine`.
    static var isBundledWithThisBuild: Bool { bundledPayloadDirectory() != nil }

    /// What one bootstrap attempt did, so the caller can log it and tests can
    /// assert it.
    enum InstallOutcome: Equatable {
        /// This build ships no starter weights. The normal, expected answer for
        /// a developer checkout and for CI.
        case notBundled

        /// The cache already holds a usable model - a previous bootstrap, or a
        /// download the user paid for. Nothing is overwritten: a cache the user
        /// already has is never replaced by the bundled copy.
        case alreadyInstalled

        /// The weights were copied into the cache and the engine can now load
        /// them without a network round trip.
        case installed

        /// The bundle carries a starter folder that does not contain everything
        /// the engine needs. A packaging mistake, and reported as one rather
        /// than left to surface as a load failure much later.
        case incomplete(missing: [String])
    }

    /// Puts the bundled weights into the model cache if they are needed and
    /// present.
    ///
    /// Called once at launch, before anything reads `EngineAvailability`, so the
    /// first thing the app computes about itself already accounts for them.
    ///
    /// Every path is injectable because the alternative is a test that writes
    /// several hundred megabytes into the developer's real Application Support
    /// directory.
    @discardableResult
    static func installIfNeeded(
        bundledDirectory: URL? = bundledPayloadDirectory(),
        cacheDirectory: URL = StarterModel.cacheDirectory,
        requiredEntries: [String] = StarterModel.requiredEntries,
        fileManager: FileManager = .default
    ) -> InstallOutcome {
        guard let bundledDirectory else { return .notBundled }

        let missing = requiredEntries.filter {
            !fileManager.fileExists(atPath: bundledDirectory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else { return .incomplete(missing: missing) }

        let alreadyPresent = requiredEntries.allSatisfy {
            fileManager.fileExists(atPath: cacheDirectory.appendingPathComponent($0).path)
        }
        guard !alreadyPresent else { return .alreadyInstalled }

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            for entry in requiredEntries {
                let destination = cacheDirectory.appendingPathComponent(entry)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try copyAtomically(
                    from: bundledDirectory.appendingPathComponent(entry),
                    to: destination,
                    fileManager: fileManager
                )
            }
        } catch {
            // A half-copied cache is worse than none: the engine would find the
            // files, fail to load them, and there would be nothing to download
            // because everything "exists". So a failure takes the partial copy
            // with it and the app falls back to downloading.
            for entry in requiredEntries {
                try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(entry))
            }
            print("Starter model could not be installed: \(error)")
            return .notBundled
        }

        return .installed
    }

    /// The starter folder inside the running app bundle, or `nil` in a build
    /// packaged without one.
    static func bundledPayloadDirectory(in bundle: Bundle = .main) -> URL? {
        guard let root = bundle.url(forResource: bundleFolderName, withExtension: nil) else { return nil }
        let payload = root.appendingPathComponent(cacheDirectory.lastPathComponent, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: payload.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return payload
    }

    // MARK: - Private

    /// Copies one cache entry via a temporary name in the destination directory,
    /// so a crash or a full disk leaves no half-written `.mlmodelc` that the
    /// engine would later treat as present.
    private static func copyAtomically(from source: URL, to destination: URL, fileManager: FileManager) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).installing")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
