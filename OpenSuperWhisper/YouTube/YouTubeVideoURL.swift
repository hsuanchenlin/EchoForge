import Foundation

/// The check between a channel's feed and the browser.
///
/// This is the security boundary of the feature, the way `UpdateManifest` is the
/// updater's: everything above it decided *which channel*, and this decides that
/// what comes back is a YouTube video link and not something a feed said was
/// one. It is written as a refusal list with reasons rather than a regular
/// expression because every rule here has a story - and because the thing on the
/// other side of it is "open this in the user's browser".
///
/// Nothing is repaired. A link that is not already a valid HTTPS YouTube video
/// URL is refused, never rewritten into one: a URL the app had to fix before it
/// could be opened is a URL nobody published.
enum YouTubeVideoURL {

    /// The only hosts a video may live on. `youtu.be` is YouTube's own share
    /// domain and comes back in real feeds, so refusing it would refuse legitimate
    /// links; everything else - including any host that merely *ends* with one of
    /// these, such as `youtube.com.example.net` - is refused by the exact-match
    /// comparison below.
    static let allowedHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "www.youtu.be",
    ]

    /// The video id alphabet YouTube publishes: 11 characters of URL-safe base64.
    static func isValidVideoID(_ candidate: String) -> Bool {
        guard candidate.count == 11 else { return false }
        return candidate.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    /// The validated URL and the video it names, or nil.
    struct Video: Equatable, Sendable {
        let url: URL
        let videoID: String
    }

    /// Validates one link from a feed.
    ///
    /// In order: it has to parse, be HTTPS, carry no credentials, sit on an
    /// allowlisted host, and name a video the way YouTube names one - `/watch?v=`,
    /// a `youtu.be/` path, or `/shorts/`. A query is allowed because a real feed
    /// link carries one (`?v=`), but nothing in it is trusted beyond the id.
    static func validate(_ candidate: String) -> Video? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }

        guard components.scheme?.lowercased() == "https" else { return nil }
        // A URL carrying a user name or a password is not a video link; it is a
        // link shaped to make the host look like something else in a UI.
        guard components.user == nil, components.password == nil else { return nil }
        guard let host = components.host?.lowercased(), allowedHosts.contains(host) else {
            return nil
        }
        guard components.port == nil else { return nil }

        guard let videoID = videoID(host: host, components: components),
              isValidVideoID(videoID) else { return nil }

        // Rebuilt from the parts that were checked rather than passed through as
        // written, so nothing that was ignored above - a fragment, extra query
        // items, a stray path segment - reaches the browser.
        guard let url = canonicalURL(forVideoID: videoID) else { return nil }
        return Video(url: url, videoID: videoID)
    }

    /// The canonical watch URL for an id this app has already validated.
    static func canonicalURL(forVideoID videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    private static func videoID(host: String, components: URLComponents) -> String? {
        let path = components.path.split(separator: "/").map(String.init)

        if host == "youtu.be" || host == "www.youtu.be" {
            // https://youtu.be/<id>
            return path.count == 1 ? path[0] : nil
        }
        if path == ["watch"] {
            return components.queryItems?.first { $0.name == "v" }?.value
        }
        if path.count == 2, path[0] == "shorts" || path[0] == "live" {
            return path[1]
        }
        return nil
    }
}
