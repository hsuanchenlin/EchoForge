import XCTest

/// `--json` exists to be scripted against, which means its shape is an interface
/// rather than an output format.
final class CLIJSONShapeTests: XCTestCase {

    func testSerializedJSONKeepsTheOrderItWasWrittenIn() {
        let value = JSONValue.object([
            ("zebra", .int(1)), ("apple", .int(2)), ("mango", .int(3)),
        ])
        let lines = value.serialized.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines[1].contains("zebra"))
        XCTAssertTrue(lines[2].contains("apple"))
        XCTAssertTrue(lines[3].contains("mango"))
    }

    /// A transcript can contain a quote, a backslash, a newline and a control
    /// character. All four have to survive a round trip.
    func testAwkwardStringsSurviveARoundTrip() throws {
        let awkward = "he said \"go\"\\ then\nstopped\u{0007}"
        let serialized = JSONValue.object([("t", .string(awkward))]).serialized
        let parsed =
            try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any]

        XCTAssertEqual(parsed?["t"] as? String, awkward)
    }

    func testNullIsDistinctFromEmptyAndFalse() throws {
        let serialized = JSONValue.object([
            ("missing", .string(String?.none)),
            ("empty", .string("")),
            ("no", .bool(false)),
        ]).serialized
        let parsed = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any]

        XCTAssertTrue(parsed?["missing"] is NSNull)
        XCTAssertEqual(parsed?["empty"] as? String, "")
        XCTAssertEqual(parsed?["no"] as? Bool, false)
    }

    func testDatesAreISO8601InUTC() {
        let value = JSONValue.date(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(value, .string("1970-01-01T00:00:00Z"))
    }

    /// Every command that emits records emits valid JSON with `--json`, on both
    /// a populated and an empty machine. The parse is the assertion.
    func testEveryCommandEmitsValidJSON() async throws {
        var populated = CLITestEnvironment.withInstalledApp()
        let history = FakeHistory()
        history.page = HistoryPage(
            rows: [Recording.fixture()], totalMatching: 1, databasePath: "/fake.sqlite")
        populated.history = history
        populated.preferences = FakePreferences(
            isReadable: true, values: [PreferenceKeys.selectedEngine: "whisper"])
        let updates = FakeUpdates()
        updates.availability = .available(.fixture())
        populated.updates = updates

        let invocations = [
            ["version", "--json"],
            ["status", "--json"],
            ["history", "--json"],
            ["logs", "--json"],
            ["settings", "--json"],
            ["update", "check", "--json"],
        ]

        for arguments in invocations {
            let execution = await runCLI(arguments, environment: populated)
            let document = execution.output.isEmpty ? execution.diagnostic : execution.output
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(document.utf8)),
                "\(arguments) produced invalid JSON: \(document)")
        }
    }

    /// A failure is JSON too, on stderr, so a script never gets an error
    /// document mixed into the stream it is parsing.
    func testAFailureIsJSONOnStderrAndStdoutStaysEmpty() async throws {
        let execution = await runCLI(["version", "--json"], environment: CLITestEnvironment.empty())

        XCTAssertTrue(execution.output.isEmpty)
        let json = try execution.decodedErrorJSON()
        XCTAssertNotNil(json["error"] as? String)
        XCTAssertEqual(json["exitCode"] as? Int, Int(ExitCode.appNotFound.rawValue))
    }

    func testPreParseFailuresHonorJSON() async throws {
        for arguments in [["wat", "--json"], ["history", "--limit", "--json"]] {
            let execution = await runCLI(arguments, environment: CLITestEnvironment.empty())
            XCTAssertEqual(execution.exitCode, .usage)
            XCTAssertNoThrow(try execution.decodedErrorJSON())
        }
    }
}

/// The rules that hold this tool's shape, checked by reading its own sources.
///
/// Blunt on purpose, in the same spirit as `CloudPrivacyTests` and
/// `HistoryProvenancePrivacyTests` in the app: a scan that occasionally has to
/// be taught about a legitimate new case is worth far more than a convention
/// nobody notices being broken.
final class CLISeamTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every Swift file under `directory`, with its comments removed.
    ///
    /// Stripping comments is what makes these scans usable at all: the rules
    /// below are worth stating in prose *next to the code that obeys them*, and
    /// a scan that could not tell "this file must never open the Keychain" from
    /// "this file opens the Keychain" would force every such note out of the
    /// source and into a document nobody reads.
    private func sources(in directory: String) throws -> [(name: String, text: String)] {
        let root = repositoryRoot.appendingPathComponent(directory)
        guard let files = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]
        else { throw XCTSkip("Sources are not beside the tests: \(root.path)") }
        return try files
            .filter { $0.hasSuffix(".swift") }
            .map { name in
                let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                return (name, Self.strippingComments(from: text))
            }
    }

    /// Line comments only. This project writes no block comments, and a
    /// half-correct block-comment parser would be worse than none: it would
    /// silently stop scanning at the first `/*` in a string literal.
    static func strippingComments(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Commands reach the machine only through `CLIEnvironment`.
    ///
    /// The failure this prevents is a test suite that quietly stops being safe
    /// to run: one `FileManager.default` or `NSWorkspace.shared` in a command,
    /// and the tests read the developer's own Mac instead of their fixtures.
    func testCommandsTouchTheMachineOnlyThroughTheEnvironment() throws {
        // The three files that are allowed to: the seam definitions, the AppKit
        // bridge, and the streaming reader. Each is small and named so the rule
        // is obvious from the list.
        let allowed = [
            "Environment/CLIEnvironment.swift",
            "Environment/WorkspaceBridge.swift",
            "Environment/LogStream.swift",
            "Environment/HistoryReader.swift",
            "Environment/LogReader.swift",
            "Environment/UpdateService.swift",
            "CommandRouter.swift",
        ]
        let forbidden = [
            "FileManager.default", "NSWorkspace", "URLSession", "Process(",
            "NSRunningApplication",
        ]

        var scanned = 0
        for (name, text) in try sources(in: "EchoForgeCLI") where !allowed.contains(name) {
            scanned += 1
            for symbol in forbidden where text.contains(symbol) {
                XCTFail(
                    "EchoForgeCLI/\(name) reaches \(symbol) directly. Everything outside this tool "
                        + "goes through CLIEnvironment, or the tests stop being safe to run.")
            }
        }
        XCTAssertGreaterThan(scanned, 8, "the scan found almost no sources")
    }

    /// The tool never opens the Keychain, which is why `settings` can say the
    /// API key is `<redacted>` and mean it.
    func testNothingReachesTheCredentialStore() throws {
        // The Security framework itself, rather than the app's
        // `CloudCredentialStore`: that type is in the app module, which this
        // target does not compile, so it is unreachable from here by
        // construction and the only way to open the Keychain would be to call
        // Security directly.
        let forbidden = [
            "import Security", "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "kSecClass",
        ]
        for (name, text) in try sources(in: "EchoForgeCLI") {
            for symbol in forbidden where text.contains(symbol) {
                XCTFail(
                    "EchoForgeCLI/\(name) uses \(symbol). The API key lives only in the "
                        + "Keychain, and this tool not opening it is what makes `settings` "
                        + "honest rather than filtered.")
            }
        }
    }

    /// One updater, and it is the app's.
    ///
    /// Nothing here may fetch a release, hash a download, mount a disk image or
    /// move an app bundle: those are `EchoForgeCore`'s, where they are reviewed
    /// as a security boundary.
    func testTheToolDoesNotImplementASecondUpdater() throws {
        let forbidden = [
            "api.github.com", "browser_download_url", "hdiutil", "codesign",
            "SHA256", "moveItem", "removeItem", "copyItem",
        ]
        for (name, text) in try sources(in: "EchoForgeCLI") {
            for symbol in forbidden where text.contains(symbol) {
                XCTFail(
                    "EchoForgeCLI/\(name) mentions \(symbol). The download, the checksum, the "
                        + "disk image and the swap belong to UpdateManifest and UpdateInstaller; "
                        + "a second copy of any of them is a second security boundary.")
            }
        }
    }

    /// The read-only promise, held at the level of what the tool can even name.
    func testNoCommandWritesToTheUsersData() throws {
        let forbidden = ["DELETE FROM", "UPDATE ", "INSERT INTO", "DROP TABLE", ".delete(", ".update("]
        for (name, text) in try sources(in: "EchoForgeCLI") {
            for symbol in forbidden where text.contains(symbol) {
                XCTFail("EchoForgeCLI/\(name) mentions \(symbol); this tool only reads.")
            }
        }
    }
}
