import XCTest

@testable import OpenSuperWhisper

/// `PreferenceKeys` is only single-ownership if it is complete.
///
/// The `echoforge` command-line tool reports settings by reading the app's
/// defaults domain from another process, so it can only ever see keys it knows
/// the names of. A preference added with a fresh string literal would work
/// perfectly in the app and be invisible to the CLI - which reports "not set"
/// rather than failing, so nothing would say so. This reads the literals back
/// out of `AppPreferences.swift` and fails instead.
final class PreferenceKeyCoverageTests: XCTestCase {

    private var appPreferencesSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenSuperWhisper/Utils/AppPreferences.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Every `key:` in `AppPreferences` names a `PreferenceKeys` constant, and
    /// none of them is a bare string.
    func testEveryPreferenceIsDeclaredThroughTheSharedKeys() throws {
        let source = try appPreferencesSource

        var literals: [String] = []
        var cursor = source.startIndex
        while let match = source.range(of: "key: \"", range: cursor..<source.endIndex) {
            guard let end = source.range(of: "\"", range: match.upperBound..<source.endIndex) else {
                break
            }
            literals.append(String(source[match.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }

        XCTAssertTrue(
            literals.isEmpty,
            "AppPreferences declares \(literals) as bare strings. Every preference key belongs "
                + "in PreferenceKeys so the app and the echoforge CLI cannot spell one "
                + "differently.")
    }

    /// Every constant the property wrappers reach for is in `PreferenceKeys.all`,
    /// which is what the CLI enumerates.
    func testEveryUsedKeyIsListedInAll() throws {
        let source = try appPreferencesSource

        var used: Set<String> = []
        var cursor = source.startIndex
        while let match = source.range(of: "PreferenceKeys.", range: cursor..<source.endIndex) {
            let rest = source[match.upperBound...]
            let name = String(rest.prefix { $0.isLetter || $0.isNumber })
            cursor = match.upperBound
            guard !name.isEmpty, name != "all" else { continue }
            used.insert(name)
        }

        XCTAssertGreaterThan(used.count, 40, "the scan found almost no preferences")

        // The constants are named after the keys they hold, so the property name
        // and the stored string are the same word - which is what lets this
        // compare the two lists at all.
        let missing = used.subtracting(PreferenceKeys.all)
        XCTAssertTrue(
            missing.isEmpty,
            "PreferenceKeys.all is missing \(missing.sorted()). The CLI enumerates that set, so "
                + "a key left out of it is a setting `echoforge settings` can never report.")
    }

    /// The one retired key that is deliberately still a literal.
    ///
    /// `selectedModelPath` is read once, by the migration that moved it to
    /// `selectedWhisperModelPath`, and nothing writes it. Giving it a constant
    /// would put a key the app no longer stores into the list the CLI reports.
    func testTheRetiredKeyIsNotPresented() {
        XCTAssertFalse(PreferenceKeys.all.contains("selectedModelPath"))
    }

    /// No key here is a credential. The API key lives only in the Keychain, and
    /// `echoforge settings` reads the defaults domain and nothing else.
    func testNoKeyLooksLikeACredential() {
        for key in PreferenceKeys.all {
            let lowered = key.lowercased()
            for secret in ["apikey", "secret", "token", "password", "credential"] {
                XCTAssertFalse(
                    lowered.contains(secret),
                    "\(key) looks like a credential. Credentials belong in the Keychain "
                        + "(CloudCredentialStore), never in the defaults domain the CLI reports.")
            }
        }
    }
}
