import Foundation
import XCTest
@testable import OpenSuperWhisper

/// The whole command, from a resolved channel to a URL handed to a browser -
/// against a feed the test wrote and a browser that only records what it was
/// asked to open.
///
/// Nothing here reaches the network and nothing here opens anything.
final class YouTubeLatestVideoServiceTests: XCTestCase {

    // MARK: - Doubles

    private struct StubFetcher: YouTubeFeedFetching {
        let result: Result<Data, Error>
        let recorder: URLRecorder

        func fetch(_ url: URL) async throws -> Data {
            recorder.record(url)
            return try result.get()
        }
    }

    /// Records what would have been opened, and opens nothing.
    private final class MockBrowserOpener: BrowserOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [URL] = []
        let failure: BrowserOpenError?

        init(failure: BrowserOpenError? = nil) {
            self.failure = failure
        }

        func openInNewTab(_ url: URL) async throws {
            lock.lock()
            opened.append(url)
            lock.unlock()
            if let failure { throw failure }
        }

        var openedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }
    }

    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        var requested: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    private let channel = YouTubeChannel(
        displayName: "Veritasium",
        aliases: ["vera tasium"],
        channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
    )

    private func feedData(newestID: String = "bbbbbbbbbbb") -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Older</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-01-01T10:00:00+00:00</published>
              </entry>
              <entry>
                <title>The newest one</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=\(newestID)"/>
                <published>2026-08-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
    }

    private func service(
        feed: Result<Data, Error>,
        opener: MockBrowserOpener,
        recorder: URLRecorder = URLRecorder()
    ) -> YouTubeLatestVideoService {
        YouTubeLatestVideoService(
            fetcher: StubFetcher(result: feed, recorder: recorder), opener: opener
        )
    }

    // MARK: - The path that works

    func testTheNewestVideoIsOpenedInTheBrowser() async {
        let opener = MockBrowserOpener()
        let recorder = URLRecorder()
        let service = service(feed: .success(feedData()), opener: opener, recorder: recorder)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        XCTAssertEqual(
            report,
            .opened(channel: "Veritasium", title: "The newest one", match: .spokenName)
        )
        XCTAssertEqual(
            opener.openedURLs.map(\.absoluteString),
            ["https://www.youtube.com/watch?v=bbbbbbbbbbb"]
        )
        // Exactly the documented feed endpoint, built from the configured id and
        // nothing else.
        XCTAssertEqual(
            recorder.requested.map(\.absoluteString),
            ["https://www.youtube.com/feeds/videos.xml?channel_id=UCHnyfMqiRRG1u-2MsSQLbXA"]
        )
    }

    // MARK: - Channels that name nothing

    func testAnUnknownChannelOpensNothingAndSaysWhereToAddIt() async {
        let opener = MockBrowserOpener()
        let recorder = URLRecorder()
        let service = service(feed: .success(feedData()), opener: opener, recorder: recorder)

        let report = await service.run(.unknown(spoken: "some other channel"))

        guard case .refused(let reason, let message, let short) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        // The class travels with the sentence, so history can group this
        // without matching on wording that is free to change.
        XCTAssertEqual(reason, .channelUnknown)
        XCTAssertTrue(message.contains("some other channel"))
        XCTAssertTrue(message.contains("Settings"))
        XCTAssertFalse(short.isEmpty)
        // Nothing was fetched and nothing was opened: an unknown channel is not
        // a lookup, it is a stop.
        XCTAssertTrue(recorder.requested.isEmpty)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAnAmbiguousChannelNamesTheRowsThatClash() async {
        let opener = MockBrowserOpener()
        let recorder = URLRecorder()
        let service = service(feed: .success(feedData()), opener: opener, recorder: recorder)

        let report = await service.run(
            .ambiguous(spoken: "veritasium", matches: ["Veritasium", "Veritasium Clips"])
        )

        guard case .refused(_, let message, _) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        XCTAssertTrue(message.contains("Veritasium Clips"))
        XCTAssertTrue(recorder.requested.isEmpty)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAStoredChannelWithAnUnusableIDIsRefusedBeforeAnyRequest() async {
        let opener = MockBrowserOpener()
        let recorder = URLRecorder()
        let service = service(feed: .success(feedData()), opener: opener, recorder: recorder)
        let broken = YouTubeChannel(displayName: "Broken", channelID: "@handle")

        let report = await service.run(.allowlisted(broken, matchedBy: .spokenName))

        XCTAssertFalse(report.didOpen)
        XCTAssertTrue(recorder.requested.isEmpty)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    // MARK: - Failures on the way

    func testBeingOfflineOpensNothingAndSaysSo() async {
        let opener = MockBrowserOpener()
        let service = service(feed: .failure(YouTubeFeedError.unreachable), opener: opener)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        XCTAssertEqual(
            report,
            .refused(
                reason: .feedUnavailable,
                message: YouTubeFeedError.unreachable.errorDescription ?? "",
                shortMessage: YouTubeFeedError.unreachable.shortMessage
            )
        )
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAnUnexpectedTransportErrorIsStillReportedAsUnreachable() async {
        let opener = MockBrowserOpener()
        let service = service(
            feed: .failure(URLError(.notConnectedToInternet)), opener: opener
        )

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        guard case .refused(_, _, let short) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        XCTAssertEqual(short, YouTubeFeedError.unreachable.shortMessage)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAnHTTPFailureNamesTheStatus() async {
        let opener = MockBrowserOpener()
        let service = service(feed: .failure(YouTubeFeedError.httpStatus(404)), opener: opener)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        guard case .refused(_, let message, _) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        XCTAssertTrue(message.contains("404"))
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAHostileFeedOpensNothingAtAll() async {
        let opener = MockBrowserOpener()
        let hostile = Data(
            """
            <?xml version="1.0"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Click me</title>
                <link rel="alternate" href="https://evil.example.com/watch?v=aaaaaaaaaaa"/>
                <published>2026-08-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
        let service = service(feed: .success(hostile), opener: opener)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        XCTAssertFalse(report.didOpen)
        // The whole point: a feed that named a page outside YouTube causes no
        // page to be opened, not a different page to be opened.
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAnEmptyFeedIsReportedAsAChannelWithNoVideos() async {
        let opener = MockBrowserOpener()
        let empty = Data(
            "<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>".utf8
        )
        let service = service(feed: .success(empty), opener: opener)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        guard case .refused(_, _, let short) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        XCTAssertEqual(short, YouTubeFeedError.noEntries.shortMessage)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testAMissingBrowserIsReportedRatherThanFallingBackToAnotherOne() async {
        let opener = MockBrowserOpener(failure: .chromeNotInstalled)
        let service = service(feed: .success(feedData()), opener: opener)

        let report = await service.run(.allowlisted(channel, matchedBy: .spokenName))

        guard case .refused(_, let message, _) = report else {
            return XCTFail("expected a refusal, got \(report)")
        }
        XCTAssertTrue(message.contains("Chrome"))
    }

    // MARK: - The browser opener itself

    func testTheChromeOpenerRefusesAURLThatIsNotAYouTubeVideo() async {
        let opener = ChromeBrowserOpener(
            locateChrome: { URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            open: { _, _ in XCTFail("nothing should be opened") }
        )

        do {
            try await opener.openInNewTab(URL(string: "https://example.com/watch?v=x")!)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? BrowserOpenError, .refusedURL)
        }
    }

    func testTheChromeOpenerSaysSoWhenChromeIsNotInstalled() async {
        let opener = ChromeBrowserOpener(
            locateChrome: { nil },
            open: { _, _ in XCTFail("nothing should be opened") }
        )

        do {
            try await opener.openInNewTab(
                URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? BrowserOpenError, .chromeNotInstalled)
        }
    }

    func testTheChromeOpenerHandsTheURLToChromeAndNothingElse() async throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let handed = URLRecorder()
        let applications = URLRecorder()
        let opener = ChromeBrowserOpener(
            locateChrome: { chrome },
            open: { url, application in
                handed.record(url)
                applications.record(application)
            }
        )

        try await opener.openInNewTab(URL(string: "https://youtu.be/dQw4w9WgXcQ")!)

        XCTAssertEqual(handed.requested.map(\.absoluteString), ["https://youtu.be/dQw4w9WgXcQ"])
        XCTAssertEqual(applications.requested, [chrome])
    }

    // MARK: - What the redirect check allows

    func testAFeedRedirectMayOnlyStayOnYouTube() {
        XCTAssertTrue(YouTubeFeedFetcher.isAllowedRedirectHost("www.youtube.com"))
        XCTAssertTrue(YouTubeFeedFetcher.isAllowedRedirectHost("consent.youtube.com"))
        XCTAssertFalse(YouTubeFeedFetcher.isAllowedRedirectHost("example.com"))
        XCTAssertFalse(YouTubeFeedFetcher.isAllowedRedirectHost("youtube.com.example.net"))
        XCTAssertFalse(YouTubeFeedFetcher.isAllowedRedirectHost(nil))
    }
}
