import XCTest
@testable import OpenSuperWhisper

/// The check between a feed and the browser.
///
/// Every case here is something that could be published in a feed, and the ones
/// that are refused are refused because the alternative is opening them in the
/// user's browser.
final class YouTubeVideoURLTests: XCTestCase {

    func testARealWatchURLIsAccepted() {
        let video = YouTubeVideoURL.validate("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(video?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(video?.url.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testAShareLinkIsAcceptedAndRebuiltAsAWatchURL() {
        // youtu.be is YouTube's own share domain and appears in real feeds; what
        // is opened is the canonical watch URL built from the id that was
        // checked, not the string that arrived.
        let video = YouTubeVideoURL.validate("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(video?.url.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testAShortsURLIsAccepted() {
        XCTAssertEqual(
            YouTubeVideoURL.validate("https://www.youtube.com/shorts/dQw4w9WgXcQ")?.videoID,
            "dQw4w9WgXcQ"
        )
    }

    func testTrackingAndFragmentsAreDroppedRatherThanPassedOn() {
        let video = YouTubeVideoURL.validate(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc&t=42#fragment"
        )
        XCTAssertEqual(video?.url.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testAnotherHostIsRefused() {
        XCTAssertNil(YouTubeVideoURL.validate("https://example.com/watch?v=dQw4w9WgXcQ"))
    }

    func testAHostThatMerelyEndsWithYouTubeIsRefused() {
        XCTAssertNil(
            YouTubeVideoURL.validate("https://youtube.com.example.net/watch?v=dQw4w9WgXcQ")
        )
        XCTAssertNil(
            YouTubeVideoURL.validate("https://notyoutube.com/watch?v=dQw4w9WgXcQ")
        )
    }

    func testASubdomainOfYouTubeThatIsNotOnTheListIsRefused() {
        XCTAssertNil(
            YouTubeVideoURL.validate("https://evil.youtube.com/watch?v=dQw4w9WgXcQ")
        )
    }

    func testPlainHTTPIsRefused() {
        XCTAssertNil(YouTubeVideoURL.validate("http://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testAnyOtherSchemeIsRefused() {
        for candidate in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "chrome://settings",
        ] {
            XCTAssertNil(YouTubeVideoURL.validate(candidate), "expected \(candidate) refused")
        }
    }

    func testCredentialsInTheURLAreRefused() {
        // The shape used to make a host look like something it is not.
        XCTAssertNil(
            YouTubeVideoURL.validate("https://www.youtube.com@example.com/watch?v=dQw4w9WgXcQ")
        )
        XCTAssertNil(
            YouTubeVideoURL.validate("https://user:pw@www.youtube.com/watch?v=dQw4w9WgXcQ")
        )
    }

    func testAPortIsRefused() {
        XCTAssertNil(YouTubeVideoURL.validate("https://www.youtube.com:8080/watch?v=dQw4w9WgXcQ"))
    }

    func testAYouTubePageThatIsNotAVideoIsRefused() {
        for candidate in [
            "https://www.youtube.com/",
            "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA",
            "https://www.youtube.com/results?search_query=anything",
            "https://www.youtube.com/watch",
        ] {
            XCTAssertNil(YouTubeVideoURL.validate(candidate), "expected \(candidate) refused")
        }
    }

    func testAVideoIDOfTheWrongShapeIsRefused() {
        XCTAssertNil(YouTubeVideoURL.validate("https://www.youtube.com/watch?v=short"))
        XCTAssertNil(YouTubeVideoURL.validate("https://www.youtube.com/watch?v=has spaces"))
        XCTAssertNil(YouTubeVideoURL.validate("https://www.youtube.com/watch?v=../../etc/pw"))
    }

    func testAnEmptyOrEnormousCandidateIsRefused() {
        XCTAssertNil(YouTubeVideoURL.validate(""))
        XCTAssertNil(
            YouTubeVideoURL.validate(
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ&x=" + String(repeating: "a", count: 4096)
            )
        )
    }

    // MARK: - Channel ids

    func testAChannelIDIsCheckedByShape() {
        XCTAssertTrue(YouTubeChannelID.isValid("UCHnyfMqiRRG1u-2MsSQLbXA"))
        XCTAssertFalse(YouTubeChannelID.isValid("UCHnyfMqiRRG1u-2MsSQLbX"))
        XCTAssertFalse(YouTubeChannelID.isValid("XXHnyfMqiRRG1u-2MsSQLbXA"))
        XCTAssertFalse(YouTubeChannelID.isValid("UCHnyfMqiRRG1u 2MsSQLbXA"))
        XCTAssertFalse(YouTubeChannelID.isValid("@veritasium"))
        XCTAssertFalse(YouTubeChannelID.isValid(""))
    }

    func testAPastedChannelURLIsAcceptedAndAHandleURLIsNot() {
        XCTAssertEqual(
            YouTubeChannelID.extract(
                from: "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA"
            ),
            "UCHnyfMqiRRG1u-2MsSQLbXA"
        )
        XCTAssertEqual(
            YouTubeChannelID.extract(from: " UCHnyfMqiRRG1u-2MsSQLbXA "),
            "UCHnyfMqiRRG1u-2MsSQLbXA"
        )
        // A handle does not contain the id, and this app never asks YouTube who
        // a handle is.
        XCTAssertNil(YouTubeChannelID.extract(from: "https://www.youtube.com/@veritasium"))
        XCTAssertNil(YouTubeChannelID.extract(from: "https://www.youtube.com/c/veritasium"))
        XCTAssertNil(YouTubeChannelID.extract(from: "veritasium"))
    }

    // MARK: - The feed endpoint

    func testTheFeedURLIsTheDocumentedOneAndOnlyBuiltFromAValidID() {
        XCTAssertEqual(
            YouTubeFeedEndpoint.url(forChannelID: "UCHnyfMqiRRG1u-2MsSQLbXA")?.absoluteString,
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCHnyfMqiRRG1u-2MsSQLbXA"
        )
        XCTAssertNil(YouTubeFeedEndpoint.url(forChannelID: "@veritasium"))
    }
}
