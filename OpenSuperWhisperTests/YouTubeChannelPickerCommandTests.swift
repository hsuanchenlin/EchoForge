import Foundation
import XCTest
@testable import OpenSuperWhisper

/// One press of the command key, end to end, through the picker - and what
/// History is left holding for each way it can go.
///
/// The regression this belongs to is the same one
/// `YouTubeCommandHistoryRegressionTests` records: "Vali101" for a stored
/// `valley101`, refused correctly and with no way back. What is asserted here is
/// the way back, and the four rules it must not break:
///
/// - an exact match still opens without a panel appearing at all;
/// - the picker can only ever produce a channel the user allowlisted;
/// - Escape opens nothing, and says so where it is still readable tomorrow;
/// - and no dictation, however worded, can raise the panel.
///
/// Nothing here reaches the network, a model, a browser or a window server.
final class YouTubeChannelPickerCommandTests: IsolatedPreferencesTestCase {

    // MARK: - Doubles

    private struct StubFetcher: YouTubeFeedFetching {
        let result: Result<Data, Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private final class MockBrowserOpener: BrowserOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [URL] = []

        func openInNewTab(_ url: URL) async throws {
            lock.lock()
            opened.append(url)
            lock.unlock()
        }

        var openedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }
    }

    /// A picker that answers however the test says, and remembers what it was
    /// offered - which is the half that matters: what a panel is *allowed* to
    /// contain is the allowlist rule at its last surface.
    private final class StubChooser: YouTubeChannelChoosing, @unchecked Sendable {
        private let lock = NSLock()
        private var answer: (@Sendable (YouTubeChannelPickerRequest) -> YouTubeChannel?)
        private var seen: [YouTubeChannelPickerRequest] = []

        init(answering: @escaping @Sendable (YouTubeChannelPickerRequest) -> YouTubeChannel?) {
            self.answer = answering
        }

        convenience init(choosing channel: YouTubeChannel?) {
            self.init(answering: { _ in channel })
        }

        @MainActor
        func chooseChannel(_ request: YouTubeChannelPickerRequest) async -> YouTubeChannel? {
            lock.lock()
            seen.append(request)
            let answer = self.answer
            lock.unlock()
            return answer(request)
        }

        var requests: [YouTubeChannelPickerRequest] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    // MARK: - Fixtures

    private let valley = YouTubeChannel(
        displayName: "valley101", aliases: [], channelID: "UCaaaaaaaaaaaaaaaaaaaaaa")
    private let veritasium = YouTubeChannel(
        displayName: "Veritasium", aliases: [], channelID: "UCbbbbbbbbbbbbbbbbbbbbbb")

    private var channels: [YouTubeChannel] { [valley, veritasium] }
    private var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: channels)
    }

    private func feedData(title: String = "The newest one") -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>\(title)</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=bbbbbbbbbbb"/>
                <published>2026-08-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
    }

    /// What the command hotkey's pipeline hands the runner, for one utterance.
    private func command(_ said: String) -> YouTubeCommandResolution {
        YouTubeCommandResolution(
            resolution: YouTubeCommandRouter.resolve(said, channels: allowlist),
            candidates: allowlist.reachable
        )
    }

    /// Runs one press and returns the report, everything written to History in
    /// order, and what Chrome was handed.
    @MainActor
    private func press(
        _ said: String,
        chooser: StubChooser,
        isPickerEnabled: Bool = true,
        opener: MockBrowserOpener = MockBrowserOpener()
    ) async -> (
        outcome: YouTubeCommandRunner.Outcome, history: [RecordingProvenance], opened: [URL]
    ) {
        let runner = YouTubeCommandRunner(
            service: YouTubeLatestVideoService(
                fetcher: StubFetcher(result: .success(feedData())), opener: opener),
            chooser: chooser
        )
        var history: [RecordingProvenance] = []
        let outcome = await runner.run(command(said), isPickerEnabled: isPickerEnabled) {
            history.append($0)
        }
        return (outcome, history, opener.openedURLs)
    }

    // MARK: - The exact match is untouched

    /// The path that already worked still works, and never sees a panel.
    @MainActor
    func testAnExactMatchOpensWithoutAPicker() async {
        let chooser = StubChooser(choosing: nil)
        let result = await press("valley101", chooser: chooser)

        XCTAssertTrue(result.outcome.report.didOpen)
        XCTAssertFalse(result.outcome.showedPicker)
        XCTAssertEqual(result.outcome.match, .spokenName)
        XCTAssertTrue(chooser.requests.isEmpty, "Nothing should have been asked.")
        XCTAssertEqual(result.opened.count, 1)
        XCTAssertEqual(result.history.map(\.kind), [.youTubeCommandOpened])
    }

    /// So does the spacing tier - "valley 101" for a stored `valley101` is still
    /// an exact match of one stored name, not a near miss.
    @MainActor
    func testTheSpacingTierOpensWithoutAPicker() async {
        let chooser = StubChooser(choosing: nil)
        let result = await press("Open YouTube channel Valley 101", chooser: chooser)

        XCTAssertTrue(result.outcome.report.didOpen)
        XCTAssertFalse(result.outcome.showedPicker)
        XCTAssertEqual(result.outcome.match, .spacing)
        XCTAssertTrue(chooser.requests.isEmpty)
    }

    // MARK: - The near miss, recovered

    /// "Vali101" against a stored `valley101`: the allowlist still refuses it,
    /// the picker offers the user's own list with that row first, and one press
    /// of Return opens it.
    @MainActor
    func testTheNearMissIsRecoveredByChoosingFromTheList() async {
        let chooser = StubChooser(choosing: valley)
        let result = await press("Open YouTube channel Vali101", chooser: chooser)

        // The matching itself has not been widened: this is still not a name the
        // allowlist can place on its own.
        guard case .unknown = command("Open YouTube channel Vali101").resolution else {
            return XCTFail("“Vali101” must still be a miss - the fix is the recovery, not a looser match.")
        }

        XCTAssertTrue(result.outcome.showedPicker)
        XCTAssertTrue(result.outcome.report.didOpen)
        XCTAssertEqual(result.outcome.match, .picker(spoken: "Vali101"))
        XCTAssertEqual(result.opened.count, 1)
        XCTAssertEqual(
            result.opened.first?.absoluteString, "https://www.youtube.com/watch?v=bbbbbbbbbbb")

        let request = try? XCTUnwrap(chooser.requests.first)
        XCTAssertEqual(request?.spokenName, "Vali101")
        XCTAssertEqual(request?.suggestions.first?.channel, valley)
        XCTAssertEqual(
            request?.suggestions.map(\.channel), channels,
            "The panel may contain the configured channels and nothing else.")
    }

    /// What History is left holding: the picker going up, then the video
    /// opening, and the sentence saying the user chose it themselves.
    @MainActor
    func testHistoryRecordsThePickerAndThenTheChoice() async {
        let result = await press(
            "Open YouTube channel Vali101", chooser: StubChooser(choosing: valley))

        XCTAssertEqual(
            result.history.map(\.refusal), [.pickerShown, nil],
            "The picker's own state is written while it is up, so a quit with it on screen leaves the truth behind.")
        XCTAssertEqual(result.history.map(\.kind), [
            .youTubeCommandNotOpened, .youTubeCommandOpened,
        ])
        let shown = try? XCTUnwrap(result.history.first?.detail)
        XCTAssertEqual(shown?.contains("Vali101"), true)
        XCTAssertEqual(shown?.contains("Nothing has been opened"), true)

        let opened = try? XCTUnwrap(result.history.last?.detail)
        XCTAssertEqual(opened?.contains("valley101"), true)
        XCTAssertEqual(
            opened?.contains("you chose this channel from your own list"), true,
            "A match nobody's spelling made has to say how it was made.")
    }

    // MARK: - Cancelling

    @MainActor
    func testEscapeOpensNothingAndSaysSoInHistory() async {
        let result = await press(
            "Open YouTube channel Vali101", chooser: StubChooser(choosing: nil))

        XCTAssertFalse(result.outcome.report.didOpen)
        XCTAssertTrue(result.opened.isEmpty, "Nothing may reach the browser.")
        XCTAssertEqual(result.history.map(\.refusal), [.pickerShown, .pickerCancelled])
        XCTAssertEqual(result.outcome.report.shortMessage, "You cancelled the choice")
        XCTAssertEqual(
            result.history.last?.detail?.contains("Vali101"), true,
            "The spelling is named, because adding it is what stops the picker next time.")
    }

    // MARK: - The refusals that stay refusals

    @MainActor
    func testAnEmptyAllowlistRefusesWithoutAPicker() async {
        let chooser = StubChooser(choosing: valley)
        let runner = YouTubeCommandRunner(
            service: YouTubeLatestVideoService(
                fetcher: StubFetcher(result: .success(feedData())), opener: MockBrowserOpener()),
            chooser: chooser
        )
        let empty = YouTubeCommandResolution(
            resolution: YouTubeCommandRouter.resolve("Vali101", channels: .empty),
            candidates: []
        )
        var history: [RecordingProvenance] = []
        let outcome = await runner.run(empty, isPickerEnabled: true) { history.append($0) }

        XCTAssertFalse(outcome.showedPicker)
        XCTAssertTrue(chooser.requests.isEmpty)
        XCTAssertEqual(history.map(\.refusal), [.noChannelsConfigured])
        XCTAssertEqual(
            history.first?.detail?.contains("no YouTube channel in your list yet"), true)
    }

    /// With the switch off, the press ends exactly the way it did before the
    /// picker existed - the same class, and the same sentence.
    @MainActor
    func testTheSwitchedOffPickerLeavesTheOldRefusalExactlyAsItWas() async {
        let chooser = StubChooser(choosing: valley)
        let result = await press(
            "Open YouTube channel Vali101", chooser: chooser, isPickerEnabled: false)

        XCTAssertFalse(result.outcome.showedPicker)
        XCTAssertTrue(chooser.requests.isEmpty)
        XCTAssertTrue(result.opened.isEmpty)
        XCTAssertEqual(result.history.map(\.refusal), [.channelUnknown])
        XCTAssertEqual(result.outcome.report.shortMessage, "Channel not in your list")
    }

    /// Silence still opens no panel: a picker that appeared after a stray press
    /// would be the app interrupting somebody who asked for nothing.
    @MainActor
    func testSilenceOpensNoPanel() async {
        let chooser = StubChooser(choosing: valley)
        let result = await press("", chooser: chooser)

        XCTAssertFalse(result.outcome.showedPicker)
        XCTAssertTrue(chooser.requests.isEmpty)
        XCTAssertEqual(result.history.map(\.refusal), [.notRecognised])
    }

    // MARK: - The allowlist is still the boundary

    /// A chooser that answers with a channel it was never offered opens nothing.
    /// The panel cannot produce one, and this is the check that says so even if
    /// one day something else could.
    @MainActor
    func testAChoiceThatIsNotOnTheListOpensNothing() async {
        let outsider = YouTubeChannel(
            displayName: "Somewhere else", channelID: "UCzzzzzzzzzzzzzzzzzzzzzz")
        let result = await press(
            "Open YouTube channel Vali101", chooser: StubChooser(choosing: outsider))

        XCTAssertFalse(result.outcome.report.didOpen)
        XCTAssertTrue(result.opened.isEmpty)
        XCTAssertEqual(result.history.map(\.refusal), [.pickerShown, .channelUnknown])
    }

    /// The panel is never given anything that could become a destination: no
    /// channel id, no URL, no host. It is given names, and it answers with a row.
    @MainActor
    func testThePanelIsGivenNoIdentifierItCouldTurnIntoADestination() async {
        let chooser = StubChooser(choosing: nil)
        _ = await press("Open YouTube channel Vali101", chooser: chooser)

        let request = try? XCTUnwrap(chooser.requests.first)
        let shownText = [request?.spokenName ?? "", request?.prompt ?? ""].joined(separator: " ")
        for channel in channels {
            XCTAssertFalse(
                shownText.contains(channel.channelID),
                "A channel ID must not be part of what the picker says.")
        }
        XCTAssertFalse(shownText.lowercased().contains("http"))
        XCTAssertFalse(shownText.lowercased().contains("youtube.com"))
    }

    /// What the picker opens is still a URL rebuilt from a validated video id,
    /// on an allow-listed host - the picker changed which channel, never how a
    /// video address is arrived at.
    @MainActor
    func testWhatIsOpenedAfterAChoiceIsStillAValidatedYouTubeURL() async {
        let result = await press(
            "Open YouTube channel Vali101", chooser: StubChooser(choosing: valley))
        let opened = try? XCTUnwrap(result.opened.first)
        XCTAssertEqual(opened?.scheme, "https")
        XCTAssertEqual(YouTubeVideoURL.allowedHosts.contains(opened?.host ?? ""), true)
        XCTAssertNotNil(opened.flatMap { YouTubeVideoURL.validate($0.absoluteString) })
    }

    /// A feed that carries nothing openable is still a refusal after a choice.
    /// Choosing a channel is not a promise that a video exists.
    @MainActor
    func testChoosingAChannelWhoseFeedHasNoVideoStillOpensNothing() async {
        let opener = MockBrowserOpener()
        let runner = YouTubeCommandRunner(
            service: YouTubeLatestVideoService(
                fetcher: StubFetcher(
                    result: .success(
                        Data(
                            """
                            <?xml version="1.0" encoding="UTF-8"?>
                            <feed xmlns="http://www.w3.org/2005/Atom"></feed>
                            """.utf8))),
                opener: opener
            ),
            chooser: StubChooser(choosing: valley)
        )
        var history: [RecordingProvenance] = []
        let outcome = await runner.run(command("Vali101"), isPickerEnabled: true) {
            history.append($0)
        }

        XCTAssertFalse(outcome.report.didOpen)
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertEqual(history.map(\.refusal), [.pickerShown, .feedUnusable])
    }

    // MARK: - Dictation stays dictation

    /// The rule the whole feature is shaped around, restated for the picker: no
    /// wording of a dictation can raise it, because a dictation has no allowlist
    /// to be a near miss of.
    @MainActor
    func testNoDictationCanRaiseThePicker() async {
        for said in [
            "Vali101",
            "Open YouTube channel Vali101",
            "open the latest youtube video from valley 101",
            "打開YouTube頻道Vali101",
            "show me the channel picker",
        ] {
            let settings = Settings(purpose: .dictation, routesSpokenIntents: true)
            XCTAssertNil(
                settings.youTubeChannels,
                "A dictation has no allowlist, so it has nothing to miss.")
            XCTAssertFalse(settings.youTubeChannelPicker)

            let styled = await SpokenIntentPipeline.apply(
                to: ProcessedText(raw: said, final: said), settings: settings)
            XCTAssertEqual(styled.intent, .dictation, "“\(said)” must stay text.")
            XCTAssertTrue(styled.intent.insertsText)
            XCTAssertEqual(styled.intent.provenance.kind, .dictation)
        }
    }

    /// And the same rule as a property of the offer: it is built from a
    /// resolution, and only a command capture has one.
    @MainActor
    func testOnlyACommandCaptureCarriesAnAllowlistAndAPickerSetting() {
        AppPreferences.shared.youTubeLatestVideoEnabled = true
        AppPreferences.shared.youTubeChannelPickerEnabled = true

        XCTAssertFalse(Settings(purpose: .dictation).youTubeChannelPicker)
        XCTAssertFalse(
            Settings(purpose: .dictation, routesSpokenIntents: true).youTubeChannelPicker)
        XCTAssertTrue(Settings(purpose: .youTubeCommand).youTubeChannelPicker)

        AppPreferences.shared.youTubeLatestVideoEnabled = false
        XCTAssertFalse(
            Settings(purpose: .youTubeCommand).youTubeChannelPicker,
            "The feature's own switch is in front of the picker's.")
    }

    /// The picker is on by default, which is the change: a near miss used to end
    /// in a two-second refusal with no way back.
    @MainActor
    func testThePickerIsOnByDefault() {
        XCTAssertTrue(AppPreferences.shared.youTubeChannelPickerEnabled)
    }
}
