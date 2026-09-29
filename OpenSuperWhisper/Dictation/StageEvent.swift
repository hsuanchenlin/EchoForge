import Foundation

/// A step the post-processing pipeline is taking, reported to the session that
/// asked for it.
///
/// `TranscriptionService.finish` calls `progress` with these instead of raising
/// a global flag. A queue transcription, a history fix, or another session's
/// finish cannot paint this session's overlay, because they either pass a no-op
/// or a different session's handler.
enum StageEvent: Equatable, Sendable {
    /// The on-device model is rewriting, translating, or applying a voice edit.
    case rewriting
    /// The spoken-intent router produced a verdict.
    case intent(SpokenIntentOutcome)
}
