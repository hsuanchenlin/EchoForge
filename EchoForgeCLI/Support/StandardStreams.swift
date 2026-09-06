import Foundation

/// stdout and stderr, and the rule about which is which.
///
/// **Results go to stdout; everything else goes to stderr.** That is not
/// tidiness, it is the whole contract of `--json`: `echoforge history --json |
/// jq` has to work, and it cannot if a progress line or a warning is mixed into
/// the document. Errors, the `--follow` banner and the download progress all go
/// to stderr for that reason, which also means they still reach a person
/// watching a terminal while the output is being piped somewhere.
enum StandardStreams {

    static func output(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// A progress line that overwrites itself, when there is a terminal to
    /// overwrite. Piped, it prints nothing at all rather than a thousand lines
    /// of carriage returns in a log file.
    static func progress(_ text: String) {
        guard isatty(STDERR_FILENO) == 1 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(text)".utf8))
    }

    static func progressDone() {
        guard isatty(STDERR_FILENO) == 1 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    /// Reads a yes/no answer.
    ///
    /// Returns `nil` when there is no terminal - a pipe, a cron job, a CI step -
    /// rather than reading a line that will never come or defaulting to yes.
    /// Every caller treats `nil` as "no": a script that meant yes says `--yes`.
    static func confirm(_ question: String) -> Bool? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        error(question)
        guard let answer = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        return answer == "y" || answer == "yes"
    }
}
