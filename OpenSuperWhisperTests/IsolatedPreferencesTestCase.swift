import XCTest
@testable import OpenSuperWhisper

/// A test case whose preference writes go to a throwaway defaults suite.
///
/// The tests run in several parallel host processes against one real defaults
/// domain, so a test that clears `selectedEngine` in one process can be read by
/// a view model loading an engine in another. Pointing `PreferenceStore` at a
/// per-test suite keeps that from being a source of flakes, and means these
/// tests neither see nor damage the developer's own settings.
class IsolatedPreferencesTestCase: XCTestCase {

    private var suiteName: String!
    private var previousDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "echoforge.tests.\(UUID().uuidString)"
        previousDefaults = PreferenceStore.defaults
        PreferenceStore.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        drainMainQueue()
        PreferenceStore.defaults.removePersistentDomain(forName: suiteName)
        PreferenceStore.defaults = previousDefaults
        previousDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Lets work a preference change woke up finish *inside* this test's suite.
    ///
    /// It is not tidiness. Changing a preference can post a notification whose
    /// observer defers to the main actor - `TranscriptionService` re-resolves which
    /// engine to run on that way - and a `Task` that ran after the restore below
    /// reads the developer's own settings instead of this test's. That is not a
    /// wrong assertion, it is a hung suite: with a cloud engine configured in those
    /// real settings, the re-resolve reaches `KeychainCloudCredentialStore`, and an
    /// ad-hoc-signed test host asking for the Keychain gets a system dialog nobody
    /// is there to answer. Ten milliseconds of run loop, three times, is enough for
    /// queued main-actor work; nothing here waits on a network or a model, both of
    /// which are switched off under `OpenSuperWhisperApp.isRunningTests`.
    private func drainMainQueue() {
        guard Thread.isMainThread else { return }
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// What was actually stored under `key`, as opposed to a default read back
    /// through `AppPreferences`.
    func storedPreference(_ key: String) -> Any? {
        PreferenceStore.defaults.object(forKey: key)
    }
}
