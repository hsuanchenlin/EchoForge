import Foundation

/// Reads a transcript that was captured by the **YouTube command hotkey** and
/// says which allowlisted channel it named.
///
/// It is a separate router from `SpokenIntentRouter` on purpose, and the
/// separation is the security model of the feature restated in types. That
/// router reads dictations - words on their way into the user's document - and
/// it has no case that can open anything. This one reads only what its own
/// shortcut captured, and its answer can only ever be a channel from the user's
/// own list. Neither can produce the other's result, so no wording of any
/// dictation can open a browser and no press of this key can paste text.
/// See `DictationPurpose` and `docs/youtube-latest-video.md`.
///
/// Because the shortcut already said what the utterance is for, the marker is
/// **optional** here: pressing the key and saying "Valley 101" is the whole
/// command. A marker is still accepted and stripped, so the sentence a user
/// already has the habit of saying keeps working, and so does the Chinese
/// spelling. That is the one behavioural difference from the old
/// dictation-borne command, and it exists because a dedicated key removes the
/// only thing the marker was ever there for: telling a command apart from a
/// sentence somebody was writing.
enum YouTubeCommandRouter {

    /// What this utterance names.
    ///
    /// - Parameters:
    ///   - transcript: the deterministic pipeline's output. Script
    ///     normalization, personal terms and CJK spacing have all run, which is
    ///     what lets a user's own spelling of a channel name match what they
    ///     stored - and why every CJK marker is listed in both scripts.
    ///   - channels: the user's allowlist. An empty one is a real answer, not a
    ///     missing input: it means the command is on and nothing has been
    ///     allowlisted yet, which the user is told.
    static func resolve(
        _ transcript: String, channels: YouTubeChannelAllowlist
    ) -> YouTubeChannelResolution {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown(spoken: "") }

        let spoken = strippingMarker(from: trimmed) ?? trimmed
        // "Open the latest YouTube video from" and then nothing: the marker was
        // said and no channel was. Quoting the whole utterance back is the only
        // message that tells the user what the app heard.
        guard !spoken.isEmpty else { return .unknown(spoken: trimmed) }

        return channels.resolve(spokenName: spoken)
    }

    /// What follows a recognised marker, or nil when the utterance did not open
    /// with one.
    ///
    /// The marker table is `SpokenIntentGrammar.openLatestVideoMarkers`, shared
    /// with nothing else now that the dictation router no longer reads it, and
    /// matched ignoring internal whitespace because a transcript writes
    /// "打開 YouTube 最新影片" or "打開YouTube最新影片" for the same words
    /// depending on the engine.
    private static func strippingMarker(from text: String) -> String? {
        for marker in SpokenIntentGrammar.openLatestVideoMarkers {
            guard let rest = SpokenIntentRouter.remainderIgnoringInternalWhitespace(
                after: marker, in: text
            ) else { continue }
            return SpokenIntentRouter.strippingLeadingSeparators(rest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
