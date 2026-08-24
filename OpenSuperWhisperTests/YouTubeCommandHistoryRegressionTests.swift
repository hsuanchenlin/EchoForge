import Foundation
import XCTest
@testable import OpenSuperWhisper

/// The command that would not open, end to end, in the configuration it failed
/// in - and what history now says about each way it can go.
///
/// This is the regression the whole change came out of. A user with one
/// allowlisted channel, `valley101`, pressed the command shortcut and said
/// "open YouTube channel Valley 101" several times over two releases and got
/// nothing, with no way afterwards to tell which of four different things had
/// happened:
///
/// - the marker family naming the **channel** did not exist yet, so the whole
///   sentence became the spoken name and was refused as a channel that is not
///   in the list (fixed separately; pinned here so it stays fixed);
/// - the engine wrote the name a way the list does not hold - "Vali101" for
///   `valley101` - and the allowlist correctly refused it;
/// - the on-device fallback that exists for exactly that is off by default, and
///   said nothing about being off;
/// - and none of it was written down anywhere that outlives a two-second
///   overlay, so all three looked identical the next morning.
///
/// Everything below is deterministic: no network, no model, no browser.
final class YouTubeCommandHistoryRegressionTests: IsolatedPreferencesTestCase {

    // MARK: - Doubles

    private struct StubFetcher: YouTubeFeedFetching {
        let result: Result<Data, Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private final class MockBrowserOpener: BrowserOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [URL] = []
        let failure: BrowserOpenError?

        init(failure: BrowserOpenError? = nil) { self.failure = failure }

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

    /// One row, named exactly as the user typed it. The id is a synthetic one of
    /// the right shape: what is under test is the matching and the record, not
    /// anybody's real channel.
    private let stored = YouTubeChannel(
        displayName: "valley101", aliases: [], channelID: "UCaaaaaaaaaaaaaaaaaaaaaa")

    private var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: [stored])
    }

    private func feedData() -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>The newest one</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=bbbbbbbbbbb"/>
                <published>2026-08-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
    }

    private func processed(_ text: String) -> ProcessedText {
        ProcessedText(raw: text, final: text)
    }

    // MARK: - The spellings that reach the channel

    /// Both marker families and both matching tiers, against the one stored
    /// spelling. "open YouTube channel X" is the family whose absence cost the
    /// user four attempts; "Valley 101" is the spacing tier.
    func testTheSpellingsThatReachTheStoredChannel() {
        let reaching = [
            "valley101",
            "Valley 101",
            "open YouTube channel Valley101",
            "Open YouTube channel Valley 101",
            "Open the YouTube channel valley101",
            "Open the latest YouTube video from Valley 101",
            "打開YouTube頻道valley101",
        ]

        for said in reaching {
            guard case .allowlisted(let channel, _) =
                YouTubeCommandRouter.resolve(said, channels: allowlist)
            else {
                return XCTFail("“\(said)” did not reach the stored channel")
            }
            XCTAssertEqual(channel.channelID, stored.channelID)
        }
    }

    /// The one that still fails, and why. The engine wrote "Vali101"; the list
    /// holds `valley101`. Widening the match to bridge that is exactly what this
    /// feature must not do - a near miss that opened *something* would be the
    /// app choosing a channel the user did not - so the answer is the record and
    /// the sentence, not a looser comparison.
    func testTheSpellingsThatCorrectlyReachNothing() {
        for said in ["Open YouTube channel Vali101", "Open the YouTube channel Bali 101",
                     "open YouTube channel, barely", "open YouTube channel Valley",
                     "open YouTube channel Valley 1012"] {
            guard case .unknown = YouTubeCommandRouter.resolve(said, channels: allowlist) else {
                return XCTFail("“\(said)” reached a channel it should not have")
            }
        }
    }

    // MARK: - What history says about each of them

    func testTheFailingCommandIsRecordedWithTheSpellingThatWasHeard() async throws {
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        AppPreferences.shared.youTubeChannelModelMatchEnabled = false
        try YouTubeChannelStore().upsert(stored)

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Open YouTube channel Vali101"),
            settings: Settings(purpose: .youTubeCommand)
        )

        // Nothing to paste, whatever it turned out to be.
        XCTAssertFalse(styled.intent.insertsText)

        let provenance = styled.intent.provenance
        XCTAssertEqual(provenance.kind, .youTubeCommandNotOpened)
        XCTAssertEqual(provenance.kind.label, "YouTube command - not opened")
        XCTAssertEqual(provenance.refusal, .channelUnknown)

        let detail = try XCTUnwrap(provenance.detail)
        // The three things the user needs and previously had none of: what was
        // heard, where to fix it, and that the fallback was not going to save
        // them because it is off.
        XCTAssertTrue(detail.contains("Vali101"), detail)
        XCTAssertTrue(detail.contains("Settings"), detail)
        XCTAssertTrue(detail.contains("spoken name"), detail)
        XCTAssertTrue(detail.contains("switched off"), detail)
    }

    func testTheWorkingCommandIsRecordedAsOpened() async throws {
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        try YouTubeChannelStore().upsert(stored)

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Open YouTube channel Valley 101"),
            settings: Settings(purpose: .youTubeCommand)
        )
        guard case .openLatestVideo(let command) = styled.intent else {
            return XCTFail("expected a command, got \(styled.intent)")
        }
        // Before it runs, the row says nothing was opened. That is the value a
        // crash would leave behind, and it is the true one.
        XCTAssertEqual(styled.intent.provenance.refusal, .didNotFinish)

        let opener = MockBrowserOpener()
        let service = YouTubeLatestVideoService(
            fetcher: StubFetcher(result: .success(feedData())), opener: opener)
        let report = await service.run(command.resolution)

        let provenance = RecordingProvenance.command(report, modelMatch: command.modelMatch)
        XCTAssertEqual(provenance.kind, .youTubeCommandOpened)
        XCTAssertEqual(provenance.kind.label, "YouTube command - opened")
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("valley101"), true)
        XCTAssertEqual(
            opener.openedURLs.map(\.absoluteString),
            ["https://www.youtube.com/watch?v=bbbbbbbbbbb"])
    }

    func testACommandTheFeedRefusedIsRecordedAsAFeedFailure() async throws {
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        try YouTubeChannelStore().upsert(stored)

        let opener = MockBrowserOpener()
        let service = YouTubeLatestVideoService(
            fetcher: StubFetcher(result: .failure(YouTubeFeedError.unreachable)), opener: opener)

        let provenance = RecordingProvenance.command(
            await service.run(.allowlisted(stored, matchedBy: .spokenName)))

        XCTAssertEqual(provenance.refusal, .feedUnavailable)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("connection"), true)
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testACommandChromeCouldNotOpenIsRecordedAsABrowserFailure() async {
        let opener = MockBrowserOpener(failure: .chromeNotInstalled)
        let service = YouTubeLatestVideoService(
            fetcher: StubFetcher(result: .success(feedData())), opener: opener)

        let provenance = RecordingProvenance.command(
            await service.run(.allowlisted(stored, matchedBy: .spokenName)))

        XCTAssertEqual(provenance.refusal, .browserUnavailable)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("Chrome"), true)
    }

    func testACommandWithTheFeatureOffIsRecordedAsSwitchedOff() async throws {
        AppPreferences.shared.youTubeLatestVideoEnabled = false
        try YouTubeChannelStore().upsert(stored)

        let styled = await SpokenIntentPipeline.apply(
            to: processed("Open YouTube channel Valley 101"),
            settings: Settings(purpose: .youTubeCommand)
        )

        let provenance = styled.intent.provenance
        XCTAssertEqual(provenance.refusal, .commandDisabled)
        XCTAssertEqual(try XCTUnwrap(provenance.detail).contains("Turn it on"), true)
        // A switched-off command is not a name that could not be placed, so the
        // fallback is not consulted and says nothing.
        guard case .openLatestVideo(let command) = styled.intent else {
            return XCTFail("expected a command, got \(styled.intent)")
        }
        XCTAssertEqual(command.modelMatch, .notNeeded)
    }

    // MARK: - The separation this must not break

    /// The same words through the **dictation** key stay text, with the command
    /// on and the channel stored. Provenance changes what history says about a
    /// press; it does not change what a press does.
    func testTheSameWordsFromTheDictationKeyAreStillOnlyText() async throws {
        AppPreferences.shared.spokenIntentsEnabled = true
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        try YouTubeChannelStore().upsert(stored)

        for said in ["valley101", "Open YouTube channel Valley 101",
                     "Open the latest YouTube video from valley101"] {
            let styled = await SpokenIntentPipeline.apply(
                to: processed(said), settings: Settings(routesSpokenIntents: true))

            XCTAssertEqual(styled.intent, .dictation, "“\(said)” must stay dictation")
            XCTAssertTrue(styled.intent.insertsText)
            XCTAssertEqual(styled.final, said)
            XCTAssertEqual(styled.intent.provenance, .dictation)
            XCTAssertNil(
                styled.intent.provenance.detail,
                "an ordinary dictation has nothing to explain")
            XCTAssertFalse(styled.intent.provenance.isYouTubeCommand)
        }
    }

    /// The command capture is not a browser control: whatever is said into it,
    /// the only thing it can produce is one of the user's own channels or a
    /// refusal, and it can never produce text to insert.
    func testTheCommandKeyIsNotGeneralBrowserControl() async throws {
        AppPreferences.shared.spokenIntentsEnabled = true
        AppPreferences.shared.voiceSnippetsEnabled = true
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        try YouTubeChannelStore().upsert(stored)

        for said in [
            "open https://example.com",
            "open youtube.com/channel/UCzzzzzzzzzzzzzzzzzzzzzz",
            "Ask: open my bank",
            "insert email signoff",
            "open the YouTube channel Some Other Channel",
        ] {
            let styled = await SpokenIntentPipeline.apply(
                to: processed(said), settings: Settings(purpose: .youTubeCommand))

            guard case .openLatestVideo(let command) = styled.intent else {
                return XCTFail("“\(said)” produced \(styled.intent)")
            }
            XCTAssertFalse(styled.intent.insertsText)
            guard case .unknown = command.resolution else {
                return XCTFail("“\(said)” reached a channel")
            }
            XCTAssertEqual(styled.intent.provenance.kind, .youTubeCommandNotOpened)
        }
    }
}
