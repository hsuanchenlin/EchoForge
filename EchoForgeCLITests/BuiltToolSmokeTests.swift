import XCTest

/// The one test that runs the **built binary** rather than the code inside it.
///
/// Everything else in this bundle proves the logic is right. This proves the
/// product exists: that `echoforge` links, starts, prints its help and its
/// version, and exits 0 - on a machine with no microphone grant, no
/// Accessibility grant, no Screen Recording grant, no model weights and no cloud
/// credential. That combination is exactly what a fresh CI runner is, and it is
/// the failure mode a unit test cannot see: v0.3.0 of this project shipped an app
/// that passed every check anyone ran and could not start on any Mac
/// (`Scripts/verify_release_package.sh`, and the reason it starts the app it is
/// verifying). This is the same idea, one size down.
///
/// It never runs a command that reads the user's data or reaches the network -
/// `--help` and `--version` only.
final class BuiltToolSmokeTests: XCTestCase {

    /// The tool beside this test bundle in the build products directory.
    ///
    /// Found by path rather than by a build setting because a test bundle has no
    /// dependency on an executable: both are built by the same scheme into the
    /// same directory, and that is the whole relationship.
    private var toolURL: URL? {
        let products = Bundle(for: BuiltToolSmokeTests.self).bundleURL.deletingLastPathComponent()
        let candidate = products.appendingPathComponent("echoforge")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        guard let toolURL else {
            throw XCTSkip(
                "echoforge was not built beside this test bundle. Build the OpenSuperWhisper "
                    + "scheme, which builds both.")
        }
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // No terminal and no stdin: anything that tried to ask a question would
        // hang here rather than pass.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }

    func testHelpRunsAndNamesEveryCommand() throws {
        let result = try run(["--help"])

        XCTAssertEqual(result.status, 0, result.error)
        for command in CommandRouter.commands {
            XCTAssertTrue(
                result.output.contains(command.spec.name),
                "--help does not list \(command.spec.name)")
        }
    }

    func testEveryCommandsOwnHelpRunsWithoutReadingAnything() throws {
        for command in CommandRouter.commands {
            let result = try run([command.spec.name, "--help"])
            XCTAssertEqual(result.status, 0, "\(command.spec.name) --help failed: \(result.error)")
            XCTAssertTrue(result.output.contains("USAGE: echoforge \(command.spec.name)"))
        }
    }

    /// The tool's own version, which needs no app installed and no permission.
    func testVersionFlagReportsTheToolsOwnVersion() throws {
        let result = try run(["--version"])

        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.output.hasPrefix("echoforge "), result.output)
        // Read out of the binary's own embedded Info.plist section, so it tracks
        // MARKETING_VERSION rather than being maintained by hand.
        XCTAssertFalse(
            result.output.contains("0.0.0"),
            "the tool reports no version of its own; CREATE_INFOPLIST_SECTION_IN_BINARY is what "
                + "puts MARKETING_VERSION into the binary.")
    }

    func testAnUnknownCommandExitsWithTheUsageCodeAndWritesNothingToStdout() throws {
        let result = try run(["nonsense"])

        XCTAssertEqual(result.status, ExitCode.usage.rawValue)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.error.contains("Unknown command"))
    }
}
