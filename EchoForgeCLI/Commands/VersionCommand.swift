import Foundation

/// Every command in this tool, as one shape.
protocol CLICommand {
    static var spec: CommandSpec { get }
    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
}

/// `echoforge version` - what is installed, and what this tool is.
///
/// Both numbers, because they answer different questions and are routinely
/// different: the app was installed months ago and the tool was built from
/// today's checkout, or the other way round. Reporting one as "the version"
/// would make a bug report about the wrong build.
///
/// The app's version is read out of the bundle's own `Info.plist` through
/// `AppBuildIdentity`, the same reader the About pane uses. There is deliberately
/// no fallback to the repository's `MARKETING_VERSION`, to a cached answer, or
/// to what the updater last installed: a version that is not read off the bundle
/// the user is actually running is a version that will eventually be wrong at
/// precisely the moment somebody needs it to be right.
enum VersionCommand: CLICommand {
    static let spec = CommandSpec(
        name: "version",
        summary: "Report the installed Kongweh version and this tool's own.",
        usage: "version [--app <absolute-path>] [--json]",
        valueOptions: ["app"],
        help: [
            "Exits \(ExitCode.appNotFound.rawValue) when no app is installed, so a script can",
            "tell \"not installed\" from \"could not read it\".",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let application = try ApplicationLocator.locate(
            override: arguments.option("app"), in: environment)
        let tool = environment.toolIdentity

        let text = """
            Kongweh \(application.identity.marketingVersion) (\(application.identity.buildNumber))
              app: \(application.url.path)
              cli: \(tool.marketingVersion) (\(tool.buildNumber))
            """

        return CommandResult(
            text: text,
            json: .object([
                ("app", application.json),
                (
                    "cli",
                    .object([
                        ("version", .string(tool.marketingVersion)),
                        ("build", .string(tool.buildNumber)),
                    ])
                ),
            ]))
    }
}
