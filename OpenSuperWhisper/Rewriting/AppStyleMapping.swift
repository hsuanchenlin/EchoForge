import Foundation

/// What a category or a single app asks for.
///
/// Two cases rather than a bare style identifier, because "leave it to the style
/// I chose in Settings" is an answer a user has to be able to give: it is how a
/// category default is switched off for one app, and how a built-in default is
/// declined without turning the whole feature off.
enum AppStyleAssignment: Equatable, Sendable {
    /// Whatever is selected in the Style pane. The app has nothing to say.
    case chosenStyle
    /// A style from `StyleRewriteCatalog`, by identifier.
    case style(String)

    /// The identifier this assignment names, or `nil` for `.chosenStyle`.
    var styleID: String? {
        switch self {
        case .chosenStyle: return nil
        case .style(let id): return id
        }
    }

    // MARK: - Storage

    /// `.chosenStyle` on disk. The empty string cannot collide with a style
    /// identifier - every identifier in `StyleRewriteCatalog` is non-empty - so
    /// the stored form stays a plain `[String: String]` that survives being read
    /// by an older build.
    static let chosenStyleStoredValue = ""

    var storedValue: String {
        switch self {
        case .chosenStyle: return Self.chosenStyleStoredValue
        case .style(let id): return id
        }
    }

    init(storedValue: String) {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self = trimmed.isEmpty ? .chosenStyle : .style(trimmed)
    }
}

/// Why a dictation is being rewritten into the style it is.
///
/// Kept alongside the assignment so Settings can say which rule applied without
/// re-deriving it, and so a test asserts the precedence rather than the answer
/// that happens to fall out of it.
enum AppStyleSource: Equatable, Sendable {
    /// No rule applied: the app is unrecognized, there is no frontmost app, or
    /// the feature is off. The style chosen in Settings stands.
    case chosenStyle
    /// The app fell into a category, and the category's default applied.
    case category(AppCategory)
    /// The user set a rule for this exact app.
    case appOverride
}

struct AppStyleResolution: Equatable, Sendable {
    let assignment: AppStyleAssignment
    let source: AppStyleSource

    static let chosenStyle = AppStyleResolution(assignment: .chosenStyle, source: .chosenStyle)
}

/// The app-to-style rules: the built-in defaults, and what the user changed.
///
/// A value type loaded from preferences and written back whole, rather than a
/// live object: resolving a dictation's style must be a pure function of "which
/// app, which rules", so the decision is testable without a Mac that has any of
/// these apps installed - the same reason `EngineSelector` is a pure function.
///
/// Two rules carry this type, and both are asymmetries worth stating:
///
/// - It chooses **which** style runs, never **whether** one runs. `isEnabled`
///   and the custom prompt come from the Style pane and are passed through
///   untouched, so no app can switch the model on for words the user did not
///   agree to send it.
/// - It never writes `styleRewriteStyleID`. The style the user chose and the
///   style this dictation uses are two different values, and keeping them apart
///   is what stops a week in Slack from quietly becoming the user's setting -
///   the same rule `EngineSelector` follows for engines.
struct AppStyleMappingStore: Equatable, Sendable {

    /// Whether the app being dictated into gets a say at all.
    var isEnabled: Bool

    /// The user's per-category choices, over the built-in defaults.
    var categoryOverrides: [AppCategory: AppStyleAssignment]

    /// The user's per-app rules, keyed by normalized bundle identifier. These
    /// beat the category.
    var appOverrides: [String: AppStyleAssignment]

    init(
        isEnabled: Bool = false,
        categoryOverrides: [AppCategory: AppStyleAssignment] = [:],
        appOverrides: [String: AppStyleAssignment] = [:]
    ) {
        self.isEnabled = isEnabled
        self.categoryOverrides = categoryOverrides
        self.appOverrides = Dictionary(
            appOverrides.map { (AppCategoryCatalog.normalize($0.key), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// A store that changes nothing - what an install that never turned this on
    /// has, and what every non-dictation transcription (a dropped file, a
    /// regenerate from history) resolves against.
    static let disabled = AppStyleMappingStore()

    // MARK: - Defaults

    /// What each category asks for before the user touches anything.
    ///
    /// Chat gets `casual` and mail gets `formal` because that is the difference
    /// a person makes without thinking about it. Code and documents both get
    /// `polish`: dictation there is a commit message, a comment or a paragraph,
    /// where the wording is the user's own and only the grammar wants fixing -
    /// `bullets` would restructure prose that was never a list.
    ///
    /// Browsers deliberately get nothing. A browser window is a mail client, a
    /// chat client, a code review and a text editor on four tabs, and the only
    /// thing that would tell them apart is the page's address - which is exactly
    /// what this feature refuses to look at. So the honest default for a browser
    /// is the style the user chose; a user who dictates into one web app all day
    /// can set a rule for their browser by hand.
    static let builtInCategoryStyles: [AppCategory: AppStyleAssignment] = [
        .workChat: .style("casual"),
        .email: .style("formal"),
        .developerTools: .style("polish"),
        .documentsNotes: .style("polish"),
        .browser: .chosenStyle,
    ]

    /// What a category asks for, the user's choice first.
    func assignment(for category: AppCategory) -> AppStyleAssignment {
        categoryOverrides[category]
            ?? Self.builtInCategoryStyles[category]
            ?? .chosenStyle
    }

    /// The rule the user set for one app, if any.
    func appOverride(for bundleIdentifier: String) -> AppStyleAssignment? {
        appOverrides[AppCategoryCatalog.normalize(bundleIdentifier)]
    }

    // MARK: - Resolving

    /// Which style the app being dictated into asks for.
    ///
    /// The single gate: with the feature off, or no app to resolve, the answer
    /// is always the user's chosen style. Precedence is app, then category, then
    /// the chosen style.
    ///
    /// A rule naming a style this build does not know - written by a newer one,
    /// or a style since removed - resolves to the chosen style rather than to
    /// some substitute, and says so in its `source`: the user's own choice is a
    /// better answer than a guess, and a surface that reported "Slack chose
    /// this" while the chosen style ran would be describing a rule that did not
    /// apply.
    func resolution(for target: DictationTargetApp?) -> AppStyleResolution {
        guard isEnabled, let target else { return .chosenStyle }
        if let override = appOverride(for: target.bundleIdentifier) {
            return resolution(override, from: .appOverride)
        }
        guard let category = target.category else { return .chosenStyle }
        return resolution(assignment(for: category), from: .category(category))
    }

    private func resolution(
        _ assignment: AppStyleAssignment, from source: AppStyleSource
    ) -> AppStyleResolution {
        guard let styleID = assignment.styleID,
              StyleRewriteCatalog.style(id: styleID) != nil
        else { return .chosenStyle }
        return AppStyleResolution(assignment: assignment, source: source)
    }

    /// The configuration one dictation runs with. Everything but the style is
    /// `base`'s, unchanged.
    func configuration(
        _ base: StyleRewriteConfiguration, for target: DictationTargetApp?
    ) -> StyleRewriteConfiguration {
        guard let styleID = resolution(for: target).assignment.styleID,
              let style = StyleRewriteCatalog.style(id: styleID)
        else { return base }
        return StyleRewriteConfiguration(
            isEnabled: base.isEnabled, style: style, customPrompt: base.customPrompt
        )
    }

    // MARK: - Editing

    mutating func setAssignment(_ assignment: AppStyleAssignment, for category: AppCategory) {
        categoryOverrides[category] = assignment
    }

    mutating func setAssignment(_ assignment: AppStyleAssignment, forApp bundleIdentifier: String) {
        let key = AppCategoryCatalog.normalize(bundleIdentifier)
        guard !key.isEmpty else { return }
        appOverrides[key] = assignment
    }

    mutating func removeApp(_ bundleIdentifier: String) {
        appOverrides.removeValue(forKey: AppCategoryCatalog.normalize(bundleIdentifier))
    }

    /// The apps the user has a rule for, in a stable order for Settings to show.
    var sortedAppOverrides: [(bundleIdentifier: String, assignment: AppStyleAssignment)] {
        appOverrides
            .sorted { $0.key < $1.key }
            .map { (bundleIdentifier: $0.key, assignment: $0.value) }
    }

    // MARK: - Storage

    /// Read as two plain string dictionaries, so what is on disk is legible and
    /// an unreadable entry costs one rule rather than the whole feature.
    static func load(from preferences: AppPreferences = .shared) -> AppStyleMappingStore {
        var categories: [AppCategory: AppStyleAssignment] = [:]
        for (rawCategory, value) in preferences.appStyleCategoryStyles {
            guard let category = AppCategory(rawValue: rawCategory) else { continue }
            categories[category] = AppStyleAssignment(storedValue: value)
        }
        let apps = preferences.appStyleMappings.reduce(into: [String: AppStyleAssignment]()) {
            partial, entry in
            let key = AppCategoryCatalog.normalize(entry.key)
            guard !key.isEmpty else { return }
            partial[key] = AppStyleAssignment(storedValue: entry.value)
        }
        return AppStyleMappingStore(
            isEnabled: preferences.appAwareStyleEnabled,
            categoryOverrides: categories,
            appOverrides: apps
        )
    }

    func save(to preferences: AppPreferences = .shared) {
        preferences.appAwareStyleEnabled = isEnabled
        preferences.appStyleCategoryStyles = categoryOverrides.reduce(into: [String: String]()) {
            partial, entry in
            partial[entry.key.rawValue] = entry.value.storedValue
        }
        preferences.appStyleMappings = appOverrides.reduce(into: [String: String]()) {
            partial, entry in
            partial[entry.key] = entry.value.storedValue
        }
    }
}
