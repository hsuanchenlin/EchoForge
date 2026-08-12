import Foundation
import Security

/// Where the user's API key lives.
///
/// The Keychain, and nowhere else. Every other setting in this app goes through
/// `PreferenceStore.defaults`, and this one deliberately does not: a preference
/// is a plist under `~/Library/Preferences` that any process running as the user
/// can read, that Time Machine copies, and that a bug report or a screen share
/// can leak whole. An API key is a bearer credential with a spend attached to it.
///
/// The rule is one line and `CloudCredentialStoreTests` scans the sources for it:
/// **the key is never written to `UserDefaults`, never written to a file this app
/// creates, never bundled, and never sent anywhere but the provider the user
/// configured.** It reaches the network in exactly one place - the `Authorization`
/// header built by `CloudRequests` - and `CloudRedaction` is what keeps it out of
/// every log line and error message on the way back.
protocol CloudCredentialStoring: Sendable {
    /// The stored key, or `nil` when there is none. `nil` and `""` mean the same
    /// thing to every caller, so an empty string is never stored.
    func apiKey() -> String?

    /// Stores a key, or removes it when handed nothing usable.
    func setAPIKey(_ key: String?)
}

/// The production store: a generic password item in the login keychain.
///
/// `kSecAttrService` carries the bundle identifier so an EchoForge install and
/// an upstream OpenSuperWhisper install cannot read each other's item - the same
/// separation the Application Support directory already gives the database and
/// the models. `kSecAttrAccount` is a fixed string rather than the provider host:
/// one key at a time is what the Settings pane offers, and keying the item by
/// host would leave a trail of orphaned keys behind every base-URL edit.
struct KeychainCloudCredentialStore: CloudCredentialStoring {
    /// The account name inside the service. Storage format: changing it strands
    /// the key of every existing install, who would then be shown an empty field
    /// with no way to know why.
    static let account = "cloud-api-key"

    let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.hsuanchenlin.EchoForge").cloud") {
        self.service = service
    }

    /// The query identifying the one item this store owns. Built in one place so
    /// a read, a write and a delete cannot disagree about which item they mean -
    /// which is the failure mode that leaves a user with a key they can neither
    /// use nor clear.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func apiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        // Available whenever the Mac is unlocked and never synced to iCloud: a
        // dictation key is a machine-local credential, and copying it to the
        // user's other devices is a decision this app has no reason to make for
        // them.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(insert as CFDictionary, nil)
    }
}

/// A store that keeps the key in memory for the length of one test.
///
/// Tests do not touch the real keychain: an unsigned test host asking for an item
/// it did not create is exactly the case macOS answers with a modal prompt, and a
/// test suite that can hang waiting for a click is worse than no test. The real
/// store's own round trip is opt-in (`CloudCredentialStoreTests`), and everything
/// that has an opinion about keys - the access gate, request construction,
/// redaction - takes a `CloudCredentialStoring` so it can be driven with this.
final class InMemoryCloudCredentialStore: CloudCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(apiKey: String? = nil) {
        self.stored = apiKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    func apiKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        stored = trimmed.isEmpty ? nil : trimmed
        lock.unlock()
    }
}
