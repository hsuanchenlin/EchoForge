import Foundation

/// What one spoken correction asks for.
///
/// Four kinds, and the split between the first two is the scope of the delete:
/// a phrase is the clause the speaker just said, a sentence is everything back
/// to the last full stop. Everything here is decided by the words alone - no
/// model classifies a dictation, for the same reason `SpokenIntentRouter` does
/// not.
enum SpokenCorrectionKind: String, Equatable, Sendable, CaseIterable {
    /// "scratch that" - drop the clause before it.
    case deletePhrase
    /// "delete the last sentence" - drop everything back to the last full stop.
    case deleteSentence
    /// "replace Friday with Monday" - rewrite the most recent occurrence.
    case replace
    /// "start over" - drop everything said before it.
    case startOver
}

/// One trigger phrase and what it means.
///
/// A trigger only fires when it is the **whole** of a clause. That single rule
/// is what keeps "I want to scratch that itch" as dictation while "send it
/// Friday, scratch that, Monday" is an edit, and it is the reason this feature
/// can be deterministic at all: the alternative - matching the words anywhere -
/// deletes part of a sentence the user meant, into a document they are not
/// looking at, with no undo. See `docs/spoken-corrections.md`.
struct SpokenCorrectionTrigger: Equatable, Sendable {
    let phrase: String
    let kind: SpokenCorrectionKind

    /// Compared with the clause folded the way `SpokenCorrectionGrammar.fold`
    /// folds it, so casing and inner spacing do not decide whether a correction
    /// is heard.
    var key: String { SpokenCorrectionGrammar.fold(phrase) }
}

/// A `replace X with Y` form: the words in front of X, and the words between X
/// and Y.
///
/// Both are needed because the two halves are what make the command
/// unambiguous. "replace" alone would swallow "replace the battery", and
/// requiring the connector is what forces the speaker to name both sides.
struct SpokenReplacementForm: Equatable, Sendable {
    /// What the clause has to start with. Empty for the English forms, whose
    /// marker is the verb itself.
    let opening: String
    /// What separates the old text from the new one.
    let connector: String
}

/// Every phrase this app will act on, and the words it treats as hesitation.
///
/// **Everything not listed here is dictation**, unchanged. The bias is
/// deliberate and it is not symmetric: a missed correction costs the user one
/// retry, and a correction fired on words they meant deletes part of their
/// sentence into somebody else's document. Every entry below is a phrase people
/// say *about* what they just said rather than as part of it, and every one is
/// still required to occupy a whole clause.
///
/// Every CJK spelling is listed in both scripts, closed under ICU's
/// per-character conversion, for the reason `SpokenIntentGrammar` lists its
/// markers twice: `ChineseScriptNormalizer` has already rewritten the transcript
/// into the user's chosen script by the time this runs, so a Simplified speaker
/// whose output is Traditional says 「删掉那句」 and this table is handed
/// 「刪掉那句」. `SpokenCorrectionGrammarTests` converts every entry both ways
/// and fails if the result is not also an entry.
enum SpokenCorrectionGrammar {

    /// The retraction phrases, longest first inside each kind so a longer
    /// spelling is never read as a shorter one with words after it.
    ///
    /// The Chinese entries are split between the two delete kinds along the
    /// language rather than along a translation: 句 *is* a sentence, so every
    /// 「…句」 form deletes a sentence, and the phrase-scoped Chinese triggers
    /// are the bare retractions a speaker actually interjects with.
    static let triggers: [SpokenCorrectionTrigger] = [
        // Sentence deletes are listed first so "delete the last sentence" is
        // never read as the phrase-scoped "delete that".
        .init(phrase: "delete the last sentence", kind: .deleteSentence),
        .init(phrase: "delete that sentence", kind: .deleteSentence),
        .init(phrase: "remove the last sentence", kind: .deleteSentence),
        .init(phrase: "scratch the last sentence", kind: .deleteSentence),
        .init(phrase: "刪掉最後一句", kind: .deleteSentence),
        .init(phrase: "删掉最后一句", kind: .deleteSentence),
        .init(phrase: "刪掉上一句", kind: .deleteSentence),
        .init(phrase: "删掉上一句", kind: .deleteSentence),
        .init(phrase: "刪除上一句", kind: .deleteSentence),
        .init(phrase: "删除上一句", kind: .deleteSentence),
        .init(phrase: "刪掉剛才那句", kind: .deleteSentence),
        .init(phrase: "删掉刚才那句", kind: .deleteSentence),
        .init(phrase: "刪掉那句", kind: .deleteSentence),
        .init(phrase: "删掉那句", kind: .deleteSentence),
        .init(phrase: "刪掉這句", kind: .deleteSentence),
        .init(phrase: "删掉这句", kind: .deleteSentence),
        .init(phrase: "刪除那句", kind: .deleteSentence),
        .init(phrase: "删除那句", kind: .deleteSentence),

        .init(phrase: "delete the last phrase", kind: .deletePhrase),
        .init(phrase: "delete that phrase", kind: .deletePhrase),
        .init(phrase: "scratch that", kind: .deletePhrase),
        .init(phrase: "delete that", kind: .deletePhrase),
        .init(phrase: "strike that", kind: .deletePhrase),
        .init(phrase: "never mind", kind: .deletePhrase),
        .init(phrase: "nevermind", kind: .deletePhrase),
        // 說錯了 and 講錯了 are said *about* the previous clause and about
        // nothing else. 算了 is the one entry here that is also an ordinary
        // phrase, and the whole-clause rule is what makes it safe: 「我覺得算了」
        // is a clause of its own and does not match, and a bare 「算了」 that
        // opens a dictation has nothing in front of it and so is left verbatim.
        .init(phrase: "說錯了", kind: .deletePhrase),
        .init(phrase: "说错了", kind: .deletePhrase),
        .init(phrase: "講錯了", kind: .deletePhrase),
        .init(phrase: "讲错了", kind: .deletePhrase),
        .init(phrase: "算了", kind: .deletePhrase),

        .init(phrase: "scratch all of that", kind: .startOver),
        .init(phrase: "scratch all that", kind: .startOver),
        .init(phrase: "delete everything", kind: .startOver),
        .init(phrase: "let's start over", kind: .startOver),
        .init(phrase: "lets start over", kind: .startOver),
        .init(phrase: "start over", kind: .startOver),
        .init(phrase: "start again", kind: .startOver),
        .init(phrase: "重新開始", kind: .startOver),
        .init(phrase: "重新开始", kind: .startOver),
        .init(phrase: "從頭開始", kind: .startOver),
        .init(phrase: "从头开始", kind: .startOver),
        .init(phrase: "全部刪掉", kind: .startOver),
        .init(phrase: "全部删掉", kind: .startOver),
    ]

    /// The `replace X with Y` shapes.
    ///
    /// English needs no opening beyond the verb, which the parser reads off the
    /// front of the clause; the Chinese forms need 把 or 將 in front, because
    /// 改成 on its own is an ordinary construction ("把它改成藍色" is a request,
    /// not a transcript correction) and the opening is what makes the clause a
    /// command about the dictation.
    static let replacementForms: [SpokenReplacementForm] = [
        .init(opening: "replace", connector: "with"),
        .init(opening: "change", connector: "to"),
        .init(opening: "把", connector: "改成"),
        .init(opening: "把", connector: "換成"),
        .init(opening: "把", connector: "换成"),
        .init(opening: "將", connector: "改成"),
        .init(opening: "将", connector: "改成"),
        .init(opening: "將", connector: "換成"),
        .init(opening: "将", connector: "换成"),
    ]

    // MARK: - Fillers

    /// Hesitation sounds, removed as whole words wherever they appear.
    ///
    /// Every entry is a sound rather than a word: none of them is something a
    /// person means, in any of the languages this app transcribes, so removing
    /// one cannot change what was said. Words that are *also* filler - "like",
    /// "actually", "basically", 「那個」, 「就是」 - are deliberately not here;
    /// they carry meaning far more often than not, and the price of getting one
    /// wrong is a sentence that no longer says what the user said.
    static let hesitationSounds: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "er", "err", "erm", "ahem",
    ]

    /// Discourse markers removed **only** when they are a clause of their own.
    ///
    /// "It's, like, complicated" is a tic and "I like this" is a sentence, and
    /// the difference between them is exactly the punctuation the speaker's
    /// pause became. Nothing here is ever removed from inside a clause.
    static let standaloneFillers: Set<String> = [
        "like", "you know", "i mean", "sort of", "kind of",
    ]

    // MARK: - Matching

    /// The trigger a clause names, or nil when it names none.
    ///
    /// A CJK trigger is compared with spaces removed and a Latin one is not -
    /// see ``foldIgnoringSpaces(_:)`` for why the asymmetry is deliberate.
    static func trigger(forClause text: String) -> SpokenCorrectionTrigger? {
        let key = fold(text)
        guard !key.isEmpty else { return nil }
        if let exact = triggers.first(where: { $0.key == key }) { return exact }
        let spaceless = foldIgnoringSpaces(text)
        return triggers.first {
            !$0.phrase.contains(where: \.isCased) && foldIgnoringSpaces($0.phrase) == spaceless
        }
    }

    /// The one spelling a clause and a trigger are compared in.
    ///
    /// Case is folded because a transcript capitalises the first word of a
    /// sentence, and inner whitespace is collapsed because an engine writes
    /// "never mind" or "nevermind" for the same two syllables and a Mandarin
    /// transcript may or may not have a space in front of a Latin word. Nothing
    /// else is folded: the characters themselves have to be the ones the user
    /// said.
    static func fold(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `fold`, with every space removed as well.
    ///
    /// Only the CJK comparisons use it, and only because those markers mix
    /// scripts: an engine writes 「刪掉 那句」 or 「刪掉那句」 for the same words
    /// depending on whether CJK spacing ran, and a table with every spacing of
    /// every entry would be a table that is always missing the one just said.
    /// It is never applied to a Latin phrase, where removing spaces would make
    /// "start over" match "startover" in the middle of a word.
    static func foldIgnoringSpaces(_ text: String) -> String {
        fold(text).filter { !$0.isWhitespace }
    }
}
