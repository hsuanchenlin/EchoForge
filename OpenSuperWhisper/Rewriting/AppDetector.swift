import AppKit
import Foundation

/// The kind of app a dictation is going into.
///
/// Deliberately coarse. The category exists so that one default can cover the
/// apps a user has never told this app about - a chat window wants different
/// words from a mail composer - and five buckets is as fine as that guess can be
/// made honestly. Anything more specific is what the per-app override is for.
///
/// The raw values are persisted (the user's per-category choice is keyed by
/// them), so renaming one silently resets that choice. `AppStyleMappingTests`
/// pins them, the same way `StyleRewriteCatalogTests` pins the style
/// identifiers.
enum AppCategory: String, CaseIterable, Equatable, Sendable {
    /// Chat and instant messaging: Slack, Messages, WhatsApp, WeChat.
    case workChat
    /// Mail clients.
    case email
    /// Editors, IDEs and terminals.
    case developerTools
    /// Long-form writing: notes, word processors, wikis.
    case documentsNotes
    /// Web browsers. Recognized, but see `AppStyleMappingStore` for why this
    /// category's built-in answer is "leave it to the chosen style".
    case browser

    /// The name Settings shows for the category. The only user-facing string
    /// this file owns; the styles' own names come from `StyleRewriteCatalog`.
    var label: String {
        switch self {
        case .workChat: return "Chat & messaging"
        case .email: return "Mail"
        case .developerTools: return "Code & terminals"
        case .documentsNotes: return "Documents & notes"
        case .browser: return "Web browsers"
        }
    }

    /// Examples, so a user can tell which bucket their app fell into without
    /// this app having to name every app it knows.
    var examples: String {
        switch self {
        case .workChat: return "Slack, Messages, WhatsApp, WeChat"
        case .email: return "Mail, Outlook, Spark"
        case .developerTools: return "Xcode, VS Code, Terminal, iTerm"
        case .documentsNotes: return "Notes, Obsidian, Pages, Word"
        case .browser: return "Safari, Chrome, Firefox, Edge"
        }
    }
}

/// Which category a bundle identifier falls into.
///
/// A hand-maintained table rather than anything inferred at runtime, because the
/// only signal this app is willing to look at is the bundle identifier itself -
/// see `docs/app-aware-style.md`. An app that is not in the table has no
/// category, and an app with no category keeps the user's chosen style; guessing
/// from an app's name or its windows is exactly what this feature does not do.
enum AppCategoryCatalog {

    /// Exact bundle identifiers, lowercased. Bundle identifiers are compared
    /// case-insensitively by macOS itself, so the lookup does too - `com.apple.Mail`
    /// and `com.apple.mail` are one app, and a table that matched only one
    /// spelling would work for some users and not others.
    static let exactMatches: [String: AppCategory] = [
        // Chat & messaging
        "com.tinyspeck.slackmacgap": .workChat,
        "com.apple.mobilesms": .workChat,
        "com.whatsapp.whatsapp": .workChat,
        "com.whatsapp.desktop": .workChat,
        "net.whatsapp.whatsapp": .workChat,
        "com.tencent.xinwechat": .workChat,
        "com.hnc.discord": .workChat,
        "com.microsoft.teams": .workChat,
        "com.microsoft.teams2": .workChat,
        "ru.keepcoder.telegram": .workChat,
        "org.telegram.desktop": .workChat,
        "com.facebook.archon": .workChat,
        "com.tencent.qq": .workChat,
        "com.linecorp.line": .workChat,

        // Mail
        "com.apple.mail": .email,
        "com.microsoft.outlook": .email,
        "re.spark.mail": .email,
        "com.readdle.smartemail-mac": .email,
        "com.readdle.sparkdesktop": .email,
        "com.airmailapp.airmail": .email,
        "com.superhuman.mail": .email,
        "com.mimestream.mimestream": .email,

        // Code & terminals
        "com.apple.dt.xcode": .developerTools,
        "com.microsoft.vscode": .developerTools,
        "com.microsoft.vscodeinsiders": .developerTools,
        "com.visualstudio.code.oss": .developerTools,
        "com.apple.terminal": .developerTools,
        "com.googlecode.iterm2": .developerTools,
        "dev.warp.warp-stable": .developerTools,
        "dev.zed.zed": .developerTools,
        "com.todesktop.230313mzl4w4u92": .developerTools, // Cursor
        "com.sublimetext.4": .developerTools,
        "com.github.githubclient": .developerTools,
        "com.figma.desktop": .developerTools,

        // Documents & notes
        "com.apple.notes": .documentsNotes,
        "com.apple.textedit": .documentsNotes,
        "com.apple.iwork.pages": .documentsNotes,
        "com.microsoft.word": .documentsNotes,
        "md.obsidian": .documentsNotes,
        "net.shinyfrog.bear": .documentsNotes,
        "notion.id": .documentsNotes,
        "com.ulyssesapp.mac": .documentsNotes,
        "com.literatureandlatte.scrivener3": .documentsNotes,
        "com.agiletortoise.drafts": .documentsNotes,

        // Web browsers
        "com.apple.safari": .browser,
        "com.google.chrome": .browser,
        "com.google.chrome.canary": .browser,
        "org.mozilla.firefox": .browser,
        "com.microsoft.edgemac": .browser,
        "com.brave.browser": .browser,
        "company.thebrowser.browser": .browser, // Arc
        "com.operasoftware.opera": .browser,
        "com.vivaldi.vivaldi": .browser,
    ]

    /// Identifier prefixes, for families that ship one app per product under one
    /// namespace. Checked only after the exact table, so a single app inside a
    /// family can still be classified differently.
    static let prefixMatches: [(prefix: String, category: AppCategory)] = [
        ("com.jetbrains.", .developerTools),
        ("com.google.android.studio", .developerTools),
    ]

    static func category(forBundleIdentifier identifier: String) -> AppCategory? {
        let normalized = normalize(identifier)
        guard !normalized.isEmpty else { return nil }
        if let exact = exactMatches[normalized] { return exact }
        return prefixMatches.first { normalized.hasPrefix($0.prefix) }?.category
    }

    /// The one spelling of a bundle identifier this app stores and compares.
    ///
    /// Everything that keys on an identifier - the table above, the user's
    /// per-app overrides - goes through this, so a mapping added for
    /// `com.apple.Mail` is found again for `com.apple.mail`.
    static func normalize(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Everything this app knows about where a dictation is going.
///
/// One field, and that is the point: a bundle identifier is the whole of the
/// signal, so there is no place in this type for a window title, a document name
/// or a web address to be carried into the rest of the app. The privacy
/// invariant in `docs/app-aware-style.md` is enforced by the shape of this type
/// as much as by the code around it, and `AppStyleMappingTests` asserts the
/// shape.
struct DictationTargetApp: Equatable, Sendable {
    /// Normalized on the way in, so two spellings of the same app are one key.
    let bundleIdentifier: String

    init(bundleIdentifier: String) {
        self.bundleIdentifier = AppCategoryCatalog.normalize(bundleIdentifier)
    }

    var category: AppCategory? {
        AppCategoryCatalog.category(forBundleIdentifier: bundleIdentifier)
    }
}

/// Reads which app is frontmost, and nothing else about it.
///
/// A protocol with exactly one member, because the seam is also the boundary:
/// anything this app could learn about the frontmost application it cannot learn
/// through here.
protocol FrontmostApplicationReading {
    func frontmostBundleIdentifier() -> String?
}

/// The real reader. `NSWorkspace.frontmostApplication` is the only call in this
/// feature that touches the system, and `bundleIdentifier` is the only property
/// read off it.
struct WorkspaceFrontmostApplicationReader: FrontmostApplicationReading {
    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

/// Which app the user is dictating into.
///
/// Resolution is local, synchronous and cheap: one property read, one dictionary
/// lookup. Nothing here starts a dictation, changes one, or is allowed to fail
/// it - when the frontmost app cannot be read the answer is `nil`, and `nil`
/// means the user's chosen style stands.
enum AppDetector {

    /// The seam the tests inject through. Nothing in the app assigns this.
    nonisolated(unsafe) static var reader: FrontmostApplicationReading
        = WorkspaceFrontmostApplicationReader()

    /// This app's own identifier, so a dictation started from EchoForge's own
    /// window is not treated as a dictation *into* EchoForge. Overridable
    /// because a test bundle's `Bundle.main` is the test runner, not the app.
    nonisolated(unsafe) static var ownBundleIdentifier: String?
        = Bundle.main.bundleIdentifier

    /// The app a dictation starting now would be typed into.
    ///
    /// `nil` when there is no frontmost app, when it is this app - dictating in
    /// EchoForge's own window is not dictating into another app - or when the
    /// system declines to say.
    static func currentTarget() -> DictationTargetApp? {
        guard let identifier = reader.frontmostBundleIdentifier() else { return nil }
        let normalized = AppCategoryCatalog.normalize(identifier)
        guard !normalized.isEmpty else { return nil }
        if let own = ownBundleIdentifier, AppCategoryCatalog.normalize(own) == normalized {
            return nil
        }
        return DictationTargetApp(bundleIdentifier: normalized)
    }
}
