import Foundation

/// Folds Traditional and Simplified Chinese onto one comparison key.
///
/// This exists so a dictionary entry written in one script still matches
/// dictation in the other. It is used **only** to decide whether a span
/// matches; the text written out is always the user's own spelling, so nothing
/// here can silently convert a user's script. Converting the *recognizer's*
/// output is a different job with a different type - `ChineseScriptNormalizer`.
///
/// Folding is done one character at a time and only accepted when the
/// transform returns exactly one character back. That keeps the folded string
/// index-aligned with the original, which is what lets the matcher map a hit on
/// the folded text back onto the exact source span. `HanCharacterTransform` is
/// where both rules live.
enum ChineseScriptFolding {

    /// The comparison key for `text`: same character count, Traditional forms
    /// folded onto their Simplified counterparts.
    static func fold(_ text: String) -> [Character] {
        HanCharacterTransform.toSimplified.characters(of: text)
    }

    /// Folding is a many-to-one mapping, so distinct Traditional characters can
    /// share a key (`髮` and `發` both fold to `发`). That leniency is wanted:
    /// it is exactly the kind of variant a recognizer confuses.
    static func fold(_ character: Character) -> Character {
        HanCharacterTransform.toSimplified.applied(to: character)
    }
}
