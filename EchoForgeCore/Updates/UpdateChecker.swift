import Foundation

/// The result of asking whether there is a newer Kongweh.
enum UpdateAvailability: Equatable {
    /// This build is the newest published release, or newer than it - which is
    /// what a local build of an unreleased version looks like, and is not an
    /// invitation to "update" backwards.
    case upToDate(current: AppVersion)

    case available(PublishedRelease)
}

/// Where release metadata comes from. A protocol so the rules that read it can
/// be tested against fixtures rather than against GitHub.
protocol ReleaseMetadataFetching: Sendable {
    func fetchLatestReleaseMetadata() async throws -> Data
}

/// The production fetcher: one unauthenticated GET against the releases API.
struct GitHubReleaseMetadataFetcher: ReleaseMetadataFetching {
    /// Kept small: this runs when the user presses a button and waits for it.
    static let timeout: TimeInterval = 20

    /// A cap on the metadata document itself. The parser is strict about what is
    /// inside it, but it still has to be read into memory first.
    static let maximumDocumentBytes = 2 * 1_000_000

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestReleaseMetadata() async throws -> Data {
        var request = URLRequest(url: UpdateManifest.latestReleaseURL, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateManifestError.noPublishedRelease
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw UpdateManifestError.malformedDocument
        }
        return data
    }
}

/// Asks whether there is a newer release, and answers only when it is sure.
///
/// The comparison is deliberately strict-greater-than on the parsed version:
/// equal is up to date, and *older* is also up to date rather than an offer to
/// downgrade. A build whose own version cannot be parsed refuses to compare at
/// all instead of assuming it is behind.
struct UpdateChecker {
    let fetcher: ReleaseMetadataFetching
    let current: AppBuildIdentity

    init(fetcher: ReleaseMetadataFetching = GitHubReleaseMetadataFetcher(),
         current: AppBuildIdentity = .current()) {
        self.fetcher = fetcher
        self.current = current
    }

    func check() async throws -> UpdateAvailability {
        guard let currentVersion = current.version else {
            throw UpdateManifestError.unreadableVersion(current.marketingVersion)
        }
        let release = try UpdateManifest.parse(try await fetcher.fetchLatestReleaseMetadata())
        return Self.compare(current: currentVersion, against: release)
    }

    /// The comparison on its own, so it can be asserted without a network.
    static func compare(current: AppVersion, against release: PublishedRelease) -> UpdateAvailability {
        release.version > current ? .available(release) : .upToDate(current: current)
    }
}
