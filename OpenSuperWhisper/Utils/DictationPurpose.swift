import Foundation

/// What one recording session was started for.
///
/// Two hotkeys, two purposes, and **nothing crosses between them**. That
/// separation is the whole point of the type and it is enforced structurally
/// rather than by convention:
///
/// - A `.dictation` session produces text and only text. `SpokenIntentRouter`
///   has no case that can open a browser, so no transcript captured by the
///   dictation shortcut can reach `YouTubeLatestVideoService` however it is
///   worded. Saying "open the latest YouTube video from Veritasium" into the
///   dictation key types those words, the way it always did before the command
///   existed.
/// - A `.youTubeCommand` session produces **no text at all**. It is captured by
///   its own shortcut, it is read only as a channel name, and the only thing it
///   can do is open the newest video from a channel the user allowlisted - or
///   fail and say why. Nothing is pasted, restyled, translated or expanded, and
///   there is no path from it back into the user's document.
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
}
