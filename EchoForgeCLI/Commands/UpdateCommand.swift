import Foundation

/// `echoforge update check` and `echoforge update install`.
///
/// This command adds **no security rule and skips none**. Every check that
/// stands between release metadata and "replace the application" is
/// `EchoForgeCore`'s, the same code the About pane runs: `UpdateManifest`
/// refuses anything but an HTTPS URL on GitHub's release hosts under this
/// repository, with the exact asset name and a parseable `X.Y.Z` tag;
/// `UpdateChecker` refuses to offer a downgrade or to compare a version it
/// cannot parse; `UpdateInstaller` checks the declared size, the published
/// SHA-256 sidecar, the downloaded bundle's identifier and version, and its
/// signature, before anything is staged. There is no `--force`, no "install
/// anyway", and `--yes` skips **only the question**, never a check.
///
/// What this file adds is the two things a terminal needs that a pane does not.
///
/// **It refuses while Kongweh is running.** The swap runs in a detached script
/// that waits for a process to exit and then renames the bundle, and the process
/// it waits for is the one that started it - which here is this tool, not the
/// app. Replacing a running application's bundle out from under it is what
/// produces "the application is damaged", so the app has to be gone first. The
/// app's own updater does not have this problem because it quits itself; a tool
/// cannot quit somebody else's app on their behalf.
///
/// **It asks before replacing anything.** `--yes` exists for scripts, and its
/// documentation says what it does and does not skip.
enum UpdateCommand: CLICommand {
    static let spec = CommandSpec(
        name: "update",
        summary: "Check for a newer Kongweh, or install one.",
        usage: "update <check|install> [--app <absolute-path>] [--yes] [--json]",
        valueOptions: ["app"],
        switches: ["yes"],
        subcommands: ["check", "install"],
        help: [
            "check   asks GitHub what the newest published release is and compares it with",
            "        the installed app. Exits 0 either way; the `updateAvailable` field and",
            "        the text say which.",
            "install downloads it, verifies it and swaps it in. Quit Kongweh first: the",
            "        swap renames the bundle, and a running app cannot replace itself.",
            "",
            "--yes answers the confirmation for a script. It skips the question and nothing",
            "else - the host allow-list, the published checksum, the bundle identity and the",
            "signature are all still checked, and any of them failing ends the install.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let application = try ApplicationLocator.locate(
            override: arguments.option("app"), in: environment)

        switch arguments.subcommand {
        case "check", nil:
            return try await check(application, in: environment)
        case "install":
            return try await install(
                application, assumeYes: arguments.switches.contains("yes"), in: environment)
        case let other?:
            throw CLIError("Unknown subcommand \"\(other)\".", exitCode: .usage)
        }
    }

    // MARK: - check

    static func check(_ application: InstalledApplication, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let availability: UpdateAvailability
        do {
            availability = try await environment.updates.check(current: application.identity)
        } catch {
            throw CLIError.wrapping(error)
        }

        switch availability {
        case .upToDate(let current):
            return CommandResult(
                text: "Kongweh \(current) is the newest published release.",
                json: .object([
                    ("updateAvailable", .bool(false)),
                    ("current", .string(current.description)),
                    ("latest", .null),
                    ("app", application.json),
                ]))
        case .available(let release):
            return CommandResult(
                text: """
                    Kongweh \(release.version) is available (you have \
                    \(application.identity.marketingVersion)).
                      asset:   \(UpdateManifest.assetName), \(bytes(release.sizeInBytes))
                      release: \(release.releasePageURL.absoluteString)
                      install: echoforge update install
                    """,
                json: .object([
                    ("updateAvailable", .bool(true)),
                    ("current", .string(application.identity.marketingVersion)),
                    ("latest", .string(release.version.description)),
                    ("tag", .string(release.tag)),
                    ("assetSizeBytes", .int(release.sizeInBytes)),
                    // Whether the release publishes the SHA-256 sidecar. Worth
                    // reporting: releases before v0.5.2 published none, and a
                    // present-but-wrong one fails the install rather than being
                    // skipped.
                    ("publishesChecksum", .bool(release.checksumURL != nil)),
                    ("releasePage", .string(release.releasePageURL.absoluteString)),
                    ("app", application.json),
                ]))
        }
    }

    // MARK: - install

    static func install(
        _ application: InstalledApplication, assumeYes: Bool, in environment: CLIEnvironment
    ) async throws -> CommandResult {
        let availability: UpdateAvailability
        do {
            availability = try await environment.updates.check(current: application.identity)
        } catch {
            throw CLIError.wrapping(error)
        }

        guard case .available(let release) = availability else {
            guard case .upToDate(let current) = availability else {
                throw CLIError("The update check did not produce a release.")
            }
            return CommandResult(
                text: "Kongweh \(current) is already the newest published release. Nothing to do.",
                json: .object([
                    ("installed", .bool(false)),
                    ("reason", .string("upToDate")),
                    ("current", .string(current.description)),
                ]))
        }

        // Checked *before* downloading 30 MB, so a user who has to quit the app
        // is told at the start rather than after the transfer.
        let running = ApplicationLocator.runningCopies(in: environment)
        if let copy = running.first {
            throw CLIError(
                "Kongweh is running (pid \(copy.processIdentifier)). Installing renames the app "
                    + "bundle, and a running app cannot be replaced - quit Kongweh and run this "
                    + "again.",
                details: [
                    ("installed", .bool(false)),
                    ("reason", .string("appRunning")),
                    ("processIdentifier", .int(Int(copy.processIdentifier))),
                ])
        }

        if !assumeYes {
            let question = """
                Replace Kongweh \(application.identity.marketingVersion) at \
                \(application.url.path) with \(release.version)? [y/N]
                """
            guard environment.confirm(question) == true else {
                return CommandResult(
                    text: "Cancelled. Nothing was downloaded or replaced.",
                    json: .object([
                        ("installed", .bool(false)),
                        ("reason", .string("cancelled")),
                        ("latest", .string(release.version.description)),
                    ]),
                    exitCode: .cancelled)
            }
        }

        let staged: URL
        do {
            staged = try await environment.updates.downloadAndVerify(
                release, replacing: application,
                progress: { progress in
                    StandardStreams.progress(describe(progress))
                })
            StandardStreams.progressDone()
        } catch {
            StandardStreams.progressDone()
            throw failure(from: error, release: release)
        }

        if let copy = ApplicationLocator.runningCopies(in: environment).first {
            throw CLIError(
                "Kongweh started while the update was downloading (pid \(copy.processIdentifier)). "
                    + "The verified update was not installed - quit Kongweh and run this again.",
                details: [
                    ("installed", .bool(false)),
                    ("reason", .string("appRunning")),
                    ("processIdentifier", .int(Int(copy.processIdentifier))),
                ])
        }

        do {
            try await environment.updates.installAndRelaunch(stagedApp: staged, replacing: application)
        } catch {
            throw failure(from: error, release: release)
        }

        return CommandResult(
            text: """
                Kongweh \(release.version) verified and staged. The swap runs as this command \
                exits, and reopens the app.
                """,
            json: .object([
                ("installed", .bool(true)),
                ("reason", .null),
                ("from", .string(application.identity.marketingVersion)),
                ("to", .string(release.version.description)),
                ("path", .string(application.url.path)),
            ]))
    }

    /// Turns a refusal from the shared installer into an exit code a script can
    /// branch on.
    ///
    /// The distinction that matters: a *verification* failure means the bytes
    /// were wrong and no amount of retrying will help, and it must never be
    /// reported as the same thing as a connection that dropped.
    static func failure(from error: Error, release: PublishedRelease) -> CLIError {
        if error is CancellationError {
            return CLIError(
                "Cancelled. Nothing was replaced.", exitCode: .cancelled,
                details: [("installed", .bool(false)), ("reason", .string("cancelled"))])
        }
        guard let refusal = error as? UpdateInstallError else {
            return CLIError.wrapping(error)
        }
        let verification = refusal.indictsDownloadedBytes
        return CLIError(
            refusal.errorDescription ?? String(describing: refusal),
            exitCode: verification ? .verificationFailed : .failure,
            details: [
                ("installed", .bool(false)),
                ("reason", .string(verification ? "verificationFailed" : "downloadFailed")),
                ("latest", .string(release.version.description)),
            ])
    }

    static func describe(_ progress: UpdateProgress) -> String {
        switch progress {
        case .connecting:
            return "connecting…"
        case .downloading(let download):
            return "downloading \(bytes(Int(download.receivedBytes))) of "
                + "\(bytes(Int(download.totalBytes)))"
        case .verifying:
            return "verifying…"
        }
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}
