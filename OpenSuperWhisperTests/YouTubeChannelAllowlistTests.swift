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
        XCTAssertEqual(resolution, .allowlisted(veritasium, matchedBy: .spokenName))
    }

    func testCasePunctuationAndSpacingDoNotHaveToMatch() {
        for spoken in ["veritasium", "VERITASIUM.", "  Veritasium  ", "veritasium,"] {
            XCTAssertEqual(
                allowlist(veritasium).resolve(spokenName: spoken),
                .allowlisted(veritasium, matchedBy: .spokenName),
                "expected “\(spoken)” to resolve"
            )
        }
    }

    func testAnAliasResolvesToTheChannelItBelongsTo() {
        XCTAssertEqual(
            allowlist(veritasium).resolve(spokenName: "Vera Tasium"),
            .allowlisted(veritasium, matchedBy: .spokenName)
        )
    }

    func testTraditionalAndSimplifiedAnswerForEachOther() {
        XCTAssertEqual(
            allowlist(kejidaodu).resolve(spokenName: "科技岛读"),
            .allowlisted(kejidaodu, matchedBy: .spokenName)
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

    // MARK: - Spacing inside the name

    /// Stored rather than computed: `YouTubeChannel` carries a `UUID` and is
    /// `Equatable` over it, so a fresh one per access would never equal itself.
    private let valley = YouTubeChannel(
        displayName: "valley101", channelID: "UCvalley101aaaaaaaaaaaaa"
    )

    /// The second tier. Where a space falls inside a name is the one variation a
    /// speaker cannot control, so it is folded - and folded in a tier of its own,
    /// so an exact stored spelling always wins first.
    func testASpacedSpellingFindsAChannelStoredWithoutSpaces() {
        XCTAssertEqual(
            allowlist(valley).resolve(spokenName: "valley 101"),
            .allowlisted(valley, matchedBy: .spacing)
        )
        XCTAssertEqual(
            allowlist(valley).resolve(spokenName: "Valley 101."),
            .allowlisted(valley, matchedBy: .spacing)
        )
    }

    func testASpacedStoredNameIsFoundBySayingItWithoutSpaces() {
        let spaced = YouTubeChannel(displayName: "小 Lin 說", channelID: "UCxiaolinaaaaaaaaaaaaaaa")
        XCTAssertEqual(
            allowlist(spaced).resolve(spokenName: "小Lin說"),
            .allowlisted(spaced, matchedBy: .spacing)
        )
        // Its own spelling is still the exact tier.
        XCTAssertEqual(
            allowlist(spaced).resolve(spokenName: "小 Lin 說"),
            .allowlisted(spaced, matchedBy: .spokenName)
        )
    }

    func testFoldingSpacingIsNotFoldingAnythingElse() {
        // Still a whole-name match: nothing is stemmed, truncated or joined to
        // a neighbour.
        for spoken in ["valley", "valley 1012", "valley 10", "the valley 101"] {
            XCTAssertEqual(
                allowlist(valley).resolve(spokenName: spoken),
                .unknown(spoken: spoken),
                "expected “\(spoken)” to name nothing"
            )
        }
    }

    /// Two rows that differ only in spacing keep their own exact spellings and
    /// only collide on a third spelling that matches both - which is refused,
    /// not guessed.
    func testTwoRowsDifferingOnlyInSpacingStayIndividuallyReachable() {
        let spaced = YouTubeChannel(displayName: "valley 101", channelID: "UCzzzzzzzzzzzzzzzzzzzzzz")
        let list = allowlist(valley, spaced)

        XCTAssertEqual(list.resolve(spokenName: "valley101"), .allowlisted(valley, matchedBy: .spokenName))
        XCTAssertEqual(list.resolve(spokenName: "valley 101"), .allowlisted(spaced, matchedBy: .spokenName))
        XCTAssertEqual(
            list.resolve(spokenName: "valley  1 0 1"),
            .ambiguous(spoken: "valley  1 0 1", matches: ["valley101", "valley 101"])
        )
    }

    func testAnExactMatchBeatsASpacingMatchOnAnotherRow() {
        let other = YouTubeChannel(
            displayName: "Valley One", aliases: ["valley101"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertEqual(
            allowlist(valley, other).resolve(spokenName: "valley 101"),
            // Two rows carry the compact key, so the spacing tier refuses - the
            // exact tier had no answer for this spelling at all.
            .ambiguous(spoken: "valley 101", matches: ["valley101", "Valley One"])
        )
        XCTAssertEqual(
            allowlist(valley, other).resolve(spokenName: "Valley One"),
            .allowlisted(other, matchedBy: .spokenName)
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

    func testThePaneSaysTheCommandHasItsOwnKeyAndDictationIsUnchanged() {
        // The distinction the whole feature rests on, and the one a user is most
        // likely to have wrong: shortening it away fails here.
        let sentence = YouTubeChannelHelpText.shortcutWorkflow(shortcut: "⌥Y")
        XCTAssertTrue(sentence.contains("⌥Y"))
        XCTAssertTrue(sentence.contains("dictation shortcut"))
        XCTAssertTrue(sentence.contains("never types"))

        // A cleared binding leaves no way to use the feature, and says so.
        let unbound = YouTubeChannelHelpText.shortcutWorkflow(shortcut: nil)
        XCTAssertTrue(unbound.contains("not set"))
        XCTAssertTrue(unbound.contains("Shortcuts"))
    }

    func testThePaneDisclosesWhatTheModelIsGivenAndWhereItRuns() {
        let hint = YouTubeChannelHelpText.modelMatchHint
        XCTAssertTrue(hint.contains("Off by default"))
        XCTAssertTrue(hint.contains("on-device"))
        XCTAssertTrue(hint.contains("never leaves this Mac"))
        XCTAssertTrue(YouTubeChannelHelpText.modelMatchDisclosure.contains("dictation never reaches it"))
    }

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

    /// Both families of the grammar are named, and each example is one the
    /// router actually accepts. A pane that taught only the video wording is how
    /// "open YouTube channel …" looked like a missing channel rather than an
    /// unsupported sentence.
    func testTheUsageSentenceTeachesBothWaysOfNamingTheCommand() {
        let sentence = YouTubeChannelHelpText.usage(exampleChannel: "Veritasium")
        XCTAssertTrue(sentence.contains("open the latest YouTube video from Veritasium"))
        XCTAssertTrue(sentence.contains("open YouTube channel Veritasium"))

        for taught in [
            "open the latest YouTube video from Veritasium",
            "open YouTube channel Veritasium",
        ] {
            XCTAssertEqual(
                YouTubeCommandRouter.resolve(taught, channels: allowlist(veritasium)),
                .allowlisted(veritasium, matchedBy: .spokenName),
                "the pane teaches “\(taught)”, so the router has to accept it"
            )
        }

        let chinese = YouTubeChannelHelpText.usage(exampleChannel: "科技島讀")
        for taught in ["播放YouTube最新影片科技島讀", "打開YouTube頻道科技島讀"] {
            XCTAssertTrue(chinese.contains(taught))
            XCTAssertEqual(
                YouTubeCommandRouter.resolve(taught, channels: allowlist(kejidaodu)),
                .allowlisted(kejidaodu, matchedBy: .spokenName),
                "the pane teaches “\(taught)”, so the router has to accept it"
            )
        }
    }

    func testSpokenKeysIncludeTheNameAndEveryDistinctAlias() {
        XCTAssertEqual(
            veritasium.spokenKeys, ["veritasium", "vera tasium", "verita zium"]
        )
    }
}
