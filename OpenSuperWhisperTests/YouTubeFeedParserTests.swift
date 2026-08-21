import XCTest
@testable import OpenSuperWhisper

/// Reading a channel feed: which entry is the newest, and everything that is
/// refused instead of coped with.
///
/// The fixtures are written here rather than fetched, which is the only way the
/// hostile ones can exist at all - and means nothing in this file reaches
/// YouTube.
final class YouTubeFeedParserTests: XCTestCase {

    private func feed(_ entries: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
              <title>A channel</title>
              <link rel="alternate" href="https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA"/>
            \(entries)
            </feed>
            """.utf8
        )
    }

    private func entry(id: String, title: String, published: String, href: String? = nil) -> String {
        """
          <entry>
            <yt:videoId>\(id)</yt:videoId>
            <title>\(title)</title>
            <link rel="alternate" href="\(href ?? "https://www.youtube.com/watch?v=\(id)")"/>
            <published>\(published)</published>
          </entry>
        """
    }

    // MARK: - Newest entry

    func testTheNewestPublishedEntryWinsRegardlessOfFeedOrder() throws {
        let data = feed(
            entry(id: "aaaaaaaaaaa", title: "Older", published: "2026-01-01T10:00:00+00:00")
                + entry(id: "bbbbbbbbbbb", title: "Newest", published: "2026-08-01T10:00:00+00:00")
                + entry(id: "ccccccccccc", title: "Middle", published: "2026-04-01T10:00:00+00:00")
        )

        let video = try YouTubeFeedParser.newestVideo(in: data)

        // The dates decide, not the order: depending on the order would make the
        // answer depend on YouTube rather than on what the feed states.
        XCTAssertEqual(video.title, "Newest")
        XCTAssertEqual(video.videoID, "bbbbbbbbbbb")
        XCTAssertEqual(video.url.absoluteString, "https://www.youtube.com/watch?v=bbbbbbbbbbb")
    }

    func testFractionalSecondsAreUnderstood() throws {
        let data = feed(
            entry(id: "aaaaaaaaaaa", title: "Older", published: "2026-01-01T10:00:00.500Z")
                + entry(id: "bbbbbbbbbbb", title: "Newer", published: "2026-02-01T10:00:00.250Z")
        )
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "Newer")
    }

    func testWithNoReadableDatesTheFirstEntryIsUsed() throws {
        let data = feed(
            entry(id: "aaaaaaaaaaa", title: "First", published: "not a date")
                + entry(id: "bbbbbbbbbbb", title: "Second", published: "")
        )
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "First")
    }

    func testAnEntryWithADateBeatsOneWithout() throws {
        let data = feed(
            entry(id: "aaaaaaaaaaa", title: "Undated", published: "")
                + entry(id: "bbbbbbbbbbb", title: "Dated", published: "2020-01-01T10:00:00+00:00")
        )
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "Dated")
    }

    func testTheChannelTitleIsNotMistakenForAVideoTitle() throws {
        let data = feed(entry(id: "aaaaaaaaaaa", title: "A video", published: "2026-01-01T10:00:00+00:00"))
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "A video")
    }

    // MARK: - Feeds with nothing to open

    func testAFeedWithNoEntriesIsItsOwnFailure() {
        // A channel that has published nothing is not a broken feed, and the
        // user is told the difference.
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: feed(""))) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .noEntries)
        }
    }

    func testAFeedWhoseEntriesAllPointElsewhereOpensNothing() {
        let data = feed(
            entry(
                id: "aaaaaaaaaaa", title: "Off site", published: "2026-01-01T10:00:00+00:00",
                href: "https://example.com/watch?v=aaaaaaaaaaa"
            )
        )
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .noUsableVideo)
        }
    }

    func testAHostileLinkIsDroppedAndNotRepairedFromTheVideoIDBesideIt() throws {
        // The entry carries a perfectly good `yt:videoId`, and it is deliberately
        // not used: guessing a URL out of a document that just failed its own
        // check is how the wrong page gets opened.
        let data = feed(
            entry(
                id: "aaaaaaaaaaa", title: "Hostile", published: "2026-08-01T10:00:00+00:00",
                href: "javascript:alert(1)"
            )
                + entry(id: "bbbbbbbbbbb", title: "Honest", published: "2026-01-01T10:00:00+00:00")
        )

        let video = try YouTubeFeedParser.newestVideo(in: data)

        XCTAssertEqual(video.title, "Honest")
        XCTAssertEqual(video.url.absoluteString, "https://www.youtube.com/watch?v=bbbbbbbbbbb")
    }

    func testALookalikeHostIsDropped() throws {
        let data = feed(
            entry(
                id: "aaaaaaaaaaa", title: "Lookalike", published: "2026-08-01T10:00:00+00:00",
                href: "https://youtube.com.example.net/watch?v=aaaaaaaaaaa"
            )
                + entry(id: "bbbbbbbbbbb", title: "Honest", published: "2026-01-01T10:00:00+00:00")
        )
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "Honest")
    }

    func testARelSelfLinkIsNotTakenForTheVideoLink() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Only a self link</title>
                <link rel="self" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-01-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .noUsableVideo)
        }
    }

    // MARK: - Malformed and hostile documents

    func testBytesThatAreNotXMLAreRefused() {
        XCTAssertThrowsError(
            try YouTubeFeedParser.newestVideo(in: Data("not xml at all".utf8))
        ) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testTruncatedXMLIsRefused() {
        let data = Data("<?xml version=\"1.0\"?><feed><entry><title>half".utf8)
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testEmptyBytesAreRefused() {
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: Data())) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testADocumentDeclaringEntitiesIsRefusedOutright() {
        // The billion-laughs shape. A channel feed declares no entities, so a
        // document that does is either not this feed or is an attack on the
        // parser - and both are answered by refusing the whole document rather
        // than by parsing carefully.
        let data = Data(
            """
            <?xml version="1.0"?>
            <!DOCTYPE feed [
              <!ENTITY lol "lol">
              <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
            ]>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>&lol2;</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-01-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testAnyDocumentTypeDeclarationIsRefusedBeforeParsing() {
        // The prolog check, on its own terms: a feed that is otherwise perfectly
        // readable is still refused for declaring a document type, because a
        // channel feed does not have one.
        let data = Data(
            """
            <?xml version="1.0"?>
            <!DOCTYPE feed>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Ordinary</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-01-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
        XCTAssertTrue(YouTubeFeedParser.prologDeclaresDocumentType(data))
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testAFeedWithACommentAndNoDocumentTypeIsStillRead() throws {
        // The scan steps over the things that legitimately sit in front of a
        // feed, so a comment does not become a refusal.
        let data = Data(
            """
            <?xml version="1.0"?>
            <!-- generated <!DOCTYPE is not a declaration inside a comment -->
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Ordinary</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-01-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
        XCTAssertFalse(YouTubeFeedParser.prologDeclaresDocumentType(data))
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "Ordinary")
    }

    func testATitleMentioningADocumentTypeIsNotMistakenForOne() throws {
        let data = feed(
            entry(
                id: "aaaaaaaaaaa", title: "How &lt;!DOCTYPE html&gt; works",
                published: "2026-01-01T10:00:00+00:00"
            )
        )
        XCTAssertFalse(YouTubeFeedParser.prologDeclaresDocumentType(data))
        XCTAssertEqual(try YouTubeFeedParser.newestVideo(in: data).title, "How <!DOCTYPE html> works")
    }

    func testADocumentPointingAtALocalFileIsRefused() {
        let data = Data(
            """
            <?xml version="1.0"?>
            <!DOCTYPE feed [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>&xxe;</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
              </entry>
            </feed>
            """.utf8
        )
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .malformed)
        }
    }

    func testAFeedLargerThanAFeedIsRefusedBeforeItIsParsed() {
        let data = Data(count: YouTubeFeedParser.maximumFeedBytes + 1)
        XCTAssertThrowsError(try YouTubeFeedParser.newestVideo(in: data)) { error in
            XCTAssertEqual(error as? YouTubeFeedError, .tooLarge)
        }
    }

    func testAnEnormousTitleIsBoundedRatherThanKept() throws {
        let data = feed(
            entry(
                id: "aaaaaaaaaaa",
                title: String(repeating: "a", count: 100_000),
                published: "2026-01-01T10:00:00+00:00"
            )
        )
        let video = try YouTubeFeedParser.newestVideo(in: data)
        XCTAssertLessThanOrEqual(video.title.count, 4096)
        XCTAssertEqual(video.url.absoluteString, "https://www.youtube.com/watch?v=aaaaaaaaaaa")
    }

    // MARK: - Messages

    func testEveryFailureHasASentenceAndAPillsWorthOfWords() {
        let failures: [YouTubeFeedError] = [
            .unreachable, .httpStatus(404), .tooLarge, .malformed, .noEntries, .noUsableVideo,
        ]
        for failure in failures {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true)
            XCTAssertFalse(failure.shortMessage.isEmpty)
            XCTAssertLessThanOrEqual(failure.shortMessage.count, 30, "\(failure)")
        }
    }
}
