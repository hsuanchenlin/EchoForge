import Foundation

/// What the transcription queue's loop does with the row the store just handed
/// it.
///
/// The rule lives out here rather than inside the loop because getting it wrong
/// is silent and expensive. `RecordingStore.getNextPendingRecording` counts
/// `.pending`, `.converting` **and** `.transcribing` as "still to do", so a pass
/// that ends without writing the row out of those three statuses is handed the
/// same row again on the very next turn - and runs the engine over it a second
/// time.
///
/// That is not hypothetical: cancelling a queued recording only added its id to
/// a set, `processRecording` returned early without touching the row, and the
/// loop immediately re-transcribed the recording the user had just cancelled.
/// On the cloud engine that is a second paid request the user never asked for;
/// on any engine it is the whole transcription again, in front of every
/// dictation queued behind it and with `isTranscriptionBusy` refusing live
/// dictation for the duration.
///
/// It is a decision about **progress**, not about identity. A row legitimately
/// comes round again - the user presses regenerate on the recording that just
/// finished while the loop is still draining - and that pass settled it, so it
/// is processed rather than abandoned.
enum TranscriptionQueueStep: Equatable {
    /// Transcribe this recording.
    case process(UUID)

    /// The previous pass handed this same row back without settling it. Running
    /// the engine again would repeat work already done, so the row is written
    /// out of the queue instead.
    case abandon(UUID)

    /// Nothing more to do. The loop returns and the queue stops being busy,
    /// which is what lets the next dictation run.
    case finished

    /// What the previous turn of the loop did.
    struct Previous: Equatable {
        let id: UUID

        /// Whether that turn left the row out of the queue's three pending
        /// statuses - completed, failed, or deleted.
        let settled: Bool

        /// Whether that turn was itself an abandonment. A row that comes back
        /// *after* the queue tried to write it out is a database that is not
        /// accepting the write, and turning the loop again cannot fix it.
        let abandoned: Bool

        init(id: UUID, settled: Bool, abandoned: Bool = false) {
            self.id = id
            self.settled = settled
            self.abandoned = abandoned
        }
    }

    static func next(_ next: UUID?, after previous: Previous?) -> TranscriptionQueueStep {
        guard let next else { return .finished }
        guard let previous, previous.id == next, !previous.settled else { return .process(next) }
        // Already abandoned once and still pending: stop rather than spin. The
        // loop exiting is what matters - a queue that never returns stays busy
        // for ever and every later dictation is refused.
        return previous.abandoned ? .finished : .abandon(next)
    }
}
