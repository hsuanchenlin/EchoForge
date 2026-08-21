import XCTest
@testable import OpenSuperWhisper

/// The allowlist: what a spoken name resolves to, and what Settings refuses to
/// store.
///
/// Pure functions over a list, so none of this touches a defaults domain, a
/// network or a browser.
final class YouTubeChannelAllowlistTests: XCTestCase {

    private let veritasium = YouTubeChannel(
        displayName: "Veritasium",
        aliases: ["vera tasium", "verita zium"],
        channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
    )
    private let kejidaodu = YouTubeChannel(
        displayName: "科技島讀",
        aliases: [],
        channelID: "UCabcdefghijklmnopqrstuv"
    )

    private func allowlist(_ channels: YouTubeChannel...) -> YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: channels)
    }

    // MARK: - Resolving a spoken name

    func testTheDisplayNameResolvesWithoutBeingListedAsAnAlias() {
        let resolution = allowlist(veritasium).resolve(spokenName: "Veritasium")
        XCTAssertEqual(resolution, .allowlisted(veritasium))
    }

    func testCasePunctuationAndSpacingDoNotHaveToMatch() {
        for spoken in ["veritasium", "VERITASIUM.", "  Veritasium  ", "veritasium,"] {
            XCTAssertEqual(
                allowlist(veritasium).resolve(spokenName: spoken),
                .allowlisted(veritasium),
                "expected “\(spoken)” to resolve"
            )
        }
    }

    func testAnAliasResolvesToTheChannelItBelongsTo() {
        XCTAssertEqual(
            allowlist(veritasium).resolve(spokenName: "Vera Tasium"),
            .allowlisted(veritasium)
        )
    }

    func testTraditionalAndSimplifiedAnswerForEachOther() {
        XCTAssertEqual(
            allowlist(kejidaodu).resolve(spokenName: "科技岛读"),
            .allowlisted(kejidaodu)
        )
    }

    func testAPartialNameIsNotAMatch() {
        // Nothing is stemmed and nothing is truncated: a near miss that opened
        // *something* would be the app choosing a channel the user did not.
        XCTAssertEqual(
            allowlist(veritasium).resolve(spokenName: "Veritasium please"),
            .unknown(spoken: "Veritasium please")
        )
        XCTAssertEqual(
            allowlist(veritasium).resolve(spokenName: "Verita"),
            .unknown(spoken: "Verita")
        )
    }

    func testAnUnknownChannelResolvesToUnknownRatherThanToAnything() {
        XCTAssertEqual(
            allowlist(veritasium).resolve(spokenName: "some other channel"),
            .unknown(spoken: "some other channel")
        )
    }

    func testAnEmptyAllowlistKnowsNoChannel() {
        XCTAssertEqual(
            YouTubeChannelAllowlist.empty.resolve(spokenName: "Veritasium"),
            .unknown(spoken: "Veritasium")
        )
    }

    func testADisabledChannelIsNotReachable() {
        var disabled = veritasium
        disabled.isEnabled = false
        XCTAssertEqual(
            allowlist(disabled).resolve(spokenName: "Veritasium"),
            .unknown(spoken: "Veritasium")
        )
    }

    func testAChannelWithAnInvalidIDIsNotReachable() {
        let broken = YouTubeChannel(displayName: "Veritasium", channelID: "@veritasium")
        XCTAssertEqual(
            allowlist(broken).resolve(spokenName: "Veritasium"),
            .unknown(spoken: "Veritasium")
        )
    }

    func testTwoChannelsAnsweringToOneNameAreAmbiguousRatherThanFirstWins() {
        let clash = YouTubeChannel(
            displayName: "Veritasium Clips",
            aliases: ["veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertEqual(
            allowlist(veritasium, clash).resolve(spokenName: "Veritasium"),
            .ambiguous(spoken: "Veritasium", matches: ["Veritasium", "Veritasium Clips"])
        )
    }

    func testAnEmptySpokenNameIsUnknown() {
        XCTAssertEqual(allowlist(veritasium).resolve(spokenName: "  "), .unknown(spoken: ""))
    }

    // MARK: - Validation

    func testAValidDraftHasNoProblems() {
        XCTAssertTrue(YouTubeChannelAllowlist.problems(with: veritasium, against: []).isEmpty)
    }

    func testANamelessDraftIsRefused() {
        let draft = YouTubeChannel(displayName: "  ", channelID: veritasium.channelID)
        XCTAssertEqual(
            YouTubeChannelAllowlist.problems(with: draft, against: []), [.missingName]
        )
    }

    func testAHandleIsNotAChannelID() {
        let draft = YouTubeChannel(displayName: "Veritasium", channelID: "@veritasium")
        XCTAssertEqual(
            YouTubeChannelAllowlist.problems(with: draft, against: []), [.invalidChannelID]
        )
    }

    func testASecondRowWithTheSameChannelIDIsRefused() {
        let duplicate = YouTubeChannel(displayName: "Derek", channelID: veritasium.channelID)
        XCTAssertEqual(
            YouTubeChannelAllowlist.problems(with: duplicate, against: [veritasium]),
            [.duplicateChannelID(existing: "Veritasium")]
        )
    }

    func testASecondRowAnsweringToTheSameSpokenNameIsRefused() {
        let clash = YouTubeChannel(
            displayName: "Veritasium",
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertEqual(
            YouTubeChannelAllowlist.problems(with: clash, against: [veritasium]),
            [.duplicateSpokenName("veritasium", existing: "Veritasium")]
        )
    }

    func testAnAliasClashingWithAnotherRowsNameIsRefused() {
        let clash = YouTubeChannel(
            displayName: "Derek's channel",
            aliases: ["Veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertEqual(
            YouTubeChannelAllowlist.problems(with: clash, against: [veritasium]),
            [.duplicateSpokenName("veritasium", existing: "Veritasium")]
        )
    }

    func testEditingARowDoesNotClashWithItself() {
        var edited = veritasium
        edited.displayName = "Veritasium"
        XCTAssertTrue(
            YouTubeChannelAllowlist.problems(with: edited, against: [veritasium]).isEmpty
        )
    }

    // MARK: - Deduplication

    func testSavingDropsBlankAndRepeatedAliases() {
        let draft = YouTubeChannel(
            displayName: " Veritasium ",
            aliases: ["vera tasium", "  ", "VERA TASIUM", "veritasium", "verita zium"],
            channelID: " UCHnyfMqiRRG1u-2MsSQLbXA "
        )

        let tidied = draft.deduplicated

        XCTAssertEqual(tidied.displayName, "Veritasium")
        XCTAssertEqual(tidied.channelID, "UCHnyfMqiRRG1u-2MsSQLbXA")
        // "VERA TASIUM" normalizes onto the first one, and "veritasium" onto the
        // display name, which already answers.
        XCTAssertEqual(tidied.aliases, ["vera tasium", "verita zium"])
    }

    // MARK: - What Settings has to say

    func testThePaneSaysWhereToFindAChannelID() {
        // The one thing a user cannot guess, so the instruction is an obligation
        // rather than decoration: shortening it away fails here.
        let instructions = YouTubeChannelHelpText.channelIDInstructions
        XCTAssertTrue(instructions.contains("Share channel"))
        XCTAssertTrue(instructions.contains("youtube.com/channel/"))
        XCTAssertTrue(instructions.contains("handle"))
    }

    func testThePaneSaysAutoplayIsTheBrowsersDecision() {
        let note = YouTubeChannelHelpText.autoplayNote
        XCTAssertTrue(note.contains("autoplay"))
        XCTAssertTrue(note.contains("Chrome"))
        // And it is repeated wherever the command is explained.
        XCTAssertTrue(YouTubeChannelHelpText.usage(exampleChannel: "Veritasium").contains(note))
    }

    func testTheUsageSentenceIsWrittenAroundTheUsersOwnChannel() {
        XCTAssertTrue(
            YouTubeChannelHelpText.usage(exampleChannel: "科技島讀").contains("科技島讀")
        )
    }

    func testSpokenKeysIncludeTheNameAndEveryDistinctAlias() {
        XCTAssertEqual(
            veritasium.spokenKeys, ["veritasium", "vera tasium", "verita zium"]
        )
    }
}
