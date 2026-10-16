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

    /// The write a Save produces, or nil when the draft is already what the
    /// row shows and there is no original to newly keep.
    static func preparing(draft: String, on recording: Recording) -> ManualTranscriptEdit? {
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

    /// The write to hand the store, or nil when there is nothing to save.
    /// Leaves the session idle either way, which is Cancel's shape as well:
    /// discarding the draft is the whole of not writing.
    mutating func save(on recording: Recording) -> ManualTranscriptEdit? {
        guard isEditing else { return nil }
        let edit = ManualTranscriptEdit.preparing(
            draft: draftTranscription, on: recording)
        cancel()
        return edit
    }
}

enum ManualEditCommitResult: Equatable {
    case applied
    case superseded
    case failed
}
