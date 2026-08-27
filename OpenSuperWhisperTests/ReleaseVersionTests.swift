import XCTest

@testable import OpenSuperWhisper

/// What the app calls its own version, and whether a release was actually
/// written up for it.
///
/// `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.pbxproj`
/// once per target and per configuration - six copies each - so a hand-edited
/// bump silently leaves some behind, and the app target and its test targets
/// then disagree about what version this is. Release notes are the other half:
/// `docs/release-notes/vX.Y.Z.md` is what the GitHub release body is created
/// from, so a version that has no notes file is a release nobody can publish
/// without writing them first.
///
/// The unit-test target runs inside the app (`TEST_HOST`), so `Bundle.main` is
/// the built app bundle and its `CFBundleShortVersionString` is whatever
/// `MARKETING_VERSION` resolved to for this build. The repository itself is
/// reached through `#filePath`, since the project sources are not in the bundle.
final class ReleaseVersionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OpenSuperWhisperTests
            .deletingLastPathComponent() // repository root
    }

    private var projectFile: String {
        get throws {
            try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("OpenSuperWhisper.xcodeproj")
                    .appendingPathComponent("project.pbxproj"),
                encoding: .utf8
            )
        }
    }

    private var builtVersion: String {
        get throws {
            try XCTUnwrap(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                "the built app has no CFBundleShortVersionString"
            )
        }
    }

    private func values(of setting: String, in project: String) -> [String] {
        project
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\(setting) = "), trimmed.hasSuffix(";") else { return nil }
                return String(trimmed.dropFirst("\(setting) = ".count).dropLast())
            }
    }

    // MARK: - Lockstep across targets and configurations

    func testEveryTargetAndConfigurationDeclaresTheSameMarketingVersion() throws {
        let declared = values(of: "MARKETING_VERSION", in: try projectFile)

        XCTAssertFalse(declared.isEmpty, "no MARKETING_VERSION found in project.pbxproj")
        XCTAssertEqual(
            Set(declared).count, 1,
            "MARKETING_VERSION is out of step across targets/configurations: \(declared)"
        )
        XCTAssertEqual(declared.first, try builtVersion)
    }

    func testEveryTargetAndConfigurationDeclaresTheSameBuildNumber() throws {
        let declared = values(of: "CURRENT_PROJECT_VERSION", in: try projectFile)

        XCTAssertFalse(declared.isEmpty, "no CURRENT_PROJECT_VERSION found in project.pbxproj")
        XCTAssertEqual(
            Set(declared).count, 1,
            "CURRENT_PROJECT_VERSION is out of step across targets/configurations: \(declared)"
        )
    }

    // MARK: - Release notes

    func testThisVersionHasReleaseNotes() throws {
        let version = try builtVersion
        let notes = repositoryRoot
            .appendingPathComponent("docs/release-notes")
            .appendingPathComponent("v\(version).md")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: notes.path),
            "version \(version) has no docs/release-notes/v\(version).md to publish as the release body"
        )
    }

    /// The notes are pasted straight into the GitHub release, so their heading
    /// is the title a user reads. It has to name this build, not the one whose
    /// notes were copied to make it.
    func testReleaseNotesAreHeadedWithThisVersion() throws {
        let version = try builtVersion
        let notes = repositoryRoot
            .appendingPathComponent("docs/release-notes")
            .appendingPathComponent("v\(version).md")
        guard FileManager.default.fileExists(atPath: notes.path) else {
            return XCTFail("no release notes for \(version); see testThisVersionHasReleaseNotes")
        }

        let heading = try XCTUnwrap(
            String(contentsOf: notes, encoding: .utf8)
                .split(separator: "\n")
                .first { $0.hasPrefix("# ") },
            "release notes have no top-level heading"
        )
        XCTAssertTrue(heading.contains(version), "release-notes heading does not name \(version): \(heading)")
    }

    /// These builds are unsigned and unnotarized, so every release has to tell
    /// people how to get past Gatekeeper - without it the download simply looks
    /// broken. Pinned because it is the one paragraph that is easy to drop when
    /// notes are written from scratch for a small release.
    func testReleaseNotesKeepTheUnsignedBuildWarning() throws {
        let version = try builtVersion
        let notes = repositoryRoot
            .appendingPathComponent("docs/release-notes")
            .appendingPathComponent("v\(version).md")
        guard FileManager.default.fileExists(atPath: notes.path) else {
            return XCTFail("no release notes for \(version); see testThisVersionHasReleaseNotes")
        }
        let text = try String(contentsOf: notes, encoding: .utf8)

        XCTAssertTrue(text.contains("not notarized"), "release notes do not warn the build is not notarized")
        XCTAssertTrue(
            text.contains("com.apple.quarantine") || text.lowercased().contains("right-click"),
            "release notes give no way around Gatekeeper"
        )
    }

    /// The one asset a release publishes, named in the notes so the download
    /// instructions and the updater cannot drift apart. `UpdateManifest` finds
    /// an update by this exact file name, so notes that told people to download
    /// something else would be describing a file no release contains.
    func testReleaseNotesNameTheAssetTheUpdaterLooksFor() throws {
        let version = try builtVersion
        let notes = repositoryRoot
            .appendingPathComponent("docs/release-notes")
            .appendingPathComponent("v\(version).md")
        guard FileManager.default.fileExists(atPath: notes.path) else {
            return XCTFail("no release notes for \(version); see testThisVersionHasReleaseNotes")
        }
        let text = try String(contentsOf: notes, encoding: .utf8)

        XCTAssertTrue(
            text.contains(UpdateManifest.assetName),
            "release notes never name \(UpdateManifest.assetName), which is the asset a release publishes"
        )
    }

    // MARK: - The notes directory as a whole

    /// Every notes file in the directory, paired with the version its file
    /// name declares. A file name that does not parse as `vX.Y.Z.md` is a file
    /// the release process could not have produced.
    private func releaseNotes() throws -> [(version: AppVersion, file: URL)] {
        let directory = repositoryRoot.appendingPathComponent("docs/release-notes")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "md" }

        var notes: [(version: AppVersion, file: URL)] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let version = try XCTUnwrap(
                AppVersion(name),
                "docs/release-notes/\(file.lastPathComponent) is not named vX.Y.Z.md"
            )
            notes.append((version, file))
        }
        XCTAssertFalse(notes.isEmpty, "docs/release-notes holds no notes")
        return notes
    }

    /// Notes for a new release are written by copying the last ones, and the
    /// heading is the line that is easiest to leave behind - which publishes a
    /// release body titled with the previous version. `testReleaseNotesAreHeadedWithThisVersion`
    /// catches that for the version being built; this catches it for every file
    /// in the directory, including one prepared before its bump lands.
    func testEveryReleaseNotesFileIsHeadedWithItsOwnVersion() throws {
        for (version, file) in try releaseNotes() {
            let heading = try XCTUnwrap(
                String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n")
                    .first { $0.hasPrefix("# ") },
                "\(file.lastPathComponent) has no top-level heading"
            )
            XCTAssertTrue(
                heading.contains(version.description),
                "\(file.lastPathComponent) is headed with another version: \(heading)"
            )
        }
    }

    /// A bump goes forward, and the notes for the build in hand are the newest
    /// ones in the directory. Both halves fail the same way in practice: notes
    /// written for a version the project never bumped to, or a bump made without
    /// moving past the release that has already been published.
    func testThisVersionIsTheNewestOneWithReleaseNotes() throws {
        let declared = try builtVersion
        let built = try XCTUnwrap(AppVersion(declared), "the built version \(declared) is not X.Y.Z")
        let newest = try XCTUnwrap(try releaseNotes().map(\.version).max())

        XCTAssertEqual(
            newest, built,
            "docs/release-notes describes \(newest) but this build is \(built)"
        )
    }
}
