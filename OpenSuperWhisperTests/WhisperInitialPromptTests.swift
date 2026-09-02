import XCTest

@testable import OpenSuperWhisper

/// Pins how the personal terms dictionary reaches Whisper *before* decoding.
///
/// Three things are load-bearing. An empty dictionary leaves the prompt exactly
/// what it was before this path existed. The list is composed in the order it
/// should be kept when the budget runs out, and the budget is the decoder's own
/// token count, so a large dictionary can never push the user's typed prompt
/// out of what whisper.cpp keeps or crowd out the rolling context. And the
/// terms stage is untouched: this is a bias, not a replacement.
final class WhisperInitialPromptTests: IsolatedPreferencesTestCase {

    // MARK: - Fixtures

    private func name(_ replacement: String, match: String = "misheard") -> PersonalTerm {
        PersonalTerm(kind: .name, match: match, replacement: replacement)
    }

    private func spelling(_ replacement: String, match: String = "misspelt") -> PersonalTerm {
        PersonalTerm(kind: .preferredSpelling, match: match, replacement: replacement)
    }

    private func fix(_ replacement: String, match: String = "wrong") -> PersonalTerm {
        PersonalTerm(kind: .replacement, match: match, replacement: replacement)
    }

    private func protect(_ match: String) -> PersonalTerm {
        PersonalTerm(kind: .protect, match: match)
    }

    /// A tokenizer for tests: one token per character. What matters to the
    /// composer is that the count is the decoder's and monotonic, not what it
    /// is, and characters make the arithmetic in each case readable.
    private func characters(_ text: String) -> Int { text.count }

    private func compose(
        _ userPrompt: String, _ terms: [PersonalTerm], budget: Int = WhisperInitialPrompt.tokenBudget
    ) -> String? {
        WhisperInitialPrompt.compose(
            userPrompt: userPrompt, terms: terms, tokenBudget: budget, tokenCount: characters
        )
    }

    // MARK: - An empty dictionary changes nothing

    func testNoPromptAndNoTermsIsNoPrompt() {
        XCTAssertNil(compose("", []))
    }

    func testAnEmptyDictionaryHandsTheTypedPromptThroughUntouched() {
        // Whitespace and all: this is what the decoder was shown before the
        // dictionary reached it, and nothing here may change that.
        XCTAssertEqual(compose("  Meeting notes \n", []), "  Meeting notes \n")
        XCTAssertEqual(compose("Meeting notes", []), "Meeting notes")
    }

    func testADictionaryWithNothingUsableInItChangesNothingEither() {
        let unusable = [
            PersonalTerm(kind: .name, match: "x", replacement: "Ken", isEnabled: false),
            PersonalTerm(kind: .name, match: "x", replacement: ""),
            PersonalTerm(kind: .name, match: "", replacement: "Ken"),
            PersonalTerm(kind: .replacement, match: "在", replacement: "再", contextHint: "一次"),
        ]
        XCTAssertNil(compose("", unusable))
        XCTAssertEqual(compose(" typed ", unusable), " typed ")
    }

    // MARK: - Composition

    func testTermsAloneBecomeACommaSeparatedList() {
        XCTAssertEqual(compose("", [name("阿 Ken"), spelling("Kubernetes")]), "阿 Ken, Kubernetes")
    }

    func testTheTypedPromptComesFirstAndTheListStartsANewSentence() {
        XCTAssertEqual(
            compose("Notes for the platform team", [name("阿 Ken")]),
            "Notes for the platform team. 阿 Ken"
        )
        XCTAssertEqual(
            compose("Notes for the platform team.", [name("阿 Ken")]),
            "Notes for the platform team. 阿 Ken"
        )
        XCTAssertEqual(compose("平台團隊的筆記。", [name("阿 Ken")]), "平台團隊的筆記。 阿 Ken")
        XCTAssertEqual(compose("  Notes  ", [name("阿 Ken")]), "Notes. 阿 Ken")
    }

    func testWhatIsListedIsWhatAnEntryWritesOutNeverWhatItMatches() {
        let words = WhisperInitialPrompt.vocabulary(from: [
            fix("釘釘群", match: "頂頂群"),
            spelling("臺北", match: "台北"),
            protect("useState"),
        ])
        XCTAssertEqual(words, ["臺北", "useState", "釘釘群"])
        XCTAssertFalse(words.contains("頂頂群"), "the mishearing would teach the decoder the mistake")
    }

    func testNamesComeFirstThenSpellingsThenProtectedTextThenMishearingFixes() {
        let words = WhisperInitialPrompt.vocabulary(from: [
            fix("釘釘群"), protect("useState"), spelling("Kubernetes"), name("阿 Ken"),
            fix("second fix"), name("GRDB"),
        ])
        XCTAssertEqual(words, ["阿 Ken", "GRDB", "Kubernetes", "useState", "釘釘群", "second fix"])
    }

    func testEveryKindHasAPlaceInTheOrder() {
        // The priority is switched exhaustively; this pins that no two kinds
        // share a rank, so the order above is total and a new kind cannot tie.
        let ranks = PersonalTermKind.allCases.map(\.decodePromptPriority)
        XCTAssertEqual(Set(ranks).count, ranks.count)
    }

    func testDuplicatesAndBlanksAreListedOnce() {
        let words = WhisperInitialPrompt.vocabulary(from: [
            name("GRDB"), spelling("GRDB"), fix(" GRDB "), protect("   "),
        ])
        XCTAssertEqual(words, ["GRDB"])
    }

    func testAnEntryWithAContextHintIsNotShownToTheDecoder() {
        // The hint says the substitution is conditional on the rest of the
        // dictation; a prompt is shown before any of it exists.
        let words = WhisperInitialPrompt.vocabulary(from: [
            PersonalTerm(kind: .replacement, match: "在", replacement: "再", contextHint: "一次"),
            PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken", contextHint: "sprint"),
            name("GRDB"),
        ])
        XCTAssertEqual(words, ["GRDB"])
    }

    func testDisabledAndIncompleteEntriesAreSkippedTheWayTheTermsStageSkipsThem() {
        let words = WhisperInitialPrompt.vocabulary(from: [
            PersonalTerm(kind: .name, match: "x", replacement: "Off", isEnabled: false),
            PersonalTerm(kind: .name, match: "x", replacement: ""),
            PersonalTerm(kind: .protect, match: ""),
            name("Kept"),
        ])
        XCTAssertEqual(words, ["Kept"])
    }

    func testAWordTheUserAlreadyTypedIntoThePromptIsNotRepeated() {
        XCTAssertEqual(
            compose("GRDB and Kubernetes.", [name("GRDB"), spelling("Kubernetes"), name("阿 Ken")]),
            "GRDB and Kubernetes. 阿 Ken"
        )
        XCTAssertEqual(compose("GRDB", [name("GRDB")]), "GRDB", "nothing to add hands the prompt through")
    }

    // MARK: - The cap

    func testTheListStopsAtTheFirstWordThatDoesNotFit() {
        // "Ken, GRDB" is 9 characters; "Ken, GRDB, Kubernetes" is 21.
        XCTAssertEqual(compose("", [name("Ken"), name("GRDB"), spelling("Kubernetes")], budget: 9), "Ken, GRDB")
        XCTAssertEqual(compose("", [name("Ken"), name("GRDB"), spelling("Kubernetes")], budget: 20), "Ken, GRDB")
        XCTAssertEqual(
            compose("", [name("Ken"), name("GRDB"), spelling("Kubernetes")], budget: 21),
            "Ken, GRDB, Kubernetes"
        )
    }

    func testAShorterLowerPriorityWordNeverSqueezesInAheadOfAName() {
        // "Kubernetes" does not fit after "Alexandra"; "k8s" would, but it is
        // a spelling and the list is in priority order, so it stays out too.
        XCTAssertEqual(
            compose("", [name("Alexandra"), name("Kubernetes"), spelling("k8s")], budget: 14),
            "Alexandra"
        )
    }

    func testATypedPromptThatFillsTheBudgetIsHandedThroughWithNothingAppended() {
        // whisper.cpp keeps the *last* tokens of an over-long prompt, so anything
        // appended here would push the user's own text out of what it sees.
        let long = String(repeating: "x", count: 30)
        XCTAssertEqual(compose(long, [name("Ken")], budget: 30), long)
        XCTAssertEqual(compose(long, [name("Ken")], budget: 10), long)
        XCTAssertEqual(compose(" \(long) ", [name("Ken")], budget: 30), " \(long) ")
    }

    func testTheTypedPromptIsNeverTrimmedToMakeRoom() {
        // Budget 12 fits the prompt and its joiner but not a single word.
        XCTAssertEqual(compose("0123456789", [name("Ken")], budget: 12), "0123456789")
    }

    func testTheBudgetLeavesTheRollingContextAtLeastAsMuchRoomAsTheDictionary() {
        // Every carried prompt token comes out of the same 224-token budget the
        // decoder keeps its own recent output in. The dictionary may have at
        // most half, so a long recording still carries what it just wrote.
        XCTAssertEqual(WhisperInitialPrompt.carriedPromptTokenLimit, 223)
        XCTAssertLessThanOrEqual(
            WhisperInitialPrompt.tokenBudget * 2, WhisperInitialPrompt.carriedPromptTokenLimit
        )
        XCTAssertGreaterThan(WhisperInitialPrompt.tokenBudget, 0)
    }

    func testTheDefaultBudgetIsTheOneTheTypeStates() throws {
        let many = (0 ..< 400).map { name("Name\($0)") }
        let composed = try XCTUnwrap(
            WhisperInitialPrompt.compose(userPrompt: "", terms: many, tokenCount: characters)
        )
        XCTAssertLessThanOrEqual(composed.count, WhisperInitialPrompt.tokenBudget)
        XCTAssertTrue(composed.hasPrefix("Name0, Name1, "))
    }

    // MARK: - Where the dictionary comes from

    func testSettingsCarryTheActiveDictionaryOnlyWhileSafeCorrectionIsOn() {
        AppPreferences.shared.safeCorrectionEnabled = false
        XCTAssertEqual(Settings().personalTerms, [])

        AppPreferences.shared.safeCorrectionEnabled = true
        XCTAssertEqual(Settings().personalTerms, PersonalTermsStore.shared.activeTerms)
    }

    /// The terms stage still runs on what the decoder returns: the prompt is a
    /// bias, and a name the decoder still missed is corrected afterwards.
    func testThePostProcessStageStillCorrectsWhatTheDecoderMissed() {
        AppPreferences.shared.whisperLanguage = "en"
        AppPreferences.shared.safeCorrectionEnabled = true
        var settings = Settings()
        settings.personalTerms = [name("阿 Ken", match: "阿肯")]

        XCTAssertNotNil(
            WhisperInitialPrompt.compose(
                userPrompt: settings.initialPrompt, terms: settings.personalTerms, tokenCount: characters
            )
        )
        XCTAssertEqual(TextPostProcessor.process("跟阿肯開會", settings: settings).final, "跟阿 Ken開會")
    }

    // MARK: - Exactly one engine has this hook

    /// Whisper is the engine with a decoding prompt. Nothing else may grow a
    /// second way of showing the dictionary to a recognizer - not a hotword
    /// list for an engine that has none, and never the cloud endpoint.
    func testOnlyTheWhisperEngineComposesADecodingPrompt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        guard let files = FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String] else {
            throw XCTSkip("Sources are not beside the tests: \(sources.path)")
        }

        var callers: [String] = []
        for file in files where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            if text.contains("WhisperInitialPrompt.compose(") {
                callers.append(file)
            }
        }
        XCTAssertEqual(callers, ["Engines/WhisperEngine.swift"])
    }
}
