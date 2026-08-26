import XCTest
@testable import OpenSuperWhisper

/// The app's identity on the user's Mac: what macOS calls it, and what it files
/// its data and permission grants under.
///
/// Those are two different names, and keeping them apart is what this file is
/// for. The product users see is **Kongweh**; everything the operating system
/// files data under is still **EchoForge**, because those identifiers are where
/// a user's recordings, personal terms, downloaded weights, Keychain item and
/// TCC grants already live. Renaming the visible half is cosmetic; renaming the
/// technical half hands every existing user an empty app and a fresh round of
/// permission prompts. So the visible name moved and nothing else did, and both
/// halves are pinned here so neither can drift into the other.
///
/// This is the same split the project already runs one level down, where the
/// module and source directories stay `OpenSuperWhisper`; `AGENTS.md` describes
/// all three names and which one is authoritative for what.
///
/// These are pinned because they are invisible from the source - they live in
/// `project.pbxproj` and `OpenSuperWhisper-Info.plist`. The identifier also has
/// to stay distinct from upstream's `ru.starmel.*` so this build can sit next to
/// an installed OpenSuperWhisper rather than replace it.
///
/// The unit-test target runs inside the app (`TEST_HOST`), so `Bundle.main`
/// here is the built app bundle.
final class AppIdentityTests: XCTestCase {
    private var app: Bundle { Bundle.main }

    func testBundleIdentifierIsEchoForge() {
        XCTAssertEqual(app.bundleIdentifier, "com.hsuanchenlin.EchoForge")
    }

    func testBundleIdentifierIsNotUpstreams() {
        // Coexistence with an installed upstream build depends on this.
        XCTAssertNotEqual(app.bundleIdentifier, "ru.starmel.OpenSuperWhisper")
    }

    /// The names macOS shows a user. Finder reads `CFBundleDisplayName` and the
    /// menu bar reads `CFBundleName`, so both have to move for the rename to be
    /// complete - `CFBundleName` in particular defaults to `$(PRODUCT_NAME)`
    /// when nothing sets it, which would silently leave the old name in the
    /// menu bar while Finder showed the new one.
    func testUserFacingNamesAreKongweh() {
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Kongweh")
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleName") as? String, "Kongweh")
    }

    /// The other side of the boundary. None of these is shown to a user, and
    /// every one of them is load-bearing for an existing install: the bundle
    /// identifier names the Application Support directory and the TCC grants,
    /// and the executable and bundle names are what `Scripts/build_release.sh`,
    /// `Scripts/verify_release_package.sh` and the in-app updater all address
    /// the shipped app by - `UpdateManifest.assetName` is `EchoForge.dmg` and
    /// `UpdateInstaller` looks for `EchoForge.app` inside it. Moving any of
    /// these is a migration, not a rename.
    func testTechnicalIdentityStillEchoForge() {
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "EchoForge")
        XCTAssertEqual(app.bundleURL.lastPathComponent, "EchoForge.app")
        XCTAssertEqual(app.bundleIdentifier, "com.hsuanchenlin.EchoForge")
    }

    /// The data an existing user already has. These paths are derived from the
    /// bundle identifier at runtime, so this is the assertion that says an
    /// install from before the rename still opens its own recordings, terms and
    /// models rather than starting empty beside them.
    func testExistingUserDataStillResolvesUnderTheOldIdentity() throws {
        let identifier = try XCTUnwrap(app.bundleIdentifier)
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent(identifier)

        XCTAssertEqual(support.lastPathComponent, "com.hsuanchenlin.EchoForge")
        XCTAssertEqual(
            PersonalTermsStore.defaultFileURL.deletingLastPathComponent().path,
            support.path,
            "the personal terms dictionary moved out from under existing installs"
        )
        XCTAssertEqual(
            Recording.recordingsDirectory.deletingLastPathComponent().path,
            support.path,
            "the recordings directory moved out from under existing installs"
        )
        // The Keychain item is keyed the same way, and a moved service string
        // strands the API key of every install that already stored one.
        XCTAssertEqual(
            KeychainCloudCredentialStore().service,
            "com.hsuanchenlin.EchoForge.cloud"
        )
    }

    func testPermissionPromptsNameKongweh() {
        // These strings are what macOS shows in the microphone and automation
        // prompts, so they are the app's name in the most load-bearing place.
        for key in ["NSMicrophoneUsageDescription", "NSAccessibilityUsageDescription", "NSAppleEventsUsageDescription"] {
            let value = app.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(value, "\(key) is missing")
            XCTAssertTrue(value?.hasPrefix("Kongweh ") == true, "\(key) does not name Kongweh: \(value ?? "nil")")
        }
    }

    // MARK: - Icon

    func testAppIconIsPackagedWithTheApp() throws {
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "AppIcon.icns")
        let icon = try XCTUnwrap(
            app.url(forResource: "AppIcon", withExtension: "icns"),
            "AppIcon.icns is not in the built app bundle"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
    }

    /// macOS picks a different image out of the `.icns` for the menu bar, Finder
    /// list view, Finder icon view and the Dock, and silently falls back to a
    /// blurry upscale of whatever it finds when one is missing. Regenerating the
    /// icon with a short iconset is the easy way to lose them, so assert the ten
    /// sizes `Scripts/generate_app_icon.sh` produces are all really in there.
    func testAppIconContainsEverySizeMacOSAsksFor() throws {
        let icon = try XCTUnwrap(app.url(forResource: "AppIcon", withExtension: "icns"))
        let types = try IcnsFile(contentsOf: icon).imageTypes

        let required = [
            "ic04": "16pt", "ic11": "16pt@2x",
            "ic05": "32pt", "ic12": "32pt@2x",
            "ic07": "128pt", "ic13": "128pt@2x",
            "ic08": "256pt", "ic14": "256pt@2x",
            "ic09": "512pt", "ic10": "512pt@2x",
        ]
        for (type, size) in required {
            XCTAssertTrue(types.contains(type), "AppIcon.icns has no \(size) image (\(type))")
        }
    }
}

/// The bare minimum of the `.icns` container format: a header, then a flat list
/// of length-prefixed chunks keyed by a four-character type.
private struct IcnsFile {
    let imageTypes: Set<String>

    enum ParseError: Error { case notAnIcns, truncated }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("icns".utf8) else { throw ParseError.notAnIcns }

        var types: Set<String> = []
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + 4], as: UTF8.self)
            let length = data[(data.startIndex + offset + 4)...].prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 8, offset + length <= data.count else { throw ParseError.truncated }
            if type != "info" && type != "TOC " { types.insert(type) }
            offset += length
        }
        imageTypes = types
    }
}
