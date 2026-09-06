import Foundation

/// What this tool takes out of anything it prints from a source it does not
/// control.
///
/// It exists because `echoforge logs` reads two files this project only partly
/// writes - the macOS unified log, which carries whatever any framework chose to
/// say about the process, and the update installer's own log - and because a
/// command whose whole job is "show me what happened" is the easiest possible
/// way to put a secret on a terminal, into a scrollback buffer, and from there
/// into a pasted bug report.
///
/// Three rules, in the order they run.
///
/// **Credentials go first**, because everything after them is cosmetic if one
/// gets through. Kongweh's own key lives in the Keychain and is never printed
/// (`CloudRedaction` holds that inside the app), but the log is not only
/// Kongweh's, and an `Authorization:` header in some framework's message is
/// still a credential on the user's screen.
///
/// **Transcripts second.** The app writes `print("Transcription result: …")`,
/// which is what somebody dictated - the single most private thing this project
/// handles. That output goes to a stdout a shipped app does not have, so it has
/// never yet appeared in a log this reads; it is redacted anyway, because "it
/// does not reach the log today" is a fact about the current build and this is a
/// rule about every future one.
///
/// **Paths last**, and only the user's home directory. `/Users/someone/...`
/// carries their name, and a log excerpt is pasted into issues; `~` says the
/// same thing about where a file is without saying who they are.
struct Redaction {
    /// What the user's home directory is called, so it can be folded to `~`.
    let homeDirectory: String

    /// The marker every redaction leaves. One string, so a reader can grep for
    /// it and know something was taken out rather than wonder.
    static let marker = "<redacted>"

    /// Prefixes after which the rest of a line is content the user spoke or
    /// wrote. Matched case-insensitively and to the end of the line.
    ///
    /// A denylist, and it is only sound because of the length cap below: a
    /// transcript printed under a prefix nobody listed here is still truncated
    /// rather than printed whole. If the app ever gains real logging, the right
    /// fix is for it to mark a field safe rather than for this list to grow.
    static let transcriptPrefixes = [
        "transcription result:",
        "fix with ai:",
        "rewrite:",
        "transcript:",
    ]

    /// The longest a single log message is printed at.
    ///
    /// A bound rather than a redaction: a framework that logs a page of XML, or
    /// an app that one day logs a paragraph somebody dictated, both stop being a
    /// wall of text on the terminal - and the second stops being a paragraph.
    static let maximumMessageLength = 400

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    func redact(_ text: String) -> String {
        var result = text
        result = Redaction.redactingCredentials(in: result)
        result = Redaction.redactingTranscripts(in: result)
        result = foldingHomeDirectory(in: result)
        return Redaction.truncated(result)
    }

    /// Header values and key-shaped tokens.
    ///
    /// Two rules and no cleverness. Everything after a credential-naming label,
    /// to the end of that line, goes - the value is what matters and its shape
    /// is the provider's business. And anything that *looks* like an API key on
    /// its own goes too, because keys appear in URLs and messages where no label
    /// precedes them.
    static func redactingCredentials(in text: String) -> String {
        let labels = [
            "authorization:", "authorization =", "bearer ", "api-key:", "api_key=",
            "apikey:", "x-api-key:", "token:", "token=", "password:", "secret:",
        ]
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            // The earliest label on the line wins, so `Authorization: Bearer x`
            // is cut once at `Authorization:` rather than twice.
            let earliest = labels
                .compactMap { label in
                    lines[index].range(of: label, options: .caseInsensitive)
                        .map { (label: label, range: $0) }
                }
                .min { $0.range.lowerBound < $1.range.lowerBound }
            if let earliest {
                lines[index] = String(lines[index][..<earliest.range.upperBound]) + marker
            }
            // Provider key prefixes, which are stable and public: OpenAI's
            // `sk-`, GitHub's `ghp_`. Twenty characters is well above anything
            // that is a word and well below any real key.
            for prefix in ["sk-", "ghp_", "gho_", "ghs_", "github_pat_"] {
                lines[index] = replacingTokens(startingWith: prefix, in: lines[index])
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func replacingTokens(startingWith prefix: String, in text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let start = remainder.range(of: prefix) {
            let run = remainder[start.lowerBound...].prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
            result += remainder[remainder.startIndex..<start.lowerBound]
            result += run.count >= 20 ? marker : String(run)
            remainder = remainder[remainder.index(start.lowerBound, offsetBy: run.count)...]
        }
        return result + remainder
    }

    static func redactingTranscripts(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                for prefix in transcriptPrefixes {
                    if let range = line.range(of: prefix, options: .caseInsensitive) {
                        return String(line[line.startIndex..<range.upperBound]) + " " + marker
                    }
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    func foldingHomeDirectory(in text: String) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return text }
        return text.replacingOccurrences(of: homeDirectory, with: "~")
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maximumMessageLength else { return text }
        return String(text.prefix(maximumMessageLength)) + "… (truncated)"
    }
}
