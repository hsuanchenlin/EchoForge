import Foundation

/// One ICU Han transform - `Hant-Hans` or `Hans-Hant` - applied a character at a
/// time and cached.
///
/// **ICU is the mapping.** A hand-written table of character pairs would be a
/// second, worse copy of something the platform already ships, already keeps
/// current, and already gets right for the tens of thousands of characters
/// nobody would put in a literal. The one table this app does keep -
/// `ChineseScriptVariant.traditionalCharacters` - is evidence for telling the
/// two apart, not a conversion, and its own tests check it against this
/// transform.
///
/// Character at a time rather than whole-string, and the result is accepted only
/// when the transform hands back exactly one character, because both callers
/// need the output to line up with the input character for character:
///
/// - `ChineseScriptFolding` maps a match on the folded text back onto the exact
///   source span, which it can only do while the two are the same length;
/// - `ChineseScriptNormalizer` has to leave every space, digit, timestamp and
///   Latin word exactly where it found it, and a transform free to insert or
///   drop characters could not promise that.
///
/// So a character whose transform returns anything other than a single character
/// is kept as it was. The conversion is deterministic, offline, and involves no
/// model, no network and no user data leaving the process.
final class HanCharacterTransform: @unchecked Sendable {

    /// Traditional -> Simplified.
    static let toSimplified = HanCharacterTransform(identifier: "Hant-Hans")
    /// Simplified -> Traditional.
    static let toTraditional = HanCharacterTransform(identifier: "Hans-Hant")

    static func transform(to variant: ChineseScriptVariant) -> HanCharacterTransform {
        switch variant {
        case .traditional: return toTraditional
        case .simplified: return toSimplified
        }
    }

    private let identifier: CFString
    private var cache: [Character: Character] = [:]
    private let cacheLock = NSLock()

    private init(identifier: String) {
        self.identifier = identifier as CFString
    }

    /// `text` with every Han character transformed, everything else untouched
    /// and the character count unchanged.
    func applied(to text: String) -> String {
        String(characters(of: text))
    }

    /// The same conversion as ``applied(to:)``, kept as characters for the
    /// caller that needs the index alignment rather than the string.
    func characters(of text: String) -> [Character] {
        text.map(applied(to:))
    }

    func applied(to character: Character) -> Character {
        cacheLock.lock()
        if let cached = cache[character] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let transformed = uncached(character)

        cacheLock.lock()
        cache[character] = transformed
        cacheLock.unlock()

        return transformed
    }

    private func uncached(_ character: Character) -> Character {
        // Only Han characters can differ between the scripts. Skipping
        // everything else keeps Latin, digits, punctuation and whitespace off
        // the ICU path entirely, which is also what makes "preserves everything
        // that is not Chinese" a property of the code rather than a hope.
        guard character.unicodeScalars.contains(where: HanCharacterTransform.isHan) else {
            return character
        }

        let mutable = NSMutableString(string: String(character))
        guard CFStringTransform(mutable, nil, identifier, false) else { return character }
        let result = mutable as String
        guard result.count == 1, let single = result.first else { return character }
        return single
    }

    /// The Han blocks. Deliberately not kana or Hangul: those are how a caller
    /// tells Japanese and Korean apart from Chinese, and converting them would
    /// be the bug this whole file exists to avoid.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400 ... 0x4DBF,     // CJK Extension A
             0x4E00 ... 0x9FFF,     // CJK Unified Ideographs
             0xF900 ... 0xFAFF,     // CJK Compatibility Ideographs
             0x20000 ... 0x2FA1F:   // CJK Extensions B-F and compatibility supplement
            return true
        default:
            return false
        }
    }
}
