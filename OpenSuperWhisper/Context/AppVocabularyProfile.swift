import Foundation

/// The words and the sample sentence one kind of app contributes to the
/// recognizer, before it decodes.
///
/// Two halves, because they do two different jobs and only one of them is
/// vocabulary:
///
/// - `terms` are words the recognizer is biased *towards*. This is what the
///   personal terms dictionary already does through `WhisperInitialPrompt`, and
///   it is the honest use of a decoding prompt: a name or an identifier the
///   model would otherwise write as the nearest ordinary English word.
/// - `hint` is one short passage written the way dictation into this kind of app
///   usually reads. whisper.cpp treats an initial prompt as *preceding
///   transcript*, so a passage carrying camelCase, a wikilink or an email
///   sign-off biases punctuation and casing rather than any particular word.
///   That is the one mechanism available for "preserve technical casing", and it
///   is a bias rather than a guarantee - `docs/app-vocabulary.md` says so where
///   a user can read it.
///
/// Both are **bounded**. A prompt is charged against the same 224-token budget
/// whisper.cpp uses to keep a long recording coherent across its 30 s windows,
/// and the user's own dictionary is composed first and is never crowded out by
/// this - see `WhisperInitialPrompt`.
struct AppVocabularyProfile: Equatable, Sendable, Identifiable {
    let category: AppCategory
    let hint: String
    let terms: [String]

    var id: String { category.rawValue }

    /// The most terms one profile may carry.
    ///
    /// A cap rather than trust, because the failure is invisible: an over-long
    /// profile does not error, it silently takes the room the *next* thing
    /// needed - and the next thing is the rolling context that keeps a two
    /// minute dictation coherent. `AppVocabularyProfileTests` holds every
    /// built-in profile under it.
    static let maximumTerms = 24

    /// The most characters a hint may be, for the same reason.
    static let maximumHintCharacters = 220
}

/// The built-in profiles: one per kind of app, and nothing per app.
///
/// The granularity is deliberate and it is the same one `AppStyleMappingStore`
/// uses. The only signal this app reads about where a dictation is going is the
/// frontmost **bundle identifier** - no window title, no document name, no web
/// address - so a profile can be about the *kind* of writing an app is for and
/// cannot be about what is on screen in it. See `docs/app-aware-style.md` for
/// the privacy invariant this inherits, and `docs/app-vocabulary.md` for this
/// feature's own story.
enum AppVocabularyCatalog {

    /// Web browsers deliberately get nothing, for exactly the reason
    /// `AppStyleMappingStore.builtInCategoryStyles` gives them `.chosenStyle`: a
    /// browser window is a mail client, a chat client, a code review and a text
    /// editor on four tabs, and the only thing that would tell them apart is the
    /// page's address - which is the one thing this feature refuses to look at.
    static let profiles: [AppVocabularyProfile] = [
        AppVocabularyProfile(
            category: .developerTools,
            // Written as preceding transcript rather than as an instruction:
            // the decoder is being shown what this user's next sentence tends to
            // look like, so the casing and the punctuation are the point.
            hint:
                "Notes on the code: refactored AuthService, fixed a nil check in viewDidLoad, "
                + "renamed max_retry_count, and opened a pull request against main.",
            terms: [
                "camelCase", "snake_case", "PascalCase", "TypeScript", "JavaScript", "Swift",
                "SwiftUI", "Xcode", "Python", "Rust", "git", "GitHub", "pull request",
                "merge conflict", "refactor", "API", "JSON", "YAML", "regex", "async", "await",
                "enum", "stdout", "localhost",
            ]),
        AppVocabularyProfile(
            category: .email,
            hint:
                "Hi Alex, thanks for the update. I have attached the revised draft; let me know "
                + "if Tuesday still works. You can reach me at alex@example.com. Best regards,",
            terms: [
                "Best regards", "Kind regards", "Sincerely", "attached", "following up",
                "please let me know", "agenda", "invite", "deadline", "cc", "bcc", "forwarded",
                "signature", "unsubscribe",
            ]),
        AppVocabularyProfile(
            category: .workChat,
            hint:
                "Sounds good - I'll push the fix now and ping you once CI is green. "
                + "Standup is at 10, and I'm out on Friday.",
            terms: [
                "standup", "sprint", "backlog", "LGTM", "PR", "ETA", "heads up", "ping",
                "on it", "shipped", "rollback", "PTO", "async", "thread",
            ]),
        AppVocabularyProfile(
            category: .documentsNotes,
            hint:
                "# Meeting notes\n- Reviewed the roadmap\n- See [[Q3 planning]] for the numbers\n"
                + "- TODO: send the summary",
            terms: [
                "heading", "sub-heading", "bullet", "checklist", "TODO", "action item",
                "follow-up", "outline", "draft", "footnote", "appendix", "backlink",
                "front matter", "callout",
            ]),
    ]

    /// The profile for one category, or nil when the category has none.
    static func profile(for category: AppCategory) -> AppVocabularyProfile? {
        profiles.first { $0.category == category }
    }

    /// The categories this build ships a profile for, in the order Settings
    /// lists them. `AppCategory.allCases` order, so the pane and the style pane
    /// agree.
    static var categoriesWithProfiles: [AppCategory] {
        AppCategory.allCases.filter { profile(for: $0) != nil }
    }
}
