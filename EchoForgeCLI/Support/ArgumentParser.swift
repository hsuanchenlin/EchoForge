import Foundation

/// What one command accepts.
///
/// Declared rather than inferred, because `--limit 20` and `--follow` cannot be
/// told apart by looking at them: a parser that guesses treats `--follow 20` as
/// a flag and a stray positional in one command and as an option in another.
/// Every command states which of its flags take a value, and the parser refuses
/// anything not named here instead of ignoring it - a typo'd `--limt 20` must
/// not silently dump the default page.
struct CommandSpec: Equatable {
    let name: String

    /// One line for `echoforge --help`.
    let summary: String

    /// The usage line, without the leading `echoforge`.
    let usage: String

    /// Flags of the form `--name <value>` or `--name=<value>`.
    let valueOptions: Set<String>

    /// Flags that are present or absent, never `--flag false`.
    let switches: Set<String>

    /// Sub-commands this command dispatches to, in the order `--help` lists
    /// them. Empty for a command that takes none.
    let subcommands: [String]

    /// What a bare argument to this command is, for the one command that takes
    /// one: `transcribe <file>`.
    ///
    /// `nil` - the default - means the command takes none, and the parser
    /// refuses one by name rather than ignoring it. That refusal is the reason
    /// this is opt-in: `echoforge history recent` silently listing everything
    /// would be worse than being told `recent` means nothing here.
    let positional: String?

    /// Lines appended under the usage line by `--help`.
    let help: [String]

    init(
        name: String,
        summary: String,
        usage: String,
        valueOptions: Set<String> = [],
        switches: Set<String> = [],
        subcommands: [String] = [],
        positional: String? = nil,
        help: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.usage = usage
        // `--json` and `--help` are accepted by every command rather than
        // declared by each, so no command can forget one.
        self.valueOptions = valueOptions
        self.switches = switches.union(ArgumentParser.universalSwitches)
        self.subcommands = subcommands
        self.positional = positional
        self.help = help
    }

    var helpText: String {
        var lines = ["USAGE: echoforge \(usage)", "", summary]
        if !subcommands.isEmpty {
            lines += ["", "SUBCOMMANDS: " + subcommands.joined(separator: ", ")]
        }
        if !help.isEmpty {
            lines += [""] + help
        }
        lines += ["", "Every command accepts --json and --help."]
        return lines.joined(separator: "\n")
    }
}

/// One command line, after parsing.
struct ParsedArguments: Equatable {
    var subcommand: String?
    var options: [String: String] = [:]
    var switches: Set<String> = []
    var positionals: [String] = []

    var wantsJSON: Bool { switches.contains("json") }
    var wantsHelp: Bool { switches.contains("help") }

    func option(_ name: String) -> String? { options[name] }

    /// An option that has to be a positive integer, refused with the flag's own
    /// name rather than with "invalid input".
    func integerOption(_ name: String, minimum: Int = 1, maximum: Int) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw), value >= minimum, value <= maximum else {
            throw CLIError(
                "--\(name) takes a whole number between \(minimum) and \(maximum); got \"\(raw)\".",
                exitCode: .usage)
        }
        return value
    }
}

/// Turns `["history", "--limit", "20", "--json"]` into a `ParsedArguments`.
///
/// A hand-written parser rather than a dependency, for one reason that outlives
/// the taste argument: this tool is compiled into the app's own Xcode project,
/// beside a security-sensitive updater, and adding a package to that project to
/// read six flags would put a third-party dependency on the same build graph as
/// the thing that replaces the application.
enum ArgumentParser {

    /// Accepted everywhere, so no command can omit one.
    static let universalSwitches: Set<String> = ["json", "help"]

    static func parse(_ arguments: [String], spec: CommandSpec) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        var sawSeparator = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if argument == "--" {
                sawSeparator = true
                continue
            }

            // `-h` is the one short flag. There are no others on purpose:
            // a second one would need a table of them, and this tool is
            // scripted more often than it is typed.
            if !sawSeparator, argument == "-h" {
                parsed.switches.insert("help")
                continue
            }

            guard !sawSeparator, argument.hasPrefix("--"), argument.count > 2 else {
                if parsed.subcommand == nil, spec.subcommands.contains(argument) {
                    parsed.subcommand = argument
                } else {
                    parsed.positionals.append(argument)
                }
                continue
            }

            let body = String(argument.dropFirst(2))
            let name: String
            var inlineValue: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[body.startIndex..<equals])
                inlineValue = String(body[body.index(after: equals)...])
            } else {
                name = body
            }

            if spec.switches.contains(name) {
                guard inlineValue == nil else {
                    throw CLIError(
                        "--\(name) is a flag and takes no value.", exitCode: .usage)
                }
                parsed.switches.insert(name)
                continue
            }

            guard spec.valueOptions.contains(name) else {
                throw CLIError(
                    "Unknown option --\(name). Run `echoforge \(spec.name) --help`.",
                    exitCode: .usage)
            }

            if let inlineValue {
                parsed.options[name] = inlineValue
                continue
            }
            guard index < arguments.count else {
                throw CLIError("--\(name) needs a value.", exitCode: .usage)
            }
            parsed.options[name] = arguments[index]
            index += 1
        }

        // A sub-command that arrived after a flag is still a sub-command; a
        // word that is not one is a mistake worth naming, because
        // `echoforge update instal` must not quietly become `update`.
        if parsed.subcommand == nil, !spec.subcommands.isEmpty, let first = parsed.positionals.first {
            throw CLIError(
                "Unknown subcommand \"\(first)\". Expected one of: "
                    + spec.subcommands.joined(separator: ", ") + ".",
                exitCode: .usage)
        }
        if !parsed.positionals.isEmpty, spec.subcommands.isEmpty, spec.positional == nil {
            throw CLIError(
                "\(spec.name) takes no arguments, but got \"\(parsed.positionals[0])\".",
                exitCode: .usage)
        }

        return parsed
    }
}
