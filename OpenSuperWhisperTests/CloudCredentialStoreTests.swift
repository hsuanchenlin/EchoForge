import XCTest

@testable import OpenSuperWhisper

/// Where the API key lives, and how it behaves.
///
/// The real Keychain round trip is **opt-in**, for a reason worth stating: an
/// unsigned test host asking macOS for a keychain item is exactly the case
/// answered with a modal prompt, and a suite that can hang waiting for a click is
/// worse than no test at all. The same rule the model-backed engine tests follow.
/// Run it deliberately with:
///
/// ```
/// ECHOFORGE_KEYCHAIN_TESTS=1 xcodebuild test … \
///   -only-testing:OpenSuperWhisperTests/CloudCredentialStoreTests
/// ```
///
/// What runs unconditionally is the behaviour every caller depends on, asserted
/// against the in-memory store the whole module is written to accept.
final class CloudCredentialStoreTests: XCTestCase {

    /// `nil` and `""` mean the same thing to every caller, so an empty string is
    /// never stored: a "key" of whitespace would pass the gate's presence check
    /// and then be refused by the provider with a message about the key being
    /// wrong.
    func testAnEmptyKeyIsNoKey() {
        let store = InMemoryCloudCredentialStore()

        store.setAPIKey("   ")
        XCTAssertNil(store.apiKey())

        store.setAPIKey("  sk-padded  ")
        XCTAssertEqual(store.apiKey(), "sk-padded", "a pasted key carries whitespace; the header must not")

        store.setAPIKey(nil)
        XCTAssertNil(store.apiKey())
    }

    /// The gate's answer changes with the key and nothing else has to be told.
    func testRemovingTheKeyRefusesEveryFeatureAgain() {
        let store = InMemoryCloudCredentialStore(apiKey: "sk-test-0123456789")
        let settings = CloudSettings(
            isCompiledIn: true,
            selectedEngine: .cloud,
            translationEnabled: true,
            baseURLText: CloudEndpoint.openAIBaseURL,
            transcriptionModel: "whisper-1",
            translationModel: "gpt-4o-mini",
            consentedFeatures: Set(CloudFeature.allCases)
        )

        for feature in CloudFeature.allCases {
            XCTAssertNoThrow(
                try CloudAccess.resolve(feature, settings: settings, credentials: store).get()
            )
        }

        store.setAPIKey(nil)

        for feature in CloudFeature.allCases {
            guard case .failure(let refusal) = CloudAccess.resolve(
                feature, settings: settings, credentials: store
            ) else {
                return XCTFail("\(feature.rawValue) was permitted with no key")
            }
            XCTAssertEqual(refusal, .noAPIKey)
        }
    }

    /// The real store, against the real Keychain, under its own service name so
    /// it cannot touch the developer's own EchoForge item.
    ///
    /// It asserts the one property a keychain-backed store has to have and that
    /// is easy to get wrong: read, write and delete all name the same item. A
    /// store where they disagree leaves a user with a key they can neither use
    /// nor clear.
    func testTheRealStoreRoundTripsAndCanBeCleared() throws {
        guard ProcessInfo.processInfo.environment["ECHOFORGE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip(
                "Opt-in: set ECHOFORGE_KEYCHAIN_TESTS=1. An unsigned test host reading the keychain "
                    + "can put a system prompt in front of the suite."
            )
        }

        let store = KeychainCloudCredentialStore(service: "echoforge.tests.\(UUID().uuidString)")
        addTeardownBlock { store.setAPIKey(nil) }

        XCTAssertNil(store.apiKey(), "a fresh service holds nothing")

        store.setAPIKey("sk-first")
        XCTAssertEqual(store.apiKey(), "sk-first")

        // The update path, which is a different Security call from the insert.
        store.setAPIKey("sk-second")
        XCTAssertEqual(store.apiKey(), "sk-second")

        store.setAPIKey(nil)
        XCTAssertNil(store.apiKey())
    }
}
