import Foundation

/// One dictionary entry that fired on a dictation.
struct AppliedTerm: Equatable {
    let termID: UUID
    let kind: PersonalTermKind
    /// The span exactly as it appeared in the input.
    let matched: String
    /// The span exactly as it was written out.
    let emitted: String
}

/// The output of the terms stage.
///
/// This carries more than the corrected string because the two extra pieces are
/// what later stages need and cannot reconstruct afterwards:
///
/// - ``protectedRanges`` tells the *deterministic* stages that follow which
///   spans they may not touch. `TextPostProcessor` uses it today to keep CJK
///   autocorrect off never-correct entries.
/// - ``mustSurviveTokens`` is the set a *rewriting* stage would have to find
///   intact in its own output before that output could be accepted. Nothing
///   consumes it yet - there is no model in this pipeline - but it is produced
///   here because only this stage knows what it changed.
struct TermsCorrection: Equatable {
    let text: String
    /// Every entry that fired, in the order it fired.
    let applied: [AppliedTerm]
    /// Character offsets into ``text``, ascending and non-overlapping, that no
    /// later deterministic stage may alter.
    let protectedRanges: [Range<Int>]

    /// The text that must still be present for a later rewrite to be accepted:
    /// what every applied entry wrote out, de-duplicated in first-seen order.
    var mustSurviveTokens: [String] {
        var seen = Set<String>()
        return applied.compactMap { seen.insert($0.emitted).inserted ? $0.emitted : nil }
    }

    var changedText: Bool { !applied.isEmpty }

    static func unchanged(_ text: String) -> TermsCorrection {
        TermsCorrection(text: text, applied: [], protectedRanges: [])
    }
}

/// Applies the personal terms dictionary. Deterministic, no model, no network.
///
/// Matching is a single left-to-right scan over characters, leftmost-longest:
/// at each position the longest entry that matches wins, and scanning resumes
/// after the span it consumed, so an entry can never rewrite text another entry
/// just produced. There is no tokenisation step, because Chinese has no word
/// spaces and entries such as `阿 Ken` or `第 3 個 sprint` straddle scripts.
///
/// Comparison is case-sensitive and folds Traditional onto Simplified
/// (``ChineseScriptFolding``) so an entry matches either script. What gets
/// written out is always the entry's own `replacement`, exactly as typed - or,
/// for a never-correct entry, the source span exactly as spoken. Nothing here
/// converts the user's script for them.
enum PersonalTermsCorrector {

    static func apply(_ terms: [PersonalTerm], to text: String) -> TermsCorrection {
        guard !text.isEmpty else { return .unchanged(text) }

        let source = Array(text)
        let foldedSource = ChineseScriptFolding.fold(text)
        let candidates = makeCandidates(terms, foldedSource: foldedSource)
        guard !candidates.isEmpty else { return .unchanged(text) }

        var output: [Character] = []
        output.reserveCapacity(source.count)
        var applied: [AppliedTerm] = []
        var protectedRanges: [Range<Int>] = []

        var index = 0
        while index < source.count {
            guard let hit = firstMatch(in: foldedSource, at: index, candidates: candidates) else {
                output.append(source[index])
                index += 1
                continue
            }

            let matched = String(source[index ..< index + hit.length])
            let emitted = hit.term.emittedText(forMatched: matched)
            let start = output.count
            output.append(contentsOf: emitted)

            if hit.term.kind == .protect {
                protectedRanges.append(start ..< output.count)
            }
            applied.append(
                AppliedTerm(termID: hit.term.id, kind: hit.term.kind, matched: matched, emitted: emitted)
            )
            index += hit.length
        }

        return TermsCorrection(
            text: String(output), applied: applied, protectedRanges: protectedRanges
        )
    }

    // MARK: - Matching

    private struct Candidate {
        let term: PersonalTerm
        let foldedMatch: [Character]
    }

    /// Entries the scan will try, longest first.
    ///
    /// Length is the only ordering that matters for correctness - it is what
    /// makes `臺北市` win over `臺北`. Ties keep file order so the result is
    /// stable and the user can resolve an ambiguity by reordering.
    private static func makeCandidates(
        _ terms: [PersonalTerm], foldedSource: [Character]
    ) -> [Candidate] {
        terms
            .filter { $0.isEnabled && $0.isValid }
            .filter { contextHintSatisfied($0, foldedSource: foldedSource) }
            .map { Candidate(term: $0, foldedMatch: ChineseScriptFolding.fold($0.match)) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.foldedMatch.count != rhs.element.foldedMatch.count {
                    return lhs.element.foldedMatch.count > rhs.element.foldedMatch.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// An entry with a context hint fires only when that hint also appears in
    /// the same dictation. This is what makes a homophone entry such as
    /// `在` → `再` usable at all: applied globally it would wreck every other
    /// sentence, and the hint is the user's way of saying when they meant it.
    private static func contextHintSatisfied(
        _ term: PersonalTerm, foldedSource: [Character]
    ) -> Bool {
        guard let hint = term.contextHint, !hint.isEmpty else { return true }
        let foldedHint = ChineseScriptFolding.fold(hint)
        guard foldedHint.count <= foldedSource.count else { return false }
        for start in 0 ... (foldedSource.count - foldedHint.count) {
            if foldedSource[start ..< start + foldedHint.count].elementsEqual(foldedHint) {
                return true
            }
        }
        return false
    }

    private static func firstMatch(
        in foldedSource: [Character], at index: Int, candidates: [Candidate]
    ) -> (term: PersonalTerm, length: Int)? {
        for candidate in candidates {
            let length = candidate.foldedMatch.count
            guard length > 0, index + length <= foldedSource.count else { continue }
            guard foldedSource[index ..< index + length].elementsEqual(candidate.foldedMatch) else {
                continue
            }
            return (candidate.term, length)
        }
        return nil
    }
}
