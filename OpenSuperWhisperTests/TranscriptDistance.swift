import Foundation

/// How far a transcript is from a reference, for the parity tests that hold a
/// live-decoded transcript to the whole-file decode or to the script it was
/// synthesised from.
///
/// Letters and digits only, lower-cased, so spacing, case and punctuation -
/// which are the engines' own and differ legitimately between a piece and a
/// whole - do not count; what counts is a character lost, invented or changed.
enum TranscriptDistance {

    static func normalized(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Levenshtein distance between the two normalised texts over the length
    /// of the reference: the character error rate.
    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let a = normalized(reference)
        let b = normalized(hypothesis)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}
