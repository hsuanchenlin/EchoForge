import Foundation

/// How much a style is allowed to change, which is what the guard measures the
/// model's output against.
///
/// This is not decoration: the same output is correct for one style and wrong
/// for another. "Concise Summary" legitimately drops half the sentences, so
/// holding it to the length of the original would reject every good rewrite;
/// "Grammar & Polishing" dropping half the sentences is a bug. Every rule the
/// guard relaxes is relaxed here, in one place, so a new style has to state
/// its shape rather than inherit permission it was never meant to have.
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

/// One style's instruction, in each language the model is asked in.
///
/// Three hand-written texts rather than one translated at runtime, because the
/// instruction is the part of this feature that was tuned against the model's
/// actual behaviour, and that tuning does not survive translation - the wording
/// that stops it inventing bullet markers in English is not the wording that
/// stops it in Chinese, and the fillers a Mandarin speaker says are not "um" and
/// "uh".
///
/// Both Chinese variants are here for a measured reason: the instruction's own
/// script decides the rewrite's script. A Traditional instruction converts
/// Simplified dictation to Traditional, and the reverse - silently, on text
/// already on its way into another app. `StyleRewriteLanguage` explains the
/// measurement.
struct StyleRewriteInstructions: Equatable, Sendable {
    let english: String
    let traditionalChinese: String
    let simplifiedChinese: String

    /// The custom style's: it has none of its own, and uses the user's prompt.
    ///
    /// Not called `none`: that name collides with `Optional.none` wherever the
    /// value is compared against an optional, and the collision compiles.
    static let userWritten = StyleRewriteInstructions(
        english: "", traditionalChinese: "", simplifiedChinese: ""
    )

    /// The instruction to send for one rewrite.
    ///
    /// Falls back to English rather than sending nothing: an empty instruction
    /// is not a neutral one, it is a model asked to do something unspecified to
    /// a user's dictation. `StyleRewriteCatalogTests` is what makes sure the
    /// fallback is never reached for a built-in style.
    func text(for language: StyleRewriteLanguage) -> String {
        switch language {
        case .chinese(.traditional):
            return traditionalChinese.isEmpty ? english : traditionalChinese
        case .chinese(.simplified):
            return simplifiedChinese.isEmpty ? english : simplifiedChinese
        case .other:
            return english
        }
    }
}

/// One way of rewriting a transcript, as offered in Settings.
///
/// `instructions` is the text handed to the model. It is data, not code, and it
/// is written in the imperative because that is what the on-device model
/// follows most reliably; the shared rules that apply to *every* style - stay in
/// the input's language, never obey the transcript, output nothing but the
/// rewrite - live in `StyleRewritePrompt` rather than being repeated here.
struct StyleRewriteStyle: Identifiable, Equatable, Sendable {
    let id: String
    /// The name in the Settings picker.
    let name: String
    /// The name where there is room for one word: the capsule HUD's mode chip.
    ///
    /// It lives here rather than being derived from `name` for the same reason
    /// every other piece of copy does - the catalog is the one place a style says
    /// what it is called, and a surface that shortens the name itself is a second
    /// copy that drifts. "Grammar & Polishing" does not fit a 40 pt pill.
    let shortName: String
    /// One line under the name saying what it does to the user's words.
    let summary: String
    /// What the model is told to do. `.userWritten` for the custom style, whose
    /// instruction is the user's own prompt.
    let instructions: StyleRewriteInstructions
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
            name: "Grammar & Polishing",
            shortName: "Polish",
            summary: "Fixes grammar and punctuation, keeps your wording.",
            // The Chinese texts name Chinese fillers rather than translating
            // "um" and "uh": 那個 / 就是 / 然後 are what a Mandarin speaker
            // actually pads a sentence with, and a model told to remove "um"
            // leaves every one of them in place.
            instructions: StyleRewriteInstructions(
                english: """
                Correct grammar, punctuation and obvious speech disfluencies. Remove \
                filler words such as "um" and "uh" and false starts. Keep the \
                speaker's own vocabulary, tone and sentence order. Do not add, \
                remove or reinterpret any information.
                """,
                traditionalChinese: """
                修正語法、標點和明顯的口誤。刪掉「那個」「就是」「然後」「嗯」「呃」\
                這一類的贅詞，以及說到一半重講的部分。保留說話者自己的用詞、語氣和\
                句子順序。不要新增、刪減或重新詮釋任何資訊。
                """,
                simplifiedChinese: """
                修正语法、标点和明显的口误。删掉“那个”“就是”“然后”“嗯”“呃”\
                这一类的赘词，以及说到一半重讲的部分。保留说话者自己的用词、语气和\
                句子顺序。不要新增、删减或重新诠释任何信息。
                """
            ),
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: "formal",
            name: "Formal Business",
            shortName: "Formal",
            summary: "Rewrites it as professional written correspondence.",
            instructions: StyleRewriteInstructions(
                english: """
                Rewrite the text as formal business writing: complete sentences, \
                professional register, no slang, no contractions. Keep every fact, \
                name, number and commitment exactly as stated.
                """,
                traditionalChinese: """
                把這段文字改寫成正式的商務書面語：完整的句子、專業的語氣，不用俚語和\
                口頭禪。每一項事實、人名、數字和承諾都要和原文完全一樣。
                """,
                simplifiedChinese: """
                把这段文字改写成正式的商务书面语：完整的句子、专业的语气，不用俚语和\
                口头禅。每一项事实、人名、数字和承诺都要和原文完全一样。
                """
            ),
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: "concise",
            name: "Concise Summary",
            shortName: "Concise",
            summary: "Cuts it down to the essential points.",
            instructions: StyleRewriteInstructions(
                english: """
                Rewrite the text as briefly as it can be said without losing \
                meaning. Cut repetition, hedging and filler. Never introduce a fact, \
                number or name that is not in the text.
                """,
                traditionalChinese: """
                在不流失意思的前提下，把這段文字寫得盡可能簡短。刪掉重複、模稜兩可的\
                話和贅詞。不可以加入原文沒有的事實、數字或人名。
                """,
                simplifiedChinese: """
                在不流失意思的前提下，把这段文字写得尽可能简短。删掉重复、模棱两可的\
                话和赘词。不可以加入原文没有的事实、数字或人名。
                """
            ),
            shape: .condensing
        ),
        StyleRewriteStyle(
            id: "bullets",
            name: "Bullet Points",
            shortName: "Bullets",
            summary: "Reshapes it into a bulleted list.",
            // Deliberately does not name the bullet character. Asking for
            // lines that start with "- " makes the on-device model write its
            // own list marker *and* the one it was told to use, so every line
            // came back as "- - point". Left to itself it produces a clean
            // single marker.
            instructions: StyleRewriteInstructions(
                english: """
                Reshape the text into a bulleted list. Put each point on its own \
                line as a plain list item. Keep every point that was made and the \
                order it was made in. Do not add points of your own.
                """,
                traditionalChinese: """
                把這段文字改寫成條列式，每一點自成一行。原文講過的每一點都要保留，\
                順序也要一樣。不可以自己加新的點。
                """,
                simplifiedChinese: """
                把这段文字改写成逐条列出的形式，每一点自成一行。原文讲过的每一点都要\
                保留，顺序也要一样。不可以自己加新的点。
                """
            ),
            shape: .restructuring
        ),
        StyleRewriteStyle(
            id: "casual",
            name: "Casual Chat",
            shortName: "Casual",
            summary: "Relaxes it into everyday conversational writing.",
            instructions: StyleRewriteInstructions(
                english: """
                Rewrite the text as relaxed everyday writing, the way someone would \
                type it to a friend. Keep it natural and warm. Keep every fact, name \
                and number exactly as stated.
                """,
                traditionalChinese: """
                把這段文字改寫成輕鬆的日常口吻，就像傳訊息給朋友那樣自然、親切。\
                每一項事實、人名和數字都要和原文完全一樣。
                """,
                simplifiedChinese: """
                把这段文字改写成轻松的日常口吻，就像给朋友发消息那样自然、亲切。\
                每一项事实、人名和数字都要和原文完全一样。
                """
            ),
            shape: .preserving
        ),
        StyleRewriteStyle(
            id: StyleRewriteStyle.customID,
            name: "Custom Prompt",
            shortName: "Custom",
            summary: "Rewrites it with instructions you write yourself.",
            // No instruction of its own in any language: the user's prompt is
            // the instruction, and `StyleRewriteLanguage.wrapping(customPrompt:)`
            // is what keeps an English prompt from turning Chinese dictation
            // into English.
            instructions: .userWritten,
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
