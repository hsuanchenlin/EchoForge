import Foundation

/// One configured channel, scored against a phrase, for **ordering a list the
/// user is about to choose from**.
///
/// This is the one place in the feature where an inexact comparison happens, and
/// it is safe here for exactly one reason: it decides nothing. A score can move
/// a row to the top of a picker; it can never open anything, never fill in a
/// channel id, and never stand in for the press of Return that a selection
/// actually requires. `YouTubeChannelAllowlist.resolve` remains the only thing
/// that turns words into a channel on its own, and it is still whole-name exact
/// in both of its tiers.
///
/// What is compared is **only what the user typed into Settings** - the display
/// name and the aliases, as `YouTubeChannelAlias.normalize` writes them. No
/// channel id, no URL and no host takes part, which is the same rule
/// `YouTubeChannelModelMatch` states for its prompt.
struct YouTubeChannelSuggestion: Equatable, Sendable, Identifiable {
    let channel: YouTubeChannel
    /// 0…1, where 1 is a stored spelling written exactly as the phrase was.
    let score: Double
    /// The stored spelling that scored best, so a surface can say which of a
    /// row's names the phrase is close to rather than only naming the row.
    let matchedSpelling: String
    /// Where this row sat in the user's own list, and the tie-break that keeps
    /// the order reproducible when two rows score the same.
    let storedIndex: Int

    var id: UUID { channel.id }

    /// Whether this row is close enough to the phrase to be worth putting
    /// forward as *the likely one* rather than merely listing.
    ///
    /// A suggestion is a hint beside a row the user still has to choose. The
    /// threshold is therefore tuned to be useful rather than to be certain -
    /// the cost of a wrong suggestion is that the user presses Down once.
    var isSuggested: Bool { score >= YouTubeChannelSuggestions.suggestionThreshold }
}

/// Ranks the user's own channels against a phrase.
///
/// Pure, total and deterministic: the same phrase and the same list produce the
/// same order every time, on every Mac, with no locale-dependent collation and
/// no dependence on hash ordering. That matters more than it looks - the order
/// is what a keyboard-first picker's Return key lands on, so an order that
/// wobbled would make the same words open different channels on different runs.
enum YouTubeChannelSuggestions {

    /// The score at or above which a row is called out as the likely one.
    ///
    /// Measured against the case this whole picker exists for: a speech engine
    /// wrote "Vali101" where the user stored `valley101`, which scores about
    /// 0.67. Anything sharing a whole word or a long prefix lands above this;
    /// two unrelated names land well below.
    static let suggestionThreshold: Double = 0.5

    /// Every reachable channel, best first.
    ///
    /// **Every** channel: nothing is dropped for scoring badly, because the list
    /// is the user's own and a picker that hid the row they wanted would be
    /// worse than one that ordered it last. Ranking moves rows; filtering
    /// (`filter(_:matching:)`) is what removes them, and only the user's typing
    /// does that.
    static func rank(
        _ phrase: String, among channels: [YouTubeChannel]
    ) -> [YouTubeChannelSuggestion] {
        let key = YouTubeChannelAlias.normalize(phrase)
        let suggestions = channels.enumerated().map { index, channel in
            YouTubeChannelSuggestion(
                channel: channel,
                score: key.isEmpty ? 0 : bestScore(for: key, in: channel).score,
                matchedSpelling: key.isEmpty
                    ? channel.displayName : bestScore(for: key, in: channel).spelling,
                storedIndex: index
            )
        }
        return suggestions.sorted(by: isOrderedBefore)
    }

    /// The rows whose stored spellings contain `query`, ranked against it.
    ///
    /// Type-to-filter is substring containment rather than the whole-name match
    /// the allowlist does, and the difference is deliberate: this compares what
    /// the user is typing *now*, in front of the list, with the list in view -
    /// the opposite situation to a spoken name being matched with nobody
    /// watching. An empty query filters nothing.
    static func filter(
        _ suggestions: [YouTubeChannelSuggestion], matching query: String
    ) -> [YouTubeChannelSuggestion] {
        let key = YouTubeChannelAlias.normalize(query)
        guard !key.isEmpty else { return suggestions }
        let compactKey = YouTubeChannelAlias.compact(key)
        let matching = suggestions.filter { suggestion in
            contains(compactKey, anySpellingOf: suggestion.channel)
        }
        // Re-scored against what is being typed: while the field has something
        // in it, that is what the user is choosing by, not the phrase that was
        // heard.
        return matching.map { suggestion in
            let best = bestScore(for: key, in: suggestion.channel)
            return YouTubeChannelSuggestion(
                channel: suggestion.channel,
                score: best.score,
                matchedSpelling: best.spelling,
                storedIndex: suggestion.storedIndex
            )
        }
        .sorted(by: isOrderedByQueryScore)
    }

    private static func contains(
        _ compactKey: String, anySpellingOf channel: YouTubeChannel
    ) -> Bool {
        for key in channel.spokenKeys {
            if key.contains(compactKey) { return true }
            if YouTubeChannelAlias.compact(key).contains(compactKey) { return true }
        }
        return false
    }

    /// Suggestions first, best first; then the user's own list order, untouched.
    ///
    /// The second half is the part worth stating. A score below the threshold is
    /// **noise** - two names that are both unlike the phrase are not thereby
    /// ranked against each other in any way a person would recognise - so
    /// ordering those rows by it would shuffle the user's list for no reason
    /// they could see. They keep the order they have in Settings, which is the
    /// order they already know.
    ///
    /// Scores are compared at four decimal places so two arithmetically equal
    /// similarities cannot swap places on a rounding difference; below that,
    /// `storedIndex` is unique, so the order is total and no comparison ever
    /// falls through to something undefined.
    private static func isOrderedBefore(
        _ lhs: YouTubeChannelSuggestion, _ rhs: YouTubeChannelSuggestion
    ) -> Bool {
        if lhs.isSuggested != rhs.isSuggested { return lhs.isSuggested }
        if lhs.isSuggested {
            let left = quantized(lhs.score)
            let right = quantized(rhs.score)
            if left != right { return left > right }
        }
        return lhs.storedIndex < rhs.storedIndex
    }

    /// Best match first, for a list the user is narrowing **by typing**.
    ///
    /// Different from the comparator above on purpose. There, a low score is
    /// noise about a phrase nobody chose to compare with; here every row on
    /// screen contains what the user just typed, so how much of the name that
    /// covers is exactly what they are choosing by - and an exact `kurz` should
    /// sit above a row that merely contains it.
    private static func isOrderedByQueryScore(
        _ lhs: YouTubeChannelSuggestion, _ rhs: YouTubeChannelSuggestion
    ) -> Bool {
        let left = quantized(lhs.score)
        let right = quantized(rhs.score)
        if left != right { return left > right }
        return lhs.storedIndex < rhs.storedIndex
    }

    private static func quantized(_ score: Double) -> Int {
        Int((score * 10_000).rounded())
    }

    /// The best any one of a row's stored spellings does against the key.
    private static func bestScore(
        for key: String, in channel: YouTubeChannel
    ) -> (score: Double, spelling: String) {
        var best = (score: 0.0, spelling: channel.displayName)
        for (index, spelling) in ([channel.displayName] + channel.aliases).enumerated() {
            let storedKey = index == 0
                ? YouTubeChannelAlias.normalize(channel.displayName)
                : YouTubeChannelAlias.normalize(spelling)
            guard !storedKey.isEmpty else { continue }
            let score = similarity(key, storedKey)
            if score > best.score {
                best = (score, spelling.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return best
    }

    /// How alike two already-normalized keys are, 0…1.
    ///
    /// Spacing is folded away first, for the reason `YouTubeChannelAlias.compact`
    /// records: where a space falls inside a name is the engine's guess rather
    /// than the speaker's word, so "valley 101" and "valley101" must not be
    /// scored as different names. What remains is edit distance over the
    /// characters, normalized by the longer string - which reads the way a
    /// person would say it: "one character in nine is wrong" is a near miss and
    /// "six in nine" is a different name.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(YouTubeChannelAlias.compact(lhs))
        let right = Array(YouTubeChannelAlias.compact(rhs))
        if left.isEmpty && right.isEmpty { return 1 }
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        let distance = editDistance(left, right)
        let longest = max(left.count, right.count)
        return max(0, 1 - Double(distance) / Double(longest))
    }

    /// Levenshtein distance, two rows at a time.
    ///
    /// Channel names are short and the list is the user's own, so the simple
    /// quadratic form is the right one: it is the version whose correctness can
    /// be read off the page, and there is no input size here for which a
    /// cleverer one would be measurably faster.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
