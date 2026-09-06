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
/// `Bundle.main` still wins when there is one, so a test host or a differently
/// signed build reads its own container rather than the user's real data.
enum AppDataLocation {
    /// The identifier the app's data is filed under. The literal is the
    /// fallback for a process with no bundle of its own - the CLI - and is
    /// pinned by `AppIdentityTests`.
    static let storageIdentifier = "com.hsuanchenlin.EchoForge"

    /// The identifier this *process* files data under.
    ///
    /// The app answers with its own, which is `storageIdentifier`; the CLI has
    /// no bundle and falls through to the constant, so both reach one directory.
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? storageIdentifier
    }

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
