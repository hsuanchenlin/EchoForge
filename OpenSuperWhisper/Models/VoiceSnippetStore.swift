import Foundation

/// The user's voice snippets, stored as JSON in the app's defaults domain.
///
/// Deliberately *not* a second `terms.json`. The personal terms dictionary is a
/// file because it is meant to be hand-edited, backed up and version-controlled;
/// snippets are written only by the Settings pane, are read on the dictation
/// path, and belong with the rest of the app's preferences - which is also what
/// lets a test redirect them by pointing `PreferenceStore.defaults` at a
/// throwaway suite, exactly as `IsolatedPreferencesTestCase` already does.
///
/// Every read decodes from the defaults domain rather than from a cached copy.
/// A snippet list is a handful of short strings, the decode is far cheaper than
/// the dictation it precedes, and holding no state is what stops the store and
/// the Settings pane from disagreeing about what is stored.
/// See `docs/voice-snippets.md`.
final class VoiceSnippetStore {
    enum StoreError: LocalizedError {
        case recoveryRequired

        var errorDescription: String? {
            "The stored snippets could not be read. Reset them before making changes."
        }
    }

    /// Where the JSON lives. A raw key rather than an `AppPreferences` property
    /// because the value is a document this type owns the codec for.
    static let snippetsKey = "voiceSnippets"

    /// Whether the samples have ever been installed.
    ///
    /// Separate from the list itself so that deleting every sample is a decision
    /// that sticks: seeding is a one-time event on a fresh install, not a floor
    /// the app keeps restoring.
    static let samplesInstalledKey = "voiceSnippetSamplesInstalled"

    static let shared = VoiceSnippetStore()

    private let defaults: () -> UserDefaults

    /// - Parameter defaults: read at every access rather than captured, because
    ///   `PreferenceStore.defaults` is what a test swaps and a store built
    ///   before that swap must still write where the test is looking.
    init(defaults: @escaping () -> UserDefaults = { PreferenceStore.defaults }) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// Every snippet, in the order the user arranged them. This is what Settings
    /// edits.
    var snippets: [VoiceSnippet] { document?.snippets ?? [] }

    /// The snippets the router may fire.
    var activeSnippets: [VoiceSnippet] {
        snippets.filter { $0.isEnabled && $0.isValid }
    }

    /// Set when something is stored under the key but cannot be decoded - a
    /// document written by a newer build, or a value someone put there by hand.
    ///
    /// Surfaced rather than swallowed, and mutations are refused while it is
    /// set: silently replacing what could not be read is how a user's snippets
    /// disappear without anyone being told.
    var loadFailure: String? {
        guard let data = defaults().data(forKey: Self.snippetsKey) else { return nil }
        guard (try? Self.decode(data)) == nil else { return nil }
        return "The stored snippets could not be read."
    }

    var canMutate: Bool { loadFailure == nil }

    private var document: VoiceSnippetDocument? {
        guard let data = defaults().data(forKey: Self.snippetsKey) else { return .empty }
        return try? Self.decode(data)
    }

    // MARK: - Writing

    /// Replaces the whole list. Whole-document writes because the list is small
    /// and has no concurrent writer but the Settings pane.
    func replaceAll(_ snippets: [VoiceSnippet]) throws {
        guard canMutate else { throw StoreError.recoveryRequired }
        let data = try Self.encode(VoiceSnippetDocument(snippets: snippets))
        defaults().set(data, forKey: Self.snippetsKey)
    }

    func upsert(_ snippet: VoiceSnippet) throws {
        var updated = snippets
        if let index = updated.firstIndex(where: { $0.id == snippet.id }) {
            updated[index] = snippet
        } else {
            updated.append(snippet)
        }
        try replaceAll(updated)
    }

    func remove(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try replaceAll(snippets.filter { !ids.contains($0.id) })
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) throws {
        var updated = snippets
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].isEnabled = isEnabled
        try replaceAll(updated)
    }

    /// Forgets an unreadable document, which is the only repair available for a
    /// value the app cannot decode. Kept explicit - behind a button the user
    /// presses after being told - rather than done implicitly on the way past.
    func reset() {
        defaults().removeObject(forKey: Self.snippetsKey)
    }

    // MARK: - Samples

    /// The two snippets a fresh install starts with.
    ///
    /// They exist to answer "what is this pane for?" in the only way that
    /// actually lands - a working example the user can say out loud - and they
    /// are written to be edited: the signoff has a name to fill in and the
    /// template has the blank lines a real one has. Both can only fire behind
    /// the spoken-commands toggle, which is off until the user turns it on.
    static let samples: [VoiceSnippet] = [
        VoiceSnippet(
            keyword: "email signoff",
            expansion: "Best regards,\n\n[your name]"
        ),
        VoiceSnippet(
            keyword: "meeting template",
            expansion: "Attendees:\n\nAgenda:\n\nDecisions:\n\nAction items:\n"
        ),
    ]

    /// Installs the samples once, on an install that has never had them.
    ///
    /// - Returns: whether they were installed by this call, so a caller can log
    ///   it the way the starter model does.
    @discardableResult
    func installSamplesIfNeeded() -> Bool {
        guard !defaults().bool(forKey: Self.samplesInstalledKey) else { return false }
        defaults().set(true, forKey: Self.samplesInstalledKey)
        // A pre-existing list is left alone: the flag is new, the snippets may
        // not be, and appending samples underneath a list someone already built
        // would be the app adding entries they never asked for.
        guard canMutate, snippets.isEmpty else { return false }
        try? replaceAll(Self.samples)
        return true
    }

    // MARK: - Codec

    static func decode(_ data: Data) throws -> VoiceSnippetDocument {
        try JSONDecoder().decode(VoiceSnippetDocument.self, from: data)
    }

    static func encode(_ document: VoiceSnippetDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}
