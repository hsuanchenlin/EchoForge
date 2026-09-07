import FluidAudio
import XCTest

@testable import OpenSuperWhisper

/// `AppDataLocation` is the one answer two processes have to agree on.
///
/// The app writes the recordings database, the terms file and the downloaded
/// models; the `echoforge` command-line tool reads them from a process with a
/// different bundle identity, or none at all. Every test here is a way those two
/// could quietly stop pointing at the same directory - which would not look like
/// a bug, it would look like an empty history.
final class AppDataLocationTests: XCTestCase {

    /// The identity is a constant, not `Bundle.main`, and the app's own bundle
    /// identifier has to equal it. `AppIdentityTests` asserts the same thing
    /// from the other side.
    func testTheStorageIdentifierIsTheAppsOwn() {
        XCTAssertEqual(AppDataLocation.storageIdentifier, "com.hsuanchenlin.EchoForge")
        XCTAssertEqual(AppDataLocation.bundleIdentifier, AppDataLocation.storageIdentifier)
    }

    /// Every path hangs off the same directory, so there is one place to change
    /// and one place that can be wrong.
    func testEveryPathIsUnderTheOneApplicationSupportDirectory() {
        let root = AppDataLocation.applicationSupportDirectory()
        XCTAssertTrue(root.path.hasSuffix("/com.hsuanchenlin.EchoForge"))

        for url in [
            AppDataLocation.recordingsDatabaseURL(),
            AppDataLocation.recordingsDirectory(),
            AppDataLocation.whisperModelsDirectory(),
        ] {
            XCTAssertTrue(
                url.path.hasPrefix(root.path + "/"),
                "\(url.lastPathComponent) is not under the app's own directory")
        }
    }

    /// The names, pinned. These are the directories every existing user's data
    /// is already in; a rename is a migration, not an edit.
    func testTheNamesAreTheOnesUsersDataIsAlreadyIn() {
        XCTAssertEqual(AppDataLocation.recordingsDatabaseURL().lastPathComponent, "recordings.sqlite")
        XCTAssertEqual(AppDataLocation.recordingsDirectory().lastPathComponent, "recordings")
        XCTAssertEqual(AppDataLocation.whisperModelsDirectory().lastPathComponent, "whisper-models")
    }

    /// The store and the model manager resolve through `AppDataLocation` rather
    /// than rebuilding the path, so a change here reaches them.
    func testTheAppsOwnReadersAgreeWithIt() {
        XCTAssertEqual(Recording.recordingsDirectory, AppDataLocation.recordingsDirectory())
        XCTAssertEqual(
            WhisperModelManager.shared.modelsDirectory, AppDataLocation.whisperModelsDirectory())
    }

    /// The one path this project does not own.
    ///
    /// `echoforge status` reports which on-device model weights are on disk, and
    /// it must not load FluidAudio and its CoreML stack to find out - so it
    /// reads the directory FluidAudio downloads into. That makes the path a
    /// duplicate of somebody else's constant, which is exactly the kind of thing
    /// that rots silently: an upstream version that moved it would leave the
    /// tool reporting "no models" forever, with nothing failing. This is what
    /// fails instead.
    func testTheFluidAudioModelsPathStillMatchesThePinnedUpstream() {
        XCTAssertEqual(
            AppDataLocation.fluidAudioModelsDirectory(),
            MLModelConfigurationUtils.defaultModelsDirectory(),
            "FluidAudio moved its models directory. `echoforge status` reads that path directly "
                + "and would silently report no models; update AppDataLocation to match.")
    }

    /// And it is outside the app's own directory, which is the reason it needs
    /// its own accessor at all rather than being another `appendingPathComponent`.
    func testTheFluidAudioPathIsNotUnderTheAppsOwnDirectory() {
        XCTAssertFalse(
            AppDataLocation.fluidAudioModelsDirectory().path
                .hasPrefix(AppDataLocation.applicationSupportDirectory().path))
    }

    /// Nothing here force-unwraps its way to a path.
    ///
    /// Three places used to write `Bundle.main.bundleIdentifier!`, which is a
    /// crash in any process that is not the app - including the tool. A source
    /// scan, because the failure is a crash at launch rather than a wrong value.
    func testNoSourceForcesABundleIdentifier() throws {
        let roots = ["OpenSuperWhisper", "EchoForgeCore", "EchoForgeCLI"]
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()

        var scanned = 0
        for root in roots {
            let directory = repositoryRoot.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(atPath: directory.path)?
                .allObjects as? [String]
            else { throw XCTSkip("Sources are not beside the tests: \(directory.path)") }
            for file in files where file.hasSuffix(".swift") {
                let text = Self.strippingComments(
                    from: try String(
                        contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
                scanned += 1
                XCTAssertFalse(
                    text.contains("Bundle.main.bundleIdentifier!"),
                    "\(root)/\(file) force-unwraps Bundle.main.bundleIdentifier, which is nil in "
                        + "the echoforge tool. Use AppDataLocation.")
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources")
    }

    /// Line comments removed, so a file may *explain* the rule it obeys without
    /// tripping the scan that enforces it - which is exactly what
    /// `AppDataLocation`'s own header does.
    static func strippingComments(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
