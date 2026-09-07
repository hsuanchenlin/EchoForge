import Foundation

/// Everything outside this tool that a command is allowed to touch.
///
/// One value, injected, because the alternative is a test suite that reads the
/// developer's own history, starts the app on their desktop and replaces the
/// copy in `/Applications` - and a suite nobody dares run is a suite that stops
/// being run. Every command below takes this and reaches for nothing else: no
/// `FileManager.default`, no `NSWorkspace.shared`, no `Date()`, no `URLSession`.
/// `CLISeamTests` scans the command sources for those names and fails if one
/// appears.
struct CLIEnvironment {
    var fileSystem: FileSystemReading
    var runningApplications: RunningApplicationsReading
    var launcher: ApplicationLaunching
    var history: HistoryReading
    var preferences: PreferencesReading
    var log: LogReading
    var updates: UpdateServicing

    /// The clock. A closure rather than a `Date` so a long-running command -
    /// `logs --follow` - sees time pass.
    var now: () -> Date

    /// Where the tool looks for the app when `--app` is not given, in order.
    var defaultApplicationLocations: [URL]

    /// Asks the person at the terminal a yes/no question. Returns `nil` when
    /// there is nobody there - a pipe, a cron job - which every caller treats
    /// as "no" rather than as "yes".
    var confirm: (String) -> Bool?

    /// The identity of the tool itself, for `echoforge version`.
    var toolIdentity: AppBuildIdentity
}

// MARK: - Seams

/// The read-only view of the filesystem the commands get.
///
/// Deliberately has no `write`, `remove` or `createDirectory`: six of the seven
/// commands are read-only, and the seventh does its writing inside
/// `UpdateInstaller`, which owns that decision and is shared with the app.
protocol FileSystemReading {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileSize(at url: URL) -> Int64?
    func modificationDate(at url: URL) -> Date?
    func contents(at url: URL) -> Data?

    /// The `Info.plist` of a bundle, or nil when there is no readable bundle
    /// there. Its own method because reading a plist is not reading a file: the
    /// app's identity comes from `Bundle`, the same way the app reads its own.
    func infoDictionary(forBundleAt url: URL) -> [String: Any]?
}

struct RunningCopy: Equatable {
    let processIdentifier: Int32
    let bundleURL: URL?
    let launchDate: Date?
}

protocol RunningApplicationsReading {
    func runningCopies(ofBundleIdentifier identifier: String) -> [RunningCopy]
}

protocol ApplicationLaunching {
    /// Opens the bundle at `url` the way the Finder would, and hands back the
    /// process macOS actually started.
    ///
    /// Throws rather than returning a flag, because "it did not open" always
    /// has a reason worth printing. Returns the copy rather than nothing so the
    /// tool can report the pid it started, and - more usefully - the path macOS
    /// resolved, which is not always the path it was given: LaunchServices
    /// activates an already-running copy of the same bundle identifier rather
    /// than starting a second one.
    func launch(at url: URL) throws -> RunningCopy?
}

/// Whether a preference reader can provide values, and what it contains.
///
/// `isReadable` remains separate from "every key is nil" so injected readers
/// can preserve an unavailable result instead of turning it into "off".
protocol PreferencesReading {
    var isReadable: Bool { get }
    func value(forKey key: String) -> Any?
}

// MARK: - Production implementations

struct SystemFileSystem: FileSystemReading {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
    }

    func fileSize(at url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    func modificationDate(at url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func contents(at url: URL) -> Data? {
        fileManager.contents(atPath: url.path)
    }

    func infoDictionary(forBundleAt url: URL) -> [String: Any]? {
        Bundle(url: url)?.infoDictionary
    }
}

/// The defaults domain the app writes.
///
/// `UserDefaults(suiteName:)` rather than `.standard`, because `.standard` in
/// this process is the *tool's* own domain and would be empty forever. The app
/// is not sandboxed, so the domain is an ordinary plist this user owns; a
/// sandboxed app's would be inside its container and this would read nothing.
struct AppDefaults: PreferencesReading {
    private let defaults: UserDefaults?

    init(suiteName: String = AppDataLocation.storageIdentifier) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    var isReadable: Bool { defaults != nil }

    func value(forKey key: String) -> Any? {
        defaults?.object(forKey: key)
    }
}

struct SystemApplicationLauncher: ApplicationLaunching {
    func launch(at url: URL) throws -> RunningCopy? {
        try WorkspaceBridge.open(url)
    }
}

struct SystemRunningApplications: RunningApplicationsReading {
    func runningCopies(ofBundleIdentifier identifier: String) -> [RunningCopy] {
        WorkspaceBridge.runningCopies(ofBundleIdentifier: identifier)
    }
}
