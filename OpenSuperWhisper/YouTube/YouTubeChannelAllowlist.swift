import Foundation

/// How a spoken phrase came to name one of the user's channels.
///
/// Carried on the resolution rather than thrown away, because the last of the
/// three is the one thing in this feature a model touches and the user is told
/// when it did - the same disclosure rule `StyleRewriteAvailability.cloudProvider`
/// follows for text that leaves the Mac. The first two are pure string
/// comparison and need no announcement.
enum YouTubeChannelMatchSource: Equatable, Sendable {
    /// A stored spelling, matched as `YouTubeChannelAlias.normalize` writes it.
    case spokenName
    /// The same spelling with its internal spaces folded away: "valley 101" for
    /// a stored `valley101`, or "小 Lin 說" for a stored `小Lin說`. Still an
    /// exact match of one stored name - only the spacing a speech engine
    /// invented is ignored.
    case spacing
    /// The on-device model picked this row out of the user's own list, after
    /// both deterministic tiers came back unknown or ambiguous. `spoken` is what
    /// it was given, so a surface can quote it back.
    case model(spoken: String)

    /// Whether a model was asked. Read by the surfaces that disclose it.
    var usedModel: Bool {
        if case .model = self { return true }
        return false
    }

    /// The sentence disclosing a model match, or nil when nothing was asked.
    var disclosure: String? {
        guard case .model(let spoken) = self else { return nil }
        return "“\(spoken)” is not one of your stored spellings; the on-device model matched it to this channel."
    }
}

/// What a spoken channel name turned out to be.
///
/// The two failures are separate cases rather than one, because the user does
/// two different things about them: an unknown name needs a row adding, and an
/// ambiguous one needs two rows telling apart. Both of them do **nothing** -
/// nothing is fetched, nothing is opened, nothing is pasted - which is the rule
/// this whole feature is arranged around: a command that cannot be carried out
/// exactly as spoken is a command that is not carried out at all.
enum YouTubeChannelResolution: Equatable, Sendable {
    case allowlisted(YouTubeChannel, matchedBy: YouTubeChannelMatchSource)
    /// No enabled, valid row answers to this name.
    case unknown(spoken: String)
    /// More than one does. The display names are carried so the message can name
    /// them, which is the only thing that makes it fixable.
    case ambiguous(spoken: String, matches: [String])
    /// The command itself is switched off, so there is no list to look in.
    ///
    /// Its own case rather than `unknown`, because the answer is different: an
    /// unknown name needs a row adding and this needs a switch turning on, and
    /// sending somebody to add a channel to a feature that is off would be the
    /// app misdirecting them. Reachable only by pressing the command hotkey
    /// while the feature is off - the key stays bound so that press can say what
    /// is wrong rather than doing nothing at all.
    case disabled(spoken: String)

    /// What the user said, in every case, so a message can quote it back.
    var spokenName: String {
        switch self {
        case .allowlisted(let channel, _): return channel.displayName
        case .unknown(let spoken): return spoken
        case .ambiguous(let spoken, _): return spoken
        case .disabled(let spoken): return spoken
        }
    }
}

/// The allowlist as the router sees it: a pure lookup from spoken words to at
/// most one channel.
///
/// A struct over a snapshot rather than a call into the store, so the decision
/// is a pure function of "these words, these channels" and can be tested without
/// a defaults domain - the same shape `SpokenIntentRouter` takes its snippets in.
struct YouTubeChannelAllowlist: Equatable, Sendable {
    let channels: [YouTubeChannel]

    static let empty = YouTubeChannelAllowlist(channels: [])

    init(channels: [YouTubeChannel]) {
        self.channels = channels
    }

    var isEmpty: Bool { channels.isEmpty }

    /// The channels a command may reach: enabled, and complete enough to fetch.
    var reachable: [YouTubeChannel] {
        channels.filter { $0.isEnabled && $0.isValid }
    }

    /// Resolves what the user said after the marker.
    ///
    /// Two deterministic tiers, tried in order, and a spoken name has to match
    /// one stored name **in full** in whichever tier answers - nothing is
    /// stemmed, nothing truncated, nothing partial. A near miss that opened
    /// *something* would be the app choosing a channel the user did not.
    ///
    /// 1. The stored spelling as `YouTubeChannelAlias.normalize` writes it:
    ///    case, edge punctuation, doubled-up whitespace and Traditional against
    ///    Simplified script folded away, because a speech engine varies all of
    ///    them on its own.
    /// 2. The same comparison with **internal spaces folded away too**, so a
    ///    stored `valley101` answers to "valley 101" and a stored `小Lin說` to
    ///    "小 Lin 說". Where a space falls inside a name is the speech engine's
    ///    guess rather than the user's word, and it is the one thing a user
    ///    cannot dictate deliberately - which is what makes this tier safe where
    ///    stemming would not be. It is still a whole-name match against one
    ///    stored row: "valley" reaches nothing, and neither does "valley 1012".
    ///
    /// Ambiguity is detected in each tier separately and separately refused, so
    /// widening the comparison can never quietly pick a winner. Two rows that
    /// share a spoken name exactly are refused at tier 1 as they always were;
    /// two rows that differ only in spacing - `valley101` and `valley 101` -
    /// each still resolve from their own exact spelling at tier 1, and only a
    /// third spelling that matches both compactly is refused as ambiguous.
    func resolve(spokenName: String) -> YouTubeChannelResolution {
        let spoken = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = YouTubeChannelAlias.normalize(spoken)
        guard !key.isEmpty else { return .unknown(spoken: spoken) }
        let reachable = self.reachable

        let named = reachable.filter { $0.spokenKeys.contains(key) }
        if named.count == 1 { return .allowlisted(named[0], matchedBy: .spokenName) }
        if named.count > 1 {
            // Two rows sharing a spoken name is refused when Settings saves, so
            // reaching here means a list that was edited before that check
            // existed or written by hand. Refusing beats picking the first: the
            // user's own list is the only thing that says which they meant.
            return .ambiguous(spoken: spoken, matches: named.map(\.displayName))
        }

        let compactKey = YouTubeChannelAlias.compact(key)
        let spaced = reachable.filter { $0.compactSpokenKeys.contains(compactKey) }
        switch spaced.count {
        case 0:
            return .unknown(spoken: spoken)
        case 1:
            return .allowlisted(spaced[0], matchedBy: .spacing)
        default:
            return .ambiguous(spoken: spoken, matches: spaced.map(\.displayName))
        }
    }
}

/// Everything Settings refuses to save, and why.
///
/// A pure function over the draft and the rest of the list, so the editor can
/// say what is wrong while the user is still typing and the store can refuse the
/// same thing on the way in.
enum YouTubeChannelProblem: Hashable, Sendable {
    case missingName
    case invalidChannelID
    /// Another row already uses this id. Two names for one channel is a
    /// duplicate, not a feature: the second row can never be the one that wins a
    /// lookup its own name does not.
    case duplicateChannelID(existing: String)
    /// A spoken name this row shares with another row, which would make every
    /// command that says it ambiguous.
    case duplicateSpokenName(String, existing: String)

    var message: String {
        switch self {
        case .missingName:
            return "Give the channel a name you can say."
        case .invalidChannelID:
            return "A channel ID looks like UCxxxxxxxxxxxxxxxxxxxxxx - 24 characters starting with UC. A handle such as @name is not one."
        case .duplicateChannelID(let existing):
            return "“\(existing)” already uses that channel ID."
        case .duplicateSpokenName(let name, let existing):
            return "“\(name)” is already how you say “\(existing)”. Spoken names have to be unique, or neither one can be opened."
        }
    }
}

extension YouTubeChannelAllowlist {

    /// What is wrong with `draft`, given everything else already stored.
    ///
    /// Validation is local and total: nothing here asks YouTube whether a
    /// channel exists, because a Settings field that needed the network to say
    /// whether it was valid would be a field that stops working on a plane.
    static func problems(
        with draft: YouTubeChannel, against existing: [YouTubeChannel]
    ) -> [YouTubeChannelProblem] {
        let tidied = draft.deduplicated
        var problems: [YouTubeChannelProblem] = []

        if YouTubeChannelAlias.normalize(tidied.displayName).isEmpty {
            problems.append(.missingName)
        }
        if !YouTubeChannelID.isValid(tidied.channelID) {
            problems.append(.invalidChannelID)
        }

        let others = existing.filter { $0.id != tidied.id }
        let storedID = tidied.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedID.isEmpty,
           let clash = others.first(where: {
               $0.channelID.trimmingCharacters(in: .whitespacesAndNewlines) == storedID
           }) {
            problems.append(.duplicateChannelID(existing: clash.displayName))
        }

        for key in tidied.spokenKeys {
            guard let clash = others.first(where: { $0.spokenKeys.contains(key) }) else { continue }
            problems.append(.duplicateSpokenName(key, existing: clash.displayName))
        }

        return problems
    }
}
