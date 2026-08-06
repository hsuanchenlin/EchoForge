import XCTest
@testable import OpenSuperWhisper

/// The snippet list: what is stored, what is offered to the router, and what
/// happens to a document the app cannot read.
///
/// The store holds no state of its own and reads `PreferenceStore.defaults` at
/// every access, so these run against the throwaway suite the base class
/// installs and never touch the developer's own snippets.
final class VoiceSnippetStoreTests: IsolatedPreferencesTestCase {

    private func makeStore() -> VoiceSnippetStore { VoiceSnippetStore() }

    // MARK: - Creating and persisting

    func testAFreshInstallHasNoSnippetsAndNoFailure() {
        let store = makeStore()

        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertNil(store.loadFailure)
        XCTAssertTrue(store.canMutate)
    }

    func testASnippetSurvivesBeingWrittenAndReadBack() throws {
        let store = makeStore()
        let snippet = VoiceSnippet(
            keyword: "Email Signoff", expansion: "Best regards,\n\n  Hsuan\n"
        )

        try store.upsert(snippet)

        // A second store, so what is asserted is the stored JSON rather than
        // anything the first one happened to be holding.
        let reloaded = makeStore().snippets
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, snippet.id)
        XCTAssertEqual(reloaded.first?.keyword, "Email Signoff")
        // Byte for byte, indentation and trailing newline included: the
        // template's whitespace is the user's own and nothing may tidy it.
        XCTAssertEqual(reloaded.first?.expansion, "Best regards,\n\n  Hsuan\n")
        XCTAssertEqual(reloaded.first?.isEnabled, true)
    }

    func testTheStoredFormIsJSONInTheDefaultsDomain() throws {
        try makeStore().upsert(VoiceSnippet(keyword: "sig", expansion: "Regards"))

        guard let data = storedPreference(VoiceSnippetStore.snippetsKey) as? Data else {
            return XCTFail("expected JSON data under \(VoiceSnippetStore.snippetsKey)")
        }
        let document = try VoiceSnippetStore.decode(data)
        XCTAssertEqual(document.version, VoiceSnippetDocument.currentVersion)
        XCTAssertEqual(document.snippets.map(\.keyword), ["sig"])
    }

    func testUpsertReplacesTheSameSnippetAndAppendsANewOne() throws {
        let store = makeStore()
        var first = VoiceSnippet(keyword: "sig", expansion: "Regards")
        try store.upsert(first)

        first.expansion = "Best regards"
        try store.upsert(first)
        try store.upsert(VoiceSnippet(keyword: "addr", expansion: "1 Main St"))

        XCTAssertEqual(store.snippets.map(\.keyword), ["sig", "addr"])
        XCTAssertEqual(store.snippets.first?.expansion, "Best regards")
    }

    func testRemoveAndToggle() throws {
        let store = makeStore()
        let keep = VoiceSnippet(keyword: "keep", expansion: "kept")
        let drop = VoiceSnippet(keyword: "drop", expansion: "dropped")
        try store.replaceAll([keep, drop])

        try store.remove([drop.id])
        XCTAssertEqual(store.snippets.map(\.keyword), ["keep"])

        try store.setEnabled(false, for: keep.id)
        XCTAssertEqual(store.snippets.first?.isEnabled, false)
        // Disabled is kept, not deleted - the same rule the terms dictionary
        // follows, so switching one off is never a way to lose it.
        XCTAssertEqual(store.snippets.count, 1)
    }

    func testRemovingNothingChangesNothing() throws {
        let store = makeStore()
        try store.replaceAll([VoiceSnippet(keyword: "sig", expansion: "Regards")])

        try store.remove([])

        XCTAssertEqual(store.snippets.count, 1)
    }

    // MARK: - What the router is offered

    func testOnlyEnabledAndCompleteSnippetsAreActive() throws {
        let store = makeStore()
        try store.replaceAll([
            VoiceSnippet(keyword: "ready", expansion: "text"),
            VoiceSnippet(keyword: "off", expansion: "text", isEnabled: false),
            VoiceSnippet(keyword: "", expansion: "text"),
            VoiceSnippet(keyword: "no template", expansion: ""),
            VoiceSnippet(keyword: "   ", expansion: "text"),
        ])

        XCTAssertEqual(store.snippets.count, 5, "half-finished snippets are kept and shown")
        XCTAssertEqual(store.activeSnippets.map(\.keyword), ["ready"])
    }

    /// A template that is only whitespace is still a template - a blank line is
    /// a thing a user stores on purpose - while an empty one has nothing to
    /// insert.
    func testValidityDistinguishesWhitespaceFromEmpty() {
        XCTAssertTrue(VoiceSnippet(keyword: "blank line", expansion: "\n").isValid)
        XCTAssertFalse(VoiceSnippet(keyword: "nothing", expansion: "").isValid)
        XCTAssertFalse(VoiceSnippet(keyword: " ,. ", expansion: "text").isValid)
    }

    // MARK: - Trigger normalization

    func testTriggersMatchAcrossCasePunctuationAndSpacing() {
        let key = VoiceSnippetTrigger.normalize("email signoff")

        XCTAssertEqual(VoiceSnippetTrigger.normalize("Email Signoff"), key)
        XCTAssertEqual(VoiceSnippetTrigger.normalize("  email   signoff  "), key)
        XCTAssertEqual(VoiceSnippetTrigger.normalize("Email signoff."), key)
        XCTAssertEqual(VoiceSnippetTrigger.normalize("“email signoff”"), key)
        XCTAssertEqual(VoiceSnippetTrigger.normalize("email signoff："), key)
    }

    /// The one folding that matters for this app's other language: a trigger
    /// typed in Traditional answers dictation transcribed in Simplified, and
    /// the other way round.
    func testTriggersMatchAcrossTraditionalAndSimplified() {
        XCTAssertEqual(
            VoiceSnippetTrigger.normalize("會議記錄"),
            VoiceSnippetTrigger.normalize("会议记录")
        )
        XCTAssertEqual(
            VoiceSnippetTrigger.normalize("會議記錄，"),
            VoiceSnippetTrigger.normalize("会议记录")
        )
        XCTAssertNotEqual(
            VoiceSnippetTrigger.normalize("會議記錄"),
            VoiceSnippetTrigger.normalize("會議")
        )
    }

    func testNormalizationNeverFoldsTwoDifferentTriggersTogether() {
        XCTAssertNotEqual(
            VoiceSnippetTrigger.normalize("email signoff"),
            VoiceSnippetTrigger.normalize("email sign off")
        )
    }

    // MARK: - Samples

    func testSamplesAreInstalledOnceOnAFreshInstall() {
        let store = makeStore()

        XCTAssertTrue(store.installSamplesIfNeeded())
        XCTAssertEqual(store.snippets.map(\.keyword), VoiceSnippetStore.samples.map(\.keyword))
        XCTAssertTrue(store.snippets.allSatisfy(\.isValid))
    }

    /// Deleting the samples is a decision, not a state the app repairs on the
    /// next launch.
    func testDeletingEverySampleSticksAcrossRelaunches() throws {
        let store = makeStore()
        store.installSamplesIfNeeded()

        try store.replaceAll([])

        XCTAssertFalse(store.installSamplesIfNeeded())
        XCTAssertTrue(store.snippets.isEmpty)
    }

    /// An install that already has snippets - one that upgraded into this
    /// feature - is never handed entries it did not create.
    func testSamplesAreNotAddedUnderAnExistingList() throws {
        let store = makeStore()
        try store.replaceAll([VoiceSnippet(keyword: "mine", expansion: "text")])

        XCTAssertFalse(store.installSamplesIfNeeded())
        XCTAssertEqual(store.snippets.map(\.keyword), ["mine"])
    }

    // MARK: - An unreadable document

    func testAnUnreadableDocumentIsReportedRatherThanOverwritten() {
        PreferenceStore.defaults.set(
            Data("not a snippet document".utf8), forKey: VoiceSnippetStore.snippetsKey
        )
        let store = makeStore()

        XCTAssertNotNil(store.loadFailure)
        XCTAssertFalse(store.canMutate)
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertTrue(store.activeSnippets.isEmpty)
        XCTAssertThrowsError(try store.replaceAll([VoiceSnippet(keyword: "a", expansion: "b")]))
        XCTAssertEqual(
            storedPreference(VoiceSnippetStore.snippetsKey) as? Data,
            Data("not a snippet document".utf8),
            "the unreadable value is left exactly as it was found"
        )
    }

    func testResettingClearsAnUnreadableDocument() throws {
        PreferenceStore.defaults.set(Data("broken".utf8), forKey: VoiceSnippetStore.snippetsKey)
        let store = makeStore()

        store.reset()

        XCTAssertNil(store.loadFailure)
        XCTAssertTrue(store.canMutate)
        try store.replaceAll([VoiceSnippet(keyword: "a", expansion: "b")])
        XCTAssertEqual(store.snippets.map(\.keyword), ["a"])
    }

    /// A document from a build that stored more than this one understands is
    /// still readable: the fields this build knows decode, and the rest are
    /// simply not shown.
    func testADocumentWithUnknownFieldsStillDecodes() throws {
        let json = """
        {"version": 1, "snippets": [{"keyword": "sig", "expansion": "Regards", "colour": "blue"}]}
        """
        let document = try VoiceSnippetStore.decode(Data(json.utf8))

        XCTAssertEqual(document.snippets.count, 1)
        XCTAssertEqual(document.snippets.first?.keyword, "sig")
        XCTAssertEqual(document.snippets.first?.isEnabled, true, "absent means enabled")
    }
}
