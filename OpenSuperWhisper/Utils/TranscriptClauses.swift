import Foundation

/// One clause of a transcript, and the exact bytes that surrounded it.
///
/// The three fields are a *partition* of the original text rather than a view
/// of it: `prefix + text + terminator`, concatenated in order over every clause,
/// reproduces the transcript byte for byte. That is what lets an edit delete one
/// clause and leave every other character of the user's dictation untouched -
/// `TranscriptClausesTests` asserts the round trip over the awkward cases
/// (newlines, doubled punctuation, full-width forms) rather than trusting it.
struct TranscriptClause: Equatable, Sendable {
    /// Whitespace between the previous clause's terminator and this clause.
    var prefix: String
    /// The clause itself, with no leading or trailing whitespace and no
    /// punctuation of its own.
    var text: String
    /// The punctuation that ended this clause plus the whitespace after it.
    /// Empty for the last clause when the transcript does not end in one.
    var terminator: String

    /// The bytes this clause occupied in the original transcript.
    var rendered: String { prefix + text + terminator }

    /// Whether the punctuation that ended this clause ends a *sentence*, which
    /// is what `delete the last sentence` walks back to.
    var endsSentence: Bool {
        terminator.contains { TranscriptClauses.sentenceTerminators.contains($0) }
    }
}

/// Splits a transcript into clauses at the punctuation a speaker's pause becomes.
///
/// This exists because a spoken correction is only ever promoted to a command
/// when it occupies a **whole clause** - "send it Friday, scratch that, Monday"
/// edits, and "I want to scratch that itch" does not. That rule is the whole
/// defence against the one failure of the correction feature that costs a user
/// anything, so the boundary it turns on is a type of its own with its own
/// tests rather than a regular expression inside the reducer.
///
/// The separators are the ones `SpokenIntentRouter` already treats as a pause,
/// in both widths, because a Chinese transcript uses the full-width forms
/// throughout. Latin `.`, `!` and `?` additionally have to be followed by
/// whitespace or the end of the transcript to count, so `3.5` and `e.g.` are one
/// clause; the CJK forms need no such rule because nothing writes a number with
/// `。` in it.
enum TranscriptClauses {

    /// The punctuation that ends a clause. A speaker's pause arrives as one of
    /// these, which is what makes them the boundary a correction has to sit
    /// inside.
    static let clauseTerminators: Set<Character> = [
        ",", "，", "、", ";", "；", ":", "：",
        ".", "。", "!", "！", "?", "？",
        "–", "—", "\n",
    ]

    /// The subset that ends a sentence rather than a clause.
    static let sentenceTerminators: Set<Character> = [
        ".", "。", "!", "！", "?", "？", "\n",
    ]

    /// The terminators that are also ordinary characters inside a token, and so
    /// only count when whitespace or the end of the transcript follows.
    private static let requiresTrailingBreak: Set<Character> = [".", "!", "?", ":", ";"]

    /// Splits `transcript` so that the clauses concatenate back to it exactly.
    ///
    /// An empty transcript produces no clauses; a transcript of nothing but
    /// punctuation produces one clause with empty `text`, so the caller can
    /// still rebuild it.
    static func split(_ transcript: String) -> [TranscriptClause] {
        guard !transcript.isEmpty else { return [] }

        let characters = Array(transcript)
        var clauses: [TranscriptClause] = []
        var index = 0

        while index < characters.count {
            // Leading whitespace belongs to this clause's prefix, so deleting a
            // clause takes the space in front of it with it.
            var prefix = ""
            while index < characters.count, characters[index].isWhitespace,
                  characters[index] != "\n" {
                prefix.append(characters[index])
                index += 1
            }

            var body = ""
            while index < characters.count, !isTerminator(at: index, in: characters) {
                body.append(characters[index])
                index += 1
            }

            var terminator = ""
            // Doubled punctuation ("Really?!") is one terminator, not two
            // clauses with an empty one between them.
            while index < characters.count, isTerminator(at: index, in: characters) {
                terminator.append(characters[index])
                index += 1
            }
            while index < characters.count, characters[index].isWhitespace {
                terminator.append(characters[index])
                index += 1
            }

            // Trailing whitespace inside the body - "hello   ," - stays with the
            // terminator so the clause text is exactly the words.
            while let last = body.last, last.isWhitespace {
                body.removeLast()
                terminator = String(last) + terminator
            }

            clauses.append(
                TranscriptClause(prefix: prefix, text: body, terminator: terminator))
        }

        return clauses
    }

    /// Rebuilds a transcript from clauses. The inverse of ``split(_:)``.
    static func join(_ clauses: [TranscriptClause]) -> String {
        clauses.map(\.rendered).joined()
    }

    private static func isTerminator(at index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        guard clauseTerminators.contains(character) else { return false }
        guard requiresTrailingBreak.contains(character) else { return true }
        // The last character of the transcript closes a clause; anything else
        // has to be followed by whitespace or another terminator to be a pause
        // rather than part of a token.
        let next = index + 1
        guard next < characters.count else { return true }
        return characters[next].isWhitespace || clauseTerminators.contains(characters[next])
    }
}
