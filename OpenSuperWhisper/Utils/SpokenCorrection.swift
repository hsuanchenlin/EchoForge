import Foundation

/// One edit a spoken correction made, as a value.
///
/// Typed operations rather than a diff, because the report this feature comes
/// from is explicit about the reason: a destructive edit executed from
/// free-form text is a guess, and a guess that deletes part of somebody's
/// sentence into an application they are not looking at. What the reducer
/// produces is a list of these - what was said, what it removed, and what it
/// put back - which is inspectable, testable and, above all, *bounded*.
struct SpokenCorrectionOperation: Equatable, Sendable {
    let kind: SpokenCorrectionKind
    /// The trigger clause exactly as the engine wrote it.
    let trigger: String
    /// The text this operation took out of the transcript, without the trigger.
    let removed: String
    /// What it put in place. Empty for every kind but `.replace`.
    let inserted: String

    init(kind: SpokenCorrectionKind, trigger: String, removed: String, inserted: String = "") {
        self.kind = kind
        self.trigger = trigger
        self.removed = removed
        self.inserted = inserted
    }
}

/// A trigger that was heard and deliberately **not** acted on.
///
/// It exists so "nothing happened" can be told apart from "nothing was said".
/// A correction that names no edit this app can be certain of leaves the words
/// exactly where they were - the report's rule, and the right one, since a
/// missed correction costs a retry and a wrong one costs a sentence.
struct SpokenCorrectionRefusal: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        /// "scratch that" with nothing in front of it in this dictation.
        case nothingToDelete
        /// "replace X with Y" where X was never said.
        case textNotFound
        /// A replacement form with one of its two halves missing.
        case incomplete
    }

    let reason: Reason
    /// The trigger clause, left in the transcript exactly as it arrived.
    let trigger: String
}

/// A transcript after the spoken-correction stage, and what the stage did.
struct SpokenCorrectionResult: Equatable, Sendable {
    let text: String
    let operations: [SpokenCorrectionOperation]
    let refusals: [SpokenCorrectionRefusal]

    init(
        text: String,
        operations: [SpokenCorrectionOperation] = [],
        refusals: [SpokenCorrectionRefusal] = []
    ) {
        self.text = text
        self.operations = operations
        self.refusals = refusals
    }

    var didCorrect: Bool { !operations.isEmpty }

    static func unchanged(_ text: String) -> SpokenCorrectionResult {
        SpokenCorrectionResult(text: text)
    }
}

/// Whether this transcription is read for spoken corrections, and how much.
///
/// Resolved once in `Settings`, beside the personal terms and the voice
/// snippets, so the reducer stays a pure function of "these words, these
/// options" and every gate in front of it is answered in one place.
struct SpokenCorrectionOptions: Equatable, Sendable {
    /// Whether retractions and replacements are acted on at all.
    var isEnabled: Bool
    /// Whether hesitation sounds are pruned. A child of `isEnabled`: with
    /// corrections off nothing here runs, which is what makes the whole stage
    /// one thing a user can switch off and reason about.
    var removesFillerWords: Bool

    init(isEnabled: Bool = false, removesFillerWords: Bool = false) {
        self.isEnabled = isEnabled
        self.removesFillerWords = removesFillerWords
    }

    /// What every path that is not live dictation gets: a dropped file, a
    /// queued recording, a regenerate from history, a voice-edit instruction and
    /// a command capture. See `Settings`.
    static let disabled = SpokenCorrectionOptions()
}

/// The deterministic reducer that turns a self-correcting utterance into the
/// text the speaker ended up meaning.
///
/// **Pure, synchronous, offline, and cannot fail.** No model classifies a
/// dictation here, for the reason `SpokenIntentRouter` gives about commands and
/// with more force: this stage *deletes* words. A model asked to execute a
/// destructive edit is a model that occasionally deletes the wrong span, into an
/// application the user is not looking at, with the audio already stopped.
///
/// Three rules carry it, and `docs/spoken-corrections.md` is the whole story:
///
/// - **A trigger has to be a whole clause.** "send it Friday, scratch that,
///   Monday" is an edit; "I want to scratch that itch" is dictation. The
///   boundary is `TranscriptClauses`, and it is the entire defence against a
///   false positive.
/// - **An edit it cannot place is not made.** "scratch that" with nothing in
///   front of it, or "replace Friday with Monday" when Friday was never said,
///   leaves the words exactly as they arrived and records a
///   `SpokenCorrectionRefusal`. Guessing is the one thing this stage may not do.
/// - **Untouched clauses come out byte for byte.** `TranscriptClause` partitions
///   the transcript rather than describing it, so every character the reducer
///   did not decide to remove is still there, spacing included.
enum SpokenCorrector {

    /// Applies every correction in one transcript, left to right.
    ///
    /// Left to right because that is the order they were spoken in: a second
    /// "scratch that" retracts what the first one left, not what it removed.
    static func apply(
        to transcript: String, options: SpokenCorrectionOptions
    ) -> SpokenCorrectionResult {
        guard options.isEnabled, !transcript.isEmpty else { return .unchanged(transcript) }

        var kept: [TranscriptClause] = []
        var operations: [SpokenCorrectionOperation] = []
        var refusals: [SpokenCorrectionRefusal] = []

        for clause in TranscriptClauses.split(transcript) {
            guard !clause.text.isEmpty else {
                kept.append(clause)
                continue
            }

            if let trigger = SpokenCorrectionGrammar.trigger(forClause: clause.text) {
                let outcome = applyRetraction(trigger, clause: clause, to: kept)
                kept = outcome.clauses
                operations.append(contentsOf: outcome.operation.map { [$0] } ?? [])
                refusals.append(contentsOf: outcome.refusal.map { [$0] } ?? [])
                continue
            }

            if let replacement = SpokenReplacement.parse(clause.text) {
                let outcome = applyReplacement(replacement, clause: clause, to: kept)
                kept = outcome.clauses
                operations.append(contentsOf: outcome.operation.map { [$0] } ?? [])
                refusals.append(contentsOf: outcome.refusal.map { [$0] } ?? [])
                continue
            }

            kept.append(clause)
        }

        if options.removesFillerWords {
            let pruned = SpokenFillerPruner.prune(kept)
            kept = pruned.clauses
            operations.append(contentsOf: pruned.operations)
        }

        return SpokenCorrectionResult(
            text: tidied(TranscriptClauses.join(kept), original: transcript),
            operations: operations,
            refusals: refusals
        )
    }

    // MARK: - Retractions

    private struct Outcome {
        var clauses: [TranscriptClause]
        var operation: SpokenCorrectionOperation?
        var refusal: SpokenCorrectionRefusal?
    }

    private static func applyRetraction(
        _ trigger: SpokenCorrectionTrigger,
        clause: TranscriptClause,
        to kept: [TranscriptClause]
    ) -> Outcome {
        // A clause with nothing before it is a correction with nothing to
        // correct. The words stay, because the alternative is deciding on the
        // user's behalf that they meant to delete something that is not there.
        let spoken = kept.filter { !$0.text.isEmpty }
        guard !spoken.isEmpty else {
            return Outcome(
                clauses: kept + [clause],
                refusal: SpokenCorrectionRefusal(reason: .nothingToDelete, trigger: clause.text))
        }

        switch trigger.kind {
        case .startOver:
            return Outcome(
                clauses: [],
                operation: SpokenCorrectionOperation(
                    kind: .startOver, trigger: clause.text,
                    removed: TranscriptClauses.join(kept)))

        case .deletePhrase:
            let cut = lastSpokenIndex(in: kept)!
            return Outcome(
                clauses: Array(kept[..<cut]),
                operation: SpokenCorrectionOperation(
                    kind: .deletePhrase, trigger: clause.text,
                    removed: TranscriptClauses.join(Array(kept[cut...]))))

        case .deleteSentence:
            let cut = sentenceStartIndex(in: kept)
            return Outcome(
                clauses: Array(kept[..<cut]),
                operation: SpokenCorrectionOperation(
                    kind: .deleteSentence, trigger: clause.text,
                    removed: TranscriptClauses.join(Array(kept[cut...]))))

        case .replace:
            // `replace` is never reached through the trigger table; it is parsed
            // from the clause, because both of its halves are the speaker's own
            // words rather than a fixed phrase.
            return Outcome(clauses: kept + [clause])
        }
    }

    /// The index of the last clause that has words in it.
    private static func lastSpokenIndex(in clauses: [TranscriptClause]) -> Int? {
        clauses.lastIndex { !$0.text.isEmpty }
    }

    /// Where the sentence that is being deleted starts.
    ///
    /// Walks back from the end over clauses until it crosses a clause whose
    /// *predecessor* ended a sentence, so "Hello there. We ship Friday, and it
    /// rains." loses "We ship Friday, and it rains." and keeps "Hello there."
    private static func sentenceStartIndex(in clauses: [TranscriptClause]) -> Int {
        var index = clauses.count - 1
        while index > 0 {
            if clauses[index - 1].endsSentence, !clauses[index - 1].text.isEmpty {
                return index
            }
            index -= 1
        }
        return 0
    }

    // MARK: - Replacements

    private static func applyReplacement(
        _ replacement: SpokenReplacement,
        clause: TranscriptClause,
        to kept: [TranscriptClause]
    ) -> Outcome {
        // The search is over what was already said and never over what follows:
        // a correction refers backwards, and looking forwards would let
        // "replace Friday with Monday" edit a Friday the speaker had not
        // reached yet.
        guard let target = lastOccurrenceIndex(of: replacement.old, in: kept) else {
            return Outcome(
                clauses: kept + [clause],
                refusal: SpokenCorrectionRefusal(reason: .textNotFound, trigger: clause.text))
        }

        var updated = kept
        var edited = updated[target.clause]
        let characters = Array(edited.text)
        let removed = String(characters[target.range])
        edited.text =
            String(characters[..<target.range.lowerBound])
            + replacement.new
            + String(characters[target.range.upperBound...])
        updated[target.clause] = edited

        return Outcome(
            clauses: updated,
            operation: SpokenCorrectionOperation(
                kind: .replace, trigger: clause.text,
                removed: removed, inserted: replacement.new))
    }

    private static func lastOccurrenceIndex(
        of needle: String, in clauses: [TranscriptClause]
    ) -> (clause: Int, range: Range<Int>)? {
        for index in clauses.indices.reversed() {
            let characters = Array(clauses[index].text)
            guard let range = lastRange(of: Array(needle), in: characters) else { continue }
            return (index, range)
        }
        return nil
    }

    /// The last case-insensitive occurrence of `needle` in `haystack`.
    ///
    /// Written over characters rather than with `String.range(of:options:)`
    /// because the result is spliced back into a clause the reducer is holding
    /// as an array, and mixing index spaces is how an edit lands one character
    /// off in a transcript that contains an emoji or a combining mark.
    private static func lastRange(
        of needle: [Character], in haystack: [Character]
    ) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let folded = needle.map { Character($0.lowercased()) }
        for start in stride(from: haystack.count - needle.count, through: 0, by: -1) {
            let slice = haystack[start ..< start + needle.count]
            if slice.map({ Character($0.lowercased()) }) == folded {
                return start ..< start + needle.count
            }
        }
        return nil
    }

    // MARK: - Tidying

    /// Cleans up after a deletion, and only after one.
    ///
    /// There is very little to clean, and that is by design: `TranscriptClause`
    /// carries the whitespace in front of a clause and the punctuation behind
    /// it, so removing whole clauses cannot leave a doubled space or a stranded
    /// comma between two survivors. The one artefact it can leave is at the very
    /// end - "we ship Friday, " when what followed the comma is gone - which is
    /// punctuation the speaker put there for a clause that no longer exists.
    ///
    /// A transcript nothing was removed from is returned **byte for byte**,
    /// which is what makes this stage a true no-op for the dictations that
    /// contain no correction at all.
    private static func tidied(_ text: String, original: String) -> String {
        guard text != original else { return original }
        var result = text
        while let last = result.last,
              last.isWhitespace
                  || (TranscriptClauses.clauseTerminators.contains(last)
                      && !TranscriptClauses.sentenceTerminators.contains(last)) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A parsed `replace X with Y`.
struct SpokenReplacement: Equatable, Sendable {
    let old: String
    let new: String

    /// Reads a clause as a replacement, or answers nil when it is not one.
    ///
    /// Both halves have to be non-empty, and that is the whole ambiguity check:
    /// "replace the battery" names nothing to put in its place and is dictation,
    /// and so is "change to Monday", which names nothing to change.
    static func parse(_ clause: String) -> SpokenReplacement? {
        // The **original** text throughout, matched case-insensitively rather
        // than lowercased first: what the speaker put in place of the old words
        // is their own text, and reading it off a folded copy would paste
        // "monday" into a sentence they said "Monday" in.
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        for form in SpokenCorrectionGrammar.replacementForms {
            guard let body = remainder(after: form.opening, in: trimmed) else { continue }
            guard let split = firstSplit(of: body, on: form.connector) else { continue }
            let old = split.before.trimmingCharacters(in: .whitespacesAndNewlines)
            let new = split.after.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !old.isEmpty, !new.isEmpty else { continue }
            return SpokenReplacement(old: old, new: new)
        }
        return nil
    }

    /// What follows `opening` at the front of the clause.
    ///
    /// A Latin opening has to end at a word boundary, so "replaced" is not
    /// "replace" followed by "d"; a CJK one does not, because Mandarin is
    /// written without spaces and 「把」 runs straight into what follows it.
    private static func remainder(after opening: String, in clause: String) -> String? {
        guard let range = clause.range(
            of: opening, options: [.caseInsensitive, .anchored], locale: nil
        ) else { return nil }
        let rest = String(clause[range.upperBound...])
        guard opening.contains(where: \.isCased) else { return rest }
        guard let first = rest.first, first.isWhitespace else { return nil }
        return rest
    }

    /// Splits on the first occurrence of `connector` that leaves words on both
    /// sides.
    private static func firstSplit(
        of body: String, on connector: String
    ) -> (before: String, after: String)? {
        let isLatin = connector.contains(where: \.isCased)
        // The Latin connectors are ordinary words, so they are only a connector
        // when they stand as one: " with " and not the "with" inside "within".
        let needle = isLatin ? " \(connector) " : connector
        var searchStart = body.startIndex
        while let range = body.range(of: needle, options: [.caseInsensitive], range: searchStart ..< body.endIndex) {
            let before = String(body[body.startIndex ..< range.lowerBound])
            let after = String(body[range.upperBound...])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (before, after)
            }
            searchStart = range.upperBound
        }
        return nil
    }
}

/// Removes the sounds a speaker makes while thinking.
///
/// Separate from the reducer above because it is a separate promise: the
/// retractions act on what the speaker *said about* their dictation, and this
/// acts on noise inside it. It is its own toggle for the same reason, and it is
/// deliberately the smaller half - the list is hesitation sounds and nothing
/// that carries meaning in any language this app transcribes.
enum SpokenFillerPruner {

    struct Pruned {
        var clauses: [TranscriptClause]
        var operations: [SpokenCorrectionOperation]
    }

    static func prune(_ clauses: [TranscriptClause]) -> Pruned {
        var kept: [TranscriptClause] = []
        var operations: [SpokenCorrectionOperation] = []

        for clause in clauses {
            let folded = SpokenCorrectionGrammar.fold(clause.text)

            // A clause that is nothing but a filler goes, and takes its own
            // punctuation with it: "It's, like, complicated" has to come back as
            // "It's complicated" rather than "It's,, complicated".
            if SpokenCorrectionGrammar.standaloneFillers.contains(folded)
                || SpokenCorrectionGrammar.hesitationSounds.contains(folded) {
                operations.append(
                    SpokenCorrectionOperation(
                        kind: .deletePhrase, trigger: clause.text, removed: clause.rendered))
                unbracket(&kept)
                continue
            }

            let stripped = strippingHesitations(from: clause.text)
            guard stripped != clause.text else {
                kept.append(clause)
                continue
            }
            guard !stripped.isEmpty else {
                operations.append(
                    SpokenCorrectionOperation(
                        kind: .deletePhrase, trigger: clause.text, removed: clause.rendered))
                unbracket(&kept)
                continue
            }
            operations.append(
                SpokenCorrectionOperation(
                    kind: .deletePhrase, trigger: clause.text,
                    removed: clause.text, inserted: stripped))
            var edited = clause
            edited.text = stripped
            // A hesitation that ended the clause took the speaker's pause with
            // it: "we should um, ship on Friday" is one thought, and leaving the
            // comma behind would punctuate it as two.
            if endedWithHesitation(clause.text), !edited.endsSentence,
               !edited.terminator.isEmpty {
                edited.terminator =
                    edited.terminator.contains(where: \.isWhitespace) ? " " : ""
            }
            kept.append(edited)
        }

        return Pruned(clauses: kept, operations: operations)
    }

    /// Takes back the comma that was only there to bracket a filler.
    ///
    /// "It's, like, complicated" is two commas holding one tic, and removing the
    /// tic without one of them leaves "It's, complicated" - punctuation the
    /// speaker never meant, introduced by the cleanup rather than by them. A
    /// terminator that ends a *sentence* is left alone, because "Hello. Um. We
    /// ship." is two sentences with a noise between them and still is afterwards.
    private static func unbracket(_ kept: inout [TranscriptClause]) {
        guard var previous = kept.last, !previous.text.isEmpty,
              !previous.terminator.isEmpty, !previous.endsSentence
        else { return }
        previous.terminator = previous.terminator.contains(where: \.isWhitespace) ? " " : ""
        kept[kept.count - 1] = previous
    }

    /// Drops whole-word hesitation sounds, leaving every protected span alone.
    ///
    /// Quoted text and anything between backticks is held out, because a
    /// transcript that says `he wrote "um" on the board` is quoting the sound
    /// rather than making it - and because code dictated into an editor is the
    /// one place a two-letter token means something exact.
    private static func strippingHesitations(from text: String) -> String {
        let characters = Array(text)
        let protected = protectedRanges(in: characters)
        var result = ""
        var word = ""
        var wordStart = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            let isProtected = protected.contains { $0.contains(wordStart) }
            if isProtected || !SpokenCorrectionGrammar.hesitationSounds.contains(word.lowercased()) {
                result += word
            }
            word = ""
        }

        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if word.isEmpty { wordStart = index }
                word.append(character)
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()

        // The space a removed word left behind is the only thing collapsed, and
        // only inside the clause it was removed from.
        return collapsingSpaces(result).trimmingCharacters(in: .whitespaces)
    }

    /// Whether the last word of a clause was a hesitation sound.
    private static func endedWithHesitation(_ text: String) -> Bool {
        var word = ""
        for character in text.reversed() {
            guard character.isLetter else { break }
            word.insert(character, at: word.startIndex)
        }
        return !word.isEmpty
            && SpokenCorrectionGrammar.hesitationSounds.contains(word.lowercased())
    }

    private static func collapsingSpaces(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            let isSpace = character == " " || character == "\t"
            if isSpace, lastWasSpace { continue }
            result.append(character)
            lastWasSpace = isSpace
        }
        return result
    }

    /// Character ranges nothing may be removed from: quoted passages, and spans
    /// between backticks.
    ///
    /// An apostrophe **inside a word** is not a quotation mark, and treating it
    /// as one is not a harmless over-caution: "don't say um, it's bad" has two
    /// of them, and a naive pairing would hold the whole middle of that sentence
    /// - the "um" included - out of the pruning the user asked for.
    static func protectedRanges(in characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openers: [(Character, Int)] = []
        let pairs: [Character: Character] = [
            "\"": "\"", "“": "”", "'": "'", "‘": "’", "「": "」", "『": "』",
            "`": "`", "«": "»",
        ]

        for (index, character) in characters.enumerated() {
            guard !isWordInternalApostrophe(at: index, in: characters) else { continue }
            if let open = openers.last, pairs[open.0] == character, index > open.1 {
                ranges.append(open.1 ..< index + 1)
                openers.removeLast()
                continue
            }
            if pairs[character] != nil {
                openers.append((character, index))
            }
        }
        return ranges
    }

    private static func isWordInternalApostrophe(
        at index: Int, in characters: [Character]
    ) -> Bool {
        guard characters[index] == "'" || characters[index] == "’" else { return false }
        guard index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isLetter && characters[index + 1].isLetter
    }
}
