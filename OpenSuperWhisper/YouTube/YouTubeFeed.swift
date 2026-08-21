import Foundation

/// One video, as a channel's feed describes it.
struct YouTubeVideo: Equatable, Sendable {
    let videoID: String
    let title: String
    let url: URL
    /// When the feed says it was published. Optional because an entry without a
    /// readable date is still an entry; see `YouTubeFeedParser.newestVideo`.
    let publishedAt: Date?
}

/// Everything that can go wrong between asking for a channel's feed and having a
/// video to open, each with the sentence the user is told.
///
/// Written as one type so every failure is named once and none of them can be
/// reported as "something went wrong": each of these has a different thing the
/// user would do about it.
enum YouTubeFeedError: LocalizedError, Equatable {
    /// The request never got an answer: offline, DNS, a timeout.
    case unreachable
    /// YouTube answered, but not with a feed.
    case httpStatus(Int)
    /// A feed larger than anything YouTube publishes for a channel.
    case tooLarge
    /// The bytes are not the feed this app knows how to read - or are a document
    /// carrying entity declarations, which a channel feed does not have and an
    /// attack on an XML parser does.
    case malformed
    /// A real feed with no entries at all: a channel that has published nothing.
    case noEntries
    /// Entries, but not one of them carried a link this app will open.
    case noUsableVideo

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Could not reach YouTube to look up that channel's latest video. Check your connection and try again."
        case .httpStatus(let code):
            return "YouTube answered with HTTP \(code) for that channel. Check the channel ID in Settings → Dictionary & Snippets → YouTube Channels."
        case .tooLarge:
            return "That channel's feed was too large to read, so nothing was opened."
        case .malformed:
            return "That channel's feed could not be read, so nothing was opened."
        case .noEntries:
            return "That channel's feed lists no videos yet, so nothing was opened."
        case .noUsableVideo:
            return "That channel's feed carried no YouTube video link, so nothing was opened."
        }
    }

    /// The same failure in the few words a dictation overlay has room for. The
    /// same division `CloudRequestError.shortMessage` makes, and for the same
    /// surfaces.
    var shortMessage: String {
        switch self {
        case .unreachable: return "Could not reach YouTube"
        case .httpStatus: return "YouTube refused that channel"
        case .tooLarge, .malformed: return "Feed could not be read"
        case .noEntries: return "That channel has no videos"
        case .noUsableVideo: return "No video link in that feed"
        }
    }
}

/// Where a channel's videos are listed.
///
/// YouTube's documented per-channel Atom feed, and the only endpoint this
/// feature knows. It is a static, unauthenticated document: no API key, no
/// session, no cookies, and nothing about the user goes with the request beyond
/// the channel id they typed in themselves.
enum YouTubeFeedEndpoint {
    static let host = "www.youtube.com"
    static let path = "/feeds/videos.xml"

    /// The feed URL for a channel id, or nil when the id is not one.
    static func url(forChannelID channelID: String) -> URL? {
        guard YouTubeChannelID.isValid(channelID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
        return components.url
    }
}

/// Reads a channel feed and picks the newest video out of it.
///
/// The parser is hostile-input code by definition - the bytes come off the
/// network and end in something being opened in a browser - so it is written to
/// refuse rather than to cope:
///
/// - **No entity declarations.** A channel feed has none; a document that
///   declares one is either not this feed or is an attack on the parser, and
///   both are answered the same way.
/// - **No external entities**, so nothing in the document can make the parser
///   fetch or read anything.
/// - **Bounded**, in bytes, in entries and in the length of any one value, so a
///   feed cannot cost more memory than a feed is worth.
/// - **Nothing is repaired.** An entry whose link is not a YouTube video URL is
///   dropped, never rewritten from a neighbouring field: guessing a URL out of a
///   document that just failed its own check is how the wrong page gets opened.
enum YouTubeFeedParser {

    /// The largest feed accepted. YouTube's own is tens of kilobytes; a megabyte
    /// is generous by an order of magnitude and still bounded.
    static let maximumFeedBytes = 1_048_576

    /// How many entries are read before the rest are ignored. The feed publishes
    /// 15; the newest is what this feature wants.
    static let maximumEntries = 100

    /// The newest video in `data`.
    ///
    /// "Newest" is the largest `published` date, not the first entry: the feed
    /// happens to arrive newest-first, and depending on that would make this
    /// answer depend on YouTube's ordering rather than on the dates it states.
    /// Entries without a readable date are used only when no entry has one, in
    /// which case document order is all there is to go on.
    static func newestVideo(in data: Data) throws -> YouTubeVideo {
        guard data.count <= maximumFeedBytes else { throw YouTubeFeedError.tooLarge }
        // Before the parser sees it at all: a channel feed has no document type
        // declaration, so one is either not this feed or is the front half of an
        // attack on an XML parser. Refusing the bytes is cheaper and more certain
        // than relying on a parser to decline each of the things a DTD can ask
        // for - and `XMLParser` does not report every declaration to its
        // delegate, which is exactly the gap this closes.
        guard !prologDeclaresDocumentType(data) else { throw YouTubeFeedError.malformed }

        let document = try parse(data)
        guard document.sawAnyEntry else { throw YouTubeFeedError.noEntries }
        guard !document.videos.isEmpty else { throw YouTubeFeedError.noUsableVideo }

        let dated = document.videos.filter { $0.publishedAt != nil }
        guard !dated.isEmpty else { return document.videos[0] }
        // `max(by:)` on a strict `<` keeps the earliest of equal dates, which is
        // the first in document order - the same answer a feed that states no
        // dates gives.
        return dated.max { left, right in
            left.publishedAt! < right.publishedAt!
        }!
    }

    // MARK: - The prolog

    /// Whether the document's prolog carries a `<!DOCTYPE …>`.
    ///
    /// A document type declaration can only appear before the root element, so
    /// the scan stops at the first element start - which is what keeps a title
    /// containing the characters "<!DOCTYPE" from being mistaken for one.
    /// Processing instructions and comments are stepped over, since both are
    /// ordinary things to find in front of a feed.
    static func prologDeclaresDocumentType(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(maximumPrologBytes))
        let openAngle = UInt8(ascii: "<")
        var index = 0

        while index < bytes.count {
            guard bytes[index] == openAngle else {
                index += 1
                continue
            }
            guard index + 1 < bytes.count else { return false }

            switch bytes[index + 1] {
            case UInt8(ascii: "?"):
                guard let end = range(of: Array("?>".utf8), in: bytes, from: index + 2) else {
                    return false
                }
                index = end
            case UInt8(ascii: "!"):
                if matches(Array("<!--".utf8), in: bytes, at: index) {
                    guard let end = range(of: Array("-->".utf8), in: bytes, from: index + 4) else {
                        return false
                    }
                    index = end
                    continue
                }
                return matches(Array("<!DOCTYPE".utf8), in: bytes, at: index, caseInsensitive: true)
            default:
                // The root element started, so the prolog is over.
                return false
            }
        }
        return false
    }

    /// How far into the bytes the prolog is looked for. A prolog is a line or
    /// two; the cap is what stops a document made entirely of comments from
    /// turning this into a scan of the whole feed.
    static let maximumPrologBytes = 65_536

    private static func matches(
        _ needle: [UInt8], in bytes: [UInt8], at offset: Int, caseInsensitive: Bool = false
    ) -> Bool {
        guard offset + needle.count <= bytes.count else { return false }
        for (position, expected) in needle.enumerated() {
            let found = bytes[offset + position]
            if found == expected { continue }
            guard caseInsensitive, lowercased(found) == lowercased(expected) else { return false }
        }
        return true
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    /// The index just past the first occurrence of `needle` at or after `from`.
    private static func range(of needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from < bytes.count else { return nil }
        var index = from
        while index + needle.count <= bytes.count {
            if matches(needle, in: bytes, at: index) { return index + needle.count }
            index += 1
        }
        return nil
    }

    // MARK: - Parsing

    private struct Document {
        var videos: [YouTubeVideo] = []
        /// Whether the feed had entries at all, which is what tells "a channel
        /// with no videos" apart from "a feed whose links were all refused".
        var sawAnyEntry = false
    }

    private static func parse(_ data: Data) throws -> Document {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        guard parser.parse(), !delegate.didRefuse else { throw YouTubeFeedError.malformed }
        return delegate.document
    }

    private final class FeedDelegate: NSObject, XMLParserDelegate {
        var document = Document()
        /// Set when the document itself is refused - an entity declaration - as
        /// opposed to failing to parse. `XMLParser` has no way to stop with a
        /// reason of our own, so the flag carries it out.
        var didRefuse = false

        private static let maximumValueCharacters = 4096

        private var inEntry = false
        private var currentTitle = ""
        private var currentPublished = ""
        private var currentLink: String?
        private var collecting: String?

        private static let iso8601 = ISO8601DateFormatter()
        private static let iso8601Fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func parser(
            _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
        ) {
            refuse(parser)
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            refuse(parser)
        }

        func parser(
            _ parser: XMLParser,
            foundUnparsedEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?,
            notationName: String?
        ) {
            refuse(parser)
        }

        private func refuse(_ parser: XMLParser) {
            didRefuse = true
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "entry":
                inEntry = true
                currentTitle = ""
                currentPublished = ""
                currentLink = nil
            case "title", "published":
                // Only inside an entry: a feed has a title of its own, and the
                // channel's name is not a video's.
                collecting = inEntry ? elementName : nil
            case "link":
                collecting = nil
                // The alternate link is the video page. `rel` is absent on some
                // generators and defaults to "alternate" in Atom, so a missing
                // one is accepted and anything else - "self", "related" - is not.
                guard inEntry, currentLink == nil else { return }
                guard (attributes["rel"] ?? "alternate") == "alternate" else { return }
                currentLink = attributes["href"]
            default:
                collecting = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let collecting else { return }
            switch collecting {
            case "title":
                append(string, to: &currentTitle)
            case "published":
                append(string, to: &currentPublished)
            default:
                break
            }
        }

        /// Appends up to the cap and no further. `XMLParser` hands over a value
        /// in chunks of its own choosing, so the truncation is applied after the
        /// append rather than before it - a single chunk can be the whole
        /// hundred kilobytes a hostile feed sent.
        private func append(_ string: String, to value: inout String) {
            guard value.count < Self.maximumValueCharacters else { return }
            value.append(string)
            if value.count > Self.maximumValueCharacters {
                value = String(value.prefix(Self.maximumValueCharacters))
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer { collecting = nil }
            guard elementName == "entry", inEntry else { return }
            inEntry = false
            document.sawAnyEntry = true

            guard document.videos.count < YouTubeFeedParser.maximumEntries else { return }
            guard let href = currentLink, let video = YouTubeVideoURL.validate(href) else {
                // Dropped, not repaired: an entry whose link is not a YouTube
                // video link tells this app nothing it may act on.
                return
            }
            document.videos.append(
                YouTubeVideo(
                    videoID: video.videoID,
                    title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: video.url,
                    publishedAt: Self.date(from: currentPublished)
                )
            )
        }

        private static func date(from text: String) -> Date? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return iso8601.date(from: trimmed) ?? iso8601Fractional.date(from: trimmed)
        }
    }
}
