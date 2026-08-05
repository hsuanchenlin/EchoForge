import Foundation

/// One run of a comparison between two transcripts.
///
/// A segment is the unit a view renders: `removed` text is struck through and
/// muted, everything else reads normally, so the result is the polished text
/// with the words it dropped still legible in place.
struct TextDiffSegment: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// Present in both texts. Carries the *revised* spelling - see
        /// ``TextDiffUtil``.
        case unchanged
        /// In the original only: the words the rewrite dropped or replaced.
        case removed
        /// In the revised text only.
        case inserted
    }

    let text: String
    let kind: Kind

    init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Compares a transcript with what a later stage made of it.
///
/// It exists for one job: showing a user what style rewriting actually changed,
/// in the Settings preview and in a history row. So it is deliberately a
/// *display* helper and not a general diff library - two properties matter, and
/// both are pinned by `TextDiffUtilTests`:
///
/// 1. **The revised text is reproduced exactly.** Concatenating every segment
///    that is not `removed` gives `revised` character for character. A diff view
///    that quietly reworded the result would be worse than no diff view.
/// 2. **Only real changes are shown.** Tokens match case-insensitively and
///    ignoring whitespace, because a style that capitalises a sentence or
///    collapses a double space has not changed the user's words, and marking it
///    up would bury the changes that did happen. Matched tokens are emitted with
///    the revised spelling, since that is the text the user is looking at.
///
/// Tokens are words, standalone punctuation, whitespace runs, and single CJK
/// characters - CJK is written without spaces, so splitting on whitespace would
/// make any Chinese comparison one enormous replacement.
enum TextDiffUtil {

    /// The largest token counts compared token by token - roughly a thousand
    /// words, since the spaces between them are tokens too.
    ///
    /// The comparison is quadratic in time and memory, and history holds
    /// transcripts of whole meetings. Past this - after the common prefix and
    /// suffix have been trimmed, which is what usually shrinks a real pair -
    /// the middle is reported as one replacement rather than making the user
    /// wait for a table with millions of cells in it.
    static let maximumComparedTokens = 2000

    /// The comparison, as runs of text ready to render.
    static func compare(original: String, revised: String) -> [TextDiffSegment] {
        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)

        if originalTokens.isEmpty && revisedTokens.isEmpty { return [] }
        if originalTokens.isEmpty { return [TextDiffSegment(revised, .inserted)] }
        if revisedTokens.isEmpty { return [TextDiffSegment(original, .removed)] }

        var builder = SegmentBuilder()

        // The common prefix and suffix, which for a rewrite of a long dictation
        // is nearly all of it. Emitted with the revised spelling.
        var start = 0
        while start < originalTokens.count, start < revisedTokens.count,
              originalTokens[start].key == revisedTokens[start].key {
            builder.append(revisedTokens[start].text, .unchanged)
            start += 1
        }

        var originalEnd = originalTokens.count
        var revisedEnd = revisedTokens.count
        while originalEnd > start, revisedEnd > start,
              originalTokens[originalEnd - 1].key == revisedTokens[revisedEnd - 1].key {
            originalEnd -= 1
            revisedEnd -= 1
        }

        let originalMiddle = Array(originalTokens[start ..< originalEnd])
        let revisedMiddle = Array(revisedTokens[start ..< revisedEnd])

        appendMiddle(originalMiddle, revisedMiddle, to: &builder)

        for token in revisedTokens[revisedEnd...] {
            builder.append(token.text, .unchanged)
        }

        return builder.segments
    }

    /// True when the two texts differ in more than case and whitespace, and a
    /// comparison would therefore show something.
    static func hasVisibleChanges(original: String, revised: String) -> Bool {
        compare(original: original, revised: revised).contains { $0.kind != .unchanged }
    }

    // MARK: - Middle

    private static func appendMiddle(
        _ original: [Token], _ revised: [Token], to builder: inout SegmentBuilder
    ) {
        if original.isEmpty && revised.isEmpty { return }
        if original.isEmpty {
            for token in revised { builder.append(token.text, .inserted) }
            return
        }
        if revised.isEmpty {
            for token in original { builder.append(token.text, .removed) }
            return
        }

        guard original.count <= maximumComparedTokens,
              revised.count <= maximumComparedTokens else {
            for token in original { builder.append(token.text, .removed) }
            for token in revised { builder.append(token.text, .inserted) }
            return
        }

        let rows = original.count
        let columns = revised.count
        let width = columns + 1

        // lengths[i * width + j] is the longest common subsequence of
        // original[i...] and revised[j...]; filling it backwards lets the walk
        // below run forwards, which is the order segments are emitted in.
        var lengths = [Int32](repeating: 0, count: (rows + 1) * width)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                lengths[i * width + j] = original[i].key == revised[j].key
                    ? lengths[(i + 1) * width + (j + 1)] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + (j + 1)])
            }
        }

        var i = 0
        var j = 0
        while i < rows, j < columns {
            if original[i].key == revised[j].key {
                builder.append(revised[j].text, .unchanged)
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + (j + 1)] {
                // Ties go to the removal, so a replaced word reads as the old
                // word struck through followed by the new one.
                builder.append(original[i].text, .removed)
                i += 1
            } else {
                builder.append(revised[j].text, .inserted)
                j += 1
            }
        }
        while i < rows {
            builder.append(original[i].text, .removed)
            i += 1
        }
        while j < columns {
            builder.append(revised[j].text, .inserted)
            j += 1
        }
    }

    // MARK: - Tokens

    /// One word, one punctuation mark, one CJK character - or one run of
    /// whitespace.
    ///
    /// `key` is what the comparison matches on and `text` is what a view shows,
    /// which is why they differ: a word matches regardless of case, and any run
    /// of whitespace matches any other, so recapitalising or respacing never
    /// registers as a change to the user's words.
    private struct Token {
        let text: String
        let key: String
    }

    /// The key every whitespace run compares as.
    private static let whitespaceKey = " "

    /// Whitespace being a token in its own right is what keeps a removal
    /// readable: the space that separated a dropped filler word from the next
    /// one is dropped with it, so the struck-through run sits in the sentence
    /// with its spacing intact instead of colliding with the word after it. In
    /// CJK, where there is no such space, nothing is invented.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let start = index
            let character = characters[index]

            if character.isWhitespace {
                while index < characters.count, characters[index].isWhitespace {
                    index += 1
                }
                tokens.append(
                    Token(text: String(characters[start ..< index]), key: whitespaceKey)
                )
                continue
            }

            if isStandalone(character) {
                index += 1
            } else {
                index += 1
                while index < characters.count,
                      continuesWord(characters, at: index, from: start) {
                    index += 1
                }
            }

            let word = String(characters[start ..< index])
            tokens.append(Token(text: word, key: word.lowercased()))
        }

        return tokens
    }

    /// Characters that are a token by themselves: CJK, which is written without
    /// spaces, and punctuation, which a style adds and removes independently of
    /// the words around it.
    private static func isStandalone(_ character: Character) -> Bool {
        if isCJK(character) { return true }
        return !(character.isLetter || character.isNumber)
    }

    /// Whether the word that began at `start` continues into `index`.
    ///
    /// Letters and digits always continue it. A connector - an apostrophe
    /// between letters, a separator between digits - continues it too, so
    /// "don't" and "$2,500" are compared as the single things they are instead
    /// of coming apart into a spray of one-character changes.
    private static func continuesWord(
        _ characters: [Character], at index: Int, from start: Int
    ) -> Bool {
        let character = characters[index]
        if isCJK(character) { return false }
        if character.isLetter || character.isNumber { return true }

        guard index > start, index + 1 < characters.count else { return false }
        let previous = characters[index - 1]
        let next = characters[index + 1]

        switch character {
        case "'", "\u{2019}", "-":
            return previous.isLetter && next.isLetter
        case ".", ",", ":", "/":
            return previous.isNumber && next.isNumber
        default:
            return false
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040 ... 0x30FF,     // Hiragana, Katakana
             0x3400 ... 0x4DBF,     // CJK Extension A
             0x4E00 ... 0x9FFF,     // CJK Unified Ideographs
             0xAC00 ... 0xD7AF,     // Hangul syllables
             0xF900 ... 0xFAFF,     // CJK Compatibility Ideographs
             0x20000 ... 0x2FA1F:   // CJK Extensions B-F and compatibility supplement
            return true
        default:
            return false
        }
    }

    // MARK: - Assembly

    /// Collects tokens into as few segments as possible, since a view renders
    /// one styled run per segment.
    private struct SegmentBuilder {
        private(set) var segments: [TextDiffSegment] = []

        mutating func append(_ text: String, _ kind: TextDiffSegment.Kind) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = TextDiffSegment(last.text + text, kind)
            } else {
                segments.append(TextDiffSegment(text, kind))
            }
        }
    }
}
