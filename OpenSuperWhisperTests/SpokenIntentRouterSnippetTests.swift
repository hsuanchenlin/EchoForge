import XCTest
@testable import OpenSuperWhisper

/// What the router does with a user's own triggers, what the pipeline does with
/// the reading, and what the capsule says about it.
///
/// The bias asserted throughout is the router's own: **anything that does not
/// name a stored trigger is dictation.** Expanding the wrong template costs the
/// user the words they actually said; a missed trigger costs them a retry.
final class SpokenIntentRouterSnippetTests: IsolatedPreferencesTestCase {

    private let signoff = VoiceSnippet(
        keyword: "email signoff", expansion: "Best regards,\n\n[your name]"
    )
    private let meeting = VoiceSnippet(
        keyword: "meeting template", expansion: "Attendees:\n\nAgenda:\n"
    )
    /// Traditional in Settings, so the Simplified transcript has something to
    /// fold onto.
    private let minutes = VoiceSnippet(keyword: "會議記錄", expansion: "會議記錄\n\n出席：\n")

    private var snippets: [VoiceSnippet] { [signoff, meeting, minutes] }

    private func route(_ transcript: String) -> SpokenIntent {
        SpokenIntentRouter.route(transcript, snippets: snippets)
    }

    private func expansion(_ transcript: String) -> String? {
        guard case .snippet(_, let expansion) = route(transcript) else { return nil }
        return expansion
    }

    // MARK: - The marker forms

    func testTheEnglishMarkersFireASnippet() {
        XCTAssertEqual(route("insert email signoff"), .snippet(keyword: signoff.keyword, expansion: signoff.expansion))
        XCTAssertEqual(route("Insert: email signoff"), .snippet(keyword: signoff.keyword, expansion: signoff.expansion))
        XCTAssertEqual(route("insert snippet email signoff"), .snippet(keyword: signoff.keyword, expansion: signoff.expansion))
        XCTAssertEqual(route("Snippet, meeting template."), .snippet(keyword: meeting.keyword, expansion: meeting.expansion))
    }

    func testTheChineseMarkersFireASnippet() {
        XCTAssertEqual(route("插入會議記錄"), .snippet(keyword: minutes.keyword, expansion: minutes.expansion))
        XCTAssertEqual(route("插入片語會議記錄"), .snippet(keyword: minutes.keyword, expansion: minutes.expansion))
        XCTAssertEqual(route("插入：會議記錄"), .snippet(keyword: minutes.keyword, expansion: minutes.expansion))
    }

    /// The trigger was typed in Traditional and the transcript came back in
    /// Simplified, which is an ordinary day for a Mandarin engine.
    func testASimplifiedTranscriptFiresATraditionalTrigger() {
        XCTAssertEqual(route("插入会议记录"), .snippet(keyword: minutes.keyword, expansion: minutes.expansion))
        XCTAssertEqual(route("会议记录"), .snippet(keyword: minutes.keyword, expansion: minutes.expansion))
    }

    func testASimplifiedTriggerIsFiredByATraditionalTranscript() {
        let simplified = VoiceSnippet(keyword: "会议记录", expansion: "会议记录\n")
        let intent = SpokenIntentRouter.route("插入會議記錄", snippets: [simplified])

        XCTAssertEqual(intent, .snippet(keyword: "会议记录", expansion: "会议记录\n"))
    }

    /// The trigger is written down once and said however it comes out: case,
    /// the pause that became a full stop, and the spacing the engine chose.
    func testATriggerMatchesLooselyEnoughToBeSaidOutLoud() {
        XCTAssertEqual(expansion("Insert Email Signoff."), signoff.expansion)
        XCTAssertEqual(expansion("insert   email   signoff"), signoff.expansion)
        XCTAssertEqual(expansion("  insert email signoff  "), signoff.expansion)
    }

    // MARK: - The trigger on its own

    func testATriggerSpokenAloneFiresIt() {
        XCTAssertEqual(expansion("email signoff"), signoff.expansion)
        XCTAssertEqual(expansion("Email signoff."), signoff.expansion)
    }

    /// The whole defence of the bare form: a trigger has to *be* the dictation,
    /// not appear in it.
    func testATriggerInsideASentenceIsDictation() {
        XCTAssertEqual(
            route("the email signoff was wrong"), .dictate("the email signoff was wrong")
        )
        XCTAssertEqual(
            route("email signoff needs a rewrite"), .dictate("email signoff needs a rewrite")
        )
    }

    // MARK: - Everything unrecognised is dictation

    func testAMarkerWithoutAStoredTriggerIsDictation() {
        XCTAssertEqual(route("insert a row above this one"), .dictate("insert a row above this one"))
        XCTAssertEqual(route("insert email"), .dictate("insert email"))
        XCTAssertEqual(route("插入一張圖片"), .dictate("插入一張圖片"))
    }

    /// "insert" is an ordinary word, so a bare one with nothing behind it is a
    /// dictation that happens to start with it.
    func testAMarkerWithNothingBehindItIsDictation() {
        XCTAssertEqual(route("insert"), .dictate("insert"))
        XCTAssertEqual(route("inserted the row"), .dictate("inserted the row"))
    }

    func testASnippetThatIsNotOfferedNeverFires() {
        XCTAssertEqual(
            SpokenIntentRouter.route("insert email signoff", snippets: []),
            .dictate("insert email signoff")
        )
        let incomplete = VoiceSnippet(keyword: "email signoff", expansion: "")
        XCTAssertEqual(
            SpokenIntentRouter.route("insert email signoff", snippets: [incomplete]),
            .dictate("insert email signoff")
        )
    }

    /// The router is not told about disabled snippets - `activeSnippets` is what
    /// it is given - and this is the seam that says so.
    func testOnlyActiveSnippetsReachTheRouter() throws {
        let store = VoiceSnippetStore()
        try store.replaceAll([
            signoff, VoiceSnippet(keyword: "meeting template", expansion: "x", isEnabled: false),
        ])

        XCTAssertEqual(store.activeSnippets.map(\.keyword), [signoff.keyword])
        XCTAssertEqual(
            SpokenIntentRouter.route("meeting template", snippets: store.activeSnippets),
            .dictate("meeting template")
        )
    }

    // MARK: - Against the commands that came first

    func testTheBuiltInCommandsAreNotShadowedByASnippet() {
        let hostile = [
            VoiceSnippet(keyword: "translate to spanish", expansion: "nope"),
            VoiceSnippet(keyword: "ask", expansion: "nope"),
        ]

        guard case .translate(let target, let text) = SpokenIntentRouter.route(
            "Translate to Spanish: the team meets at three.", snippets: hostile
        ) else { return XCTFail("a translation must still be a translation") }
        XCTAssertEqual(target.languageCode, "es")
        XCTAssertEqual(text, "the team meets at three.")

        XCTAssertEqual(
            SpokenIntentRouter.route("Ask: what is the deadline?", snippets: hostile),
            .ask(query: "what is the deadline?")
        )
    }

    /// Two snippets on one trigger resolve to the one higher in the user's own
    /// list, which is the order the Settings pane shows them in.
    func testTheFirstOfTwoSnippetsSharingATriggerWins() {
        let first = VoiceSnippet(keyword: "sig", expansion: "first")
        let second = VoiceSnippet(keyword: "Sig.", expansion: "second")

        XCTAssertEqual(
            SpokenIntentRouter.route("insert sig", snippets: [first, second]),
            .snippet(keyword: "sig", expansion: "first")
        )
    }

    // MARK: - The pipeline

    private func processed(_ text: String) -> ProcessedText {
        ProcessedText(raw: text, final: text)
    }

    private func enableRouting() throws {
        AppPreferences.shared.spokenIntentsEnabled = true
        try VoiceSnippetStore().replaceAll(snippets)
    }

    func testTheExpansionIsInsertedByteForByteAndNeverRewritten() async throws {
        try enableRouting()

        let styled = await SpokenIntentPipeline.apply(
            to: processed("insert meeting template"),
            settings: Settings(routesSpokenIntents: true)
        )

        XCTAssertEqual(styled.intent, .snippet(keyword: "meeting template"))
        XCTAssertTrue(styled.intent.insertsText)
        // The template, exactly as it is stored - the rewriting stage is not
        // consulted at all, which is what keeps the blank lines.
        XCTAssertEqual(styled.final, meeting.expansion)
        XCTAssertEqual(styled.status, .notRequested)
        XCTAssertNil(styled.statusExplanation)
        // What was said is still what history keeps.
        XCTAssertEqual(styled.raw, "insert meeting template")
        XCTAssertEqual(styled.transcript, "insert meeting template")
    }

    func testSnippetsRideOnSpokenCommandsAndOnTheirOwnToggle() throws {
        try VoiceSnippetStore().replaceAll(snippets)

        // Spoken commands off - the default - so nothing is offered at all.
        XCTAssertTrue(Settings(routesSpokenIntents: true).voiceSnippets.isEmpty)

        AppPreferences.shared.spokenIntentsEnabled = true
        XCTAssertEqual(
            Settings(routesSpokenIntents: true).voiceSnippets.map(\.keyword),
            snippets.map(\.keyword)
        )

        // Every path that is not live dictation: a dropped file, a queued
        // recording, a regenerate from history.
        XCTAssertTrue(Settings().voiceSnippets.isEmpty)

        // The macro family switched off without touching Ask or Translate.
        AppPreferences.shared.voiceSnippetsEnabled = false
        XCTAssertTrue(Settings(routesSpokenIntents: true).voiceSnippets.isEmpty)
        XCTAssertTrue(Settings(routesSpokenIntents: true).routesSpokenIntents)
    }

    func testATriggerOnAnUnroutedPathIsPlainDictation() async throws {
        try enableRouting()

        let styled = await SpokenIntentPipeline.apply(
            to: processed("insert email signoff"), settings: Settings()
        )

        XCTAssertEqual(styled.intent, .dictation)
        XCTAssertEqual(styled.final, "insert email signoff")
    }

    @MainActor
    func testTheCapsuleIsToldASnippetFired() async throws {
        try enableRouting()
        SpokenIntentActivity.shared.clear()

        _ = await SpokenIntentPipeline.apply(
            to: processed("insert email signoff"),
            settings: Settings(routesSpokenIntents: true)
        )

        XCTAssertEqual(SpokenIntentActivity.shared.outcome, .snippet(keyword: "email signoff"))
        SpokenIntentActivity.shared.clear()
    }

    // MARK: - The chip

    func testTheChipNamesTheTriggerWhenItFits() {
        XCTAssertEqual(
            SpokenIntentOutcome.snippet(keyword: "email signoff").capsuleMode?.label,
            "Snippet: email signoff"
        )
        XCTAssertEqual(CapsuleHUDMode.snippet(named: "  meeting template  ").label, "Snippet: meeting template")
    }

    /// A trigger is the user's own text and can be a sentence; the chip widens
    /// the whole capsule to hold it, so past a limit it says only what it is.
    func testTheChipFallsBackToTheBareWordForALongTrigger() {
        let long = String(repeating: "a", count: CapsuleHUDMode.maximumSnippetKeywordCharacters + 1)

        XCTAssertEqual(CapsuleHUDMode.snippet(named: long).label, "Snippet")
        XCTAssertEqual(CapsuleHUDMode.snippet(named: "   ").label, "Snippet")
    }

    /// The chip is set once the words exist, and only while the capsule is
    /// showing its own decode - a snippet fired by a queued file must not
    /// relabel a recording that is still in progress.
    @MainActor
    func testTheChipOnlyChangesDuringThisSessionsDecode() {
        let viewModel = CapsuleHUDViewModel(now: { Date() }, schedule: { _, _ in })
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        viewModel.setMode(.snippet(named: "email signoff"))
        XCTAssertEqual(viewModel.mode.label, "Dictate")

        viewModel.beginPolishing(.transcribing)
        viewModel.setMode(.snippet(named: "email signoff"))
        XCTAssertEqual(viewModel.mode.label, "Snippet: email signoff")
    }
}
