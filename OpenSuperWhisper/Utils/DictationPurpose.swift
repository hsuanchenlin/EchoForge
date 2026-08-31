import Foundation

/// What one recording session was started for.
///
/// One hotkey, one purpose, and **nothing crosses between them**. That
/// separation is the whole point of the type and it is enforced structurally
/// rather than by convention:
///
/// - A `.dictation` session produces text and only text. `SpokenIntentRouter`
///   has no case that can open a browser, so no transcript captured by the
///   dictation shortcut can reach `YouTubeLatestVideoService` however it is
///   worded. Saying "open the latest YouTube video from Veritasium" into the
///   dictation key types those words, the way it always did before the command
///   existed. It also cannot become a voice edit: highlighting text and
///   speaking an instruction is a different key.
/// - A `.youTubeCommand` session produces **no text at all**. It is captured by
///   its own shortcut, it is read only as a channel name, and the only thing it
///   can do is open the newest video from a channel the user allowlisted - or
///   fail and say why. Nothing is pasted, restyled, translated or expanded, and
///   there is no path from it back into the user's document.
/// - A `.selectionEdit` session produces a **rewrite of already-written text**,
///   never of the words that were just spoken. The spoken words are the
///   instruction; the selected (or clipboard) text is what is rewritten; and
///   only the rewrite is pasted. The instruction itself is never inserted.
///   See `docs/selection-edit.md`.
///
/// It is carried on `Settings` rather than read from preferences, so the
/// decision belongs to the session that heard the words: a queued file, a
/// regenerate from history and the Ask panel's own follow-up are all
/// `.dictation` and cannot become anything else halfway through.
/// See `docs/youtube-latest-video.md`.
enum DictationPurpose: Equatable, Sendable {
    /// The ordinary dictation shortcut: words for whatever app the user is in.
    case dictation
    /// The YouTube command shortcut: a channel name, and nothing to insert.
    case youTubeCommand
    /// The voice-edit shortcut: a spoken instruction applied to selected or
    /// clipboard text, and the rewrite pasted in its place.
    case selectionEdit
}
