import Foundation

/// The last check between Paraformer's output and the user's document.
///
/// Paraformer-large (zh) takes no language parameter and refuses nothing. Fed
/// anything that is not Mandarin it answers anyway, and one of the two ways it
/// answers is not text at all: the sub-word units of a vocabulary with no
/// English in it, still carrying the `@@` continuation markers a BPE tokeniser
/// uses internally (`docs/upstream-issues.md`). That string used to be pasted
/// straight into whatever the user was typing in.
/// `LanguageUtil.paraformerLanguages` locks the *dictation language* to `zh`,
/// which is all a picker can do; it cannot stop somebody speaking English into
/// the microphone.
///
/// So this classifies the **output**, and only the output. Nothing here
/// retokenises, strips markers, or repairs a transcript: a transcript that has
/// to be repaired to be shown is one the app is guessing at, and a guess pasted
/// into someone's editor is the failure this exists to stop. A rejected
/// dictation becomes `TranscriptionError.unsupportedSpokenLanguage`, which keeps
/// the recording (`DictationFailureOutcome`) so the user can switch engine and
/// press regenerate.
///
/// Two rules, in this order, both measured against the pinned FluidAudio:
///
/// - **`@@` anywhere.** vocab8404 contains no such token, so every `@@` in a
///   transcript is a tokeniser internal that leaked. Presence, not proportion:
///   a bilingual recording whose English sentence came back as fragments is
///   still a transcript with fragments in it.
/// - **Predominantly Latin.** The `@@` markers are not guaranteed - the model
///   also returns whole Latin words - so a share test stands behind the marker
///   test. A Mandarin transcript is written in Han characters; one that is more
///   than `latinShareThreshold` Latin letters is not one.
///
/// What it deliberately does **not** catch: Cantonese, which comes back as
/// fluent, plausible, wrong Mandarin. There is no signal in the output to read
/// there, and the engine's caveats say so instead.
///
/// The share test needs evidence before it condemns anything, hence
/// `minimumLetters`. Above that line it is tuned to fire rather than to be
/// certain: the cost of a false positive is a kept recording, a sentence, and
/// one press of regenerate, and the cost of a false negative is corruption in
/// the user's text.
enum ParaformerLanguageGuard {

    /// Why a transcript is not Mandarin. Two values because there are two
    /// signals, and a test that cannot tell them apart cannot show that the
    /// second one still works when the first is absent.
    enum Rejection: Equatable {
        /// Raw BPE continuation markers leaked into the transcript.
        case bpeFragments
        /// The transcript is written in Latin letters, not Han characters.
        case latinScript
    }

    /// How many letters the share test needs before it will judge anything.
    ///
    /// Below this a transcript is too short to be evidence of a language: a
    /// Mandarin dictation that mentions one acronym would otherwise be condemned
    /// by it.
    static let minimumLetters = 8

    /// The Latin share above which a transcript is not Mandarin.
    ///
    /// Strictly above: English through this model measures at or near 1.0, while
    /// Mandarin quoting a spelled-out address or product name sits below. Four
    /// fifths is where those two stop overlapping.
    static let latinShareThreshold = 0.8

    /// Why this transcript cannot be shown to the user, or `nil` if it can.
    static func rejection(in transcript: String) -> Rejection? {
        if transcript.contains("@@") { return .bpeFragments }
        if isPredominantlyLatin(transcript) { return .latinScript }
        return nil
    }

    /// The sentence stored on the kept recording, and shown wherever a failed
    /// dictation gets a full line.
    ///
    /// It names the engine (the user chose it and can unchoose it), what the
    /// engine can do, and the two existing ways to move off it - the Models tab
    /// and the engine shortcut. The shortcut is named as "the engine shortcut"
    /// rather than as ⌥M on purpose: the binding is the user's to change, and
    /// `EngineShortcutHint` is the one surface that reads which key is actually
    /// in force.
    static let message =
        "Paraformer transcribes Mandarin only, and this recording came back as something else. "
        + "The audio has been kept - switch engine in Settings → Model, or with the engine "
        + "shortcut, then press regenerate."

    /// The short form, for the 200 pt indicator card and the capsule - the same
    /// division `CloudRequestError.shortMessage` makes.
    static let shortMessage = "Not Mandarin"

    /// The failure a rejected transcript is reported as.
    ///
    /// Built here rather than at the throw site so the copy above and the error
    /// the user actually meets cannot drift apart.
    static let failure = TranscriptionError.unsupportedSpokenLanguage(
        message: message, shortMessage: shortMessage
    )

    // MARK: - Private

    private static func isPredominantlyLatin(_ text: String) -> Bool {
        var letters = 0
        var latin = 0
        for character in text where character.isLetter {
            letters += 1
            if isLatin(character) { latin += 1 }
        }
        guard letters >= minimumLetters else { return false }
        return Double(latin) / Double(letters) > latinShareThreshold
    }

    /// Latin letters, including the accented ranges and the fullwidth forms -
    /// the model does not emit the latter, but a script test that misses them is
    /// a script test with a hole in it.
    private static func isLatin(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0041...0x005A,      // A-Z
             0x0061...0x007A,      // a-z
             0x00C0...0x024F,      // Latin-1 Supplement and Latin Extended-A/B
             0x1E00...0x1EFF,      // Latin Extended Additional
             0xFF21...0xFF3A,      // fullwidth A-Z
             0xFF41...0xFF5A:      // fullwidth a-z
            return true
        default:
            return false
        }
    }
}
