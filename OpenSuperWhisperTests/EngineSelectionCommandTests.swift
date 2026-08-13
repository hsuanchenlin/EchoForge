import XCTest

@testable import OpenSuperWhisper

/// The one path a user's engine choice takes, whichever control they used.
///
/// There are three of those controls now - the Settings picker, the Cloud pane's
/// toggle and the engine shortcut - and this exists so that they cannot mean three
/// slightly different things. Each test here is something that used to live in one
/// of them and had to be remembered in the others.
@MainActor
final class EngineSelectionCommandTests: IsolatedPreferencesTestCase {

    func testItPersistsTheChoiceAndAnnouncesIt() {
        AppPreferences.shared.selectedEngine = .whisper
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .selectedEngineChanged, object: nil, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        EngineSelectionCommand.select(.sensevoice)

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .sensevoice)
        XCTAssertEqual(announcements, 1, "an open Settings pane has to hear about it")
    }

    /// Selecting the engine that is already selected is not an event: it would
    /// otherwise restart a download, re-post two notifications and reset a language
    /// for a press that changed nothing.
    func testSelectingTheSelectedEngineDoesNothing() {
        AppPreferences.shared.selectedEngine = .sensevoice
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .selectedEngineChanged, object: nil, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        EngineSelectionCommand.select(.sensevoice)

        XCTAssertEqual(announcements, 0)
    }

    /// The rule onboarding, Settings and `EngineConfiguration.resolve` all apply: an
    /// engine is never left paired with a language it only mis-transcribes.
    /// Paraformer does not refuse German, it returns fluent Mandarin for it.
    func testTheLanguageFollowsAnEngineThatCannotDictateIt() {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.whisperLanguage = "de"

        EngineSelectionCommand.select(.paraformer)

        XCTAssertEqual(AppPreferences.shared.whisperLanguage, LanguageUtil.fallbackLanguage(engine: .paraformer))
    }

    func testTheLanguageIsLeftAloneWhenTheNewEngineDoesIt() {
        AppPreferences.shared.selectedEngine = .whisper
        AppPreferences.shared.whisperLanguage = "zh"

        EngineSelectionCommand.select(.sensevoice)

        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "zh")
    }

    /// The cloud engine keeps its own bookkeeping (`CloudTranscriptionSelection`),
    /// so switching to it and back leaves the user on the engine they were using
    /// rather than on `EngineKind.fallback` and a Whisper model they may never have
    /// downloaded.
    ///
    /// No consent is recorded here, so `CloudAccess` refuses the engine at the
    /// consent gate - before the Keychain - which is also why this test can select
    /// it at all.
    func testSelectingTheCloudEngineRemembersWhereToComeBackTo() {
        AppPreferences.shared.selectedEngine = .sensevoice

        EngineSelectionCommand.select(.cloud)

        XCTAssertEqual(AppPreferences.shared.selectedEngine, .cloud)
        XCTAssertEqual(AppPreferences.shared.cloudPreviousLocalEngine, .sensevoice)
        XCTAssertEqual(CloudTranscriptionSelection.localEngineToRestore(), .sensevoice)
    }

    /// Choosing an engine is never a grant of consent. Selecting the cloud engine
    /// leaves the consent record exactly as it was, which is what makes
    /// `CloudAccess` a gate rather than a formality.
    func testSelectingTheCloudEngineGrantsNoConsent() {
        AppPreferences.shared.selectedEngine = .sensevoice

        EngineSelectionCommand.select(.cloud)

        XCTAssertEqual(AppPreferences.shared.cloudConsentedFeatures, [])
        XCTAssertFalse(CloudAccess.isSelectable(
            .transcription,
            credentials: InMemoryCloudCredentialStore(apiKey: "sk-a-key-that-exists-anyway")
        ))
    }

    /// A fresh install answers "no" before the Keychain is reached, so asking
    /// whether the cloud could be switched to costs an install that never chose it
    /// nothing at all - the ordering `CloudAccess.resolve` documents.
    func testAskingWhetherCloudIsSelectableNeverReadsTheKeychainWithoutConsent() {
        let credentials = RecordingCredentialStore()

        XCTAssertFalse(CloudAccess.isSelectable(.transcription, credentials: credentials))
        XCTAssertEqual(credentials.reads, 0)

        CloudConsent.grant(.transcription)
        _ = CloudAccess.isSelectable(.transcription, credentials: credentials)
        XCTAssertEqual(credentials.reads, 1, "with consent recorded, the key is what is left to check")
    }

    /// The app's own resolution must not read the real Keychain from a test host,
    /// whatever the preferences say.
    ///
    /// This is a hang, not a wrong answer: `EngineAvailability.current()` is
    /// reached from anywhere, including work a preference change woke up, and an
    /// ad-hoc-signed test host asking macOS for an item it did not create gets a
    /// modal prompt with nobody there to answer it. `CloudAccess` uses an empty
    /// in-memory store under a test, so the answer is always "no key".
    func testTheAppsOwnResolutionNeverReachesTheKeychainUnderATest() {
        let preferences = AppPreferences.shared
        preferences.selectedEngine = .cloud
        preferences.cloudBaseURL = "https://api.openai.com"
        preferences.cloudTranscriptionModel = "whisper-1"
        CloudConsent.grant(.transcription, preferences: preferences)

        guard case .failure(let refusal) = CloudAccess.resolve(.transcription) else {
            return XCTFail("a test host has no key, so nothing may be permitted")
        }
        XCTAssertEqual(
            refusal,
            .noAPIKey,
            "everything else is configured, so this is the gate that has to be the one refusing"
        )
        XCTAssertFalse(EngineAvailability.current().isUsable(.cloud))
        XCTAssertFalse(CloudAccess.isSelectable(.transcription))
    }

    private final class RecordingCredentialStore: CloudCredentialStoring, @unchecked Sendable {
        private(set) var reads = 0

        func apiKey() -> String? {
            reads += 1
            return nil
        }

        func setAPIKey(_ key: String?) {}
    }
}
