import Foundation

/// What a spoken channel name turned out to be.
///
/// The two failures are separate cases rather than one, because the user does
/// two different things about them: an unknown name needs a row adding, and an
/// ambiguous one needs two rows telling apart. Both of them do **nothing** -
/// nothing is fetched, nothing is opened, nothing is pasted - which is the rule
/// this whole feature is arranged around: a command that cannot be carried out
/// exactly as spoken is a command that is not carried out at all.
enum YouTubeChannelResolution: Equatable, Sendable {
    case allowlisted(YouTubeChannel)
    /// No enabled, valid row answers to this name.
    case unknown(spoken: String)
    /// More than one does. The display names are carried so the message can name
    /// them, which is the only thing that makes it fixable.
    case ambiguous(spoken: String, matches: [String])

    /// What the user said, in every case, so a message can quote it back.
    var spokenName: String {
        switch self {
        case .allowlisted(let channel): return channel.displayName
        case .unknown(let spoken): return spoken
        case .ambiguous(let spoken, _): return spoken
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

    /// Resolves what the user said after the marker.
    ///
    /// The whole remainder has to name one channel: nothing partial matches and
    /// nothing is stemmed, so "Veritasium please" names no channel and
    /// "Veritasium" names one. That is the same rule a voice snippet trigger
    /// follows, and for the same reason - a near-miss that opened *something*
    /// would be the app choosing a channel the user did not.
    func resolve(spokenName: String) -> YouTubeChannelResolution {
        let spoken = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = YouTubeChannelAlias.normalize(spoken)
        guard !key.isEmpty else { return .unknown(spoken: spoken) }

        let matches = channels.filter { channel in
            channel.isEnabled && channel.isValid && channel.spokenKeys.contains(key)
        }

        switch matches.count {
        case 0:
            return .unknown(spoken: spoken)
        case 1:
            return .allowlisted(matches[0])
        default:
            // Two rows sharing a spoken name is refused when Settings saves, so
            // reaching here means a list that was edited before that check
            // existed or written by hand. Refusing beats picking the first: the
            // user's own list is the only thing that says which they meant.
            return .ambiguous(spoken: spoken, matches: matches.map(\.displayName))
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
