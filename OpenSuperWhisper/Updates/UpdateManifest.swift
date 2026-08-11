import Foundation

/// A published EchoForge release, once it has survived being checked.
///
/// The type only exists in a validated form: there is no way to construct one
/// from release metadata except through `UpdateManifest.parse`, which rejects
/// anything it is not certain about. That is deliberate. Everything here arrives
/// over the network from a service this app does not control, and the end of the
/// path it feeds is "download this and replace the running application", so the
/// parsing is the security boundary rather than a convenience.
struct PublishedRelease: Equatable {
    let version: AppVersion

    /// The tag, kept verbatim for the release-page link.
    let tag: String

    /// The release notes as published, shown to the user *before* anything is
    /// downloaded. Truncated rather than trusted to be small.
    let notes: String

    /// Where the disk image is fetched from. Guaranteed by `parse` to be an
    /// HTTPS URL on a GitHub release-download host for this repository.
    let downloadURL: URL

    /// The declared size of that asset, for the progress bar and for a sanity
    /// check on what actually arrives.
    let sizeInBytes: Int

    /// Where the published SHA-256 of that asset is, when the release carries
    /// one. Optional because it has to be: releases up to and including v0.5.1
    /// published no sidecar, and refusing to update from them would strand
    /// exactly the users who most need the update. What it changes when it *is*
    /// present is that the downloaded bytes are checked against a digest the
    /// release states, rather than only against its length.
    let checksumURL: URL?

    init(
        version: AppVersion,
        tag: String,
        notes: String,
        downloadURL: URL,
        sizeInBytes: Int,
        checksumURL: URL? = nil
    ) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.downloadURL = downloadURL
        self.sizeInBytes = sizeInBytes
        self.checksumURL = checksumURL
    }

    /// The human-facing release page, for "what changed" and for anyone who
    /// would rather install it by hand.
    var releasePageURL: URL {
        URL(string: "\(UpdateManifest.releasePagePrefix)\(tag)") ?? downloadURL
    }
}

/// Why a release-metadata document was refused.
///
/// Each case is a specific thing that was wrong, because "update check failed"
/// tells a user nothing and tells whoever has to debug it less.
enum UpdateManifestError: LocalizedError, Equatable {
    case malformedDocument
    case noPublishedRelease
    case unreadableVersion(String)
    case noDiskImageAsset
    case untrustedDownloadHost(String)

    var errorDescription: String? {
        switch self {
        case .malformedDocument:
            return "The update information could not be read."
        case .noPublishedRelease:
            return "No published release was found."
        case .unreadableVersion(let tag):
            return "The latest release is not named like a version (\(tag))."
        case .noDiskImageAsset:
            return "The latest release has no \(UpdateManifest.assetName) to download."
        case .untrustedDownloadHost(let host):
            return "The download is not hosted where EchoForge releases are published (\(host))."
        }
    }
}

/// Reads GitHub's release metadata, and refuses everything it is not sure about.
///
/// The rules below are the whole point of the type, so they are stated once
/// here rather than spread through the checker:
///
/// - The **only** download URL that is ever accepted is HTTPS on
///   `github.com`/`objects.githubusercontent.com`, under this repository's path.
///   An updater that installs whatever URL the metadata names is a remote code
///   execution primitive with extra steps, and "the metadata came from GitHub"
///   is not a defence when the metadata is what is being trusted.
/// - The asset must be named exactly `EchoForge.dmg`. Not "contains", not
///   "ends with .dmg".
/// - Drafts and pre-releases are ignored: they are not published releases.
/// - The tag must parse as `vX.Y.Z`. An unparseable tag is refused rather than
///   treated as newer or older.
enum UpdateManifest {
    /// The repository releases are published from. Changing it changes what the
    /// app will install, so it is a constant with a test on it rather than a
    /// setting.
    ///
    /// It must be the repository's **canonical** name, not a name that redirects
    /// to it. GitHub renames are transparent almost everywhere - the git remote,
    /// the API, the web UI all follow the redirect - so `hsuanchenlin/OpenSuperWhisper`
    /// went on working after the rename to `hsuanchenlin/EchoForge` and nothing
    /// looked wrong. But `browser_download_url` in the release metadata is
    /// always the *canonical* path, so the prefix check below compared
    /// `/hsuanchenlin/EchoForge/...` against `/hsuanchenlin/OpenSuperWhisper/`
    /// and refused every genuine release as `untrustedDownloadHost`. The
    /// repository directory and the Swift module are still named
    /// OpenSuperWhisper (see the naming note in AGENTS.md); this constant is not
    /// about either of those, it is about where releases actually live.
    static let repositoryPath = "hsuanchenlin/EchoForge"

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repositoryPath)/releases/latest")!

    static let releasePagePrefix = "https://github.com/\(repositoryPath)/releases/tag/"

    /// The one asset name this app will download.
    static let assetName = "EchoForge.dmg"

    /// The sidecar naming the disk image's SHA-256, published beside it by
    /// `Scripts/build_release.sh`. Same exact-name rule as the asset itself.
    static let checksumAssetName = "\(assetName).sha256"

    /// A cap on the sidecar document. It is 80 bytes in practice; this is the
    /// bound that keeps a hostile one from being read into memory at all.
    static let maximumChecksumBytes = 4096

    /// Hosts a release asset may be served from. GitHub serves release downloads
    /// from `github.com` and redirects to its object store, and nothing else is
    /// accepted.
    static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// Release notes longer than this are cut before they reach a `Text` view.
    /// The document is attacker-controlled in the threat model this file assumes,
    /// and an unbounded string is a denial of service against the window it is
    /// rendered in.
    static let maximumNotesLength = 20_000

    /// The largest asset the updater will agree to download, in bytes. The DMG
    /// is around 30 MB; 500 MB is far above anything a real release has been and
    /// far below "fill the disk".
    static let maximumAssetBytes = 500 * 1_000_000

    static func parse(_ data: Data) throws -> PublishedRelease {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateManifestError.malformedDocument
        }

        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            throw UpdateManifestError.noPublishedRelease
        }

        guard let tag = root["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateManifestError.noPublishedRelease
        }
        guard let version = AppVersion(tag) else {
            throw UpdateManifestError.unreadableVersion(tag)
        }

        guard let assets = root["assets"] as? [[String: Any]] else {
            throw UpdateManifestError.noDiskImageAsset
        }
        guard
            let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
            let urlString = asset["browser_download_url"] as? String,
            let url = URL(string: urlString)
        else {
            throw UpdateManifestError.noDiskImageAsset
        }

        guard isTrustedAssetURL(url) else {
            throw UpdateManifestError.untrustedDownloadHost(url.host ?? urlString)
        }

        let size = asset["size"] as? Int ?? 0
        guard size > 0, size <= maximumAssetBytes else {
            throw UpdateManifestError.noDiskImageAsset
        }

        let notes = (root["body"] as? String ?? "").prefix(maximumNotesLength)

        // The sidecar goes through exactly the same host and path rules as the
        // asset. A checksum fetched from somewhere else would be a checksum an
        // attacker could choose, which is worse than no checksum at all: it
        // would look like verification while proving nothing.
        let checksumURL = (assets.first { ($0["name"] as? String) == checksumAssetName })
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
            .flatMap { isTrustedAssetURL($0) ? $0 : nil }

        return PublishedRelease(
            version: version,
            tag: tag,
            notes: String(notes),
            downloadURL: url,
            sizeInBytes: size,
            checksumURL: checksumURL
        )
    }

    /// HTTPS, an allow-listed host, and under this repository's path. The rule
    /// every URL taken from release metadata is held to.
    static func isTrustedAssetURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.lowercased() == "https" else { return false }
        return allowedDownloadHosts.contains(host) && url.path.hasPrefix("/\(repositoryPath)/")
    }

    /// Whether a URL the download's `URLSession` is about to follow a redirect
    /// to is still one of `allowedDownloadHosts`.
    ///
    /// `parse` only ever sees `browser_download_url`, which GitHub's API always
    /// returns as a `github.com` URL; the actual bytes are served from a
    /// redirect to its object store. Without re-checking the redirect target,
    /// the host allow-list is enforced on a URL nothing ever downloads from and
    /// not on the one that matters. Deliberately looser than `parse`'s check:
    /// the object-store URL is a signed, opaque path that never contains
    /// `repositoryPath`, so only the host and scheme are re-checked here.
    static func isAllowedRedirectHost(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedDownloadHosts.contains(host)
    }
}
