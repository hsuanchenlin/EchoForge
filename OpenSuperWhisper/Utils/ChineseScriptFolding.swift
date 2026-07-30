import Foundation

/// Folds Traditional and Simplified Chinese onto one comparison key.
///
/// This exists so a dictionary entry written in one script still matches
/// dictation in the other. It is used **only** to decide whether a span
/// matches; the text written out is always the user's own spelling, so nothing
/// here can silently convert a user's script.
///
/// Folding is done one character at a time and only accepted when the
/// transform returns exactly one character back. That keeps the folded string
/// index-aligned with the original, which is what lets the matcher map a hit on
/// the folded text back onto the exact source span.
enum ChineseScriptFolding {

    private static var cache: [Character: Character] = [:]
    private static let cacheLock = NSLock()

    /// The comparison key for `text`: same character count, Traditional forms
    /// folded onto their Simplified counterparts.
    static func fold(_ text: String) -> [Character] {
        text.map(fold(_:))
    }

    static func fold(_ character: Character) -> Character {
        cacheLock.lock()
        if let cached = cache[character] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let folded = transform(character)

        cacheLock.lock()
        cache[character] = folded
        cacheLock.unlock()

        return folded
    }

    /// Folding is a many-to-one mapping, so distinct Traditional characters can
    /// share a key (`髮` and `發` both fold to `发`). That leniency is wanted:
    /// it is exactly the kind of variant a recognizer confuses.
    private static func transform(_ character: Character) -> Character {
        // Only Han characters can differ between the scripts. Skipping everything
        // else keeps Latin, digits and punctuation off the ICU path entirely.
        guard character.unicodeScalars.contains(where: isHan) else { return character }

        let mutable = NSMutableString(string: String(character))
        guard CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false) else {
            return character
        }
        let result = mutable as String
        guard result.count == 1, let single = result.first else { return character }
        return single
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,       // CJK Extension A
             0x4E00...0x9FFF,       // CJK Unified Ideographs
             0xF900...0xFAFF,       // CJK Compatibility Ideographs
             0x20000...0x2FA1F:     // CJK Extensions B-F and compatibility supplement
            return true
        default:
            return false
        }
    }
}
