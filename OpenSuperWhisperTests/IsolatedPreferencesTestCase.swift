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
        PreferenceStore.defaults.removePersistentDomain(forName: suiteName)
        PreferenceStore.defaults = previousDefaults
        previousDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// What was actually stored under `key`, as opposed to a default read back
    /// through `AppPreferences`.
    func storedPreference(_ key: String) -> Any? {
        PreferenceStore.defaults.object(forKey: key)
    }
}
