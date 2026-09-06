import Foundation

/// Where this app's data lives on disk, and what it is called there.
///
/// It exists because two processes now have to agree on that answer: the app,
/// which writes, and the `echoforge` command-line tool, which reads. They cannot
/// agree by both asking `Bundle.main`, because a command-line tool has no bundle
/// identifier at all - `Bundle.main.bundleIdentifier!` was force-unwrapped in
/// three places, which is a crash in any process that is not the app.
///
/// The identifier is **release and storage identity**, not the product name and
/// not the Swift module: `com.hsuanchenlin.EchoForge` names the folder holding
/// every existing user's recordings, personal terms and downloaded models, their
/// Keychain item and their TCC grants. Changing it hands every user an empty app.
/// See the naming section of `AGENTS.md`.
///
/// The constant is deliberately **not** `Bundle.main.bundleIdentifier`, even
/// though the app's is the same string. The identity of the data has to be the
/// same answer in every process that reads it, and asking each process for its
/// own identity gives a different answer in each: `nil` in a plain tool, the
/// tool's own identifier once it carries an embedded Info.plist section, and the
/// host app's under a test host. Every one of those but the last would point at
/// a directory with none of the user's recordings in it - and it would look
/// like an empty history rather than like a bug.
enum AppDataLocation {
    /// The identifier the app's data is filed under, everywhere, in every
    /// process. Pinned against the app's own bundle identifier by
    /// `AppIdentityTests`; changing it hands every user an empty app.
    static let storageIdentifier = "com.hsuanchenlin.EchoForge"

    /// The name the data directory carries. An alias for `storageIdentifier`,
    /// kept because that is what the path is *called* at every call site.
    static var bundleIdentifier: String { storageIdentifier }

    /// `~/Library/Application Support/com.hsuanchenlin.EchoForge/`, the home of
    /// the recordings database, `terms.json` and the downloaded models.
    static func applicationSupportDirectory(
        bundleIdentifier: String = AppDataLocation.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// The GRDB database every history row is stored in.
    static func recordingsDatabaseURL(
        bundleIdentifier: String = AppDataLocation.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(bundleIdentifier: bundleIdentifier, fileManager: fileManager)
            .appendingPathComponent("recordings.sqlite")
    }

    /// Where `WhisperModelManager` keeps the `.bin` files it downloads.
    /// `echoforge status` reports whether one is on disk, so the name is here
    /// rather than private to the manager.
    static func whisperModelsDirectory(
        bundleIdentifier: String = AppDataLocation.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(bundleIdentifier: bundleIdentifier, fileManager: fileManager)
            .appendingPathComponent("whisper-models", isDirectory: true)
    }

    /// The directory holding the `.wav` beside each row.
    static func recordingsDirectory(
        bundleIdentifier: String = AppDataLocation.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(bundleIdentifier: bundleIdentifier, fileManager: fileManager)
            .appendingPathComponent("recordings", isDirectory: true)
    }
}
