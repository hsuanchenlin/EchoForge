import XCTest
@testable import OpenSuperWhisper

/// The allowlist as it is stored: what survives a write, what the store refuses,
/// and what happens to a document the app cannot read.
///
/// The store reads `PreferenceStore.defaults` at every access, so these run
/// against the throwaway suite the base class installs and never touch the
/// developer's own channels.
final class YouTubeChannelStoreTests: IsolatedPreferencesTestCase {

    private func makeStore() -> YouTubeChannelStore { YouTubeChannelStore() }

    private func channel(
        name: String = "Veritasium",
        aliases: [String] = [],
        id: String = "UCHnyfMqiRRG1u-2MsSQLbXA"
    ) -> YouTubeChannel {
        YouTubeChannel(displayName: name, aliases: aliases, channelID: id)
    }

    func testAFreshInstallAllowlistsNothing() {
        let store = makeStore()

        XCTAssertTrue(store.channels.isEmpty)
        XCTAssertTrue(store.allowlist.isEmpty)
        XCTAssertNil(store.loadFailure)
        XCTAssertTrue(store.canMutate)
    }

    func testAChannelSurvivesBeingWrittenAndReadBack() throws {
        let store = makeStore()
        try store.upsert(channel(aliases: ["vera tasium"]))

        // A second store, so what is asserted is the stored JSON rather than
        // anything the first one happened to be holding.
        let reloaded = makeStore().channels
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.displayName, "Veritasium")
        XCTAssertEqual(reloaded.first?.aliases, ["vera tasium"])
        XCTAssertEqual(reloaded.first?.channelID, "UCHnyfMqiRRG1u-2MsSQLbXA")
        XCTAssertEqual(reloaded.first?.isEnabled, true)
    }

    func testTheStoredFormIsJSONInTheDefaultsDomain() throws {
        try makeStore().upsert(channel())

        guard let data = storedPreference(YouTubeChannelStore.channelsKey) as? Data else {
            return XCTFail("expected JSON data under \(YouTubeChannelStore.channelsKey)")
        }
        let document = try YouTubeChannelStore.decode(data)
        XCTAssertEqual(document.version, YouTubeChannelDocument.currentVersion)
        XCTAssertEqual(document.channels.map(\.displayName), ["Veritasium"])
    }

    func testSavingRefusesADraftThatWouldMakeTheListUnusable() throws {
        let store = makeStore()
        try store.upsert(channel())

        // A second row answering to the same spoken name could only ever make
        // every command that says it do nothing, so it is refused at the door.
        XCTAssertThrowsError(
            try store.upsert(channel(name: "VERITASIUM", id: "UCzzzzzzzzzzzzzzzzzzzzzz"))
        )
        XCTAssertThrowsError(try store.upsert(channel(name: "Derek")))
        XCTAssertThrowsError(try store.upsert(channel(name: "Nameless", id: "@handle")))
        XCTAssertEqual(store.channels.count, 1)
    }

    func testSavingTidiesAliasesOnTheWayIn() throws {
        let store = makeStore()
        try store.upsert(channel(name: " Veritasium ", aliases: ["vera tasium", "VERA TASIUM", " "]))

        XCTAssertEqual(store.channels.first?.displayName, "Veritasium")
        XCTAssertEqual(store.channels.first?.aliases, ["vera tasium"])
    }

    func testEditingAnExistingRowReplacesItRatherThanAppending() throws {
        let store = makeStore()
        var stored = channel()
        try store.upsert(stored)

        stored.displayName = "Veritasium main"
        try store.upsert(stored)

        XCTAssertEqual(store.channels.map(\.displayName), ["Veritasium main"])
    }

    func testDisablingARowKeepsItAndTakesItOffTheAllowlist() throws {
        let store = makeStore()
        let stored = channel()
        try store.upsert(stored)

        try store.setEnabled(false, for: stored.id)

        XCTAssertEqual(store.channels.count, 1)
        XCTAssertTrue(store.allowlist.isEmpty)
    }

    func testRemovingARowTakesItOut() throws {
        let store = makeStore()
        let stored = channel()
        try store.upsert(stored)

        try store.remove([stored.id])

        XCTAssertTrue(store.channels.isEmpty)
    }

    func testAnUnreadableDocumentIsReportedAndFreezesWrites() throws {
        PreferenceStore.defaults.set(
            Data("not json".utf8), forKey: YouTubeChannelStore.channelsKey
        )
        let store = makeStore()

        XCTAssertNotNil(store.loadFailure)
        XCTAssertFalse(store.canMutate)
        // Silently replacing what could not be read is how a user's list
        // disappears without anyone being told.
        XCTAssertThrowsError(try store.upsert(channel()))

        store.reset()

        XCTAssertNil(store.loadFailure)
        XCTAssertTrue(store.canMutate)
    }

    func testTheAllowlistOffersOnlyRowsACommandCouldUse() throws {
        let store = makeStore()
        try store.replaceAll([
            channel(),
            YouTubeChannel(displayName: "Broken", channelID: "@handle"),
            YouTubeChannel(
                displayName: "Off", channelID: "UCzzzzzzzzzzzzzzzzzzzzzz", isEnabled: false
            ),
        ])

        XCTAssertEqual(store.allowlist.channels.map(\.displayName), ["Veritasium"])
    }

    // MARK: - The gates in front of it

    func testADefaultInstallRoutesNoChannelsAtAll() {
        // Spoken commands are off by default, so the command cannot run - and a
        // `nil` allowlist is what leaves the words as ordinary dictation.
        XCTAssertNil(Settings(routesSpokenIntents: true).youTubeChannels)
    }

    func testTheAllowlistReachesTheDictationPathOnlyWithBothSwitchesOn() throws {
        try makeStore().upsert(channel())
        AppPreferences.shared.spokenIntentsEnabled = true

        AppPreferences.shared.youTubeLatestVideoEnabled = false
        XCTAssertNil(Settings(routesSpokenIntents: true).youTubeChannels)

        AppPreferences.shared.youTubeLatestVideoEnabled = true
        XCTAssertEqual(
            Settings(routesSpokenIntents: true).youTubeChannels?.channels.map(\.displayName),
            ["Veritasium"]
        )

        // A dropped file, a queued recording or a regenerate from history never
        // routes, whatever the preferences say.
        XCTAssertNil(Settings().youTubeChannels)
    }
}
