import Foundation

/// What became of one spoken "open the latest video from …".
///
/// Two cases and no third: it opened, or it did not and the user is told why in
/// a sentence they can act on. There is deliberately no "partly worked" - a
/// command that cannot be carried out exactly as spoken does nothing at all.
enum YouTubeLatestVideoReport: Equatable, Sendable {
    /// The video is open in Chrome. The channel is named as the user's own list
    /// names it, and the title is what the feed called the video. `match` is how
    /// the spoken words reached that channel, carried so the one case a model
    /// took part in says so out loud.
    case opened(channel: String, title: String, match: YouTubeChannelMatchSource)
    /// Nothing was opened. `reason` classifies it for history and for tests,
    /// `message` is the sentence for a surface with room, and `shortMessage` the
    /// few words a dictation overlay has.
    ///
    /// The class is carried rather than derived from the message because the
    /// message is copy - free to be reworded without relabelling every row a
    /// user already has - and because a surface that grouped failures by
    /// matching on their wording would be a surface that mis-groups them the
    /// first time one is rewritten.
    case refused(reason: YouTubeCommandRefusal, message: String, shortMessage: String)

    var didOpen: Bool {
        if case .opened = self { return true }
        return false
    }

    /// The few words a dictation overlay has room for, or nil when the command
    /// opened.
    var shortMessage: String? {
        guard case .refused(_, _, let short) = self else { return nil }
        return short
    }

    /// The full sentence in both cases, for the log and for the VoiceOver
    /// announcement - the one surface that can carry a whole sentence while the
    /// user is looking at another app.
    var spokenSummary: String {
        switch self {
        case .opened(let channel, let title, let match):
            let opened = title.isEmpty
                ? "Opened the latest video from \(channel) in Chrome."
                : "Opened “\(title)” from \(channel) in Chrome."
            // Disclosed at the moment it happened, not only in Settings: the
            // one thing a user cannot see from the result is that a model chose
            // which of their channels this was.
            guard let disclosure = match.disclosure else { return opened }
            return "\(opened) \(disclosure)"
        case .refused(_, let message, _):
            return message
        }
    }
}

extension YouTubeLatestVideoReport {

    /// The refusal a resolution determines on its own, before anything is
    /// fetched and before Chrome is asked for anything - or nil for an
    /// allowlisted channel, which needs the feed and the browser to know.
    ///
    /// Pure and separate from `run` so the two callers cannot disagree: the
    /// service answers with it, and history writes it the moment the words are
    /// stored, which is what keeps the row the user is most likely to be
    /// reading - "that name is not in your list" - correct from the instant it
    /// appears rather than after a round trip that was never going to happen.
    static func refusal(for resolution: YouTubeChannelResolution) -> YouTubeLatestVideoReport? {
        switch resolution {
        case .allowlisted:
            return nil
        case .unknown(let spoken):
            // A marker with nothing behind it, or nothing heard at all: there
            // was never a name to look up, which is a different thing to tell
            // somebody than "that channel is not in your list".
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .refused(
                    reason: .notRecognised,
                    message: "No channel name was heard, so nothing was opened. Hold the YouTube command shortcut and say a channel name from Settings → Dictionary & Snippets → YouTube Channels.",
                    shortMessage: YouTubeCommandRefusal.notRecognised.shortLabel
                )
            }
            return .refused(
                reason: .channelUnknown,
                message: "No allowlisted YouTube channel answers to “\(spoken)”. Add it in Settings → Dictionary & Snippets → YouTube Channels, or add that spelling as a spoken name on the channel you meant.",
                shortMessage: "Channel not in your list"
            )
        case .ambiguous(let spoken, let matches):
            return .refused(
                reason: .channelAmbiguous,
                message: "“\(spoken)” answers for more than one channel (\(YouTubeChannelHandle.format(all: matches).joined(separator: ", "))). Give them different spoken names in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "Two channels answer to that"
            )
        case .disabled:
            return .refused(
                reason: .commandDisabled,
                message: "The YouTube command is switched off, so nothing was opened. Turn it on in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "YouTube command is off"
            )
        }
    }
}

extension YouTubeLatestVideoReport {

    /// The refusal for a miss with nothing to offer instead: the allowlist holds
    /// no channel a command could reach.
    ///
    /// Its own sentence rather than `channelUnknown`'s because the fix is a
    /// different one - "add that spelling to the channel you meant" is not
    /// advice anybody can act on with no channels stored.
    static func noChannelsConfigured(spoken: String) -> YouTubeLatestVideoReport {
        .refused(
            reason: .noChannelsConfigured,
            message: "Nothing was opened: “\(spoken)” did not match anything, and there is no YouTube channel in your list yet. Add one in Settings → Dictionary & Snippets → YouTube Channels.",
            shortMessage: YouTubeCommandRefusal.noChannelsConfigured.shortLabel
        )
    }

    /// The refusal for a picker the user closed without choosing.
    ///
    /// What it advises is whichever fix the cause actually has. An unknown name
    /// is still not a stored spelling, and adding it is what opens directly
    /// next time. An ambiguous one already is a stored spelling - of two rows -
    /// so that advice cannot fix anything; giving the rows different spoken
    /// names can.
    static func pickerCancelled(
        spoken: String, cause: YouTubeChannelPickerRequest.Cause
    ) -> YouTubeLatestVideoReport {
        let message: String
        switch cause {
        case .unknown:
            message = "You closed the channel picker without choosing, so nothing was opened. “\(spoken)” is still not one of your stored spellings - add it as a spoken name in Settings → Dictionary & Snippets → YouTube Channels to have it open directly."
        case .ambiguous(let matches):
            message = "You closed the channel picker without choosing, so nothing was opened. “\(spoken)” still answers to more than one channel (\(YouTubeChannelHandle.format(all: matches).joined(separator: ", "))) - give them different spoken names in Settings → Dictionary & Snippets → YouTube Channels to have one open directly."
        }
        return .refused(
            reason: .pickerCancelled,
            message: message,
            shortMessage: YouTubeCommandRefusal.pickerCancelled.shortLabel
        )
    }
}

/// Carries out a resolved spoken command: newest entry from the channel's feed,
/// validated, opened in Chrome.
///
/// It is a struct over two seams rather than a singleton so the whole path can be
/// tested end to end - hostile feed in, nothing opened out - and so the only
/// production wiring is the one place that builds it with the real fetcher and
/// the real opener.
struct YouTubeLatestVideoService: Sendable {
    private let fetcher: YouTubeFeedFetching
    private let opener: BrowserOpening

    init(fetcher: YouTubeFeedFetching, opener: BrowserOpening) {
        self.fetcher = fetcher
        self.opener = opener
    }

    /// The service the app runs with.
    static let live = YouTubeLatestVideoService(
        fetcher: YouTubeFeedFetcher(), opener: ChromeBrowserOpener()
    )

    /// Runs whatever the router resolved.
    ///
    /// The unknown and ambiguous cases are answered here rather than earlier
    /// because this is where the message belongs: they are the two outcomes that
    /// look like a failure to the user and are in fact the allowlist doing its
    /// job, and both must reach a surface instead of being dropped silently.
    func run(_ resolution: YouTubeChannelResolution) async -> YouTubeLatestVideoReport {
        if let refusal = YouTubeLatestVideoReport.refusal(for: resolution) { return refusal }
        guard case .allowlisted(let channel, let match) = resolution else {
            // Unreachable: `refusal(for:)` answers every other case. Written out
            // so a case added to the resolution without a refusal beside it
            // fails closed here rather than opening something.
            return .refused(
                reason: .notRecognised,
                message: "That command could not be read, so nothing was opened.",
                shortMessage: YouTubeCommandRefusal.notRecognised.shortLabel
            )
        }
        return await open(latestFrom: channel, match: match)
    }

    private func open(
        latestFrom channel: YouTubeChannel, match: YouTubeChannelMatchSource
    ) async -> YouTubeLatestVideoReport {
        guard let feedURL = YouTubeFeedEndpoint.url(forChannelID: channel.channelID) else {
            // Only reachable for a row stored before the id was validated, which
            // is why it is a message about the id rather than an assertion.
            return .refused(
                reason: .channelIDUnusable,
                message: "\(channel.handle) has no usable channel ID, so nothing was opened. Fix it in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "That channel ID is not valid"
            )
        }

        let video: YouTubeVideo
        do {
            let data = try await fetcher.fetch(feedURL)
            video = try YouTubeFeedParser.newestVideo(in: data)
        } catch let error as YouTubeFeedError {
            return .refused(
                reason: error.refusal,
                message: error.errorDescription ?? error.shortMessage,
                shortMessage: error.shortMessage
            )
        } catch {
            return .refused(
                reason: YouTubeFeedError.unreachable.refusal,
                message: YouTubeFeedError.unreachable.errorDescription ?? "",
                shortMessage: YouTubeFeedError.unreachable.shortMessage
            )
        }

        do {
            try await opener.openInNewTab(video.url)
        } catch let error as BrowserOpenError {
            return .refused(
                reason: .browserUnavailable,
                message: error.errorDescription ?? error.shortMessage,
                shortMessage: error.shortMessage
            )
        } catch {
            let failure = BrowserOpenError.launchFailed(error.localizedDescription)
            return .refused(
                reason: .browserUnavailable,
                message: failure.errorDescription ?? failure.shortMessage,
                shortMessage: failure.shortMessage
            )
        }

        // The handle form, because this string is the channel *named back* to
        // the user - it reaches the overlay, the VoiceOver announcement and the
        // History row, and never a lookup. See `YouTubeChannelHandle`.
        return .opened(channel: channel.handle, title: video.title, match: match)
    }
}
