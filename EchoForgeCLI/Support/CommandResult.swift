import Foundation

/// What a shell learns from a command that did not succeed.
///
/// Distinct codes rather than a blanket `1`, because the whole point of a
/// scriptable surface is that the script can tell the cases apart without
/// parsing English: "no app installed" and "the update failed verification" ask
/// for very different next steps.
enum ExitCode: Int32, Equatable {
    /// The command did what it said.
    case success = 0

    /// It ran and could not finish - the general failure.
    case failure = 1

    /// The arguments were wrong. Nothing was read or done.
    case usage = 2

    /// No Kongweh app could be resolved at the expected path or at `--app`.
    case appNotFound = 3

    /// A local source could not be read: the history database, the log, the
    /// preferences domain. Distinct from `failure` because it usually means
    /// "the app has not run yet on this Mac" rather than "something broke".
    case sourceUnavailable = 4

    /// A download was refused: a checksum, a signature, a bundle identifier, a
    /// host that is not where releases are published. Its own code because it
    /// is the one failure a script must never retry blindly.
    case verificationFailed = 5

    /// The user said no, or pressed Ctrl-C.
    case cancelled = 6
}

/// What a command produces: one rendering for a person and one for a script.
///
/// Both are built even when only one is asked for, which is deliberate - it is
/// what makes `CLIJSONShapeTests` able to assert the JSON of a command it runs
/// in text mode, and it costs nothing at this size.
struct CommandResult: Equatable {
    /// The human rendering, without a trailing newline.
    let text: String

    /// The `--json` rendering.
    let json: JSONValue

    let exitCode: ExitCode

    init(text: String, json: JSONValue, exitCode: ExitCode = .success) {
        self.text = text
        self.json = json
        self.exitCode = exitCode
    }

    func rendered(asJSON: Bool) -> String {
        asJSON ? json.serialized : (text.isEmpty ? "" : text + "\n")
    }
}

/// A command that could not run, carrying the reason and the code.
///
/// `LocalizedError` so anything thrown out of the shared `EchoForgeCore` update
/// path - which speaks in `UpdateManifestError` and `UpdateInstallError` - is
/// reported in its own words rather than as "an error occurred".
struct CLIError: Error, Equatable {
    let message: String
    let exitCode: ExitCode

    /// Extra fields for the `--json` rendering, so a script can branch on
    /// something better than a string.
    let details: [(key: String, value: JSONValue)]

    init(_ message: String, exitCode: ExitCode = .failure, details: [(key: String, value: JSONValue)] = []) {
        self.message = message
        self.exitCode = exitCode
        self.details = details
    }

    static func == (lhs: CLIError, rhs: CLIError) -> Bool {
        lhs.message == rhs.message && lhs.exitCode == rhs.exitCode
    }

    var json: JSONValue {
        .object([("error", .string(message)), ("exitCode", .int(Int(exitCode.rawValue)))] + details)
    }

    /// Wraps anything thrown by the shared code in the tool's own vocabulary.
    static func wrapping(_ error: Error, exitCode: ExitCode = .failure) -> CLIError {
        if let cliError = error as? CLIError { return cliError }
        if error is CancellationError {
            return CLIError("Cancelled.", exitCode: .cancelled)
        }
        let described = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return CLIError(described, exitCode: exitCode)
    }
}
