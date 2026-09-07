import XCTest

/// `settings` reports what is stored and refuses to guess or to leak.
final class SettingsCommandTests: XCTestCase {

    private func environment(_ values: [String: Any], readable: Bool = true) -> CLIEnvironment {
        var environment = CLITestEnvironment.empty()
        environment.preferences = FakePreferences(isReadable: readable, values: values)
        return environment
    }

    func testAStoredValueIsReportedAndAnUnsetOneIsNotGuessed() async throws {
        let execution = await runCLI(
            ["settings", "--json"],
            environment: environment([PreferenceKeys.selectedEngine: "sensevoice"]))

        let rows = try execution.decodedJSON()["settings"] as? [[String: Any]] ?? []
        let engine = rows.first { $0["key"] as? String == PreferenceKeys.selectedEngine }
        XCTAssertEqual(engine?["set"] as? Bool, true)
        XCTAssertEqual(engine?["value"] as? String, "sensevoice")

        // `capsuleHUDEnabled` defaults to true in the app. This tool must not
        // say so - it did not read a value, and the app's default is the app's.
        let capsule = rows.first { $0["key"] as? String == PreferenceKeys.capsuleHUDEnabled }
        XCTAssertEqual(capsule?["set"] as? Bool, false)
        XCTAssertTrue(capsule?["value"] is NSNull)
    }

    func testAnUnreadablePreferencesDomainFailsRatherThanReportingEverythingAsOff() async throws {
        let execution = await runCLI(["settings"], environment: environment([:], readable: false))

        XCTAssertEqual(execution.exitCode, .sourceUnavailable)
        XCTAssertTrue(execution.output.isEmpty)
        XCTAssertTrue(execution.diagnostic.contains("could not provide values"))
    }

    // MARK: - Secrecy

    /// The rule this command exists under: no credential reaches the output.
    func testNoRenderingEverCarriesACredential() async throws {
        // Values that would be a leak if any of them were printed. None of these
        // keys is in the inventory, which is the point - the tool reports the
        // inventory and not the domain.
        let execution = await runCLI(
            ["settings", "--json"],
            environment: environment([
                "cloudAPIKey": "sk-livekey000000000000000000",
                "authToken": "ghp_0000000000000000000000000",
                PreferenceKeys.cloudBaseURL: "https://api.openai.com/v1",
            ]))

        for forbidden in ["sk-livekey", "ghp_0000", "authToken", "cloudAPIKey"] {
            XCTAssertFalse(
                execution.output.contains(forbidden),
                "\(forbidden) reached the output")
        }
        // The setting that is legitimately reportable still is.
        XCTAssertTrue(execution.output.contains("https://api.openai.com/v1"))
    }

    func testCloudBaseURLUserInfoIsRemovedFromTextAndJSON() async throws {
        let values = [PreferenceKeys.cloudBaseURL: "https://user:password@example.com/v1"]

        let textExecution = await runCLI(["settings"], environment: environment(values))
        XCTAssertTrue(textExecution.output.contains("https://example.com/v1"))
        XCTAssertFalse(textExecution.output.contains("user:password"))
        XCTAssertFalse(textExecution.output.contains("password@"))

        let jsonExecution = await runCLI(
            ["settings", "--json"], environment: environment(values))
        XCTAssertTrue(jsonExecution.output.contains("https://example.com/v1"))
        XCTAssertFalse(jsonExecution.output.contains("user:password"))
        XCTAssertFalse(jsonExecution.output.contains("password@"))
    }

    /// The API key is listed as withheld rather than omitted, so its absence is
    /// visible: an omitted row reads as "there is no key".
    func testTheKeychainRowIsPresentAndRedacted() async throws {
        let execution = await runCLI(["settings", "--json"], environment: environment([:]))

        let withheld = try execution.decodedJSON()["withheld"] as? [[String: Any]] ?? []
        let key = withheld.first { ($0["label"] as? String) == "API key" }
        XCTAssertNotNil(key, "the API key row is missing; its absence must be visible")
        XCTAssertEqual(key?["value"] as? String, Redaction.marker)
        XCTAssertTrue((key?["reason"] as? String ?? "").contains("Keychain"))
    }

    func testTheTextRenderingAlsoRedactsTheKey() async throws {
        let execution = await runCLI(["settings"], environment: environment([:]))
        XCTAssertTrue(execution.output.contains("API key"))
        XCTAssertTrue(execution.output.contains(Redaction.marker))
    }

    func testEachTextSectionHeaderAppearsOnce() async throws {
        let execution = await runCLI(["settings"], environment: environment([:]))
        for section in Set(PreferenceInventory.all.map(\.section)) {
            XCTAssertEqual(
                execution.output.components(separatedBy: "\n\(section.uppercased())\n").count - 1
                    + (execution.output.hasPrefix(section.uppercased() + "\n") ? 1 : 0),
                1)
        }
    }

    // MARK: - Type mismatches

    /// A hand-edited domain must be reported as the mismatch it is, not coerced.
    func testAWrongTypeIsReportedRatherThanCoerced() {
        let value = StoredValue("yes", kind: .boolean)
        XCTAssertTrue(value.isSet)
        XCTAssertTrue(value.display.contains("unexpected type"))
    }

    /// The microphone selection is bytes, not something to print.
    func testOpaqueValuesAreReportedAsPresentAndNotDecoded() {
        let value = StoredValue(Data([0xDE, 0xAD, 0xBE, 0xEF]), kind: .opaque)
        XCTAssertEqual(value.display, "set (4 bytes, not shown)")
        XCTAssertFalse(value.json.serialized.contains("DEAD"))
    }

    /// Every key the tool reports is a real one, so `settings` cannot report a
    /// key nothing writes.
    func testEveryInventoryKeyIsADeclaredPreference() {
        for preference in PreferenceInventory.all {
            XCTAssertTrue(
                PreferenceKeys.all.contains(preference.key),
                "\(preference.label) reports \"\(preference.key)\", which is not a PreferenceKeys "
                    + "constant - so nothing in the app writes it.")
        }
    }
}

/// `logs` reads bounded windows and redacts everything it prints.
final class LogsCommandTests: XCTestCase {

    private func environment(_ result: LogReadResult) -> (CLIEnvironment, FakeLog) {
        var environment = CLITestEnvironment.empty()
        let log = FakeLog()
        log.result = result
        environment.log = log
        return (environment, log)
    }

    func testItDefaultsToABoundedTailAndWindow() async throws {
        let (environment, log) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))

        _ = await runCLI(["logs"], environment: environment)

        XCTAssertEqual(log.requests.first?.tail, LogLimits.defaultTail)
        XCTAssertEqual(log.requests.first?.since, LogLimits.defaultSince)
        XCTAssertEqual(log.requests.first?.source, .unified)
    }

    func testTailAndSinceAreForwardedAndBounded() async throws {
        let (environment, log) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))

        _ = await runCLI(["logs", "--tail", "5", "--since", "2h"], environment: environment)
        XCTAssertEqual(log.requests.first?.tail, 5)
        XCTAssertEqual(log.requests.first?.since, "2h")

        let tooMany = await runCLI(
            ["logs", "--tail", "\(LogLimits.maximumTail + 1)"], environment: environment)
        XCTAssertEqual(tooMany.exitCode, .usage)
    }

    /// `--since` is the one user-supplied value that reaches the argument list
    /// of a process this tool starts, so it is validated rather than passed on.
    func testAnUnrecognisedSinceIsRefusedBeforeAnythingRuns() async throws {
        let (environment, log) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))

        for bad in ["yesterday", "2 hours", "-1h", "h", "2x", "; rm -rf /"] {
            let execution = await runCLI(["logs", "--since", bad], environment: environment)
            XCTAssertEqual(execution.exitCode, .usage, "--since \(bad) should be refused")
        }
        XCTAssertTrue(log.requests.isEmpty, "nothing may be read before --since is validated")
    }

    func testUnknownSourceNamesTheOnesThatExist() async throws {
        let (environment, _) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))
        let execution = await runCLI(["logs", "--source", "syslog"], environment: environment)

        XCTAssertEqual(execution.exitCode, .usage)
        XCTAssertTrue(execution.diagnostic.contains("unified"))
        XCTAssertTrue(execution.diagnostic.contains("update-install"))
    }

    /// A source that could not be read is not an empty source.
    func testAnUnavailableSourceHasItsOwnExitCode() async throws {
        let (environment, _) = environment(
            LogReadResult(
                source: .updateInstall, entries: [],
                unavailableReason: "No installer log at /tmp/x."))

        let execution = await runCLI(["logs", "--source", "update-install", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .sourceUnavailable)
        let json = try execution.decodedJSON()
        XCTAssertEqual(json["available"] as? Bool, false)
        XCTAssertEqual((json["entries"] as? [Any])?.count, 0)
    }

    /// Read it and found nothing is a success.
    func testAnEmptyWindowSucceeds() async throws {
        let (environment, _) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))
        let execution = await runCLI(["logs"], environment: environment)

        XCTAssertEqual(execution.exitCode, .success)
        XCTAssertTrue(execution.output.contains("nothing in the window"))
    }

    // MARK: - Redaction

    func testCredentialsAndTranscriptsAreRedactedFromEveryRendering() async throws {
        let (environment, _) = environment(
            LogReadResult(
                source: .unified,
                entries: [
                    LogEntry(timestamp: nil, category: nil, message: "Authorization: Bearer abc123secret"),
                    LogEntry(timestamp: nil, category: nil, message: "using sk-livekey000000000000000000"),
                    LogEntry(
                        timestamp: nil, category: nil,
                        message: "Transcription result: the thing I said out loud"),
                ],
                unavailableReason: nil))

        for arguments in [["logs"], ["logs", "--json"]] {
            let execution = await runCLI(arguments, environment: environment)
            for forbidden in ["abc123secret", "sk-livekey", "the thing I said out loud"] {
                XCTAssertFalse(
                    execution.output.contains(forbidden),
                    "\(forbidden) survived \(arguments)")
            }
            XCTAssertTrue(execution.output.contains(Redaction.marker))
        }
    }

    /// `--follow` and `--json` together would produce a document with no end.
    func testFollowAndJSONAreRefusedTogether() async throws {
        let (environment, _) = environment(
            LogReadResult(source: .unified, entries: [], unavailableReason: nil))
        let execution = await runCLI(["logs", "--follow", "--json"], environment: environment)

        XCTAssertEqual(execution.exitCode, .usage)
    }
}

final class LogStreamTests: XCTestCase {
    func testInterruptForceStopsAChildThatIgnoresTermination() throws {
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            raise(SIGINT)
        }

        try LogStream.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"],
            onLine: { _ in })

        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}

/// The redaction rules on their own.
final class RedactionTests: XCTestCase {

    private let redaction = Redaction(homeDirectory: "/Users/someone")

    func testCredentialLabelsTakeTheRestOfTheirLine() {
        XCTAssertEqual(
            Redaction.redactingCredentials(in: "Authorization: Bearer xyz"),
            "Authorization:\(Redaction.marker)")
        XCTAssertEqual(
            Redaction.redactingCredentials(in: "api_key=abcdef"),
            "api_key=\(Redaction.marker)")
    }

    /// Only that line: a log is many lines and one credential must not blank the
    /// rest of the window.
    func testOnlyTheLineWithTheCredentialIsCut() {
        let redacted = Redaction.redactingCredentials(in: "first\ntoken: abc\nthird")
        XCTAssertTrue(redacted.hasPrefix("first\n"))
        XCTAssertTrue(redacted.hasSuffix("\nthird"))
    }

    func testKeyShapedTokensGoEvenWithNoLabel() {
        XCTAssertEqual(
            Redaction.redactingCredentials(in: "see sk-abcdefghijklmnopqrstuvwxyz now"),
            "see \(Redaction.marker) now")
    }

    /// Short things that merely start with a prefix are words, not keys.
    func testAShortPrefixMatchIsLeftAlone() {
        XCTAssertEqual(Redaction.redactingCredentials(in: "sk-test"), "sk-test")
    }

    func testTranscriptPrefixesTakeTheRestOfTheirLine() {
        for message in [
            "Transcription result: hello world",
            "Ask: private question",
            "Voice edit: private instruction -> private rewrite",
        ] {
            let redacted = Redaction.redactingTranscripts(in: message)
            XCTAssertTrue(redacted.hasSuffix(Redaction.marker))
            XCTAssertFalse(redacted.contains("private"))
            XCTAssertFalse(redacted.contains("hello world"))
        }
    }

    func testTranscriptPrefixesOnlyMatchAtMessageStart() {
        let message = "Task: Ask: inspect the updater"
        XCTAssertEqual(Redaction.redactingTranscripts(in: message), message)
    }

    func testTheHomeDirectoryIsFolded() {
        XCTAssertEqual(
            redaction.foldingHomeDirectory(in: "/Users/someone/Library/x"),
            "~/Library/x")
    }

    /// A framework that logs a page of XML should not become a page of terminal.
    func testLongMessagesAreTruncated() {
        let long = String(repeating: "z", count: Redaction.maximumMessageLength * 2)
        let redacted = redaction.redact(long)
        XCTAssertTrue(redacted.hasSuffix("(truncated)"))
        XCTAssertLessThan(redacted.count, Redaction.maximumMessageLength + 20)
    }

    func testDurationGrammarAcceptsOnlyWhatLogShowTakes() {
        for good in ["30s", "15m", "2h", "7d", "1h"] {
            XCTAssertTrue(LogDuration.isValid(good), "\(good) should be valid")
        }
        for bad in ["", "h", "0h", "-1h", "1w", "2 h", "1h30m", "1h;", "yesterday"] {
            XCTAssertFalse(LogDuration.isValid(bad), "\(bad) should be refused")
        }
    }
}
