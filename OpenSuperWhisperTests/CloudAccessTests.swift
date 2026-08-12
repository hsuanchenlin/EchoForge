import XCTest

@testable import OpenSuperWhisper

/// The gate: what has to be true before anything the user says can leave their
/// Mac, and what happens when one of those things is not.
///
/// Pure, so every refusal is asserted without a Keychain, a network, or a Mac
/// configured any particular way - the same reason `EngineSelectionTests` exists
/// for the engine decision.
final class CloudAccessTests: XCTestCase {

    private func settings(
        isCompiledIn: Bool = true,
        engine: EngineKind = .whisper,
        translation: Bool = false,
        baseURL: String = CloudEndpoint.openAIBaseURL,
        transcriptionModel: String = "whisper-1",
        translationModel: String = "gpt-4o-mini",
        consented: Set<CloudFeature> = []
    ) -> CloudSettings {
        CloudSettings(
            isCompiledIn: isCompiledIn,
            selectedEngine: engine,
            translationEnabled: translation,
            baseURLText: baseURL,
            transcriptionModel: transcriptionModel,
            translationModel: translationModel,
            consentedFeatures: consented
        )
    }

    private func refusal(
        _ feature: CloudFeature,
        _ settings: CloudSettings,
        key: String? = "sk-test-0123456789"
    ) -> CloudAccessRefusal? {
        let result = CloudAccess.resolve(
            feature,
            settings: settings,
            credentials: InMemoryCloudCredentialStore(apiKey: key)
        )
        guard case .failure(let refusal) = result else { return nil }
        return refusal
    }

    /// The state every install starts in, and the one this whole feature is
    /// judged by: nothing is permitted, for either feature.
    func testAFreshInstallIsRefusedForEveryFeature() {
        let fresh = settings()

        for feature in CloudFeature.allCases {
            XCTAssertEqual(
                refusal(feature, fresh), .featureIsLocal(feature),
                "\(feature.rawValue) must be local until the user says otherwise"
            )
        }
    }

    /// An offline-only build refuses before it looks at anything else, so a
    /// preferences file carried over from a normal build cannot switch the cloud
    /// on inside it.
    func testAnOfflineOnlyBuildRefusesEvenAFullyConfiguredFeature() {
        let configured = settings(
            isCompiledIn: false,
            engine: .cloud,
            translation: true,
            consented: Set(CloudFeature.allCases)
        )

        for feature in CloudFeature.allCases {
            XCTAssertEqual(refusal(feature, configured), .notInThisBuild)
        }
    }

    /// Turning the feature on is not consenting to it. This is the case a
    /// hand-edited preference or a downgrade produces, and it has to refuse
    /// rather than treat the flag as the decision.
    func testAnEnabledFeatureWithNoRecordedConsentIsRefused() {
        XCTAssertEqual(
            refusal(.transcription, settings(engine: .cloud)),
            .consentNotGiven(.transcription)
        )
        XCTAssertEqual(
            refusal(.translation, settings(translation: true)),
            .consentNotGiven(.translation)
        )
    }

    /// Consent for one feature says nothing about the other. Agreeing that a
    /// sentence you asked to have translated may be uploaded is not agreeing that
    /// every recording you make may be.
    func testConsentingToOneFeatureDoesNotPermitTheOther() {
        let translationOnly = settings(
            engine: .cloud, translation: true, consented: [.translation]
        )

        XCTAssertEqual(
            refusal(.transcription, translationOnly), .consentNotGiven(.transcription)
        )
        XCTAssertNil(refusal(.translation, translationOnly))
    }

    /// The key is the last thing checked, and its absence is its own message -
    /// "cloud is unavailable" would leave a user with no idea which of six
    /// things is missing.
    func testWithEverythingButAKeyTheRefusalNamesTheKey() {
        XCTAssertEqual(
            refusal(.transcription, settings(engine: .cloud, consented: [.transcription]), key: nil),
            .noAPIKey
        )
    }

    /// The Keychain is not touched for a feature the user has left on Local.
    ///
    /// It reads as an optimisation and is not one: a Keychain read from an
    /// unsigned build can put a system prompt in front of someone who has not
    /// asked for any of this, and `EngineAvailability.current` runs this gate on
    /// every transcription.
    func testTheKeychainIsNotConsultedForALocalFeature() {
        let counting = CountingCredentialStore()

        _ = CloudAccess.resolve(.transcription, settings: settings(), credentials: counting)

        XCTAssertEqual(counting.reads, 0)
    }

    /// Everything present: a permitted call carrying exactly what the request
    /// builder needs.
    func testAFullyConfiguredFeatureProducesACall() throws {
        let result = CloudAccess.resolve(
            .translation,
            settings: settings(translation: true, consented: [.translation]),
            credentials: InMemoryCloudCredentialStore(apiKey: "sk-test-0123456789")
        )

        let call = try result.get()
        XCTAssertEqual(call.feature, .translation)
        XCTAssertEqual(call.model, "gpt-4o-mini")
        XCTAssertEqual(call.apiKey, "sk-test-0123456789")
        XCTAssertEqual(call.endpoint.host, "api.openai.com")
    }

    /// A model field emptied by hand refuses with the field's name rather than
    /// producing a request the provider answers with an unreadable 400.
    func testAFeatureWithNoModelNamedIsRefused() {
        XCTAssertEqual(
            refusal(
                .transcription,
                settings(engine: .cloud, transcriptionModel: "   ", consented: [.transcription])
            ),
            .noModelNamed(.transcription)
        )
    }

    /// The two refusals that are not mistakes are not reported as mistakes: a
    /// dictation that ran locally because the user wants it to run locally is
    /// not an event, and saying so on every transcription would be noise.
    func testOnlyMisconfigurationsAreWorthTellingTheUserAbout() {
        XCTAssertFalse(CloudAccessRefusal.notInThisBuild.isMisconfiguration)
        XCTAssertFalse(CloudAccessRefusal.featureIsLocal(.translation).isMisconfiguration)
        XCTAssertTrue(CloudAccessRefusal.noAPIKey.isMisconfiguration)
        XCTAssertTrue(CloudAccessRefusal.consentNotGiven(.transcription).isMisconfiguration)
    }
}

/// The base URL, which is the security boundary of the whole module: whatever a
/// user types here is where their dictation and their API key are sent.
final class CloudEndpointTests: XCTestCase {

    private func endpoint(_ text: String) throws -> CloudEndpoint {
        try CloudEndpoint.resolve(text).get()
    }

    private func failure(_ text: String) -> CloudEndpointError? {
        guard case .failure(let error) = CloudEndpoint.resolve(text) else { return nil }
        return error
    }

    /// The default, and the two endpoints built from it.
    func testTheDefaultBaseURLProducesTheOpenAIEndpoints() throws {
        let resolved = try endpoint(CloudEndpoint.openAIBaseURL)

        XCTAssertEqual(
            resolved.transcriptions.absoluteString,
            "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            resolved.chatCompletions.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    /// Every provider's documentation quotes its base URL with the version
    /// segment on it, so that is what people paste. Appending to it unmodified
    /// gives `/v1/v1/...` and a 404 nobody can read.
    func testAPastedBaseURLKeepsExactlyOneVersionSegment() throws {
        for written in [
            "https://api.openai.com/v1",
            "https://api.openai.com/v1/",
            "https://api.openai.com/",
            "  https://api.openai.com/V1  ",
        ] {
            XCTAssertEqual(
                try endpoint(written).transcriptions.absoluteString,
                "https://api.openai.com/v1/audio/transcriptions",
                written
            )
        }
    }

    /// A provider reached through a path prefix - a gateway, a self-hosted proxy -
    /// keeps its prefix.
    func testAPathPrefixSurvives() throws {
        XCTAssertEqual(
            try endpoint("https://gateway.example.com/openai/v1").chatCompletions.absoluteString,
            "https://gateway.example.com/openai/v1/chat/completions"
        )
    }

    /// The rule that matters: plaintext to somewhere other than this machine
    /// would put both the dictation and the bearer token on the wire.
    func testPlainHTTPToARemoteHostIsRefused() {
        XCTAssertEqual(failure("http://api.example.com"), .insecure(host: "api.example.com"))
    }

    /// And its deliberate exception. `http://127.0.0.1:11434` is how the local
    /// OpenAI-compatible servers people actually run are reached, and bytes sent
    /// there have not left the Mac.
    func testPlainHTTPToLoopbackIsAllowedAndSaysSo() throws {
        let local = try endpoint("http://127.0.0.1:11434")

        XCTAssertTrue(local.isLoopback)
        XCTAssertEqual(local.chatCompletions.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertTrue(try endpoint("http://localhost:1234/v1").isLoopback)
        XCTAssertFalse(try endpoint(CloudEndpoint.openAIBaseURL).isLoopback)
    }

    /// A credential in the URL would sit somewhere this module redacts nothing
    /// from, and a query string would end up in the middle of the endpoint path.
    func testURLsThatWouldCarryTheKeyOrBreakThePathAreRefused() {
        XCTAssertEqual(failure("https://key@api.example.com"), .carriesCredentials)
        XCTAssertEqual(failure("https://api.example.com?token=abc"), .carriesAQueryOrFragment)
        XCTAssertEqual(failure("https://api.example.com#x"), .carriesAQueryOrFragment)
        XCTAssertEqual(failure("ftp://api.example.com"), .unsupportedScheme("ftp"))
        XCTAssertEqual(failure("  "), .empty)
    }

    /// A host-less string - which is what "api.openai.com" typed without a
    /// scheme is - is refused rather than quietly treated as a relative path.
    func testAStringWithNoSchemeIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(failure("api.openai.com/v1"), .hasNoHost)
    }
}

/// Turning cloud transcription on and off, which is a change of engine and has
/// to be reversible.
final class CloudTranscriptionSelectionTests: IsolatedPreferencesTestCase {

    /// Switching to the cloud and back leaves the user on the engine they were
    /// using - not on `EngineKind.fallback` and a Whisper model they may never
    /// have downloaded.
    func testTurningItOffRestoresTheEngineTheUserWasOn() {
        let preferences = AppPreferences.shared
        preferences.selectedEngine = .sensevoice

        CloudTranscriptionSelection.enable(preferences: preferences)
        XCTAssertEqual(preferences.selectedEngine, .cloud)

        CloudTranscriptionSelection.disable(preferences: preferences)
        XCTAssertEqual(preferences.selectedEngine, .sensevoice)
    }

    /// A remembered "previous local engine" that is itself the cloud one - which
    /// only a hand-edited preference produces - must not make turning it off a
    /// no-op.
    func testItNeverRestoresTheCloudEngineAsTheLocalOne() {
        let preferences = AppPreferences.shared
        preferences.selectedEngine = .cloud
        preferences.cloudPreviousLocalEngine = .cloud
        preferences.lastReadyEngine = nil

        CloudTranscriptionSelection.disable(preferences: preferences)

        XCTAssertEqual(preferences.selectedEngine, EngineKind.fallback)
    }

    /// Revoking consent switches the feature off as well. A stored consent with
    /// the feature off is a loaded gun; the pane's reset button is the one place
    /// that says "forget it", and it has to mean it.
    func testRevokingConsentAlsoTurnsTheFeatureOff() {
        let preferences = AppPreferences.shared
        preferences.selectedEngine = .whisper
        CloudConsent.grant(.transcription, preferences: preferences)
        CloudConsent.grant(.translation, preferences: preferences)
        CloudTranscriptionSelection.enable(preferences: preferences)
        preferences.cloudTranslationEnabled = true

        CloudConsent.revokeEverything(preferences: preferences)

        XCTAssertEqual(preferences.cloudConsentedFeatures, [])
        XCTAssertEqual(preferences.selectedEngine, .whisper)
        XCTAssertFalse(preferences.cloudTranslationEnabled)
    }

    /// Consent survives switching a feature off and on again. Asking twice
    /// trains people to click through it, which is the opposite of what it is
    /// for.
    func testConsentSurvivesTurningTheFeatureOffAndOnAgain() {
        let preferences = AppPreferences.shared
        CloudConsent.grant(.translation, preferences: preferences)
        preferences.cloudTranslationEnabled = true
        preferences.cloudTranslationEnabled = false

        XCTAssertTrue(
            CloudSettings.current(preferences: preferences).hasConsented(to: .translation)
        )
    }
}

/// The consent sheet's wording, which is the disclosure itself rather than
/// decoration around one.
final class CloudConsentCopyTests: XCTestCase {

    /// Three requirements, one test: it names what leaves the Mac, it names
    /// where it goes, and it says the choice can be undone.
    func testTheSheetNamesWhatLeavesTheMacWhereItGoesAndHowToUndoIt() {
        let copy = CloudConsent.copy(for: .transcription, host: "api.openai.com", isLoopback: false)
        let everything = ([copy.title, copy.body] + copy.points).joined(separator: " ")

        XCTAssertTrue(everything.contains("the audio of every dictation you record"))
        XCTAssertTrue(everything.contains("api.openai.com"))
        XCTAssertTrue(everything.contains("Keychain"))
        XCTAssertTrue(everything.lowercased().contains("switch back to on-device"))
        XCTAssertEqual(copy.cancel, "Keep it on my Mac")
    }

    /// Translation's sheet says translation's payload. Reusing one sentence for
    /// both would overstate one of them and understate the other.
    func testEachFeatureNamesItsOwnPayload() {
        let translation = CloudConsent.copy(for: .translation, host: "h", isLoopback: false)

        XCTAssertTrue(
            translation.points.joined().contains("the text of every dictation you ask to have translated")
        )
        XCTAssertFalse(translation.points.joined().contains("audio"))
    }

    /// The sheet covers the pane footer - the only other place the disclosure
    /// link lives - at exactly the moment the user is deciding, so the full
    /// "what is sent, when, and where" page has to be reachable from the sheet
    /// itself.
    func testTheSheetLinksTheFullDisclosure() {
        let copy = CloudConsent.copy(for: .transcription, host: "api.openai.com", isLoopback: false)

        XCTAssertTrue(copy.learnMore.contains("What is sent"))
        XCTAssertTrue(CloudConsent.docsURL.absoluteString.hasSuffix("docs/cloud-api.md"))
    }

    /// A provider on this Mac is a different disclosure, and saying "a company
    /// outside your control" about the user's own Ollama would make the real
    /// warning less believable when it matters.
    func testALocalProviderIsNotDescribedAsACompany() {
        let local = CloudConsent.copy(for: .transcription, host: "127.0.0.1", isLoopback: true)

        XCTAssertFalse(local.points.joined().contains("a company outside your control"))
        XCTAssertTrue(local.points.joined().contains("does not leave it"))
    }
}

/// Counts reads so a test can assert the Keychain was never asked.
private final class CountingCredentialStore: CloudCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _reads
    }

    func apiKey() -> String? {
        lock.lock()
        _reads += 1
        lock.unlock()
        return "sk-should-not-have-been-read"
    }

    func setAPIKey(_ key: String?) {}
}
