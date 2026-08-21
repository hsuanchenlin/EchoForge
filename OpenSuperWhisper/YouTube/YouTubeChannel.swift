import Foundation

/// One channel the user has allowlisted for the spoken "open the latest YouTube
/// video from …" command.
///
/// The allowlist is the whole security model of this feature. Nothing here ever
/// searches YouTube, resolves a handle, or turns spoken words into a URL: a
/// command can only ever reach a channel whose canonical id the user typed into
/// Settings themselves, and every other channel in the world is a channel this
/// app has no way to open. See `docs/youtube-latest-video.md`.
struct YouTubeChannel: Codable, Identifiable, Equatable, Sendable {
    var id: UUID

    /// What the user calls this channel, and the first thing they can say.
    /// Shown in Settings and named back to them when the command runs.
    var displayName: String

    /// The other ways they say it. A speech engine writes one channel name
    /// several ways - "Veritasium", "Verita Zium" - and an alias is how the user
    /// records the spelling their own dictation actually produces, without
    /// renaming the row.
    var aliases: [String]

    /// The canonical `UC…` channel id, which is the only thing the feed request
    /// is built from. Validated by ``YouTubeChannelID``.
    var channelID: String

    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        aliases: [String] = [],
        channelID: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.channelID = channelID
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, aliases, channelID
        case isEnabled = "enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        channelID = try container.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// A channel a spoken command may reach.
    ///
    /// A half-finished row is kept and shown rather than dropped - the same rule
    /// `VoiceSnippet.isValid` follows - it simply never answers to anything. An
    /// entry with an unusable id is the important half: it is exactly the row
    /// that would otherwise send a request somewhere nobody chose.
    var isValid: Bool {
        !YouTubeChannelAlias.normalize(displayName).isEmpty
            && YouTubeChannelID.isValid(channelID)
    }

    /// Every spoken name this channel answers to, normalized and deduplicated.
    ///
    /// The display name is included, so the obvious thing to say works without
    /// the user having to also type it in as an alias.
    var spokenKeys: [String] {
        var keys: [String] = []
        for spelling in [displayName] + aliases {
            let key = YouTubeChannelAlias.normalize(spelling)
            guard !key.isEmpty, !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    /// The row with its aliases tidied: trimmed, emptied of blanks, and free of
    /// two spellings that normalize to the same thing. Applied when Settings
    /// saves, so what is stored is what the matcher will actually use.
    var deduplicated: YouTubeChannel {
        var tidied = self
        tidied.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        tidied.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let displayKey = YouTubeChannelAlias.normalize(tidied.displayName)
        if !displayKey.isEmpty { seen.insert(displayKey) }
        tidied.aliases = aliases.compactMap { alias in
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = YouTubeChannelAlias.normalize(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
        return tidied
    }
}

/// How a spoken channel name is compared against what the user stored.
///
/// Deliberately the same shape as `VoiceSnippetTrigger.normalize` and
/// deliberately not the same function: that one is the snippet feature's
/// comparison key and is free to change with it, and a channel name is compared
/// for a different reason. What both fold away is what a speech engine varies on
/// its own - case, the punctuation a pause becomes, doubled-up whitespace, and
/// Traditional against Simplified script - and neither folds anything that could
/// let one entry answer for another: nothing is stemmed, nothing truncated, a
/// name spaced differently ("小 Lin 說" against "小Lin說") is a different name
/// to record as an alias, and a spoken name has to match a stored one in full.
enum YouTubeChannelAlias {

    private static let edgePunctuation: Set<Character> = [
        ":", "：", ",", "，", "、", ";", "；", ".", "。", "?", "？", "!", "！",
        "-", "–", "—", "\"", "'", "“", "”", "「", "」", "『", "』",
    ]

    static func normalize(_ text: String) -> String {
        let folded = String(ChineseScriptFolding.fold(text.lowercased()))
        var characters = Array(
            folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        )
        while let first = characters.first, isEdge(first) { characters.removeFirst() }
        while let last = characters.last, isEdge(last) { characters.removeLast() }
        return String(characters)
    }

    private static func isEdge(_ character: Character) -> Bool {
        edgePunctuation.contains(character) || character.isWhitespace
    }
}

/// The whole stored allowlist.
///
/// `version` exists so a later format change can be recognised rather than
/// guessed at, the same reason `VoiceSnippetDocument` carries one.
struct YouTubeChannelDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var channels: [YouTubeChannel]

    static let empty = YouTubeChannelDocument(channels: [])

    init(version: Int = YouTubeChannelDocument.currentVersion, channels: [YouTubeChannel]) {
        self.version = version
        self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? YouTubeChannelDocument.currentVersion
        channels = try container.decodeIfPresent([YouTubeChannel].self, forKey: .channels) ?? []
    }
}
