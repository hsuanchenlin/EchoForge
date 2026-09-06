import XCTest

/// The parser is the one part of this tool a user interacts with before anything
/// has been read, so the failures that matter are the ones where a mistyped flag
/// does something instead of saying so: `--limt 20` returning the default page,
/// `--json` swallowing a value, a sub-command typo silently becoming the bare
/// command.
final class ArgumentParserTests: XCTestCase {

    private let spec = CommandSpec(
        name: "example",
        summary: "An example.",
        usage: "example [--limit <n>] [--follow]",
        valueOptions: ["limit", "query"],
        switches: ["follow"],
        subcommands: ["check", "install"])

    func testSeparatedOptionTakesTheNextArgument() throws {
        let parsed = try ArgumentParser.parse(["--limit", "20"], spec: spec)
        XCTAssertEqual(parsed.option("limit"), "20")
        XCTAssertTrue(parsed.positionals.isEmpty)
    }

    func testInlineOptionTakesWhatFollowsTheEquals() throws {
        let parsed = try ArgumentParser.parse(["--limit=20"], spec: spec)
        XCTAssertEqual(parsed.option("limit"), "20")
    }

    /// A phrase with an `=` or a leading dash in it is a query, not syntax.
    func testAnOptionValueMayContainAnythingAfterTheFirstEquals() throws {
        let parsed = try ArgumentParser.parse(["--query=a=b"], spec: spec)
        XCTAssertEqual(parsed.option("query"), "a=b")
    }

    func testSwitchesAreCollectedAndUniversalOnesAreAlwaysAccepted() throws {
        let parsed = try ArgumentParser.parse(["--follow", "--json"], spec: spec)
        XCTAssertTrue(parsed.switches.contains("follow"))
        XCTAssertTrue(parsed.wantsJSON)
        XCTAssertFalse(parsed.wantsHelp)
    }

    func testShortHelpFlagIsAccepted() throws {
        XCTAssertTrue(try ArgumentParser.parse(["-h"], spec: spec).wantsHelp)
    }

    /// The failure this parser exists to prevent: a typo must not be ignored.
    func testAnUnknownOptionIsAUsageError() {
        assertUsageError(["--limt", "20"], containing: "--limt")
    }

    func testAnOptionWithNoValueIsAUsageError() {
        assertUsageError(["--limit"], containing: "needs a value")
    }

    func testASwitchGivenAValueIsAUsageError() {
        assertUsageError(["--follow=yes"], containing: "takes no value")
    }

    func testAMistypedSubcommandIsNamedRatherThanIgnored() {
        assertUsageError(["instal"], containing: "Unknown subcommand")
    }

    func testASubcommandIsRecognisedAfterAFlag() throws {
        let parsed = try ArgumentParser.parse(["--json", "install"], spec: spec)
        XCTAssertEqual(parsed.subcommand, "install")
        XCTAssertTrue(parsed.wantsJSON)
    }

    /// A command that takes no arguments says so rather than ignoring one.
    func testAStrayArgumentIsAUsageError() {
        let bare = CommandSpec(name: "settings", summary: "s", usage: "settings")
        XCTAssertThrowsError(try ArgumentParser.parse(["extra"], spec: bare)) { error in
            XCTAssertEqual((error as? CLIError)?.exitCode, .usage)
        }
    }

    /// `--` ends flag parsing, so a value that looks like a flag can still be
    /// passed.
    func testDoubleDashEndsOptionParsing() throws {
        let bare = CommandSpec(name: "example", summary: "s", usage: "e", subcommands: ["check"])
        let parsed = try ArgumentParser.parse(["check", "--", "--json"], spec: bare)
        XCTAssertEqual(parsed.subcommand, "check")
        XCTAssertEqual(parsed.positionals, ["--json"])
        XCTAssertFalse(parsed.wantsJSON)
    }

    // MARK: - Bounded integers

    func testIntegerOptionRejectsOutOfRangeAndNonNumbers() throws {
        let parsed = try ArgumentParser.parse(["--limit", "0"], spec: spec)
        XCTAssertThrowsError(try parsed.integerOption("limit", maximum: 100))

        let tooBig = try ArgumentParser.parse(["--limit", "101"], spec: spec)
        XCTAssertThrowsError(try tooBig.integerOption("limit", maximum: 100))

        let word = try ArgumentParser.parse(["--limit", "many"], spec: spec)
        XCTAssertThrowsError(try word.integerOption("limit", maximum: 100)) { error in
            XCTAssertTrue((error as? CLIError)?.message.contains("--limit") == true)
        }

        let absent = try ArgumentParser.parse([], spec: spec)
        XCTAssertNil(try absent.integerOption("limit", maximum: 100))
    }

    // MARK: - Help

    /// Every command's help states the two universal flags, so no command has to
    /// remember to.
    func testEveryCommandsHelpNamesTheUniversalFlags() {
        for command in CommandRouter.commands {
            XCTAssertTrue(
                command.spec.helpText.contains("--json"),
                "\(command.spec.name) --help does not mention --json")
            XCTAssertTrue(
                command.spec.helpText.contains("USAGE: echoforge \(command.spec.name)"),
                "\(command.spec.name) --help does not lead with its own usage line")
        }
    }

    private func assertUsageError(
        _ arguments: [String], containing fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try ArgumentParser.parse(arguments, spec: spec), file: file, line: line) {
            error in
            guard let error = error as? CLIError else {
                return XCTFail("not a CLIError: \(error)", file: file, line: line)
            }
            XCTAssertEqual(error.exitCode, .usage, file: file, line: line)
            XCTAssertTrue(
                error.message.contains(fragment),
                "\"\(error.message)\" does not mention \(fragment)", file: file, line: line)
        }
    }
}
