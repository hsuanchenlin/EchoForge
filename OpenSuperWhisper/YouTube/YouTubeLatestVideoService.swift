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
    /// Nothing was opened. `message` is the sentence for a surface with room and
    /// `shortMessage` the few words a dictation overlay has.
    case refused(message: String, shortMessage: String)

    var didOpen: Bool {
        if case .opened = self { return true }
        return false
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
        case .refused(let message, _):
            return message
        }
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
        switch resolution {
        case .unknown(let spoken):
            return .refused(
                message: "No allowlisted YouTube channel answers to “\(spoken)”. Add it in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "Channel not in your list"
            )
        case .ambiguous(let spoken, let matches):
            return .refused(
                message: "“\(spoken)” answers for more than one channel (\(matches.joined(separator: ", "))). Give them different spoken names in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "Two channels answer to that"
            )
        case .disabled:
            return .refused(
                message: "The YouTube command is switched off, so nothing was opened. Turn it on in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "YouTube command is off"
            )
        case .allowlisted(let channel, let match):
            return await open(latestFrom: channel, match: match)
        }
    }

    private func open(
        latestFrom channel: YouTubeChannel, match: YouTubeChannelMatchSource
    ) async -> YouTubeLatestVideoReport {
        guard let feedURL = YouTubeFeedEndpoint.url(forChannelID: channel.channelID) else {
            // Only reachable for a row stored before the id was validated, which
            // is why it is a message about the id rather than an assertion.
            return .refused(
                message: "“\(channel.displayName)” has no usable channel ID, so nothing was opened. Fix it in Settings → Dictionary & Snippets → YouTube Channels.",
                shortMessage: "That channel ID is not valid"
            )
        }

        let video: YouTubeVideo
        do {
            let data = try await fetcher.fetch(feedURL)
            video = try YouTubeFeedParser.newestVideo(in: data)
        } catch let error as YouTubeFeedError {
            return .refused(
                message: error.errorDescription ?? error.shortMessage,
                shortMessage: error.shortMessage
            )
        } catch {
            return .refused(
                message: YouTubeFeedError.unreachable.errorDescription ?? "",
                shortMessage: YouTubeFeedError.unreachable.shortMessage
            )
        }

        do {
            try await opener.openInNewTab(video.url)
        } catch let error as BrowserOpenError {
            return .refused(
                message: error.errorDescription ?? error.shortMessage,
                shortMessage: error.shortMessage
            )
        } catch {
            let failure = BrowserOpenError.launchFailed(error.localizedDescription)
            return .refused(
                message: failure.errorDescription ?? failure.shortMessage,
                shortMessage: failure.shortMessage
            )
        }

        return .opened(channel: channel.displayName, title: video.title, match: match)
    }
}
