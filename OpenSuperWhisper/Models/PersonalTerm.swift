import Foundation

/// What a dictionary entry does to the text it matches.
///
/// The four kinds are deliberately distinct rather than one "find and replace"
/// with flags, because they differ in what later stages are allowed to do to
/// the result. See `docs/personal-terms.md`.
enum PersonalTermKind: String, Codable, CaseIterable, Identifiable {
    /// A literal substitution fixing what the recognizer heard,
    /// e.g. `頂頂群` → `釘釘群`.
    case replacement

    /// A literal substitution fixing orthography rather than recognition,
    /// e.g. `k8s` → `Kubernetes`, `台北` → `臺北`.
    case preferredSpelling

    /// A substitution for a personal or product name. Behaves like a
    /// replacement, and additionally always belongs to the must-survive set a
    /// later rewriting stage has to check its output against.
    case name

    /// Text that must never be corrected: the matched span is emitted exactly
    /// as the user said it and is excluded from every later stage.
    case protect

    var id: String { rawValue }

    /// True when the entry writes its own target text over what was matched.
    /// `protect` is the only kind that does not.
    var substitutesText: Bool { self != .protect }

    var displayName: String {
        switch self {
        case .replacement: return "Replacement"
        case .preferredSpelling: return "Preferred spelling"
        case .name: return "Name"
        case .protect: return "Never correct"
        }
    }

    var explanation: String {
        switch self {
        case .replacement:
            return "Fixes what the recognizer misheard, e.g. 頂頂群 → 釘釘群."
        case .preferredSpelling:
            return "Fixes how a word is written, e.g. k8s → Kubernetes."
        case .name:
            return "A person or product name, e.g. 阿 Ken. Always kept by later stages."
        case .protect:
            return "Kept exactly as spoken, e.g. useState. Never touched by any later stage."
        }
    }
}

/// One entry in the user's personal terms dictionary.
///
/// Entries are stored as plain JSON in `terms.json` so the dictionary can be
/// read, hand-edited, backed up and copied between machines without the app.
/// Decoding is deliberately forgiving about missing optional fields for the
/// same reason - a hand-written entry with only `kind`, `match` and
/// `replacement` is valid.
struct PersonalTerm: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: PersonalTermKind
    /// The text to look for. Matched longest-first over a character scan, so it
    /// does not have to be a whitespace-delimited word.
    var match: String
    /// The text to write out, exactly as the user typed it. Unused by
    /// ``PersonalTermKind/protect``, which emits what it matched.
    var replacement: String
    /// An optional short string that must also appear somewhere in the same
    /// dictation for this entry to fire. Exists because a blindly global
    /// homophone substitution such as `在` → `再` would be catastrophic.
    var contextHint: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        kind: PersonalTermKind,
        match: String,
        replacement: String = "",
        contextHint: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.match = match
        self.replacement = replacement
        self.contextHint = contextHint
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, match, replacement, contextHint
        case isEnabled = "enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(PersonalTermKind.self, forKey: .kind)
        match = try container.decode(String.self, forKey: .match)
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        let hint = try container.decodeIfPresent(String.self, forKey: .contextHint)
        contextHint = (hint?.isEmpty ?? true) ? nil : hint
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// An entry the corrector can act on.
    ///
    /// Invalid entries are kept in the file and shown in the UI rather than
    /// dropped, so a half-finished entry is never silently deleted; they are
    /// simply skipped when correcting text.
    var isValid: Bool {
        guard !match.isEmpty else { return false }
        return kind.substitutesText ? !replacement.isEmpty : true
    }

    /// What this entry writes out when it matches `matchedText`.
    func emittedText(forMatched matchedText: String) -> String {
        kind.substitutesText ? replacement : matchedText
    }
}

/// The whole `terms.json` document.
///
/// `version` exists so a future format change can be recognised rather than
/// guessed at. Entries the current build cannot understand are dropped on load
/// instead of failing the whole file, which keeps a dictionary written by a
/// newer build usable by an older one.
struct PersonalTermsDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var terms: [PersonalTerm]

    static let empty = PersonalTermsDocument(version: currentVersion, terms: [])

    init(version: Int = currentVersion, terms: [PersonalTerm]) {
        self.version = version
        self.terms = terms
    }

    enum CodingKeys: String, CodingKey {
        case version, terms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        let decoded = try container.decodeIfPresent([FailableTerm].self, forKey: .terms) ?? []
        terms = decoded.compactMap { $0.term }
    }

    /// Lets one unreadable entry - an unknown `kind`, a missing `match` - be
    /// skipped without taking the rest of the user's dictionary with it.
    private struct FailableTerm: Decodable {
        let term: PersonalTerm?

        init(from decoder: Decoder) throws {
            term = try? PersonalTerm(from: decoder)
        }
    }
}
