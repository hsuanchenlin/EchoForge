import Foundation

/// Why a rewrite was thrown away and the transcript used as it was.
///
/// Each case is a failure that was actually observed while testing an on-device
/// model against dictated speech, not a hypothetical. They are kept apart
/// because the user can act on some of them - a custom prompt that keeps being
/// rejected for `numbersChanged` is a prompt asking the model to do arithmetic -
/// and the Settings preview names the one that fired.
enum StyleRewriteRejection: Equatable, Sendable {
    /// The model returned nothing usable.
    case empty
    /// The rewrite is in a different script from the transcript. The observed
    /// case is Chinese dictation coming back as English.
    case scriptChanged
    /// The rewrite switched between Traditional and Simplified Chinese. Its own
    /// case rather than `scriptChanged` because the cause is different - the
    /// model converted the characters rather than translating the text - and
    /// because it is the one a user of the app's own Chinese engines is most
    /// likely to see.
    case chineseVariantChanged
    /// A quantity, date or amount appeared, vanished or changed value.
    case numbersChanged
    /// A currency or percent sign was dropped or invented, which changes what a
    /// number means without changing the number.
    case symbolsLost
    /// The personal terms dictionary corrected something and the rewrite lost
    /// it. Carries the token so the reason can name it.
    case termLost(String)
    /// Far shorter than this style is allowed to be - the observed case is a
    /// model answering the transcript instead of rewriting it.
    case tooShort
    /// Far longer than this style is allowed to be - the observed case is a
    /// model explaining what it did, or inventing detail.
    case tooLong
    /// The model addressed the user - a refusal, an apology, or a "Here is the
    /// rewritten text:" preamble - rather than only rewriting.
    case modelAddressedTheUser

    /// One sentence, for the Settings preview and the console.
    var explanation: String {
        switch self {
        case .empty:
            return "The rewrite came back empty."
        case .scriptChanged:
            return "The rewrite was in a different language from the transcript."
        case .chineseVariantChanged:
            return "The rewrite switched between Traditional and Simplified Chinese."
        case .numbersChanged:
            return "The rewrite changed, dropped or invented a number."
        case .symbolsLost:
            return "The rewrite dropped or invented a currency or percent sign."
        case .termLost(let token):
            return "The rewrite lost a dictionary term: \(token)"
        case .tooShort:
            return "The rewrite was far shorter than this style allows."
        case .tooLong:
            return "The rewrite was far longer than this style allows."
        case .modelAddressedTheUser:
            return "The model replied to the text instead of rewriting it."
        }
    }
}

/// The verdict on one candidate rewrite.
enum StyleRewriteVerdict: Equatable, Sendable {
    case accepted(String)
    case rejected(StyleRewriteRejection)

    var acceptedText: String? {
        if case .accepted(let text) = self { return text }
        return nil
    }

    var rejection: StyleRewriteRejection? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// The mechanical check every rewrite has to pass before it is allowed to
/// replace the user's words.
///
/// This is the load-bearing half of the feature. A language model asked to
/// restyle dictated speech will, given real input, occasionally translate it,
/// change a time, drop a currency unit, obey an instruction someone spoke into
/// the microphone, or answer the text instead of rewriting it. None of those
/// are visible to a user who is watching text land in another app, so the app
/// does not rely on the model behaving: it compares the rewrite against the
/// transcript it came from and discards anything that fails.
///
/// Everything here is deterministic, pure and synchronous - no model, no
/// network, no `Settings`. That is deliberate: the rules are the product
/// decision, and they are testable exactly as written.
///
/// The asymmetry running through it is that **a style may omit, but nothing may
/// invent**. "Concise Summary" is allowed to leave a number out, because that is what
/// summarising is; no style is allowed to produce a number that was not said.
enum StyleRewriteGuard {

    /// Symbols that change what a number means without being part of it.
    private static let meaningfulSymbols: Set<Character> = [
        "$", "€", "£", "¥", "₩", "₪", "₹", "%", "％", "＄", "￥",
    ]

    /// Openers that mean the model was talking to the user rather than
    /// rewriting. Matched case-insensitively, and only counted when the phrase
    /// is absent from the transcript - otherwise a dictation that genuinely
    /// begins "I'm sorry I missed the call" would reject its own rewrite.
    private static let addressingMarkers: [String] = [
        "i'm sorry", "i am sorry", "i cannot", "i can't", "i won't", "i'm unable",
        "as an ai", "as a language model", "sure, here", "sure! here",
        "here is the rewritten", "here's the rewritten", "here is the revised",
        "rewritten text:", "rewritten version:", "revised text:",
        "抱歉", "很抱歉", "我無法", "我无法", "作为一个", "作為一個", "以下是改寫", "以下是改写",
    ]

    /// Decides whether `candidate` may replace `transcript`.
    ///
    /// - Parameters:
    ///   - candidate: what the model returned, unmodified.
    ///   - transcript: the deterministic pipeline's output - the text that will
    ///     be used if this fails. Not the engine's raw output: the terms
    ///     dictionary has already run, and its corrections are what
    ///     `mustSurvive` is about.
    ///   - mustSurvive: `ProcessedText.mustSurviveTokens` - what the dictionary
    ///     wrote into the transcript. The user typed these entries to say how
    ///     their own vocabulary is spelled, so a rewrite that loses one is wrong
    ///     whatever style it was asked for.
    ///   - shape: how much this style is allowed to change.
    static func check(
        candidate: String,
        transcript: String,
        mustSurvive: [String],
        shape: StyleRewriteShape
    ) -> StyleRewriteVerdict {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }

        if addressesTheUser(candidate: trimmed, transcript: transcript) {
            return .rejected(.modelAddressedTheUser)
        }

        // Both language checks are asking the same question - "is this still the
        // user's own text?" - and a translation's answer is deliberately no. It
        // is the one shape that may say so; `StyleRewriteShape` is where that is
        // decided, and `TranslationRewrite` documents what stands in their place
        // (the target language is named in the instruction, in that language).
        if !shape.mayChangeLanguage {
            guard scriptMatches(trimmed, transcript) else { return .rejected(.scriptChanged) }
            guard chineseVariantSurvives(trimmed, transcript) else {
                return .rejected(.chineseVariantChanged)
            }
        }

        if let lengthRejection = lengthRejection(for: trimmed, transcript: transcript, shape: shape) {
            return .rejected(lengthRejection)
        }

        // List markers are stripped before counting digits so that "1." at the
        // start of a line in a bulleted rewrite is not read as an invented
        // number. Only a restructuring style is allowed to have added them.
        let comparable = shape.mayAddListMarkers ? strippingListMarkers(trimmed) : trimmed

        guard numbersSurvive(in: comparable, transcript: transcript, shape: shape) else {
            return .rejected(.numbersChanged)
        }
        guard symbolsSurvive(in: comparable, transcript: transcript, shape: shape) else {
            return .rejected(.symbolsLost)
        }
        if let lost = mustSurvive.first(where: { !trimmed.contains($0) }) {
            return .rejected(.termLost(lost))
        }

        return .accepted(trimmed)
    }

    // MARK: - Language

    /// Whether the rewrite is written in the same script family as the input.
    ///
    /// A cheap ratio rather than language identification, and that is the right
    /// tool: the failure being caught is a whole transcript coming back
    /// translated, which moves the ratio from one end of the range to the other.
    /// A rewrite that keeps the language but borrows an English product name
    /// does not.
    private static func scriptMatches(_ candidate: String, _ transcript: String) -> Bool {
        guard let transcriptRatio = cjkRatio(of: transcript),
              let candidateRatio = cjkRatio(of: candidate) else {
            // One side has no letters at all to compare - digits, punctuation or
            // emoji. There is nothing to be wrong about.
            return true
        }
        return (transcriptRatio >= 0.3) == (candidateRatio >= 0.3)
    }

    /// Whether the rewrite is written in the same Chinese variant as the input.
    ///
    /// The same asymmetry as everywhere else in this file: **a rewrite may omit,
    /// but nothing may invent.** A Traditional transcript whose rewrite drops a
    /// Traditional-only character is fine - it may have been reworded. A
    /// Traditional transcript whose rewrite contains a Simplified-only character
    /// invented one, and the whole rewrite is suspect: the observed failure is
    /// not one character but a wholesale conversion, sometimes of only part of
    /// the text, which is how a Simplified rewrite of Traditional dictation
    /// comes back reading half in each.
    ///
    /// It applies to every style, including the custom one. Restyling text is
    /// never a licence to change the script the user writes in, and a user who
    /// wants the other variant has an app-wide way to ask for it: the Chinese
    /// output script setting, which by the time a transcript reaches here has
    /// already written it in that script (`docs/chinese-script.md`). So this
    /// check is what stops the model undoing that choice. It only fires when the
    /// transcript itself is decisive, so dictation that already mixes the two is
    /// left alone.
    private static func chineseVariantSurvives(_ candidate: String, _ transcript: String) -> Bool {
        let source = ChineseScriptVariant.signal(in: transcript)
        guard source.isDecisive else { return true }
        let rewritten = ChineseScriptVariant.signal(in: candidate)
        return source.traditional > 0 ? rewritten.simplified == 0 : rewritten.traditional == 0
    }

    /// The share of letter-like characters that are CJK, or nil when there are
    /// no letter-like characters.
    private static func cjkRatio(of text: String) -> Double? {
        var letters = 0
        var cjk = 0
        for character in text where character.isLetter {
            letters += 1
            if isCJK(character) { cjk += 1 }
        }
        guard letters > 0 else { return nil }
        return Double(cjk) / Double(letters)
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

    // MARK: - Length

    private static func lengthRejection(
        for candidate: String, transcript: String, shape: StyleRewriteShape
    ) -> StyleRewriteRejection? {
        let transcriptLength = transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard transcriptLength > 0 else { return nil }
        let ratio = Double(candidate.count) / Double(transcriptLength)
        let accepted = shape.acceptedLengthRatio
        if ratio < accepted.lowerBound { return .tooShort }
        if ratio > accepted.upperBound { return .tooLong }
        return nil
    }

    // MARK: - Numbers and symbols

    /// Numbers in the rewrite, compared against the transcript.
    ///
    /// A style that may omit content has to satisfy the weaker half of the rule
    /// - every number it kept was in the transcript - and every other style has
    /// to reproduce them exactly.
    private static func numbersSurvive(
        in candidate: String, transcript: String, shape: StyleRewriteShape
    ) -> Bool {
        let source = counted(numberTokens(in: transcript))
        let rewritten = counted(numberTokens(in: candidate))
        if shape.mayOmitContent {
            return rewritten.allSatisfy { token, count in source[token, default: 0] >= count }
        }
        return source == rewritten
    }

    private static func symbolsSurvive(
        in candidate: String, transcript: String, shape: StyleRewriteShape
    ) -> Bool {
        let source = counted(transcript.filter { meaningfulSymbols.contains($0) }.map(String.init))
        let rewritten = counted(candidate.filter { meaningfulSymbols.contains($0) }.map(String.init))
        if shape.mayOmitContent {
            return rewritten.allSatisfy { symbol, count in source[symbol, default: 0] >= count }
        }
        return source == rewritten
    }

    private static func counted(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { counts, token in counts[token, default: 0] += 1 }
    }

    /// Every number in `text`, normalised so that only a change of value is a
    /// change.
    ///
    /// Full-width digits are folded onto ASCII and thousands separators are
    /// dropped, so `１,０００` and `1000` are the same number; a decimal point is
    /// kept, so `3.5` and `35` are not. Numbers written as words - "thirty",
    /// "三十" - are deliberately out of scope: the guard would have to
    /// understand two languages' numerals to compare them, and getting that
    /// subtly wrong would reject correct rewrites. `docs/style-rewriting.md`
    /// records the limit.
    static func numberTokens(in text: String) -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var current = ""
        var index = 0

        while index < characters.count {
            if let digit = asciiDigit(characters[index]) {
                current.append(digit)
                index += 1
            } else if !current.isEmpty,
                      characters[index] == "." || characters[index] == "．",
                      index + 1 < characters.count,
                      asciiDigit(characters[index + 1]) != nil {
                current.append(".")
                index += 1
            } else if !current.isEmpty, isThousandsSeparator(characters, at: index) {
                index += 1
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                index += 1
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A separator only counts as one when exactly three digits follow it, so
    /// `1,000` is one number and `3,5 people` stays two.
    private static func isThousandsSeparator(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "," || characters[index] == "，" else { return false }
        let digitsStart = index + 1
        let digitsEnd = digitsStart + 3
        guard digitsEnd <= characters.count else { return false }
        guard (digitsStart ..< digitsEnd).allSatisfy({ asciiDigit(characters[$0]) != nil }) else {
            return false
        }
        return digitsEnd == characters.count || asciiDigit(characters[digitsEnd]) == nil
    }

    private static func asciiDigit(_ character: Character) -> Character? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x30 ... 0x39:
            return character
        case 0xFF10 ... 0xFF19:  // full-width ０-９
            return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
        default:
            return nil
        }
    }

    // MARK: - List markers

    /// Removes one leading list marker from each line.
    ///
    /// Only used for styles that are allowed to add them. A marker is a bullet
    /// character or a short number followed by `.`/`)`, and it must be followed
    /// by a space - so `-` in `well-known` and `2024.` mid-sentence are left
    /// alone.
    static func strippingListMarkers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { strippingLeadingMarker(String($0)) }
            .joined(separator: "\n")
    }

    private static let bulletCharacters: Set<Character> = ["-", "*", "•", "‣", "–", "—", "·"]
    private static let ordinalTerminators: Set<Character> = [".", ")", "、", "．", "）"]

    private static func strippingLeadingMarker(_ line: String) -> String {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count else { return line }

        var afterMarker: Int
        if bulletCharacters.contains(characters[index]) {
            afterMarker = index + 1
        } else {
            var digitEnd = index
            while digitEnd < characters.count,
                  asciiDigit(characters[digitEnd]) != nil,
                  digitEnd - index < 3 {
                digitEnd += 1
            }
            guard digitEnd > index,
                  digitEnd < characters.count,
                  ordinalTerminators.contains(characters[digitEnd]) else { return line }
            afterMarker = digitEnd + 1
        }

        guard afterMarker >= characters.count || characters[afterMarker].isWhitespace else {
            return line
        }
        var textStart = afterMarker
        while textStart < characters.count, characters[textStart].isWhitespace { textStart += 1 }
        return String(characters[textStart...])
    }

    // MARK: - Addressing the user

    private static func addressesTheUser(candidate: String, transcript: String) -> Bool {
        let lowercasedCandidate = candidate.lowercased()
        let lowercasedTranscript = transcript.lowercased()
        return addressingMarkers.contains { marker in
            lowercasedCandidate.contains(marker) && !lowercasedTranscript.contains(marker)
        }
    }
}
