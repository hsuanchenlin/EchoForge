import XCTest
@testable import OpenSuperWhisper

/// The one place a model touches this feature, and every way it is made
/// harmless.
///
/// The model is injected, so none of this reaches Apple Intelligence and none of
/// it depends on the Mac the tests run on - which is the same seam
/// `StyleRewriteServiceTests` uses and for the same reason.
final class YouTubeChannelModelMatchTests: IsolatedPreferencesTestCase {

    private let valley = YouTubeChannel(
        displayName: "valley101",
        aliases: ["valley one oh one"],
        channelID: "UCvalley101aaaaaaaaaaaaa"
    )
    private let veritasium = YouTubeChannel(
        displayName: "Veritasium",
        channelID: "UCHnyfMqiRRG1u-2MsSQLbXA"
    )

    private var allowlist: YouTubeChannelAllowlist {
        YouTubeChannelAllowlist(channels: [valley, veritasium])
    }

    /// A rewriter that answers with whatever it was told to, and remembers what
    /// it was asked.
    private final class StubRewriter: StyleRewriting, @unchecked Sendable {
        enum Behaviour {
            case answer(String)
            case fail(Error)
            case hang
        }
        let behaviour: Behaviour
        private(set) var prompts: [String] = []
        private(set) var sessionInstructions: [String] = []

        init(_ behaviour: Behaviour) { self.behaviour = behaviour }

        func rewrite(_ request: StyleRewriteRequest) async throws -> String {
            prompts.append(request.prompt)
            sessionInstructions.append(request.sessionInstructions)
            switch behaviour {
            case .answer(let text): return text
            case .fail(let error): throw error
            case .hang:
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return ""
            }
        }
    }

    private struct RefusingRewriter: StyleRewriting {
        struct Refused: Error {}
        func rewrite(_ request: StyleRewriteRequest) async throws -> String { throw Refused() }
    }

    private func refine(
        _ resolution: YouTubeChannelResolution,
        availability: StyleRewriteAvailability = .available,
        rewriter: StyleRewriting?,
        budget: TimeInterval? = nil
    ) async -> YouTubeChannelResolution {
        await YouTubeChannelModelMatch.refine(
            resolution,
            in: allowlist,
            availability: availability,
            rewriter: rewriter,
            budgetOverride: budget
        )
    }

    // MARK: - The answer it was asked for

    func testAnIndexNamingOneCandidateResolvesToThatChannel() async {
        let resolved = await refine(
            .unknown(spoken: "valley one o one"), rewriter: StubRewriter(.answer("1"))
        )
        XCTAssertEqual(resolved, .allowlisted(valley, matchedBy: .model(spoken: "valley one o one")))
    }

    func testTheAnswerMayAlsoBeTheChannelsOwnName() async {
        // A model asked for a number often returns the name. Reading it costs
        // nothing, because the name is looked up in the same candidate list.
        let resolved = await refine(
            .unknown(spoken: "vera tasium"), rewriter: StubRewriter(.answer("Veritasium"))
        )
        XCTAssertEqual(
            resolved, .allowlisted(veritasium, matchedBy: .model(spoken: "vera tasium"))
        )
    }

    func testAnAmbiguousResolutionCanAlsoBeSettledByTheModel() async {
        let clash = YouTubeChannel(
            displayName: "Veritasium Clips", aliases: ["veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        let resolved = await YouTubeChannelModelMatch.refine(
            .ambiguous(spoken: "Veritasium", matches: ["Veritasium", "Veritasium Clips"]),
            in: YouTubeChannelAllowlist(channels: [veritasium, clash]),
            availability: .available,
            rewriter: StubRewriter(.answer("1"))
        )
        XCTAssertEqual(
            resolved, .allowlisted(veritasium, matchedBy: .model(spoken: "Veritasium"))
        )
    }

    func testTheModelIsGivenOnlyTheSpokenPhraseAndTheStoredNames() async {
        let stub = StubRewriter(.answer("NONE"))
        _ = await refine(.unknown(spoken: "valley one o one"), rewriter: stub)

        let sent = stub.prompts.first ?? ""
        XCTAssertFalse(sent.isEmpty, "the model was never asked")
        XCTAssertTrue(sent.contains("valley one o one"))
        XCTAssertTrue(sent.contains("valley101"))
        XCTAssertTrue(sent.contains("valley one oh one"))
        XCTAssertTrue(sent.contains("Veritasium"))
        // Nothing that could become a target: no channel id, no URL, no host.
        XCTAssertFalse(sent.contains(valley.channelID))
        XCTAssertFalse(sent.contains(veritasium.channelID))
        XCTAssertFalse(sent.lowercased().contains("youtube.com"))
        XCTAssertFalse(sent.lowercased().contains("http"))
    }

    // MARK: - Fail closed

    func testAHallucinatedChannelIsRefused() async {
        for answer in [
            "Linus Tech Tips",
            "UCzzzzzzzzzzzzzzzzzzzzzz",
            "https://www.youtube.com/channel/UCzzzzzzzzzzzzzzzzzzzzzz",
            "https://youtu.be/dQw4w9WgXcQ",
            "open Chrome",
            "3",
            "0",
            "-1",
            "+1",
            "1.5",
            "1 or 2",
            "one",
            "the first one",
            "It is probably valley101.",
            "",
            "   ",
        ] {
            let resolved = await refine(
                .unknown(spoken: "something"), rewriter: StubRewriter(.answer(answer))
            )
            XCTAssertEqual(
                resolved, .unknown(spoken: "something"),
                "expected “\(answer)” to be refused"
            )
        }
    }

    func testAnExplicitNoMatchIsRefused() async {
        for answer in ["NONE", "none", " None. "] {
            let resolved = await refine(
                .unknown(spoken: "something"), rewriter: StubRewriter(.answer(answer))
            )
            XCTAssertEqual(resolved, .unknown(spoken: "something"))
        }
    }

    func testAnUnavailableModelChangesNothing() async {
        for availability: StyleRewriteAvailability in [
            .unsupportedSystem, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady,
            .cloudNotConfigured("no key"),
        ] {
            let resolved = await refine(
                .unknown(spoken: "valley one o one"),
                availability: availability,
                rewriter: StubRewriter(.answer("1"))
            )
            XCTAssertEqual(
                resolved, .unknown(spoken: "valley one o one"),
                "expected \(availability) to refuse"
            )
        }
    }

    func testNoRewriterAtAllChangesNothing() async {
        let resolved = await refine(.unknown(spoken: "valley one o one"), rewriter: nil)
        XCTAssertEqual(resolved, .unknown(spoken: "valley one o one"))
    }

    func testAModelThatThrowsChangesNothing() async {
        let resolved = await refine(
            .unknown(spoken: "valley one o one"), rewriter: RefusingRewriter()
        )
        XCTAssertEqual(resolved, .unknown(spoken: "valley one o one"))
    }

    func testAModelThatNeverAnswersIsAbandonedAtItsDeadline() async {
        let resolved = await refine(
            .unknown(spoken: "valley one o one"),
            rewriter: StubRewriter(.hang),
            budget: 0.2
        )
        XCTAssertEqual(resolved, .unknown(spoken: "valley one o one"))
    }

    func testAnAlreadyResolvedChannelIsNeverReAsked() async {
        let stub = StubRewriter(.answer("2"))
        let resolved = await refine(
            .allowlisted(valley, matchedBy: .spokenName), rewriter: stub
        )
        XCTAssertEqual(resolved, .allowlisted(valley, matchedBy: .spokenName))
        XCTAssertTrue(stub.prompts.isEmpty)
    }

    func testAnEmptyAllowlistIsNeverAsked() async {
        let stub = StubRewriter(.answer("1"))
        let resolved = await YouTubeChannelModelMatch.refine(
            .unknown(spoken: "valley"),
            in: .empty,
            availability: .available,
            rewriter: stub
        )
        XCTAssertEqual(resolved, .unknown(spoken: "valley"))
        XCTAssertTrue(stub.prompts.isEmpty)
    }

    func testAListLongerThanTheCapIsNotAsked() async {
        let many = (0..<(YouTubeChannelModelMatch.maximumCandidates + 1)).map { index in
            YouTubeChannel(
                displayName: "channel \(index)",
                channelID: "UC" + String(format: "%022d", index)
            )
        }
        let stub = StubRewriter(.answer("1"))
        let resolved = await YouTubeChannelModelMatch.refine(
            .unknown(spoken: "channel"),
            in: YouTubeChannelAllowlist(channels: many),
            availability: .available,
            rewriter: stub
        )
        XCTAssertEqual(resolved, .unknown(spoken: "channel"))
        XCTAssertTrue(stub.prompts.isEmpty)
    }

    func testAnUtteranceLongerThanTheCapIsNotAsked() async {
        let long = String(repeating: "a", count: YouTubeChannelModelMatch.maximumSpokenCharacters + 1)
        let stub = StubRewriter(.answer("1"))
        let resolved = await refine(.unknown(spoken: long), rewriter: stub)
        XCTAssertEqual(resolved, .unknown(spoken: long))
        XCTAssertTrue(stub.prompts.isEmpty)
    }

    // MARK: - The disabled case is never a model's to fix

    func testASwitchedOffCommandIsNotHandedToTheModel() async {
        let stub = StubRewriter(.answer("1"))
        let resolved = await refine(.disabled(spoken: "valley 101"), rewriter: stub)
        XCTAssertEqual(resolved, .disabled(spoken: "valley 101"))
        XCTAssertTrue(stub.prompts.isEmpty)
    }

    // MARK: - Interpretation, on its own

    func testInterpretOnlyEverReturnsACandidate() {
        let candidates = [valley, veritasium]
        XCTAssertEqual(YouTubeChannelModelMatch.interpret("2", candidates: candidates), veritasium)
        // A model asked for a number does write "2." - that much is forgiven.
        XCTAssertEqual(YouTubeChannelModelMatch.interpret(" 2. ", candidates: candidates), veritasium)
        // A sign is not: "-1" must never select the first entry.
        XCTAssertNil(YouTubeChannelModelMatch.interpret("-1", candidates: candidates))
        XCTAssertEqual(
            YouTubeChannelModelMatch.interpret("valley 101", candidates: candidates), valley
        )
        for answer in ["NONE", "5", "Linus", "UCzzzzzzzzzzzzzzzzzzzzzz", "1 or 2", "one"] {
            XCTAssertNil(
                YouTubeChannelModelMatch.interpret(answer, candidates: candidates),
                "expected “\(answer)” to name nothing"
            )
        }
    }

    /// Two candidates answering to what the model said is the ambiguity the
    /// fallback exists inside; it is not the model's to break.
    func testANameTwoCandidatesAnswerToIsRefused() {
        let clash = YouTubeChannel(
            displayName: "Veritasium Clips", aliases: ["veritasium"],
            channelID: "UCzzzzzzzzzzzzzzzzzzzzzz"
        )
        XCTAssertNil(
            YouTubeChannelModelMatch.interpret("Veritasium", candidates: [veritasium, clash])
        )
    }

    // MARK: - What the user is told

    func testAModelMatchIsDisclosedAndAPlainOneIsNot() {
        XCTAssertNil(YouTubeChannelMatchSource.spokenName.disclosure)
        XCTAssertNil(YouTubeChannelMatchSource.spacing.disclosure)
        let disclosure = YouTubeChannelMatchSource.model(spoken: "valley 101").disclosure
        XCTAssertNotNil(disclosure)
        XCTAssertTrue(disclosure?.contains("valley 101") == true)
        XCTAssertTrue(disclosure?.contains("on-device") == true)
    }

    func testTheOpenedReportSaysWhenAModelChoseTheChannel() {
        let plain = YouTubeLatestVideoReport.opened(
            channel: "valley101", title: "Ep 12", match: .spokenName
        )
        XCTAssertFalse(plain.spokenSummary.contains("model"))

        let matched = YouTubeLatestVideoReport.opened(
            channel: "valley101", title: "Ep 12", match: .model(spoken: "valley 101")
        )
        XCTAssertTrue(matched.spokenSummary.contains("Ep 12"))
        XCTAssertTrue(matched.spokenSummary.contains("on-device"))
    }

    // MARK: - Privacy defaults

    func testTheModelIsNeverAskedOnADefaultInstall() {
        XCTAssertFalse(AppPreferences.shared.youTubeChannelModelMatchEnabled)
    }

    /// The one place that decides where this feature's model runs: nowhere but
    /// this Mac. `CloudPrivacyTests` holds the same rule for the other two.
    func testChannelMatchingHasNoCloudPath() {
        XCTAssertNil(OnDeviceModelFeature.channelMatching.cloudFeature)
    }
}
