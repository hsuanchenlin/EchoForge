import Foundation

/// `echoforge start` - open Kongweh, or say why it did not.
///
/// The whole command is one decision and one call. The decision is
/// `StartDecision`, which is pure, because the interesting cases are all about
/// what is *already* running and none of them should need a real desktop to
/// test: a copy running from the path asked for, a copy running from a different
/// path, several copies, none.
///
/// Never starting a second copy is not a nicety. Two Kongwehs share one
/// microphone, one set of global shortcuts and one recordings database, so the
/// second one is not a second app - it is a fight over the first one's state.
/// macOS agrees, which is why `NSWorkspace` activates a running copy rather than
/// duplicating it unless explicitly told otherwise; this command never tells it
/// otherwise, and refuses first so the user is told rather than left wondering
/// why `--app /tmp/EchoForge.app` brought the copy in `/Applications` forward.
enum StartCommand: CLICommand {
    static let spec = CommandSpec(
        name: "start",
        summary: "Launch the installed Kongweh app.",
        usage: "start [--app <absolute-path>] [--json]",
        valueOptions: ["app"],
        help: [
            "Does nothing and exits 0 when Kongweh is already running: two copies would",
            "share one microphone, one set of shortcuts and one database.",
            "",
            "--app names a copy somewhere else, for testing a build before installing it.",
            "It must be an absolute path to a bundle whose identifier is Kongweh's, and",
            "it is still refused while any copy is running.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let application = try ApplicationLocator.locate(
            override: arguments.option("app"), in: environment)
        let running = ApplicationLocator.runningCopies(in: environment)

        switch StartDecision.decide(requested: application.url, running: running) {
        case .alreadyRunning(let copy):
            let elsewhere = copy.bundleURL.map { $0.standardizedFileURL != application.url }
            let where_ = copy.bundleURL?.path ?? "an unknown path"
            var text = "Kongweh is already running (pid \(copy.processIdentifier)) from \(where_)."
            if elsewhere == true {
                text += """


                    That is not the copy you named (\(application.path)). macOS activates a running
                    copy rather than starting a second one, so quit the running copy first.
                    """
            }
            return CommandResult(
                text: text,
                json: .object([
                    ("started", .bool(false)),
                    ("alreadyRunning", .bool(true)),
                    ("processIdentifier", .int(Int(copy.processIdentifier))),
                    ("runningPath", .string(copy.bundleURL?.path)),
                    ("requestedPath", .string(application.url.path)),
                    ("app", application.json),
                ]))

        case .start:
            let started = try environment.launcher.launch(at: application.url)
            return CommandResult(
                text: "Started Kongweh \(application.identity.marketingVersion) "
                    + "from \(application.url.path).",
                json: .object([
                    ("started", .bool(true)),
                    ("alreadyRunning", .bool(false)),
                    ("processIdentifier", .int(started.map { Int($0.processIdentifier) })),
                    ("runningPath", .string((started?.bundleURL ?? application.url).path)),
                    ("requestedPath", .string(application.url.path)),
                    ("app", application.json),
                ]))
        }
    }
}

private extension InstalledApplication {
    var path: String { url.path }
}

/// Whether to launch, given what is already running.
///
/// Pure and separate so the cases that matter can be asserted without a desktop.
enum StartDecision: Equatable {
    case start
    case alreadyRunning(RunningCopy)

    static func decide(requested: URL, running: [RunningCopy]) -> StartDecision {
        guard !running.isEmpty else { return .start }
        // The copy at the requested path wins when there is one, so the message
        // names the process the caller was actually asking about rather than
        // whichever copy macOS listed first.
        let match = running.first { $0.bundleURL?.standardizedFileURL == requested.standardizedFileURL }
        return .alreadyRunning(match ?? running[0])
    }
}
