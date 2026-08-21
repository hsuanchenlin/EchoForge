import XCTest
@testable import OpenSuperWhisper

/// The grammar for "open the latest YouTube video from …".
///
/// The router is pure, so every case here is a string in and a decision out -
/// and the decision that matters most is the one where nothing is recognised and
/// the words stay dictation.
final class SpokenIntentRouterYouTubeTests: XCTestCase {

    private let veritasium = YouTubeChannel(
        displayName: "Veritasium",
        aliases: ["vera tasium"],
        channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
    )
    private let kejidaodu = YouTubeChannel(
        displayName: "科技島讀",
        channelID: "UCabcdefghijklmnopqrstuv"
    )

    private var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: [veritasium, kejidaodu])
    }

    private func route(_ transcript: String) -> SpokenIntent {
        SpokenIntentRouter.route(transcript, channels: allowlist)
    }

    // MARK: - The command

    func testEverySpellingOfTheEnglishCommandIsRecognised() {
        for said in [
            "Open the latest YouTube video from Veritasium",
            "open the newest youtube video from Veritasium",
            "Play the latest YouTube video from Veritasium.",
            "play the newest YouTube video from Veritasium",
            "Open latest YouTube video from Veritasium",
            "play latest youtube video from Veritasium",
            "Open YouTube latest video from Veritasium",
            "play youtube latest video from: Veritasium",
        ] {
            XCTAssertEqual(
                route(said), .openLatestVideo(.allowlisted(veritasium)),
                "expected “\(said)” to be the command"
            )
        }
    }

    func testTheChineseCommandIsRecognisedWithOrWithoutSpaces() {
        for said in [
            "打開YouTube最新影片科技島讀",
            "打開 YouTube 最新影片 科技島讀",
            "播放YouTube最新影片：科技島讀",
            "打开YouTube最新视频 科技岛读",
            "播放 youtube 最新影片 科技島讀",
        ] {
            XCTAssertEqual(
                route(said), .openLatestVideo(.allowlisted(kejidaodu)),
                "expected “\(said)” to be the command"
            )
        }
    }

    /// The guarantee the translate grammar carries, held here too: the command a
    /// Simplified speaker dictates still routes after `ChineseScriptNormalizer`
    /// has written their transcript in Traditional - marker and channel name
    /// included. ICU writes 视频 as 視頻, which no engine spelling uses, so the
    /// marker list has to know the converted form as its own entry.
    func testTheCommandStillRoutesAfterTheTranscriptWasConvertedToTheOtherScript() {
        let spoken = "打开YouTube最新视频 科技岛读"
        let normalized = ChineseScriptNormalizer.normalized(
            spoken, to: .traditional, languageCode: "zh"
        )
        XCTAssertNotEqual(normalized, spoken)
        XCTAssertEqual(route(normalized), .openLatestVideo(.allowlisted(kejidaodu)))
    }

    func testAnAliasNamesTheSameChannel() {
        XCTAssertEqual(
            route("Open the latest YouTube video from vera tasium"),
            .openLatestVideo(.allowlisted(veritasium))
        )
    }

    // MARK: - Channels that name nothing

    func testAnUnknownChannelIsTheCommandRatherThanDictation() {
        // The marker names YouTube and says which video is wanted, so this is
        // not a sentence anybody was writing: the user is told their channel is
        // not listed instead of having the words pasted into their document.
        XCTAssertEqual(
            route("Open the latest YouTube video from Some Other Channel"),
            .openLatestVideo(.unknown(spoken: "Some Other Channel"))
        )
    }

    func testAnAmbiguousChannelIsRefusedRatherThanGuessed() {
        let clash = YouTubeChannel(
            displayName: "Veritasium Clips",
            aliases: ["veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        let intent = SpokenIntentRouter.route(
            "Open the latest YouTube video from Veritasium",
            channels: YouTubeChannelAllowlist(channels: [veritasium, clash])
        )
        XCTAssertEqual(
            intent,
            .openLatestVideo(
                .ambiguous(spoken: "Veritasium", matches: ["Veritasium", "Veritasium Clips"])
            )
        )
    }

    func testAnEmptyAllowlistStillReadsTheCommandAndSaysNothingAnswers() {
        // Empty is not the same as absent: the user switched the feature on and
        // has listed nothing, and that is worth being told.
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Open the latest YouTube video from Veritasium", channels: .empty
            ),
            .openLatestVideo(.unknown(spoken: "Veritasium"))
        )
    }

    // MARK: - Everything that stays dictation

    func testWithoutAnAllowlistTheSameWordsAreDictation() {
        // `nil` channels is every path that does not run this command: the
        // feature switched off, a dropped file, a regenerate from history.
        let said = "Open the latest YouTube video from Veritasium"
        XCTAssertEqual(SpokenIntentRouter.route(said), .dictate(said))
    }

    func testOrdinarySentencesAreNotCommands() {
        for said in [
            "Open the latest video from Veritasium",
            "I watched the latest YouTube video from Veritasium yesterday",
            "Open YouTube",
            "Can you open the latest YouTube video from Veritasium for me",
            "The newest YouTube video from Veritasium was about relativity",
            "youtube latest video",
        ] {
            XCTAssertEqual(route(said), .dictate(said), "expected “\(said)” to stay dictation")
        }
    }

    func testAMarkerWithNoChannelBehindItIsDictation() {
        let said = "Open the latest YouTube video from"
        XCTAssertEqual(route(said), .dictate(said))
        let trailing = "Open the latest YouTube video from  "
        XCTAssertEqual(route(trailing), .dictate(trailing))
    }

    func testTheMarkerOnlyCountsAtTheFrontOfADictation() {
        let said = "Tell them to open the latest YouTube video from Veritasium"
        XCTAssertEqual(route(said), .dictate(said))
    }

    // MARK: - The commands that were already there

    func testTheOlderCommandsAreUnaffected() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Ask: what is the capital of France", channels: allowlist),
            .ask(query: "what is the capital of France")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Translate to Spanish: good morning", channels: allowlist),
            .translate(
                target: SpokenTranslationTarget(languageCode: "es"), text: "good morning"
            )
        )
        let snippet = VoiceSnippet(keyword: "email signoff", expansion: "Best regards")
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "insert email signoff", snippets: [snippet], channels: allowlist
            ),
            .snippet(keyword: "email signoff", expansion: "Best regards")
        )
        let plain = "Just some words I said out loud."
        XCTAssertEqual(SpokenIntentRouter.route(plain, channels: allowlist), .dictate(plain))
    }

    // MARK: - What the outcome promises

    func testTheCommandInsertsNothing() {
        let outcome = SpokenIntentOutcome.openLatestVideo(.allowlisted(veritasium))
        XCTAssertFalse(outcome.insertsText)
        XCTAssertEqual(outcome.capsuleMode, CapsuleHUDMode(label: "YouTube: Veritasium"))
    }

    func testAnUnknownChannelAlsoInsertsNothingAndIsNamedOnTheChip() {
        let outcome = SpokenIntentOutcome.openLatestVideo(.unknown(spoken: "Some Channel"))
        XCTAssertFalse(outcome.insertsText)
        XCTAssertEqual(outcome.capsuleMode, CapsuleHUDMode(label: "YouTube: Some Channel"))
    }

    func testALongChannelNameFallsBackToThePlainChip() {
        let outcome = SpokenIntentOutcome.openLatestVideo(
            .unknown(spoken: "a channel with a very long name indeed")
        )
        XCTAssertEqual(outcome.capsuleMode, CapsuleHUDMode(label: "YouTube"))
    }
}
