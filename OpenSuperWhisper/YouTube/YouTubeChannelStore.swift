import Foundation

/// The user's allowlisted YouTube channels, stored as JSON in the app's defaults
/// domain.
///
/// Shaped exactly like `VoiceSnippetStore`, and for the same reasons: the list is
/// written only by the Settings pane, read on the dictation path, holds no state
/// of its own so the pane and the router cannot disagree about what is stored,
/// and lives in the defaults domain - which is what lets a test point
/// `PreferenceStore.defaults` at a throwaway suite and never touch the
/// developer's own list. It is deliberately not a second hand-editable file: a
/// channel id is copied from a browser, not maintained by hand the way
/// `terms.json` is.
final class YouTubeChannelStore {
    enum StoreError: LocalizedError {
        case recoveryRequired
        case rejected([YouTubeChannelProblem])

        var errorDescription: String? {
            switch self {
            case .recoveryRequired:
                return "The stored channels could not be read. Reset them before making changes."
            case .rejected(let problems):
                return problems.map(\.message).joined(separator: " ")
            }
        }
    }

    static let channelsKey = "youTubeChannels"

    static let shared = YouTubeChannelStore()

    private let defaults: () -> UserDefaults

    /// - Parameter defaults: read at every access rather than captured, because
    ///   `PreferenceStore.defaults` is what a test swaps and a store built
    ///   before that swap must still write where the test is looking.
    init(defaults: @escaping () -> UserDefaults = { PreferenceStore.defaults }) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// Every channel, in the order the user arranged them. This is what Settings
    /// edits.
    var channels: [YouTubeChannel] { document?.channels ?? [] }

    /// The channels a spoken command may reach.
    var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: channels.filter { $0.isEnabled && $0.isValid })
    }

    /// Set when something is stored under the key but cannot be decoded - a
    /// document written by a newer build, or a value someone put there by hand.
    /// Surfaced rather than swallowed, and mutations are refused while it is set.
    var loadFailure: String? {
        guard let data = defaults().data(forKey: Self.channelsKey) else { return nil }
        guard (try? Self.decode(data)) == nil else { return nil }
        return "The stored YouTube channels could not be read."
    }

    var canMutate: Bool { loadFailure == nil }

    private var document: YouTubeChannelDocument? {
        guard let data = defaults().data(forKey: Self.channelsKey) else { return .empty }
        return try? Self.decode(data)
    }

    // MARK: - Writing

    /// Replaces the whole list. Whole-document writes because the list is small
    /// and has no concurrent writer but the Settings pane.
    func replaceAll(_ channels: [YouTubeChannel]) throws {
        guard canMutate else { throw StoreError.recoveryRequired }
        let data = try Self.encode(YouTubeChannelDocument(channels: channels))
        defaults().set(data, forKey: Self.channelsKey)
    }

    /// Adds or updates one row, refusing a draft that would make the allowlist
    /// unusable.
    ///
    /// The refusal is here rather than only in the editor because this is the
    /// door every write goes through, and a list holding two rows that answer to
    /// one spoken name is a list where saying that name can only ever do nothing.
    func upsert(_ channel: YouTubeChannel) throws {
        guard canMutate else { throw StoreError.recoveryRequired }
        let tidied = channel.deduplicated
        let problems = YouTubeChannelAllowlist.problems(with: tidied, against: channels)
        guard problems.isEmpty else { throw StoreError.rejected(problems) }

        var updated = channels
        if let index = updated.firstIndex(where: { $0.id == tidied.id }) {
            updated[index] = tidied
        } else {
            updated.append(tidied)
        }
        try replaceAll(updated)
    }

    func remove(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try replaceAll(channels.filter { !ids.contains($0.id) })
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) throws {
        var updated = channels
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].isEnabled = isEnabled
        try replaceAll(updated)
    }

    /// Forgets an unreadable document, which is the only repair available for a
    /// value the app cannot decode. Kept explicit - behind a button the user
    /// presses after being told - rather than done implicitly on the way past.
    func reset() {
        defaults().removeObject(forKey: Self.channelsKey)
    }

    // MARK: - Codec

    static func decode(_ data: Data) throws -> YouTubeChannelDocument {
        try JSONDecoder().decode(YouTubeChannelDocument.self, from: data)
    }

    static func encode(_ document: YouTubeChannelDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}
