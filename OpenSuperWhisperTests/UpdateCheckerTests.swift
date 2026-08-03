import XCTest

@testable import OpenSuperWhisper

/// Release versions, compared the way releases are ordered.
final class AppVersionTests: XCTestCase {

    func testParsesTaggedAndUntaggedVersions() {
        XCTAssertEqual(AppVersion("0.3.0"), AppVersion("v0.3.0"))
        XCTAssertEqual(AppVersion(" v1.2.3 ")?.description, "1.2.3")
    }

    /// The input comes off the network, so anything that is not exactly three
    /// numbers is refused rather than guessed at.
    func testRefusesAnythingThatIsNotThreeNumbers() {
        for text in ["", "1", "1.2", "1.2.3.4", "1.2.x", "one.two.three", "1.-2.3", "1..3", "latest", "v"] {
            XCTAssertNil(AppVersion(text), "\(text) should not parse as a version")
        }
    }

    /// The reason this type exists: `"0.10.0" < "0.9.0"` is true for strings.
    func testOrdersByNumberRatherThanByString() {
        XCTAssertTrue(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        XCTAssertTrue(AppVersion("0.2.2")! < AppVersion("0.3.0")!)
        XCTAssertTrue(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        XCTAssertEqual(AppVersion("0.3.0"), AppVersion("0.3.0"))
    }
}

/// Reading GitHub's release metadata, which is the security boundary of the
/// updater: everything downstream of it acts on what it returns.
final class UpdateManifestTests: XCTestCase {

    private func metadata(
        tag: String = "v0.3.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String = "EchoForge.dmg",
        downloadURL: String = "https://github.com/hsuanchenlin/OpenSuperWhisper/releases/download/v0.3.0/EchoForge.dmg",
        size: Int = 30_000_000,
        body: String = "notes"
    ) -> Data {
        let document: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "body": body,
            "assets": [["name": assetName, "browser_download_url": downloadURL, "size": size]],
        ]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    func testReadsAPublishedRelease() throws {
        let release = try UpdateManifest.parse(metadata())

        XCTAssertEqual(release.version, AppVersion("0.3.0"))
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.notes, "notes")
        XCTAssertEqual(release.sizeInBytes, 30_000_000)
        XCTAssertEqual(release.releasePageURL.absoluteString,
                       "https://github.com/hsuanchenlin/OpenSuperWhisper/releases/tag/v0.3.0")
    }

    // MARK: - What it refuses

    /// The one that matters most. An updater that downloads whatever URL the
    /// metadata names is a remote code execution primitive with extra steps, so
    /// the host allow-list is not advisory.
    func testRefusesADownloadFromAnywhereButGitHubsReleaseHosts() {
        for url in [
            "https://example.com/EchoForge.dmg",
            "https://github.com.evil.test/hsuanchenlin/OpenSuperWhisper/EchoForge.dmg",
            "https://raw.githubusercontent.com/hsuanchenlin/OpenSuperWhisper/EchoForge.dmg",
        ] {
            XCTAssertThrowsError(try UpdateManifest.parse(metadata(downloadURL: url)), url) { error in
                guard case UpdateManifestError.untrustedDownloadHost = error else {
                    return XCTFail("\(url) was refused for the wrong reason: \(error)")
                }
            }
        }
    }

    /// HTTPS only. A plaintext download of an executable is not something to
    /// accept because the host name looked right.
    func testRefusesAPlainHTTPDownload() {
        XCTAssertThrowsError(
            try UpdateManifest.parse(
                metadata(downloadURL: "http://github.com/hsuanchenlin/OpenSuperWhisper/releases/download/v0.3.0/EchoForge.dmg")
            )
        )
    }

    /// A GitHub-hosted asset belonging to somebody else's repository is still
    /// somebody else's build.
    func testRefusesAnAssetFromAnotherRepository() {
        XCTAssertThrowsError(
            try UpdateManifest.parse(
                metadata(downloadURL: "https://github.com/someone/else/releases/download/v9.9.9/EchoForge.dmg")
            )
        )
    }

    /// The repository check is a path-prefix match, not "contains somewhere in
    /// the path". A URL that merely mentions the repository path lower down -
    /// which `.contains` would have accepted - must still be refused.
    func testRefusesAUrlThatOnlyContainsTheRepositoryPathAsASubstring() {
        for url in [
            "https://github.com/someone/hsuanchenlin/OpenSuperWhisper/releases/download/v9.9.9/EchoForge.dmg",
            "https://github.com/hsuanchenlin/OpenSuperWhisper-fork/releases/download/v9.9.9/EchoForge.dmg",
        ] {
            XCTAssertThrowsError(try UpdateManifest.parse(metadata(downloadURL: url)), url) { error in
                guard case UpdateManifestError.untrustedDownloadHost = error else {
                    return XCTFail("\(url) was refused for the wrong reason: \(error)")
                }
            }
        }
    }

    /// Exact name. Not "contains", not "ends with .dmg".
    func testRefusesAnAssetThatIsNotTheExpectedDiskImage() {
        for name in ["EchoForge.dmg.zip", "echoforge.dmg", "EchoForge-0.3.0.dmg", "Installer.dmg"] {
            XCTAssertThrowsError(try UpdateManifest.parse(metadata(assetName: name)), name)
        }
    }

    func testRefusesDraftsAndPrereleases() {
        XCTAssertThrowsError(try UpdateManifest.parse(metadata(draft: true)))
        XCTAssertThrowsError(try UpdateManifest.parse(metadata(prerelease: true)))
    }

    func testRefusesATagThatIsNotAVersion() {
        XCTAssertThrowsError(try UpdateManifest.parse(metadata(tag: "nightly"))) { error in
            XCTAssertEqual(error as? UpdateManifestError, .unreadableVersion("nightly"))
        }
    }

    func testRefusesAnImplausibleAssetSize() {
        XCTAssertThrowsError(try UpdateManifest.parse(metadata(size: 0)))
        XCTAssertThrowsError(try UpdateManifest.parse(metadata(size: UpdateManifest.maximumAssetBytes + 1)))
    }

    func testRefusesADocumentThatIsNotJSON() {
        XCTAssertThrowsError(try UpdateManifest.parse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? UpdateManifestError, .malformedDocument)
        }
    }

    /// The notes are rendered in a window. An unbounded attacker-controlled
    /// string is a denial of service against it.
    func testTruncatesUnboundedReleaseNotes() throws {
        let release = try UpdateManifest.parse(
            metadata(body: String(repeating: "a", count: UpdateManifest.maximumNotesLength * 2))
        )

        XCTAssertEqual(release.notes.count, UpdateManifest.maximumNotesLength)
    }

    /// Every refusal has to say what was wrong. "Update check failed" tells the
    /// user nothing and whoever has to debug it less.
    func testEveryRefusalCarriesAReadableReason() {
        let errors: [UpdateManifestError] = [
            .malformedDocument, .noPublishedRelease, .unreadableVersion("x"),
            .noDiskImageAsset, .untrustedDownloadHost("example.com"),
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty, "\(error)")
            XCTAssertFalse(error.localizedDescription.contains("UpdateManifestError"), "\(error)")
        }
    }
}

/// The redirect target GitHub's object store actually serves the bytes from,
/// re-checked at the one point that matters: the download itself.
final class UpdateManifestRedirectHostTests: XCTestCase {

    func testAllowsGitHubsOwnDownloadHosts() {
        for host in ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            let url = URL(string: "https://\(host)/some/signed/path?token=x")
            XCTAssertTrue(UpdateManifest.isAllowedRedirectHost(url), host)
        }
    }

    /// The redirect check is deliberately looser than `parse`'s: the object
    /// store's URL is a signed, opaque path that never contains the repository
    /// path, so only the host is re-checked here.
    func testAllowsAnObjectStoreURLWithNoRepositoryPathInIt() {
        let url = URL(string: "https://objects.githubusercontent.com/github-production-release-asset/12345/abcdef")
        XCTAssertTrue(UpdateManifest.isAllowedRedirectHost(url))
    }

    func testRefusesAnyOtherHost() {
        XCTAssertFalse(UpdateManifest.isAllowedRedirectHost(URL(string: "https://evil.example.com/EchoForge.dmg")))
    }

    func testRefusesPlainHTTPEvenOnAnAllowedHost() {
        XCTAssertFalse(UpdateManifest.isAllowedRedirectHost(URL(string: "http://objects.githubusercontent.com/x")))
    }

    func testRefusesNoURLAtAll() {
        XCTAssertFalse(UpdateManifest.isAllowedRedirectHost(nil))
    }
}

/// Deciding whether there is something newer.
final class UpdateComparisonTests: XCTestCase {

    private func release(_ version: String) -> PublishedRelease {
        PublishedRelease(
            version: AppVersion(version)!,
            tag: "v\(version)",
            notes: "",
            downloadURL: URL(string: "https://github.com/hsuanchenlin/OpenSuperWhisper/releases/download/v\(version)/EchoForge.dmg")!,
            sizeInBytes: 1
        )
    }

    func testANewerReleaseIsOffered() {
        XCTAssertEqual(
            UpdateChecker.compare(current: AppVersion("0.2.2")!, against: release("0.3.0")),
            .available(release("0.3.0"))
        )
    }

    func testTheSameVersionIsUpToDate() {
        XCTAssertEqual(
            UpdateChecker.compare(current: AppVersion("0.3.0")!, against: release("0.3.0")),
            .upToDate(current: AppVersion("0.3.0")!)
        )
    }

    /// A local build of an unreleased version must never be offered a downgrade
    /// dressed up as an update.
    func testAnOlderPublishedReleaseIsNeverOfferedAsAnUpdate() {
        XCTAssertEqual(
            UpdateChecker.compare(current: AppVersion("0.4.0")!, against: release("0.3.0")),
            .upToDate(current: AppVersion("0.4.0")!)
        )
    }
}

/// What a downloaded build has to prove before it is allowed to replace the one
/// that is running.
final class DownloadedBuildRequirementsTests: XCTestCase {

    private let requirements = DownloadedBuildRequirements(
        expectedBundleIdentifier: "com.hsuanchenlin.EchoForge",
        expectedVersion: "0.3.0"
    )

    func testAcceptsTheBuildThatWasOffered() {
        XCTAssertNil(
            requirements.validateIdentity(bundleIdentifier: "com.hsuanchenlin.EchoForge", version: "0.3.0")
        )
    }

    /// The disk image could contain anything. A bundle that is not this app is
    /// discarded rather than installed over it.
    func testRefusesABundleThatIsNotEchoForge() {
        XCTAssertEqual(
            requirements.validateIdentity(bundleIdentifier: "ru.starmel.OpenSuperWhisper", version: "0.3.0"),
            .wrongBundleIdentifier(found: "ru.starmel.OpenSuperWhisper")
        )
        XCTAssertEqual(
            requirements.validateIdentity(bundleIdentifier: nil, version: "0.3.0"),
            .wrongBundleIdentifier(found: "nothing")
        )
    }

    /// The version has to be the one whose notes the user just read and agreed
    /// to, not merely some EchoForge.
    func testRefusesABuildThatIsNotTheVersionThatWasOffered() {
        XCTAssertEqual(
            requirements.validateIdentity(bundleIdentifier: "com.hsuanchenlin.EchoForge", version: "0.1.0"),
            .wrongVersion(expected: "0.3.0", found: "0.1.0")
        )
    }

    /// The requirements are built from the running app's own identifier, so an
    /// update can never move the user to a different bundle - which would mean a
    /// different Application Support directory and an empty app.
    func testTheExpectedIdentifierIsTheRunningAppsOwn() {
        let release = PublishedRelease(
            version: AppVersion("0.3.0")!,
            tag: "v0.3.0",
            notes: "",
            downloadURL: URL(string: "https://github.com/hsuanchenlin/OpenSuperWhisper/releases/download/v0.3.0/EchoForge.dmg")!,
            sizeInBytes: 1
        )

        XCTAssertEqual(
            DownloadedBuildRequirements.forOffered(release).expectedBundleIdentifier,
            AppBuildIdentity.current().bundleIdentifier
        )
    }

    func testEveryInstallFailureCarriesAReadableReason() {
        let errors: [UpdateInstallError] = [
            .downloadFailed("x"), .unexpectedSize(expected: 1, received: 2),
            .diskImageCouldNotBeOpened("x"), .noApplicationInDiskImage,
            .wrongBundleIdentifier(found: "x"), .wrongVersion(expected: "1.0.0", found: "2.0.0"),
            .signatureRejected("x"), .replacementFailed("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty, "\(error)")
            XCTAssertFalse(error.localizedDescription.contains("UpdateInstallError"), "\(error)")
        }
    }
}

/// What the About pane reads out of the bundle it is running in.
final class AppBuildIdentityTests: XCTestCase {

    /// The unit tests run inside the app (`TEST_HOST`), so `Bundle.main` is the
    /// built app bundle and these are the real settings.
    func testReadsThisBuildsVersionAndNumber() {
        let identity = AppBuildIdentity.current()

        XCTAssertEqual(identity.bundleIdentifier, "com.hsuanchenlin.EchoForge")
        XCTAssertNotNil(identity.version, "this build's MARKETING_VERSION is not a version: \(identity.marketingVersion)")
        XCTAssertFalse(identity.buildNumber.isEmpty)
    }

    /// Both numbers, because the marketing version alone cannot tell two builds
    /// of the same release apart - which is exactly what anyone reading this pane
    /// is trying to do.
    func testTheDisplayStringCarriesBothNumbers() {
        let identity = AppBuildIdentity(
            marketingVersion: "0.3.0", buildNumber: "7", bundleIdentifier: "com.hsuanchenlin.EchoForge"
        )

        XCTAssertEqual(identity.displayString, "Version 0.3.0 (7)")
    }
}
