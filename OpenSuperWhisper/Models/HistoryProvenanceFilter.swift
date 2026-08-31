import Foundation

/// What the history list is showing.
///
/// A pure value rather than a set of toggles, because the question a user brings
/// to this control is singular - "show me the commands that did not open" - and
/// because the rows it selects have to be selected in SQL: history is paged, so
/// filtering the page that happens to be loaded would silently hide older rows
/// that match. `RecordingStore` turns `kinds` into the query's predicate.
///
/// `.all` carries `nil` rather than every kind, so the unfiltered query keeps
/// the shape it always had and a kind added later is visible under `.all`
/// without anyone remembering to add it here.
enum HistoryProvenanceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case dictation
    case ask
    case youTubeCommandOpened
    case youTubeCommandNotOpened
    case selectionEdit
    case fileTranscription
    case unknown

    var id: String { rawValue }

    /// The label on the control. Kept beside the kinds it selects so the two
    /// cannot drift apart.
    var title: String {
        switch self {
        case .all: return "All"
        case .dictation: return RecordingProvenanceKind.dictation.label
        case .ask: return RecordingProvenanceKind.ask.label
        case .youTubeCommandOpened: return RecordingProvenanceKind.youTubeCommandOpened.label
        case .youTubeCommandNotOpened: return RecordingProvenanceKind.youTubeCommandNotOpened.label
        case .selectionEdit: return RecordingProvenanceKind.selectionEdit.label
        case .fileTranscription: return RecordingProvenanceKind.fileTranscription.label
        case .unknown: return RecordingProvenanceKind.unknown.label
        }
    }

    /// The same choice on the collapsed control, where it shares one row with
    /// the search field in a 450 pt window.
    ///
    /// Shorter than `title` for the two command outcomes only, and only there:
    /// the menu that is open in front of the user spells them out in full, and
    /// the collapsed label sits beside a filter icon that already says what kind
    /// of thing it is naming.
    var menuLabel: String {
        switch self {
        case .youTubeCommandOpened: return "Opened"
        case .youTubeCommandNotOpened: return "Not opened"
        case .selectionEdit: return "Voice edit"
        case .fileTranscription: return "Files"
        case .unknown: return "Older"
        default: return title
        }
    }

    /// The kinds this filter admits, or nil for "every row".
    ///
    /// `.unknown` admits a row whose stored kind is `unknown` **and** a row with
    /// nothing stored at all, which is every row made before provenance existed.
    /// `RecordingStore` is where that NULL is turned into a match, because only
    /// the query can see it.
    var kinds: Set<RecordingProvenanceKind>? {
        switch self {
        case .all: return nil
        case .dictation: return [.dictation]
        case .ask: return [.ask]
        case .youTubeCommandOpened: return [.youTubeCommandOpened]
        case .youTubeCommandNotOpened: return [.youTubeCommandNotOpened]
        case .selectionEdit: return [.selectionEdit]
        case .fileTranscription: return [.fileTranscription]
        case .unknown: return [.unknown]
        }
    }

    /// Whether rows with no provenance stored - everything recorded before this
    /// existed - are included.
    var includesUnrecorded: Bool {
        switch self {
        case .all, .unknown: return true
        default: return false
        }
    }
}
