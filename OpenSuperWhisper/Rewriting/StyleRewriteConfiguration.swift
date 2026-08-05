import Foundation

/// What the user asked the rewriting stage to do, resolved from preferences.
///
/// Pure and `Equatable` so the decision "does a rewrite run at all, and with
/// what instruction" is testable without a model, a Mac that has one, or a
/// preferences domain. `Settings` builds one of these per transcription, the
/// same way it snapshots every other preference the pipeline reads.
struct StyleRewriteConfiguration: Equatable, Sendable {
    /// The user's toggle. Independent of `safeCorrectionEnabled`, which is a
    /// peer stage and must keep working when this is off.
    let isEnabled: Bool
    let style: StyleRewriteStyle
    /// The user's own instruction, used only by the custom style.
    let customPrompt: String

    /// What the model is actually told to do, written in the language the
    /// dictation is in.
    ///
    /// The language is a parameter rather than a stored value because it is not
    /// a preference: it is read off the transcript, so the same configuration
    /// answers differently for two dictations by the same user.
    func instruction(for language: StyleRewriteLanguage) -> String {
        guard style.isCustom else {
            return style.instructions.text(for: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prompt = trimmedCustomPrompt
        return prompt.isEmpty ? "" : language.wrapping(customPrompt: prompt)
    }

    /// The instruction without any language applied to it, which is all
    /// `isRunnable` needs: whether a style has one at all does not depend on
    /// which language it would be written in.
    private var baseInstruction: String {
        style.isCustom ? trimmedCustomPrompt : style.instructions.english
    }

    private var trimmedCustomPrompt: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when there is a rewrite to attempt at all.
    ///
    /// An enabled custom style with an empty prompt is deliberately *not*
    /// runnable: sending an empty instruction to the model would return
    /// something arbitrary, and the honest answer to "you have not written your
    /// prompt yet" is to leave the transcript alone.
    var isRunnable: Bool { isEnabled && !baseInstruction.isEmpty }

    init(isEnabled: Bool, style: StyleRewriteStyle, customPrompt: String) {
        self.isEnabled = isEnabled
        self.style = style
        self.customPrompt = customPrompt
    }

    /// Reads the three stored values, tolerating an unknown style identifier.
    static func resolve(
        isEnabled: Bool, storedStyleID: String, customPrompt: String
    ) -> StyleRewriteConfiguration {
        StyleRewriteConfiguration(
            isEnabled: isEnabled,
            style: StyleRewriteCatalog.style(forStoredID: storedStyleID),
            customPrompt: customPrompt
        )
    }

    /// The configuration of an app whose user has never switched this on.
    static let disabled = StyleRewriteConfiguration(
        isEnabled: false,
        style: StyleRewriteCatalog.style(forStoredID: StyleRewriteCatalog.defaultStyleID),
        customPrompt: ""
    )
}

/// How long a rewrite may take before the transcript is used unrewritten.
///
/// Dictation is not a chat window: the text is on its way into whatever app the
/// user was typing in, and a rewrite that has not finished is worth less than
/// the transcript arriving now. So the budget is a hard ceiling with a
/// deterministic fallback, not a spinner.
///
/// It scales with length because the model generates the rewrite token by
/// token - a 40-character "send it tomorrow" and a 2,000-character monologue
/// are not the same wait - and it is capped because past a point the honest
/// answer is that this dictation is too long to rewrite before it is needed.
enum StyleRewriteBudget {
    static let base: TimeInterval = 3
    static let perCharacter: TimeInterval = 1.0 / 200.0
    static let ceiling: TimeInterval = 12

    static func seconds(forCharacterCount count: Int) -> TimeInterval {
        min(ceiling, base + Double(max(0, count)) * perCharacter)
    }
}
