import Foundation

/// The text Whisper is shown before it decodes: the user's own initial prompt,
/// followed by the words from their personal terms dictionary.
///
/// The dictionary used to reach a transcript only *after* the engine, as the
/// terms stage of `TextPostProcessor` - which cannot save a name the recognizer
/// never emitted close enough to match. whisper.cpp's `initial_prompt` is
/// conditioning text the decoder treats as preceding transcript, so a name
/// listed in it is one the decoder is biased to write, before the terms stage
/// ever sees the result. This is additive: the terms stage still runs on the
/// output exactly as it did, and an empty dictionary leaves the prompt exactly
/// what the user typed (`nil` when they typed nothing).
///
/// Whisper is the one engine with this hook. Parakeet, SenseVoice and Paraformer
/// take no decoding prompt in the pinned runtimes, and the cloud endpoint is
/// deliberately never shown the dictionary - a personal dictionary is the most
/// identifying text the app holds, and `docs/cloud-api.md` says the prompt it
/// sends is the typed setting alone. `CloudPrivacyTests` scans for that.
///
/// The budget is measured with the model's own tokenizer, injected as
/// `tokenCount`, because nothing cheaper is honest: a Han character is one to
/// three tokens and a name is rarely one, so a character cap either starves an
/// English dictionary or overruns a Chinese one. See `docs/personal-terms.md`.
enum WhisperInitialPrompt {

    /// The most prompt tokens whisper.cpp will carry, measured off the pinned
    /// submodule rather than read off a constant: `whisper_full_with_state`
    /// budgets `n_text_ctx / 2` = 224 tokens of context per 30 s window, and
    /// with `carry_initial_prompt` the initial prompt may occupy all but one of
    /// them. A longer prompt is cut from the **front** - the last 223 tokens are
    /// kept - which is why the user's own text goes first and is never trimmed
    /// here: if it does not fit, nothing is appended that could push it out.
    static let carriedPromptTokenLimit = 223

    /// The most tokens a composed prompt may occupy.
    ///
    /// Every carried prompt token is taken from the same 224-token budget the
    /// rolling context uses to keep a long recording coherent across its 30 s
    /// windows, so a prompt that filled the budget would leave the decoder no
    /// memory of what it just wrote. Half of what can be carried is the ceiling:
    /// the dictionary never gets more room than the transcript, and
    /// `WhisperInitialPromptTests` pins the inequality rather than the number.
    static let tokenBudget = carriedPromptTokenLimit / 2

    /// Between one dictionary word and the next. A comma-separated list is the
    /// form Whisper's own documentation gives for a vocabulary prompt.
    static let wordSeparator = ", "

    /// Composes the prompt for one transcription, or `nil` when there is nothing
    /// to show the decoder.
    ///
    /// - Parameters:
    ///   - userPrompt: the Initial Prompt setting, exactly as typed.
    ///   - terms: the dictionary this transcription runs with - already gated on
    ///     `safeCorrectionEnabled`, so an empty array is "nothing to add".
    ///   - tokenBudget: the ceiling on the composed prompt, in tokens.
    ///   - tokenCount: the model's tokenizer.
    static func compose(
        userPrompt: String,
        terms: [PersonalTerm],
        tokenBudget: Int = tokenBudget,
        tokenCount: (String) -> Int
    ) -> String? {
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = vocabulary(from: terms).filter { !trimmedUserPrompt.contains($0) }

        // An empty dictionary must not change what the decoder was shown before
        // it existed: the setting goes through untouched, whitespace and all.
        guard !words.isEmpty else {
            return userPrompt.isEmpty ? nil : userPrompt
        }

        var composed = trimmedUserPrompt
        if !composed.isEmpty {
            // The user's text is theirs. If it already fills the budget, adding
            // to it would only push its start out of what whisper.cpp keeps.
            guard tokenCount(composed) < tokenBudget else { return userPrompt }
            composed += sentenceJoiner(after: composed)
        }

        var appended = 0
        for word in words {
            let candidate = composed + (appended == 0 ? "" : wordSeparator) + word
            // Stop at the first word that does not fit rather than skipping it:
            // the list is in priority order, and a shorter, lower-priority word
            // squeezing in ahead of a name would invert that.
            guard tokenCount(candidate) <= tokenBudget else { break }
            composed = candidate
            appended += 1
        }

        // Nothing fit after the user's own prompt: hand that through as typed.
        guard appended > 0 else {
            return userPrompt.isEmpty ? nil : userPrompt
        }
        return composed
    }

    /// The dictionary as a list of words to bias the decoder toward, in the
    /// order they should be kept when the budget runs out.
    ///
    /// What is listed is what an entry *writes out* - the replacement for a
    /// substituting kind, the matched text for a never-correct one - because that
    /// is the spelling the user wants to see and the terms stage will accept.
    /// What an entry matches on is never listed: `頂頂群` is the mishearing, and
    /// a prompt that showed it would be teaching the decoder the mistake.
    ///
    /// An entry with a context hint is left out. The hint says the substitution
    /// is conditional on the rest of the dictation, and a prompt is shown before
    /// any of it exists; a homophone target such as `再` would be biased into
    /// every dictation, which is the outcome the hint exists to prevent.
    ///
    /// Disabled and half-finished entries are skipped the way the terms stage
    /// skips them, duplicates are kept once, and ties within a kind keep file
    /// order - the same tie-break `PersonalTermsCorrector` uses.
    static func vocabulary(from terms: [PersonalTerm]) -> [String] {
        let ranked = terms.enumerated()
            .filter { $0.element.isEnabled && $0.element.isValid }
            .filter { ($0.element.contextHint ?? "").isEmpty }
            .sorted { lhs, rhs in
                let lhsRank = lhs.element.kind.decodePromptPriority
                let rhsRank = rhs.element.kind.decodePromptPriority
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var seen = Set<String>()
        var words: [String] = []
        for term in ranked {
            let word = term.emittedText(forMatched: term.match)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            words.append(word)
        }
        return words
    }

    /// What separates the user's prompt from the list that follows it. Their
    /// text reads as a sentence to the decoder, so the list starts a new one
    /// unless they already closed theirs.
    private static func sentenceJoiner(after prompt: String) -> String {
        guard let last = prompt.last else { return "" }
        return closingPunctuation.contains(last) ? " " : ". "
    }

    private static let closingPunctuation: Set<Character> = [
        ".", "!", "?", ",", ";", ":", "。", "！", "？", "，", "、", "；", "：",
    ]
}

extension PersonalTermKind {
    /// Where entries of this kind stand when the decoding prompt runs out of
    /// room: lower is kept first.
    ///
    /// Names first because a name is what the recognizer has never seen and a
    /// post-hoc replacement can least often rescue; then spellings, which are
    /// words it knows written the user's way; then protected text, which is the
    /// user's own spelling of something it must not touch; and last the
    /// mishearing fixes, whose targets are usually ordinary words the decoder
    /// needs the least help with. Switched exhaustively so a new kind has to
    /// say where it stands rather than inheriting a place.
    var decodePromptPriority: Int {
        switch self {
        case .name: return 0
        case .preferredSpelling: return 1
        case .protect: return 2
        case .replacement: return 3
        }
    }
}
