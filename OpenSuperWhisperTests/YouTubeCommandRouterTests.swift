import XCTest
@testable import OpenSuperWhisper

/// What the YouTube command hotkey's capture is read as, and - the half that
/// matters more - what the dictation shortcut's capture can never be read as.
///
/// Both routers are pure, so every case here is a string in and a decision out.
final class YouTubeCommandRouterTests: XCTestCase {

    private let veritasium = YouTubeChannel(
        displayName: "Veritasium",
        aliases: ["vera tasium"],
        channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
    )
    private let kejidaodu = YouTubeChannel(
        displayName: "科技島讀",
        channelID: "UCabcdefghijklmnopqrstuv"
    )
    private let valley = YouTubeChannel(
        displayName: "valley101",
        channelID: "UCvalley101aaaaaaaaaaaaa"
    )

    private var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: [veritasium, kejidaodu, valley])
    }

    private func resolve(_ transcript: String) -> YouTubeChannelResolution {
        YouTubeCommandRouter.resolve(transcript, channels: allowlist)
    }

    // MARK: - The bare channel name

    /// The key already said what the utterance is for, so a marker is no longer
    /// what tells a command apart from a sentence. Saying the channel is the
    /// whole command.
    func testNamingTheChannelOnItsOwnIsTheWholeCommand() {
        XCTAssertEqual(resolve("Veritasium"), .allowlisted(veritasium, matchedBy: .spokenName))
        XCTAssertEqual(resolve("科技島讀"), .allowlisted(kejidaodu, matchedBy: .spokenName))
        XCTAssertEqual(resolve("  veritasium.  "), .allowlisted(veritasium, matchedBy: .spokenName))
    }

    func testAnAliasNamesTheSameChannel() {
        XCTAssertEqual(resolve("vera tasium"), .allowlisted(veritasium, matchedBy: .spokenName))
    }

    // MARK: - The marker, still accepted

    func testEverySpellingOfTheEnglishCommandIsStillAccepted() {
        for said in [
            "Open the latest YouTube video from Veritasium",
            "open the newest youtube video from Veritasium",
            "Play the latest YouTube video from Veritasium.",
            "play the newest YouTube video from Veritasium",
            "Open latest YouTube video from Veritasium",
            "play latest youtube video from Veritasium",
            "Open YouTube latest video from Veritasium",
            "play youtube latest video from: Veritasium",
            "Open the YouTube channel Veritasium",
            "play the youtube channel Veritasium",
            "Open YouTube channel: Veritasium",
            "play youtube channel Veritasium",
        ] {
            XCTAssertEqual(
                resolve(said), .allowlisted(veritasium, matchedBy: .spokenName),
                "expected “\(said)” to name Veritasium"
            )
        }
    }

    /// The regression this family was added for: what a user actually said into
    /// the command key, four times, every one of them refused as a channel that
    /// was in their list all along. Naming the channel is the same command as
    /// naming its latest video.
    func testNamingTheChannelRatherThanTheVideoIsTheSameCommand() {
        XCTAssertEqual(
            resolve("open YouTube channel valley101"),
            .allowlisted(valley, matchedBy: .spokenName)
        )
        // And the spacing tier still answers behind the marker, which is the
        // half a speech engine varies on its own.
        XCTAssertEqual(
            resolve("Open the YouTube channel valley 101"),
            .allowlisted(valley, matchedBy: .spacing)
        )
    }

    func testTheChineseCommandIsAcceptedWithOrWithoutSpaces() {
        for said in [
            "打開YouTube最新影片科技島讀",
            "打開 YouTube 最新影片 科技島讀",
            "播放YouTube最新影片：科技島讀",
            "打开YouTube最新视频 科技岛读",
            "播放 youtube 最新影片 科技島讀",
            "打開YouTube頻道科技島讀",
            "打开YouTube频道 科技岛读",
            "播放 YouTube 頻道 科技島讀",
            "開啟YouTube頻道：科技島讀",
        ] {
            XCTAssertEqual(
                resolve(said), .allowlisted(kejidaodu, matchedBy: .spokenName),
                "expected “\(said)” to name 科技島讀"
            )
        }
    }

    /// The same guarantee the translate grammar carries: a Simplified speaker's
    /// command still routes after `ChineseScriptNormalizer` has written their
    /// transcript in Traditional - marker and channel name included.
    func testTheCommandStillRoutesAfterTheTranscriptWasConvertedToTheOtherScript() {
        let spoken = "打开YouTube最新视频 科技岛读"
        let normalized = ChineseScriptNormalizer.normalized(
            spoken, to: .traditional, languageCode: "zh"
        )
        XCTAssertNotEqual(normalized, spoken)
        XCTAssertEqual(resolve(normalized), .allowlisted(kejidaodu, matchedBy: .spokenName))

        let channelForm = "打开YouTube频道 科技岛读"
        let convertedChannelForm = ChineseScriptNormalizer.normalized(
            channelForm, to: .traditional, languageCode: "zh"
        )
        XCTAssertNotEqual(convertedChannelForm, channelForm)
        XCTAssertEqual(
            resolve(convertedChannelForm), .allowlisted(kejidaodu, matchedBy: .spokenName)
        )
    }

    func testAMarkerWithNoChannelBehindItQuotesTheWholeUtteranceBack() {
        // Nothing to open and nothing to guess at, and the message has to say
        // what the app actually heard.
        XCTAssertEqual(
            resolve("Open the latest YouTube video from"),
            .unknown(spoken: "Open the latest YouTube video from")
        )
        XCTAssertEqual(
            resolve("open YouTube channel"),
            .unknown(spoken: "open YouTube channel")
        )
        XCTAssertEqual(
            resolve("打開YouTube頻道"),
            .unknown(spoken: "打開YouTube頻道")
        )
    }

    func testNothingSaidNamesNothing() {
        XCTAssertEqual(resolve("   "), .unknown(spoken: ""))
    }

    // MARK: - Channels that name nothing

    func testAnUnknownChannelIsRefusedRatherThanGuessed() {
        XCTAssertEqual(
            resolve("Some Other Channel"), .unknown(spoken: "Some Other Channel")
        )
        XCTAssertEqual(
            resolve("Open the latest YouTube video from Some Other Channel"),
            .unknown(spoken: "Some Other Channel")
        )
        XCTAssertEqual(
            resolve("open YouTube channel Some Other Channel"),
            .unknown(spoken: "Some Other Channel")
        )
        // A name the engine misheard - "valley 101" written as "Bali 101" - is
        // still nobody's channel, and the marker being stripped is what lets the
        // message quote back the two words the user can act on rather than the
        // whole sentence they said.
        XCTAssertEqual(
            resolve("Open the YouTube channel Bali 101"), .unknown(spoken: "Bali 101")
        )
    }

    func testAPartialNameNamesNothing() {
        // Nothing is stemmed and nothing truncated, on this path either.
        XCTAssertEqual(resolve("Verita"), .unknown(spoken: "Verita"))
        XCTAssertEqual(resolve("Veritasium please"), .unknown(spoken: "Veritasium please"))
        // Widening the marker did not widen the match: what follows one still
        // has to be a stored spelling in full.
        XCTAssertEqual(
            resolve("open YouTube channel valley"), .unknown(spoken: "valley")
        )
        XCTAssertEqual(
            resolve("open YouTube channel valley 1012"), .unknown(spoken: "valley 1012")
        )
    }

    func testAnAmbiguousChannelIsRefusedRatherThanGuessed() {
        let clash = YouTubeChannel(
            displayName: "Veritasium Clips",
            aliases: ["veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertEqual(
            YouTubeCommandRouter.resolve(
                "Veritasium",
                channels: YouTubeChannelAllowlist(channels: [veritasium, clash])
            ),
            .ambiguous(spoken: "Veritasium", matches: ["Veritasium", "Veritasium Clips"])
        )
    }

    func testAnEmptyAllowlistSaysNothingAnswersRatherThanNothingHappening() {
        XCTAssertEqual(
            YouTubeCommandRouter.resolve("Veritasium", channels: .empty),
            .unknown(spoken: "Veritasium")
        )
    }

    // MARK: - Spacing

    func testASpokenSpaceInsideTheNameStillFindsTheChannel() {
        // The whole point of the second tier: "valley one oh one" comes back as
        // "valley 101" or "valley101" depending on the engine and the day.
        XCTAssertEqual(resolve("valley 101"), .allowlisted(valley, matchedBy: .spacing))
        XCTAssertEqual(
            resolve("Open the latest YouTube video from valley 101"),
            .allowlisted(valley, matchedBy: .spacing)
        )
    }

    // MARK: - Dictation can never do this

    /// The regression this whole shape exists for. Every one of these is what a
    /// user might say into the **dictation** shortcut, and every one of them is
    /// text on its way into their document - there is no reading of a dictation
    /// that opens a browser, because `SpokenIntent` has no case for one.
    func testNoDictationHoweverWordedCanBecomeACommand() {
        for said in [
            "Open the latest YouTube video from Veritasium",
            "播放YouTube最新影片科技島讀",
            "open the newest youtube video from valley 101",
            "Play the latest YouTube video from Veritasium.",
            "Veritasium",
            "open YouTube channel valley101",
            "Open the YouTube channel Veritasium",
            "打開YouTube頻道科技島讀",
        ] {
            XCTAssertEqual(
                SpokenIntentRouter.route(said), .dictate(said),
                "expected “\(said)” to be dictated as text"
            )
        }
    }

    func testTheOtherSpokenCommandsAreUnaffected() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Ask: what is the capital of France"),
            .ask(query: "what is the capital of France")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Translate to Spanish: good morning"),
            .translate(target: SpokenTranslationTarget(languageCode: "es"), text: "good morning")
        )
        let snippet = VoiceSnippet(keyword: "email signoff", expansion: "Best regards")
        XCTAssertEqual(
            SpokenIntentRouter.route("insert email signoff", snippets: [snippet]),
            .snippet(keyword: "email signoff", expansion: "Best regards")
        )
    }

    // MARK: - What the outcome promises

    func testTheCommandInsertsNothing() {
        for resolution: YouTubeChannelResolution in [
            .allowlisted(veritasium, matchedBy: .spokenName),
            .allowlisted(veritasium, matchedBy: .model(spoken: "vera")),
            .unknown(spoken: "Some Channel"),
            .ambiguous(spoken: "Veritasium", matches: ["a", "b"]),
            .disabled(spoken: "Veritasium"),
        ] {
            XCTAssertFalse(SpokenIntentOutcome.openLatestVideo(resolution).insertsText)
        }
    }

    func testTheChipNamesWhateverWasHeard() {
        XCTAssertEqual(
            SpokenIntentOutcome.openLatestVideo(
                .allowlisted(veritasium, matchedBy: .spokenName)
            ).capsuleMode,
            CapsuleHUDMode(label: "YouTube: Veritasium")
        )
        XCTAssertEqual(
            SpokenIntentOutcome.openLatestVideo(.unknown(spoken: "Some Channel")).capsuleMode,
            CapsuleHUDMode(label: "YouTube: Some Channel")
        )
        XCTAssertEqual(
            SpokenIntentOutcome.openLatestVideo(
                .unknown(spoken: "a channel with a very long name indeed")
            ).capsuleMode,
            CapsuleHUDMode(label: "YouTube")
        )
    }
}
