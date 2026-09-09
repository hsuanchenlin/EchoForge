import Foundation

/// Which app vocabulary a dictation is decoded with, and why.
///
/// Carried rather than reduced to the profile alone so Settings and the tests
/// can say *which rule applied* without re-deriving it - the same division
/// `AppStyleResolution` makes.
struct AppVocabularyResolution: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// No profile applied: the feature is off, there is no frontmost app,
        /// the app is one the user excluded, its kind is switched off, or its
        /// kind has no profile.
        case none
        /// The app fell into a category and that category's profile applied.
        case category(AppCategory)
    }

    let profile: AppVocabularyProfile?
    let source: Source

    static let none = AppVocabularyResolution(profile: nil, source: .none)
}

/// The app-to-vocabulary rules: the built-in profiles, and what the user
/// switched off.
///
/// A value type loaded from preferences and written back whole, rather than a
/// live object, for the reason `AppStyleMappingStore` is one: resolving a
/// dictation's vocabulary has to be a pure function of "which app, which rules",
/// so it is testable on a Mac with none of these applications installed.
///
/// Three rules carry it, and `docs/app-vocabulary.md` is the whole story:
///
/// - **The bundle identifier is the whole of the signal.** `DictationTargetApp`
///   has one field and this type reads no other, so there is nowhere for a
///   window title or a document name to enter. `AppVocabularyTests` scans the
///   sources for the same names `AppStyleMappingTests` does.
/// - **It adds vocabulary, it never removes any.** The user's own dictionary is
///   composed into the decoding prompt first and is never crowded out by a
///   profile; see `WhisperInitialPrompt`.
/// - **Nothing here reaches a network.** The prompt it contributes to is
///   whisper.cpp's, on this Mac. The cloud engine is never shown a profile, for
///   the same reason it is never shown the dictionary - `CloudPrivacyTests`
///   holds both.
struct AppVocabularyStore: Equatable, Sendable {

    /// Whether the app being dictated into contributes vocabulary at all.
    var isEnabled: Bool

    /// Categories the user switched off. Absent means on, so a category added
    /// in a later build is on for everyone rather than silently off for the
    /// users who had already visited this pane.
    var disabledCategories: Set<AppCategory>

    /// Apps the user excluded, by normalized bundle identifier. Beats the
    /// category, the way a per-app style rule does.
    var excludedApps: Set<String>

    init(
        isEnabled: Bool = false,
        disabledCategories: Set<AppCategory> = [],
        excludedApps: Set<String> = []
    ) {
        self.isEnabled = isEnabled
        self.disabledCategories = disabledCategories
        self.excludedApps = Set(excludedApps.map(AppCategoryCatalog.normalize).filter { !$0.isEmpty })
    }

    /// A store that contributes nothing - what an install that never turned this
    /// on has, and what every transcription with no app to resolve against gets.
    static let disabled = AppVocabularyStore()

    // MARK: - Resolving

    func resolution(for target: DictationTargetApp?) -> AppVocabularyResolution {
        guard isEnabled, let target else { return .none }
        guard !excludedApps.contains(target.bundleIdentifier) else { return .none }
        guard let category = target.category, !disabledCategories.contains(category) else {
            return .none
        }
        guard let profile = AppVocabularyCatalog.profile(for: category) else { return .none }
        return AppVocabularyResolution(profile: bounded(profile), source: .category(category))
    }

    func profile(for target: DictationTargetApp?) -> AppVocabularyProfile? {
        resolution(for: target).profile
    }

    /// The profile as it is actually used: never longer than the caps.
    ///
    /// Applied on the way out rather than trusted on the way in, so the bound
    /// holds for a profile added later by someone who did not read the cap.
    private func bounded(_ profile: AppVocabularyProfile) -> AppVocabularyProfile {
        AppVocabularyProfile(
            category: profile.category,
            hint: String(profile.hint.prefix(AppVocabularyProfile.maximumHintCharacters)),
            terms: Array(profile.terms.prefix(AppVocabularyProfile.maximumTerms)))
    }

    // MARK: - Editing

    func isEnabled(_ category: AppCategory) -> Bool {
        !disabledCategories.contains(category)
    }

    mutating func setEnabled(_ enabled: Bool, for category: AppCategory) {
        if enabled {
            disabledCategories.remove(category)
        } else {
            disabledCategories.insert(category)
        }
    }

    mutating func exclude(_ bundleIdentifier: String) {
        let key = AppCategoryCatalog.normalize(bundleIdentifier)
        guard !key.isEmpty else { return }
        excludedApps.insert(key)
    }

    mutating func include(_ bundleIdentifier: String) {
        excludedApps.remove(AppCategoryCatalog.normalize(bundleIdentifier))
    }

    /// The excluded apps in a stable order for Settings to show.
    var sortedExcludedApps: [String] { excludedApps.sorted() }

    // MARK: - Storage

    /// Read as a plain string list and a plain string dictionary, so what is on
    /// disk is legible and an unreadable entry costs one rule rather than the
    /// whole feature - the same shape `AppStyleMappingStore` stores.
    static func load(from preferences: AppPreferences = .shared) -> AppVocabularyStore {
        var disabled: Set<AppCategory> = []
        for (rawCategory, isOn) in preferences.appVocabularyCategories {
            guard let category = AppCategory(rawValue: rawCategory), !isOn else { continue }
            disabled.insert(category)
        }
        return AppVocabularyStore(
            isEnabled: preferences.appVocabularyEnabled,
            disabledCategories: disabled,
            excludedApps: Set(preferences.appVocabularyExcludedApps))
    }

    func save(to preferences: AppPreferences = .shared) {
        preferences.appVocabularyEnabled = isEnabled
        preferences.appVocabularyCategories = AppCategory.allCases.reduce(into: [String: Bool]()) {
            partial, category in
            partial[category.rawValue] = !disabledCategories.contains(category)
        }
        preferences.appVocabularyExcludedApps = sortedExcludedApps
    }
}
