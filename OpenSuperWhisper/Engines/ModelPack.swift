import Foundation

/// A set of model weights published as one versioned, checksummed archive.
///
/// The app used to get weights two ways, neither of them checked: bundled into
/// the `.app` - which made every update carry 212 MB of bytes the machine
/// already had - or fetched straight from Hugging Face with no digest, no host
/// rule and no version of its own. A pack is the third way and is meant to
/// replace both: published beside the release it belongs to, named by version,
/// and verified against a SHA-256 before a single file reaches the model cache.
///
/// Like `PublishedRelease`, the type only exists in a validated form. There is
/// no way to make one except through `ModelPackManifest.parse`, because what is
/// on the other end of it is "unpack this into the directory CoreML loads from".
struct ModelPack: Equatable {
    /// Stable identifier, and the name the pack is published under. Also what a
    /// receipt records, so renaming one strands what users already installed.
    let id: String

    /// The pack's own version, which moves independently of the app's. Two
    /// builds of the app can want the same weights, and re-cutting the weights
    /// must not require re-cutting the app.
    let version: String

    /// The engine these weights are for.
    let engine: EngineKind

    /// The directory inside the model cache root, named exactly as the engine
    /// already expects it - so an installed pack is indistinguishable from a
    /// download the engine did itself, which is what keeps Settings' badges and
    /// every `isModelDownloaded` check working unchanged.
    let cacheFolder: String

    /// What has to be in that directory afterwards. Checked before the install
    /// is called a success, so a truncated archive cannot leave a cache the
    /// engine will find and fail to load.
    let entries: [String]

    let sizeInBytes: Int64

    /// Lowercase hex. The pack is data rather than code, so `codesign` has
    /// nothing to say about it; this and the host rule are what stand in for a
    /// signature.
    let sha256: String

    /// Guaranteed by `parse` to be an HTTPS URL on a GitHub release host under
    /// this repository, exactly as `UpdateManifest` requires of the disk image.
    let url: URL

    /// The oldest app that may install this pack, when the pack needs one. An
    /// app older than it skips the pack rather than installing weights it cannot
    /// load.
    let minimumAppVersion: AppVersion?
}

enum ModelPackManifestError: LocalizedError, Equatable {
    case malformedDocument
    case unsupportedSchema(Int)
    case incompletePack(String)
    case unknownEngine(String)
    case engineNotClearedForRedistribution(String)
    case unsafeEntry(String)
    case untrustedHost(String)
    case badChecksum(String)

    var errorDescription: String? {
        switch self {
        case .malformedDocument:
            return "The model pack list could not be read."
        case .unsupportedSchema(let version):
            return "The model pack list is version \(version), which this build does not understand."
        case .incompletePack(let id):
            return "The model pack \(id) is missing something it needs."
        case .unknownEngine(let engine):
            return "The model pack names an engine this build does not have (\(engine))."
        case .engineNotClearedForRedistribution(let engine):
            return "EchoForge does not publish weights for \(engine)."
        case .unsafeEntry(let entry):
            return "The model pack names a file it is not allowed to write (\(entry))."
        case .untrustedHost(let host):
            return "The model pack is not published where EchoForge publishes them (\(host))."
        case .badChecksum(let id):
            return "The model pack \(id) does not carry a usable SHA-256."
        }
    }
}

/// Reads the model pack list, and refuses everything it is not sure about.
///
/// The same discipline as `UpdateManifest`, for the same reason: the end of this
/// path is writing files into a directory the app then loads executable model
/// code from. Every rule below is a refusal, and the tests assert the refusals
/// rather than the acceptances.
enum ModelPackManifest {
    /// The only schema this build reads. A newer document is refused rather than
    /// half-understood - a field this build ignores could be the one saying
    /// "these weights are for a different encoder precision".
    static let supportedSchemaVersion = 1

    /// The list that ships inside the app. Bundled rather than fetched, which is
    /// a deliberate difference from the release manifest: it costs a few hundred
    /// bytes, it works on a machine that has never been online, and it adds no
    /// second network trust boundary. `parse` is written so a fetched document
    /// can be handed to it unchanged if that ever becomes worth doing.
    static let bundledResourceName = "ModelPacks"

    static func parse(_ data: Data) throws -> [ModelPack] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelPackManifestError.malformedDocument
        }
        let schema = root["schemaVersion"] as? Int ?? 0
        guard schema == supportedSchemaVersion else {
            throw ModelPackManifestError.unsupportedSchema(schema)
        }
        guard let packs = root["packs"] as? [[String: Any]] else {
            throw ModelPackManifestError.malformedDocument
        }
        return try packs.map(parsePack)
    }

    /// The packs this build can install, in the order the document lists them.
    /// A pack that needs a newer app is left out rather than refused, because a
    /// document listing packs for several app versions is the normal case.
    static func installable(_ packs: [ModelPack], appVersion: AppVersion?) -> [ModelPack] {
        packs.filter { pack in
            guard let minimum = pack.minimumAppVersion else { return true }
            guard let appVersion else { return false }
            return appVersion >= minimum
        }
    }

    /// The pack list this build ships, filtered to what this build may install.
    ///
    /// Empty is a working state, not a broken one: an engine with no pack - or a
    /// build older than a pack's `minimumAppVersion` - downloads weights exactly
    /// as it did before, which is why a packaging mistake below falls back
    /// rather than failing.
    static func bundled(in bundle: Bundle = .main, appVersion: AppVersion? = AppBuildIdentity.current().version) -> [ModelPack] {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return []
        }
        guard let packs = try? parse(data) else {
            // A malformed list that ships inside the app is a packaging mistake,
            // and the app has to keep working: without packs it downloads the
            // way it always did.
            print("Model pack list could not be read; falling back to downloading models.")
            return []
        }
        return installable(packs, appVersion: appVersion)
    }

    // MARK: - Private

    private static func parsePack(_ document: [String: Any]) throws -> ModelPack {
        guard let id = document["id"] as? String, !id.isEmpty else {
            throw ModelPackManifestError.malformedDocument
        }
        guard let version = document["version"] as? String, !version.isEmpty,
            let engineName = document["engine"] as? String,
            let cacheFolder = document["cacheFolder"] as? String,
            let entries = document["entries"] as? [String], !entries.isEmpty,
            let urlString = document["url"] as? String,
            let url = URL(string: urlString)
        else {
            throw ModelPackManifestError.incompletePack(id)
        }
        guard let engine = EngineKind(rawValue: engineName) else {
            throw ModelPackManifestError.unknownEngine(engineName)
        }
        guard enginesClearedForRedistribution.contains(engine) else {
            throw ModelPackManifestError.engineNotClearedForRedistribution(engineName)
        }
        // Every name is written into a directory, so every name has to be one
        // path component and nothing clever. This is the check that stops a
        // pack from writing outside the cache it was given.
        for name in entries + [cacheFolder] {
            guard isSafeComponent(name) else { throw ModelPackManifestError.unsafeEntry(name) }
        }
        guard UpdateManifest.isTrustedAssetURL(url) else {
            throw ModelPackManifestError.untrustedHost(url.host ?? urlString)
        }
        let digest = (document["sha256"] as? String ?? "").lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw ModelPackManifestError.badChecksum(id)
        }
        let size = (document["bytes"] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= maximumPackBytes else {
            throw ModelPackManifestError.incompletePack(id)
        }

        return ModelPack(
            id: id,
            version: version,
            engine: engine,
            cacheFolder: cacheFolder,
            entries: entries,
            sizeInBytes: size,
            sha256: digest,
            url: url,
            minimumAppVersion: (document["minimumAppVersion"] as? String).flatMap(AppVersion.init)
        )
    }

    /// The engines whose weights this project has actually written down a
    /// position on redistributing.
    ///
    /// Publishing a pack *is* redistribution, and the CoreML conversions the app
    /// fetches assert no licence of their own - so it is a claim that has to be
    /// justified per model rather than taken as the default.
    /// `docs/speech-model-attribution.md` justifies exactly one: SenseVoiceSmall,
    /// under the FunASR Model Open Source License v1.1, and says in as many words
    /// that no other model may be published as a pack until the same paragraph is
    /// written for it. Paraformer in particular is still download-only.
    ///
    /// That sentence is a licence position, so it is a refusal here rather than
    /// something to be remembered: a pack for any other engine fails to parse,
    /// and the whole list with it, until the paragraph exists and this set names
    /// the engine. `ModelPackManifestTests` pins it.
    static let enginesClearedForRedistribution: Set<EngineKind> = [.sensevoice]

    /// Far above the largest model the app offers (Paraformer, ~653 MB) and far
    /// below "fill the disk".
    static let maximumPackBytes: Int64 = 4 * 1_000_000_000

    /// One path component, no traversal, no hidden names. This is the check
    /// that stops `../../../bin/something` from being an entry.
    static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else { return false }
        return !name.unicodeScalars.contains("\0")
    }
}
