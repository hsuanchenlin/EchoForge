import AppKit
import XCTest
@testable import OpenSuperWhisper

/// The recovery a missed channel name offers: which presses are given one, what
/// it contains, how it is ordered, and what every key does.
///
/// The case it exists for is the one `YouTubeCommandHistoryRegressionTests`
/// records: a user with `valley101` stored, a speech engine that wrote
/// "Vali101", and a refusal with no way back from it. The allowlist is still
/// right to refuse that - a near miss that opened *something* would be the app
/// choosing a channel the user did not - so what changes is not the matching but
/// what happens after it fails: the user's own list, and a keystroke.
///
/// Nothing here reaches a network, a model, a browser or a window server.
final class YouTubeChannelPickerTests: XCTestCase {

    // MARK: - Fixtures

    private let valley = YouTubeChannel(
        displayName: "valley101", aliases: [], channelID: "UCaaaaaaaaaaaaaaaaaaaaaa")
    private let veritasium = YouTubeChannel(
        displayName: "Veritasium", aliases: ["Verita Zium"],
        channelID: "UCbbbbbbbbbbbbbbbbbbbbbb")
    private let kurzgesagt = YouTubeChannel(
        displayName: "Kurzgesagt", aliases: [], channelID: "UCcccccccccccccccccccccc")

    private var allChannels: [YouTubeChannel] { [valley, veritasium, kurzgesagt] }

    private func offer(
        _ resolution: YouTubeChannelResolution,
        candidates: [YouTubeChannel]? = nil,
        isEnabled: Bool = true
    ) -> YouTubeChannelPickerOffer {
        .make(
            for: resolution,
            candidates: candidates ?? allChannels,
            isEnabled: isEnabled
        )
    }

    private func request(spoken: String = "Vali101") throws -> YouTubeChannelPickerRequest {
        guard case .picker(let request) = offer(.unknown(spoken: spoken)) else {
            throw XCTSkip("expected a picker for “\(spoken)”")
        }
        return request
    }

    // MARK: - Who is offered one

    /// The whole reason this exists. The engine wrote "Vali101"; the list holds
    /// `valley101`; the allowlist refuses, and the user is now shown their own
    /// three channels with the near miss first.
    func testTheNearMissIsOfferedThePickerWithTheClosestChannelFirst() throws {
        let request = try request(spoken: "Vali101")

        XCTAssertEqual(request.spokenName, "Vali101")
        XCTAssertEqual(request.cause, .unknown)
        XCTAssertEqual(
            request.suggestions.map(\.channel), [valley, veritasium, kurzgesagt],
            "The near miss ranks first; the rest keep the user's own list order.")
        XCTAssertTrue(
            request.suggestions[0].isSuggested,
            "“Vali101” against a stored `valley101` is what the threshold was measured on.")
        XCTAssertFalse(request.suggestions[1].isSuggested)
        XCTAssertFalse(request.suggestions[2].isSuggested)
    }

    /// An exact match never sees a picker: it opens, as it always did.
    func testAnExactMatchIsNotOfferedAPicker() {
        let allowlist = YouTubeChannelAllowlist(channels: allChannels)
        let resolution = allowlist.resolve(spokenName: "valley101")
        XCTAssertEqual(resolution, .allowlisted(valley, matchedBy: .spokenName))
        XCTAssertEqual(offer(resolution), .none(.resolved))
    }

    /// And neither does the spacing tier, which is still an exact match of one
    /// stored name.
    func testTheSpacingTierIsNotOfferedAPicker() {
        let allowlist = YouTubeChannelAllowlist(channels: allChannels)
        let resolution = allowlist.resolve(spokenName: "valley 101")
        XCTAssertEqual(resolution, .allowlisted(valley, matchedBy: .spacing))
        XCTAssertEqual(offer(resolution), .none(.resolved))
    }

    /// Two rows answering to one name is the other failure a list can fix, so it
    /// is offered the picker too - and the sentence names both rows.
    func testAnAmbiguousNameIsOfferedThePickerNamingTheRows() throws {
        let resolution = YouTubeChannelResolution.ambiguous(
            spoken: "V", matches: ["valley101", "Veritasium"])
        guard case .picker(let request) = offer(resolution) else {
            return XCTFail("an ambiguous name should be offered the picker")
        }
        XCTAssertEqual(request.cause, .ambiguous(matches: ["valley101", "Veritasium"]))
        XCTAssertTrue(request.prompt.contains("valley101"))
        XCTAssertTrue(request.prompt.contains("Veritasium"))
    }

    /// A press with nothing behind it gets no panel. A picker that appeared and
    /// took focus after a stray press of the key would be the app interrupting
    /// somebody who asked for nothing.
    func testSilenceIsNotOfferedAPicker() {
        XCTAssertEqual(offer(.unknown(spoken: "")), .none(.nothingHeard))
        XCTAssertEqual(offer(.unknown(spoken: "   ")), .none(.nothingHeard))
    }

    /// The feature switched off answers "it is switched off", not a picker.
    func testASwitchedOffCommandIsNotOfferedAPicker() {
        XCTAssertEqual(offer(.disabled(spoken: "Vali101")), .none(.switchedOff))
    }

    /// The picker's own switch restores exactly the behaviour that shipped
    /// before it existed.
    func testTheDisabledPickerIsNotOffered() {
        XCTAssertEqual(
            offer(.unknown(spoken: "Vali101"), isEnabled: false), .none(.switchedOff))
    }

    /// An empty list is a refusal, not an empty picker - and its own refusal,
    /// because "add that spelling to the channel you meant" is not advice
    /// anybody can act on with no channels stored.
    func testAnEmptyAllowlistIsARefusalRatherThanAnEmptyPicker() {
        XCTAssertEqual(
            offer(.unknown(spoken: "Vali101"), candidates: []), .none(.noChannelsConfigured))

        let report = YouTubeLatestVideoReport.noChannelsConfigured(spoken: "Vali101")
        XCTAssertEqual(RecordingProvenance.command(report).refusal, .noChannelsConfigured)
        XCTAssertTrue(report.spokenSummary.contains("Vali101"))
        XCTAssertTrue(report.spokenSummary.contains("Settings"))
    }

    /// Rows a command could not have opened are not offered either: a disabled
    /// or half-finished row would be a choice that fails the moment it is made.
    func testOnlyRowsACommandCouldHaveOpenedAreOffered() throws {
        let disabled = YouTubeChannel(
            displayName: "Switched off", channelID: "UCdddddddddddddddddddddd",
            isEnabled: false)
        let broken = YouTubeChannel(displayName: "No id", channelID: "@handle")

        guard case .picker(let request) = offer(
            .unknown(spoken: "Vali101"), candidates: [valley, disabled, broken])
        else { return XCTFail("expected a picker") }

        XCTAssertEqual(request.suggestions.map(\.channel), [valley])
    }

    // MARK: - Ranking

    /// Ranking is a hint, so what it must be is *reproducible*: the same phrase
    /// and the same list in the same order, every time, on every Mac.
    func testTheOrderIsDeterministic() {
        let first = YouTubeChannelSuggestions.rank("Vali101", among: allChannels)
        for _ in 0..<20 {
            XCTAssertEqual(
                YouTubeChannelSuggestions.rank("Vali101", among: allChannels).map(\.channel),
                first.map(\.channel))
        }
    }

    /// Equal scores fall back to the user's own list order, never to anything
    /// undefined.
    func testEqualScoresKeepTheStoredOrder() {
        let ranked = YouTubeChannelSuggestions.rank("", among: allChannels)
        XCTAssertEqual(ranked.map(\.score), [0, 0, 0])
        XCTAssertEqual(ranked.map(\.channel), allChannels)
    }

    /// Rows that are not near misses keep the order the user gave them in
    /// Settings. Ordering them by a score that is below the suggestion threshold
    /// would shuffle their own list for a reason nobody could see - two names
    /// that are both unlike the phrase are not thereby ranked against each
    /// other.
    func testRowsBelowTheSuggestionThresholdKeepTheUsersOwnOrder() {
        let xiaolin = YouTubeChannel(
            displayName: "小Lin說", channelID: "UCdddddddddddddddddddddd")
        let stored = [valley, veritasium, kurzgesagt, xiaolin]

        let ranked = YouTubeChannelSuggestions.rank("Vali101", among: stored)
        XCTAssertEqual(ranked.first?.channel, valley)
        XCTAssertTrue(ranked[0].isSuggested)
        XCTAssertEqual(
            ranked.dropFirst().map(\.channel), [veritasium, kurzgesagt, xiaolin],
            "Everything that is not a near miss stays in the order Settings shows it in.")
        for suggestion in ranked.dropFirst() { XCTAssertFalse(suggestion.isSuggested) }
    }

    /// Typing is the other case, and it ranks by score throughout: every row on
    /// screen contains what was typed, so how much of the name it covers is
    /// exactly what the user is choosing by.
    @MainActor
    func testTypingRanksTheClosestNameFirstEvenBelowTheThreshold() throws {
        let kurzClub = YouTubeChannel(
            displayName: "The Kurz Club", channelID: "UCffffffffffffffffffffff")
        guard case .picker(let request) = YouTubeChannelPickerOffer.make(
            for: .unknown(spoken: "Vali101"),
            candidates: [valley, veritasium, kurzgesagt, kurzClub],
            isEnabled: true
        ) else { return XCTFail("expected a picker") }

        let model = YouTubeChannelPickerViewModel(request: request)
        model.query = "kurz"
        XCTAssertEqual(
            model.rows.map(\.channel), [kurzgesagt, kurzClub],
            "“kurz” covers more of “Kurzgesagt” than of “The Kurz Club”.")
    }

    /// An alias is a stored spelling like any other, and the row says which one
    /// the phrase was close to.
    func testAnAliasCanBeWhatARowIsRankedBy() {
        let ranked = YouTubeChannelSuggestions.rank("Verita Zilm", among: allChannels)
        XCTAssertEqual(ranked.first?.channel, veritasium)
        XCTAssertEqual(ranked.first?.matchedSpelling, "Verita Zium")
    }

    /// Spacing is folded before scoring, for the reason
    /// `YouTubeChannelAlias.compact` records: where a space falls inside a name
    /// is the engine's guess rather than the speaker's word.
    func testSpacingDoesNotCostSimilarity() {
        XCTAssertEqual(YouTubeChannelSuggestions.similarity("valley 101", "valley101"), 1)
        XCTAssertEqual(YouTubeChannelSuggestions.similarity("valley101", "valley101"), 1)
    }

    /// The measurement the threshold was set from, kept as an assertion so
    /// changing the scorer cannot quietly stop suggesting the case this feature
    /// was built for.
    func testTheNearMissScoresAboveTheThresholdAndAnUnrelatedNameDoesNot() {
        let near = YouTubeChannelSuggestions.similarity("vali101", "valley101")
        let unrelated = YouTubeChannelSuggestions.similarity("kurzgesagt", "valley101")
        XCTAssertGreaterThanOrEqual(near, YouTubeChannelSuggestions.suggestionThreshold)
        XCTAssertLessThan(unrelated, YouTubeChannelSuggestions.suggestionThreshold)
    }

    /// Nothing is compared but what the user typed into Settings. A channel id
    /// takes no part in the ranking, which is the same rule
    /// `YouTubeChannelModelMatch` states for its prompt.
    func testAChannelIDIsNeverWhatARowIsRankedBy() {
        let ranked = YouTubeChannelSuggestions.rank(
            "UCaaaaaaaaaaaaaaaaaaaaaa", among: allChannels)
        for suggestion in ranked {
            XCTAssertFalse(suggestion.isSuggested)
            XCTAssertNotEqual(suggestion.matchedSpelling, suggestion.channel.channelID)
        }
    }

    // MARK: - Type to filter

    @MainActor
    func testTypingNarrowsTheListAndClearingItRestoresEveryChannel() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        XCTAssertEqual(model.rows.count, 3)

        model.query = "ver"
        XCTAssertEqual(model.rows.map(\.channel), [veritasium])

        model.query = ""
        XCTAssertEqual(model.rows.map(\.channel), [valley, veritasium, kurzgesagt])
    }

    /// The filter ignores what a speech engine and a keyboard both vary: case,
    /// and the spacing inside a name.
    @MainActor
    func testTheFilterIgnoresCaseAndSpacing() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        model.query = "VALLEY 101"
        XCTAssertEqual(model.rows.map(\.channel), [valley])
    }

    /// A filter that matches nothing says so rather than showing an empty box.
    @MainActor
    func testAFilterThatMatchesNothingExplainsItself() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        model.query = "zzzz"
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.highlighted)
        XCTAssertNil(model.highlightedChannel)
        XCTAssertEqual(model.emptyMessage?.contains("zzzz"), true)
    }

    /// Typing another letter must not move the selection off a row that is still
    /// listed.
    @MainActor
    func testTheHighlightSticksToItsRowWhileThatRowIsStillListed() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        model.highlightNext()
        XCTAssertEqual(model.highlightedChannel, veritasium)

        model.query = "v"
        XCTAssertEqual(
            model.highlightedChannel, veritasium,
            "Veritasium is still on screen, so the highlight stays on it.")

        model.query = "kurz"
        XCTAssertEqual(
            model.highlightedChannel, kurzgesagt,
            "Its row is gone, so the highlight falls to the top of what is left.")
    }

    // MARK: - Keys

    @MainActor
    func testTheArrowKeysMoveThroughTheListAndWrapAround() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        XCTAssertEqual(model.highlightedChannel, valley)

        model.highlightNext()
        XCTAssertEqual(model.highlightedChannel, veritasium)
        model.highlightNext()
        XCTAssertEqual(model.highlightedChannel, kurzgesagt)
        model.highlightNext()
        XCTAssertEqual(model.highlightedChannel, valley, "Down wraps to the top.")

        model.highlightPrevious()
        XCTAssertEqual(model.highlightedChannel, kurzgesagt, "Up wraps to the bottom.")
    }

    /// The panel opens on a row, so the very first Return means something: a
    /// keyboard-first picker whose first keystroke has to be an arrow key costs
    /// a press for nothing.
    @MainActor
    func testReturnOpensTheHighlightedChannel() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        var chosen: YouTubeChannel??
        model.onFinish = { chosen = $0 }

        model.commit()
        XCTAssertEqual(chosen, .some(valley))
    }

    @MainActor
    func testEscapeOpensNothing() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        var chosen: YouTubeChannel??
        model.onFinish = { chosen = $0 }

        model.cancel()
        XCTAssertEqual(chosen, .some(nil), "Cancel answers, and answers with nothing.")
    }

    /// Return with the list filtered down to nothing opens nothing. A Return
    /// that opened *something* out of an empty list is the one thing this panel
    /// must never do.
    @MainActor
    func testReturnOnAnEmptyFilterOpensNothing() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        var finished = false
        model.onFinish = { _ in finished = true }

        model.query = "zzzz"
        model.commit()
        XCTAssertFalse(finished)
    }

    /// The answer is given once. A commit after a cancel - a stray key during
    /// the fade-out - must not turn a cancelled command into an opened one.
    @MainActor
    func testThePanelAnswersExactlyOnce() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        var answers: [YouTubeChannel?] = []
        model.onFinish = { answers.append($0) }

        model.cancel()
        model.commit()
        model.cancel()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first, .some(nil))
    }

    /// The allowlist rule at the last surface that touches it: the view model
    /// can only ever answer with one of the channels it was given.
    @MainActor
    func testThePanelCannotAnswerWithAChannelItWasNotGiven() throws {
        let outsider = YouTubeChannel(
            displayName: "Not in the list", channelID: "UCeeeeeeeeeeeeeeeeeeeeee")
        let model = YouTubeChannelPickerViewModel(request: try request())
        var finished = false
        model.onFinish = { _ in finished = true }

        model.choose(outsider)
        XCTAssertFalse(finished, "A channel that was never offered is not an answer.")
    }

    /// The key mapping itself, as a function of a key code - so the four keys
    /// this panel answers to are pinned without a window server.
    @MainActor
    func testTheKeyMapping() throws {
        func press(_ code: YouTubeChannelPickerWindowController.KeyCode, flags: NSEvent
            .ModifierFlags = []) -> NSEvent?
        {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code.rawValue)
        }

        let model = YouTubeChannelPickerViewModel(request: try request())
        var answers: [YouTubeChannel?] = []
        model.onFinish = { answers.append($0) }

        let down = try XCTUnwrap(press(.downArrow))
        XCTAssertTrue(YouTubeChannelPickerWindowController.handle(down, with: model))
        XCTAssertEqual(model.highlightedChannel, veritasium)

        let up = try XCTUnwrap(press(.upArrow))
        XCTAssertTrue(YouTubeChannelPickerWindowController.handle(up, with: model))
        XCTAssertEqual(model.highlightedChannel, valley)

        // A modified key belongs to whoever the user meant it for - ⌘A in the
        // filter field, or a system shortcut - and must reach the field.
        let commandDown = try XCTUnwrap(press(.downArrow, flags: .command))
        XCTAssertFalse(YouTubeChannelPickerWindowController.handle(commandDown, with: model))

        let escape = try XCTUnwrap(press(.escape))
        XCTAssertTrue(YouTubeChannelPickerWindowController.handle(escape, with: model))
        XCTAssertEqual(answers, [nil])
    }

    /// This app's own users type Chinese, so a composing input method is not an
    /// edge case. While one owns the filter field's marked text, Return, Escape
    /// and the arrows are **its** keys: taking them would make Return finish the
    /// command on a half-typed word and Escape close the panel instead of the
    /// candidate list.
    @MainActor
    func testAComposingInputMethodKeepsEveryKeyThePickerWouldOtherwiseTake() throws {
        let model = YouTubeChannelPickerViewModel(request: try request())
        var finished = false
        model.onFinish = { _ in finished = true }

        for code in [YouTubeChannelPickerWindowController.KeyCode.downArrow, .upArrow,
                     .return, .keypadEnter, .escape] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code.rawValue))
            XCTAssertFalse(
                YouTubeChannelPickerWindowController.handle(
                    event, with: model, isComposing: true),
                "\(code) must reach the input method while it is composing.")
        }

        XCTAssertEqual(model.highlightedChannel, valley, "Nothing moved.")
        XCTAssertFalse(finished, "And nothing was answered.")
    }

    // MARK: - Accessibility

    /// Every element a screen reader or a UI test has to find carries an
    /// identifier, and a row's is derived from the channel rather than from its
    /// position - a list that reorders as you type cannot be addressed by index.
    @MainActor
    func testTheElementsCarryStableAccessibilityIdentifiers() throws {
        XCTAssertEqual(
            YouTubeChannelPickerAccessibility.row(valley),
            "youtube.channel.picker.row.\(valley.id.uuidString)")
        XCTAssertNotEqual(
            YouTubeChannelPickerAccessibility.row(valley),
            YouTubeChannelPickerAccessibility.row(veritasium))

        let identifiers = [
            YouTubeChannelPickerAccessibility.panel,
            YouTubeChannelPickerAccessibility.heardPhrase,
            YouTubeChannelPickerAccessibility.prompt,
            YouTubeChannelPickerAccessibility.filterField,
            YouTubeChannelPickerAccessibility.list,
            YouTubeChannelPickerAccessibility.emptyMessage,
            YouTubeChannelPickerAccessibility.cancelButton,
            YouTubeChannelPickerAccessibility.openButton,
        ]
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "Identifiers must be unique.")
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("youtube.channel.picker"))
        }

        // And the view actually uses them, rather than spelling its own.
        let source = try sourceOf("YouTube/YouTubeChannelPickerView.swift")
        for name in ["panel", "heardPhrase", "prompt", "filterField", "list",
                     "emptyMessage", "cancelButton", "openButton"] {
            XCTAssertTrue(
                source.contains("YouTubeChannelPickerAccessibility.\(name)"),
                "The picker view does not use the `\(name)` identifier.")
        }
    }

    /// The phrase that was heard reaches the panel: it is the single most useful
    /// thing on the card, because it is what tells a user whether the engine
    /// misheard them or their list is missing a spelling.
    @MainActor
    func testTheHeardPhraseIsOnTheCard() throws {
        let source = try sourceOf("YouTube/YouTubeChannelPickerView.swift")
        XCTAssertTrue(source.contains("viewModel.request.spokenName"))
        XCTAssertTrue(source.contains("viewModel.request.prompt"))
    }

    // MARK: - Helpers

    private func sourceOf(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenSuperWhisperTests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("OpenSuperWhisper")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
