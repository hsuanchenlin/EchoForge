import Foundation

/// One voice snippet: a phrase the user says, and the text it expands into.
///
/// The keyword is both the trigger and the label - there is deliberately no
/// separate name field. A snippet the user has to name twice is a snippet whose
/// chip can disagree with what they have to say to fire it, and the capsule HUD
/// shows the trigger for exactly that reason.
///
/// `expansion` is the one string in this app that is never touched by anything:
/// no rewriting, no trimming, no spacing pass. A template is typed the way it is
/// wanted, indentation and blank lines included, and comes out byte for byte.
/// See `docs/voice-snippets.md`.
struct VoiceSnippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// What the user says. Matched through ``VoiceSnippetTrigger/normalize(_:)``,
    /// so case, surrounding punctuation, run-together spaces and the Chinese
    /// script it was written in do not have to match.
    var keyword: String
    /// The text written out, exactly as it is stored here.
    var expansion: String
    var isEnabled: Bool

    init(id: UUID = UUID(), keyword: String, expansion: String, isEnabled: Bool = true) {
        self.id = id
        self.keyword = keyword
        self.expansion = expansion
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, keyword, expansion
        case isEnabled = "enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyword = try container.decode(String.self, forKey: .keyword)
        expansion = try container.decodeIfPresent(String.self, forKey: .expansion) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// A snippet the router may fire.
    ///
    /// A half-finished one is kept and shown rather than dropped - the same rule
    /// `PersonalTerm.isValid` follows - it is simply never matched. The expansion
    /// is checked unstripped: a template that is nothing but a newline is a
    /// template, while one that is the empty string has nothing to insert.
    var isValid: Bool {
        !VoiceSnippetTrigger.normalize(keyword).isEmpty && !expansion.isEmpty
    }

    /// The key this snippet is looked up by. Empty when the keyword is blank,
    /// which `isValid` has already refused.
    var triggerKey: String { VoiceSnippetTrigger.normalize(keyword) }
}

/// How a spoken phrase is compared against a snippet's keyword.
///
/// The comparison is deliberately forgiving, because every difference it folds
/// away is one a speech engine introduces on its own and none of them change
/// which snippet was asked for:
///
/// - **case**, so "Email Signoff" in Settings answers "email signoff" spoken;
/// - **surrounding punctuation**, because the pause around a command comes back
///   as a comma or a full stop;
/// - **run-together spacing**, because a transcript's spacing is the engine's
///   choice rather than the speaker's;
/// - **Traditional against Simplified**, through `ChineseScriptFolding`, so a
///   keyword typed in one script answers dictation in the other.
///
/// What it does *not* fold is anything that would let one snippet answer for
/// another: nothing is stemmed, nothing is truncated, and a normalized phrase
/// has to match a normalized keyword in full.
enum VoiceSnippetTrigger {

    /// The punctuation a speaker's pause is written back as, at either end of a
    /// phrase. It overlaps `SpokenIntentRouter`'s own separator set and is kept
    /// apart from it on purpose: that one decides whether a marker is delimited,
    /// this one decides what is not part of a keyword.
    private static let edgePunctuation: Set<Character> = [
        ":", "：", ",", "，", "、", ";", "；", ".", "。", "?", "？", "!", "！",
        "-", "–", "—", "\"", "'", "“", "”", "「", "」", "『", "』",
    ]

    /// The comparison key for `text`.
    static func normalize(_ text: String) -> String {
        let folded = String(ChineseScriptFolding.fold(text.lowercased()))
        var characters = Array(
            folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        )
        while let first = characters.first, isEdge(first) { characters.removeFirst() }
        while let last = characters.last, isEdge(last) { characters.removeLast() }
        return String(characters)
    }

    /// Whether a character is scenery around the phrase rather than part of it:
    /// the punctuation a pause became, or the space in front of it.
    private static func isEdge(_ character: Character) -> Bool {
        edgePunctuation.contains(character) || character.isWhitespace
    }
}

/// The whole stored snippet list.
///
/// `version` exists so a later format change can be recognised rather than
/// guessed at, the same reason `PersonalTermsDocument` carries one. Unlike that
/// file this one is written only by the app - it lives in the defaults domain,
/// not somewhere a user hand-edits - so it does not preserve fields it cannot
/// read.
struct VoiceSnippetDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var snippets: [VoiceSnippet]

    static let empty = VoiceSnippetDocument(snippets: [])

    init(version: Int = VoiceSnippetDocument.currentVersion, snippets: [VoiceSnippet]) {
        self.version = version
        self.snippets = snippets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? VoiceSnippetDocument.currentVersion
        snippets = try container.decodeIfPresent([VoiceSnippet].self, forKey: .snippets) ?? []
    }
}
