import Foundation

/// A release version, compared the way releases are ordered rather than the way
/// strings are.
///
/// It exists because `"0.10.0" < "0.9.0"` is true for strings and false for
/// software, and an updater that got that wrong would offer people a downgrade
/// and call it an update. Parsing is deliberately strict: anything that is not
/// `X.Y.Z` (or `vX.Y.Z`, which is how the tags are written) is rejected rather
/// than guessed at, because the input comes off the network.
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    /// Parses `X.Y.Z`, tolerating a leading `v` and surrounding whitespace and
    /// nothing else. No pre-release or build metadata: this project has never
    /// published one, and accepting a syntax the release process cannot produce
    /// only widens what an updater will believe.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Self.component(parts[0]),
            let minor = Self.component(parts[1]),
            let patch = Self.component(parts[2])
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    private static func component(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text) else { return nil }
        return value
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What this build calls itself, read from the bundle it is running out of.
///
/// Both numbers are shown rather than just the marketing one: `MARKETING_VERSION`
/// is what a release is called and `CURRENT_PROJECT_VERSION` is what tells two
/// builds of the same release apart, which is exactly the question anyone asking
/// "which build am I running" is trying to answer.
struct AppBuildIdentity: Equatable {
    /// `CFBundleShortVersionString`, i.e. `MARKETING_VERSION`. "0.3.0".
    let marketingVersion: String

    /// `CFBundleVersion`, i.e. `CURRENT_PROJECT_VERSION`. "7".
    let buildNumber: String

    let bundleIdentifier: String

    /// The parsed form of `marketingVersion`, or `nil` if this build carries
    /// something the release process could not have produced.
    var version: AppVersion? { AppVersion(marketingVersion) }

    /// One line for the About pane and for a bug report.
    var displayString: String { "Version \(marketingVersion) (\(buildNumber))" }

    static func current(bundle: Bundle = .main) -> AppBuildIdentity {
        AppBuildIdentity(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            bundleIdentifier: bundle.bundleIdentifier ?? ""
        )
    }
}
