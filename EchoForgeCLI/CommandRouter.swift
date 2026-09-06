import Foundation

/// `echoforge` itself: the command list, `--help`, and the one place a failure
/// becomes an exit code.
///
/// `execute` returns the rendered output rather than printing it, and takes its
/// environment rather than building one, so the whole surface - every command,
/// every failure, every exit code, and the exact bytes of both renderings - is
/// reachable from a test with nothing running and nothing installed. Only
/// `main.swift` prints.
enum CommandRouter {

    /// One command, as a value.
    ///
    /// A descriptor rather than `[any CLICommand.Type]`: an array of existential
    /// metatypes reads well and crashed the 6.3 compiler outright when the help
    /// text mapped over it. A closure is the same dispatch with none of that.
    struct Descriptor {
        let spec: CommandSpec
        let run: (ParsedArguments, CLIEnvironment) async throws -> CommandResult

        init<Command: CLICommand>(_ command: Command.Type) {
            self.spec = Command.spec
            self.run = { arguments, environment in
                try await Command.run(arguments, in: environment)
            }
        }
    }

    /// Every command, in the order `--help` lists them: what you look at first,
    /// then what you read, then what changes something.
    static let commands: [Descriptor] = [
        Descriptor(VersionCommand.self),
        Descriptor(StatusCommand.self),
        Descriptor(StartCommand.self),
        Descriptor(HistoryCommand.self),
        Descriptor(LogsCommand.self),
        Descriptor(SettingsCommand.self),
        Descriptor(UpdateCommand.self),
    ]

    static func command(named name: String) -> Descriptor? {
        commands.first { $0.spec.name == name }
    }

    /// What one invocation produces.
    struct Execution {
        /// Written to stdout. Empty for a command that streamed its own output.
        let output: String

        /// Written to stderr.
        let diagnostic: String

        let exitCode: ExitCode
    }

    static func execute(arguments: [String], environment: CLIEnvironment) async -> Execution {
        let wantsJSON = arguments.contains("--json")
        guard let first = arguments.first else {
            return Execution(output: overviewHelp + "\n", diagnostic: "", exitCode: .success)
        }

        // `--help` and `--version` before a command name, because that is what
        // people type. `--version` reports the *tool*, which is the only thing
        // it can mean without an app to look at.
        if first == "--help" || first == "-h" || first == "help" {
            return Execution(output: overviewHelp + "\n", diagnostic: "", exitCode: .success)
        }
        if first == "--version" {
            let identity = environment.toolIdentity
            return Execution(
                output: "echoforge \(identity.marketingVersion) (\(identity.buildNumber))\n",
                diagnostic: "", exitCode: .success)
        }

        guard let command = command(named: first) else {
            let error = CLIError("Unknown command \"\(first)\".", exitCode: .usage)
            return wantsJSON
                ? failed(error, asJSON: true)
                : Execution(
                    output: "", diagnostic: error.message + "\n\n" + overviewHelp,
                    exitCode: .usage)
        }

        let spec = command.spec
        let parsed: ParsedArguments
        do {
            parsed = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        } catch {
            return failed(CLIError.wrapping(error, exitCode: .usage), asJSON: wantsJSON)
        }

        if parsed.wantsHelp {
            return Execution(output: spec.helpText + "\n", diagnostic: "", exitCode: .success)
        }

        do {
            let result = try await command.run(parsed, environment)
            return Execution(
                output: result.rendered(asJSON: parsed.wantsJSON),
                diagnostic: "",
                exitCode: result.exitCode)
        } catch {
            return failed(CLIError.wrapping(error), asJSON: parsed.wantsJSON)
        }
    }

    /// A failure, rendered the way the invocation asked for.
    ///
    /// The message always goes to **stderr**, in both modes, so `--json | jq`
    /// never chokes on an error document mixed into the output stream - and a
    /// script that wants the machine-readable failure reads stderr, which is
    /// where the only thing there is to read has gone.
    static func failed(_ error: CLIError, asJSON: Bool) -> Execution {
        Execution(
            output: "",
            diagnostic: asJSON ? error.json.serialized : "echoforge: \(error.message)\n",
            exitCode: error.exitCode)
    }

    static var overviewHelp: String {
        var lines = [
            "USAGE: echoforge <command> [options]",
            "",
            "A local, read-only-by-default control surface for Kongweh (EchoForge).",
            "",
            "COMMANDS:",
        ]
        let width = commands.map { $0.spec.name.count }.max() ?? 0
        for command in commands {
            let name = command.spec.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(command.spec.summary)")
        }
        lines += [
            "",
            "Every command accepts --json and --help.",
            "Only `update install` changes anything; everything else reads.",
            "Nothing here reaches the network except the update check and install.",
        ]
        return lines.joined(separator: "\n")
    }
}

extension CLIEnvironment {
    /// The real thing, wired to this Mac.
    ///
    /// The only place production implementations are chosen, so a test can see
    /// at a glance what it is standing in for.
    static func system() -> CLIEnvironment {
        let fileSystem = SystemFileSystem()
        return CLIEnvironment(
            fileSystem: fileSystem,
            runningApplications: SystemRunningApplications(),
            launcher: SystemApplicationLauncher(),
            history: ReadOnlyHistoryReader(fileSystem: fileSystem),
            preferences: AppDefaults(),
            log: SystemLogReader(fileSystem: fileSystem),
            updates: SharedUpdateService(),
            now: Date.init,
            defaultApplicationLocations: ApplicationLocator.defaultLocations(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
            confirm: StandardStreams.confirm,
            toolIdentity: AppBuildIdentity.current())
    }
}
