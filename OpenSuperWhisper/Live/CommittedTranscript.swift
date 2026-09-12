import Foundation

/// The utterances a dictation has decoded so far, and the one raw transcript
/// they make.
///
/// Two callers build one: `SenseVoiceEngine`, whose chunker hands the model
/// one piece of a recording at a time, and live dictation, which decodes each
/// utterance `LiveCutPolicy` cuts while the microphone is still open. Both
/// face the same question - the seam between two pieces is a pause in the
/// speech, not a word boundary the model saw, so what would the writing system
/// have put there? - and so both get one answer, here. The result is a *raw*
/// transcript: it goes through `TranscriptionService.finish` like any engine's
/// output, and nothing here trims, corrects or punctuates beyond the two rules
/// below.
///
/// 1. **The join reconstructs the writing system's own spacing.** Chinese and
///    Japanese do not separate words, and an engine that punctuates usually
///    ends a piece in `。` already, so a space there is visible damage. English
///    and Korean do separate words, and gluing `gold.` to `The` is equally
///    visible. Hence a script test at the seam rather than one fixed separator:
///    with `auto` an engine is not told which language it is hearing.
/// 2. **A piece that decoded to nothing but punctuation is dropped.** An engine
///    handed near-silence answers `.`, `。` or `...` rather than nothing, and
///    every such piece kept is a stray mark in the user's document. A piece
///    with a letter or a digit in it is kept byte for byte, whatever else it
///    holds, because deciding what the user said is the engine's job.
struct CommittedTranscript: Equatable {

    /// The pieces kept, in the order they were appended, each trimmed of the
    /// surrounding whitespace the engines already strip from their output.
    private(set) var utterances: [String] = []

    init() {}

    init(utterances: [String]) {
        for utterance in utterances {
            append(utterance)
        }
    }

    var isEmpty: Bool { utterances.isEmpty }

    /// The transcript so far. A single kept utterance comes back exactly as it
    /// was appended, so a dictation the policy never cut reads the same as the
    /// whole-file decode would.
    var text: String { Self.joined(utterances) }

    /// Appends one decoded piece. Returns whether it was kept: `false` for one
    /// that was empty or nothing but punctuation and whitespace, which leaves
    /// the transcript unchanged.
    @discardableResult
    mutating func append(_ raw: String) -> Bool {
        guard let kept = Self.kept(raw) else { return false }
        utterances.append(kept)
        return true
    }

    /// `raw` trimmed, or `nil` when nothing in it is a letter or a digit.
    static func kept(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return trimmed
    }

    /// Joins pieces into one transcript by the script test above.
    static func joined(_ pieces: [String]) -> String {
        pieces.reduce(into: "") { result, piece in
            guard let previous = result.last, let next = piece.first else {
                result += piece
                return
            }
            if !isScriptWithoutWordSpaces(previous) && !isScriptWithoutWordSpaces(next) {
                result += " "
            }
            result += piece
        }
    }

    /// Han, kana and the CJK punctuation and fullwidth forms that surround them.
    /// Hangul is deliberately absent: Korean is written with spaces between
    /// words, so a Korean seam needs one.
    private static let scriptsWithoutWordSpaces: [ClosedRange<UInt32>] = [
        0x3000...0x303F,  // CJK symbols and punctuation, incl. 。、
        0x3040...0x30FF,  // hiragana and katakana
        0x3400...0x4DBF,  // CJK unified ideographs extension A
        0x4E00...0x9FFF,  // CJK unified ideographs
        0xF900...0xFAFF,  // CJK compatibility ideographs
        0xFF00...0xFFEF,  // halfwidth and fullwidth forms, incl. ，！？
    ]

    private static func isScriptWithoutWordSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scriptsWithoutWordSpaces.contains { $0.contains(scalar.value) }
        }
    }
}
