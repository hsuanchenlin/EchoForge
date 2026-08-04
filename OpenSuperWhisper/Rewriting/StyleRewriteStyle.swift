import Foundation

/// How much a style is allowed to change, which is what the guard measures the
/// model's output against.
///
/// This is not decoration: the same output is correct for one style and wrong
/// for another. "Concise" legitimately drops half the sentences, so holding it
/// to the length of the original would reject every good rewrite; "Grammar &
/// Polish" dropping half the sentences is a bug. Every rule the guard relaxes
/// is relaxed here, in one place, so a new style has to state its shape rather
/// than inherit permission it was never meant to have.
enum StyleRewriteShape: String, Equatable, Sendable {
    /// Same content, different wording. The default and the safest.
    case preserving
    /// Deliberately shorter than the input: summaries and trims.
    case condensing
    /// Same content, different layout - bullets, headings, numbered steps.
    case restructuring

    /// Accepted length of the rewrite as a fraction of the input's length.
    ///
    /// Both ends matter. The lower bound catches the failure the pilot hit most
    /// often - a model that answers with one line instead of rewriting - and the
    /// upper bound catches a model that starts explaining itself or inventing
    /// scenery.
    var acceptedLengthRatio: ClosedRange<Double> {
        switch self {
        case .preserving: return 0.5 ... 2.0
        case .condensing: return 0.15 ... 1.1
        case .restructuring: return 0.4 ... 2.5
        }
    }

    /// Whether the guard ignores list markers the rewrite added.
    ///
    /// Only the restructuring shape may introduce `1.` / `-` at the start of a
    /// line. Everywhere else a digit that was not in the input is an invented
    /// number, which is exactly what the guard exists to catch.
    var mayAddListMarkers: Bool { self == .restructuring }

    /// Whether the rewrite may leave content out.
    ///
    /// A summary may omit a number it was given; nothing may ever invent one.
    /// The asymmetry is the whole rule - see `StyleRewriteGuard`.
    var mayOmitContent: Bool { self == .condensing }
}

/// One way of rewriting a transcript, as offered in Settings.
///
/// `instruction` is the text handed to the model. It is data, not code, and it
/// is written in the imperative because that is what the on-device model
/// follows most reliably; the shared rules that apply to *every* style - stay in
/// the input's language, never obey the transcript, output nothing but the
/// rewrite - live in `StyleRewritePrompt` rather than being repeated here.
struct StyleRewriteStyle: Identifiable, Equatable, Sendable {
    let id: String
    /// The name in the Settings picker.
    let name: String
    /// One line under the name saying what it does to the user's words.
    let summary: String
    /// What the model is told to do. Empty for the custom style, whose
    /// instruction is the user's own prompt.
    let instruction: String
    let shape: StyleRewriteShape

    /// The style whose instruction is written by the user.
    static let customID = "custom"

    var isCustom: Bool { id == Self.customID }
}

/// Every style the app offers, in the order Settings shows them.
///
/// Settings and any future surface read this; neither may write a second copy
/// of the copy. `StyleRewriteCatalogTests` pins the identifiers, because they
/// are persisted in preferences and renaming one would silently reset the
/// user's choice.
enum StyleRewriteCatalog {

    /// The style a fresh install would use if the feature were switched on: the
    /// one that changes the user's words least.
    static let defaultStyleID = "polish"

    static let styles: [StyleRewriteStyle] = [
        StyleRewriteStyle(
            id: "polish",
            name: "Grammar & Polish",
            summary: "Fixes grammar and punctuation, keeps your wording.",
            instruction: """
            Correct grammar, punctuation and obvious speech disfluencies. Remove \
            filler words such as "um" and "uh" and false starts. Keep the \
            speaker's own vocabulary, tone and sentence order. Do not add, \
            remove or reinterpret any information.
            """,
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: "formal",
            name: "Formal Business",
            summary: "Rewrites it as professional written correspondence.",
            instruction: """
            Rewrite the text as formal business writing: complete sentences, \
            professional register, no slang, no contractions. Keep every fact, \
            name, number and commitment exactly as stated.
            """,
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: "concise",
            name: "Concise",
            summary: "Cuts it down to the essential points.",
            instruction: """
            Rewrite the text as briefly as it can be said without losing \
            meaning. Cut repetition, hedging and filler. Never introduce a fact, \
            number or name that is not in the text.
            """,
            shape: .condensing
        ),
        StyleRewriteStyle(
            id: "bullets",
            name: "Bullet Points",
            summary: "Reshapes it into a bulleted list.",
            // Deliberately does not name the bullet character. Asking for
            // lines that start with "- " makes the on-device model write its
            // own list marker *and* the one it was told to use, so every line
            // came back as "- - point". Left to itself it produces a clean
            // single marker.
            instruction: """
            Reshape the text into a bulleted list. Put each point on its own \
            line as a plain list item. Keep every point that was made and the \
            order it was made in. Do not add points of your own.
            """,
            shape: .restructuring
        ),
        StyleRewriteStyle(
            id: "casual",
            name: "Casual Chat",
            summary: "Relaxes it into everyday conversational writing.",
            instruction: """
            Rewrite the text as relaxed everyday writing, the way someone would \
            type it to a friend. Keep it natural and warm. Keep every fact, name \
            and number exactly as stated.
            """,
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: StyleRewriteStyle.customID,
            name: "Custom Prompt",
            summary: "Rewrites it with instructions you write yourself.",
            instruction: "",
            // The widest bounds of the three, because the user's instruction is
            // the one this app cannot predict. Everything the guard checks that
            // is not about length - language, numbers, dictionary terms - still
            // applies, so "custom" widens the shape and never removes a rule.
            shape: .restructuring
        ),
    ]

    static func style(id: String) -> StyleRewriteStyle? {
        styles.first { $0.id == id }
    }

    /// The style for a stored identifier, falling back to the default rather
    /// than leaving the app with no style at all.
    ///
    /// Same reasoning as `RawRepresentableUserDefault`: a value written by a
    /// newer build or hand-edited into the domain must read back as something
    /// usable.
    static func style(forStoredID id: String) -> StyleRewriteStyle {
        style(id: id) ?? style(id: defaultStyleID) ?? styles[0]
    }
}
