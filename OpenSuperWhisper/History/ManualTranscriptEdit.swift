import Foundation

/// What Save on a history card writes: the typed transcript, and the original
/// to keep when this row has none yet.
///
/// "Show original" and "Compare" already read `rawTranscription`. A first
/// manual edit that overwrote the only copy would leave those disclosures
/// with nothing to show, so a row whose raw side is missing keeps the text
/// the card currently shows as that original. A later edit, or a row
/// post-processing or Fix with AI already filled, leaves that copy alone -
/// it is the only record of what was actually said.
struct ManualTranscriptEdit: Equatable, Sendable {
    let transcription: String
    /// Set when the row had no original worth keeping. Nil means leave
    /// `rawTranscription` as it is.
    let preservedOriginal: String?

    /// The write a Save produces, or nil when there is nothing to write: the
    /// draft is empty, or it is already what the row shows and there is no
    /// original to newly keep.
    ///
    /// An empty save would store a blank transcript, which the card draws as
    /// "No speech detected" and which hides Edit, so the words could not be
    /// typed back.
    static func preparing(draft: String, on recording: Recording) -> ManualTranscriptEdit? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let preservedOriginal = Self.originalToPreserve(on: recording)
        if draft == recording.transcription, preservedOriginal == nil {
            return nil
        }
        return ManualTranscriptEdit(
            transcription: draft, preservedOriginal: preservedOriginal)
    }

    /// The current transcript, when this row has no original stored yet.
    static func originalToPreserve(on recording: Recording) -> String? {
        if let raw = recording.rawTranscription, !raw.isEmpty { return nil }
        return recording.transcription
    }
}

/// Card-local editor state: a draft over one row, or idle.
///
/// Local to the card rather than app-lifetime, unlike "Fix with AI": typing
/// is not a model call that outlives a scroll, and tearing the card down
/// while the user is mid-sentence is the same as Cancel.
struct HistoryTranscriptEditing: Equatable, Sendable {
    var isEditing = false
    var draftTranscription = ""

    mutating func begin(transcript: String) {
        guard !isEditing else { return }
        draftTranscription = transcript
        isEditing = true
    }

    mutating func cancel() {
        draftTranscription = ""
        isEditing = false
    }

    /// Whether Save should be offered. An empty draft is refused rather than
    /// stored as a blank transcript.
    var canSave: Bool {
        isEditing
            && !draftTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The write to hand the store, or nil when there is nothing to save.
    /// Leaves the session open: a failed write must not drop the draft, and an
    /// empty draft is refused rather than stored.
    func save(on recording: Recording) -> ManualTranscriptEdit? {
        guard canSave else { return nil }
        return ManualTranscriptEdit.preparing(
            draft: draftTranscription, on: recording)
    }
}

enum ManualEditCommitResult: Equatable {
    case applied
    case superseded
    case failed

    /// Whether the inline editor should close. A failed write leaves it open
    /// so the typed text is still there to retry.
    var closesEditor: Bool {
        switch self {
        case .applied, .superseded:
            return true
        case .failed:
            return false
        }
    }
}
