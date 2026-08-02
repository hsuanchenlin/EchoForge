import Foundation

/// The user's personal terms dictionary, stored as a plain `terms.json`.
///
/// Deliberately a single global file rather than anything nested inside a style
/// profile: the dictionary belongs to the user, outlives any profile, and has
/// to survive deleting every one of them. It is also kept out of
/// `recordings.sqlite`, which has a retention policy that deletes old rows.
///
/// The store is a plain singleton with its own lock rather than an
/// `ObservableObject`, following `AppPreferences`: the transcription pipeline
/// reads it from a detached task, and the settings screen wraps it in its own
/// view model. See `docs/personal-terms.md`.
final class PersonalTermsStore {
    enum StoreError: LocalizedError {
        case recoveryRequired

        var errorDescription: String? {
            "Reload or repair terms.json before changing the dictionary."
        }
    }

    static let shared = PersonalTermsStore()

    /// `~/Library/Application Support/<bundle id>/terms.json`, beside the
    /// recordings database and the models directory.
    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "EchoForge"
        )
        return appDirectory.appendingPathComponent("terms.json")
    }

    let fileURL: URL

    private let lock = NSLock()
    private var document: PersonalTermsDocument = .empty
    private var loadFailureMessage: String?

    init(fileURL: URL = PersonalTermsStore.defaultFileURL) {
        self.fileURL = fileURL
        reload()
    }

    // MARK: - Reading

    /// Every entry in the file, including disabled and half-finished ones, in
    /// file order. This is what the settings UI edits.
    var terms: [PersonalTerm] {
        lock.lock()
        defer { lock.unlock() }
        return document.terms
    }

    /// The entries the corrector should act on.
    var activeTerms: [PersonalTerm] {
        terms.filter { $0.isEnabled && $0.isValid }
    }

    /// Set when the file exists but could not be read, so the settings screen
    /// can say so instead of appearing to have lost the user's dictionary.
    /// A file that fails to load is never overwritten implicitly.
    var loadFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadFailureMessage
    }

    // MARK: - Loading and saving

    /// Re-reads `terms.json`.
    ///
    /// A missing file is not an error - it is simply an empty dictionary, which
    /// is the state every user starts in.
    func reload() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            lock.lock()
            if Self.isFileNotFound(error) {
                document = .empty
                loadFailureMessage = nil
            } else {
                loadFailureMessage = "terms.json could not be read: \(error.localizedDescription)"
            }
            lock.unlock()
            return
        }

        do {
            let decoded = try Self.decode(data)
            lock.lock()
            document = decoded
            loadFailureMessage = nil
            lock.unlock()
        } catch {
            lock.lock()
            document = .empty
            loadFailureMessage = "terms.json could not be read: \(error.localizedDescription)"
            lock.unlock()
        }
    }

    /// Replaces the whole dictionary and writes it out.
    ///
    /// Whole-file writes rather than per-entry mutation because the file is
    /// small, hand-editable and has no meaningful concurrent writer.
    func replaceAll(_ terms: [PersonalTerm]) throws {
        lock.lock()
        guard loadFailureMessage == nil else {
            lock.unlock()
            throw StoreError.recoveryRequired
        }
        var updated = document
        lock.unlock()
        updated.replaceTerms(terms)
        let data = try Self.encode(updated)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)

        lock.lock()
        document = updated
        loadFailureMessage = nil
        lock.unlock()
    }

    // MARK: - Codec

    static func decode(_ data: Data) throws -> PersonalTermsDocument {
        try JSONDecoder().decode(PersonalTermsDocument.self, from: data)
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    /// Pretty-printed with sorted keys so the file stays readable and diffable
    /// for the users who will hand-edit or version-control it.
    static func encode(_ document: PersonalTermsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}
