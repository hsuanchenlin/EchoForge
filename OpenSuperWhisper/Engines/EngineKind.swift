import Foundation

/// The speech-recognition engines the app can run.
///
/// The raw values are the strings persisted in `UserDefaults` under
/// `selectedEngine`, so they are storage format, not display text: renaming one
/// silently resets every existing user's engine choice. User-facing names live
/// in the Settings and onboarding views instead.
///
/// Adding an engine means adding a case here; `makeEngine()` switches
/// exhaustively, so the compiler points at the one place that has to construct
/// it. `LanguageUtil` deliberately switches exhaustively for the same reason.
enum EngineKind: String, CaseIterable {
    case whisper
    case fluidaudio

    /// Paraformer-large (zh). Opt-in only: it has no entry in the engine picker
    /// yet, so it is reachable by writing the `selectedEngine` default by hand
    /// and nothing else. That is deliberate - the Settings and onboarding
    /// surfaces it needs (a one-row download of ~653 MB, a language control that
    /// collapses to Chinese, the model attribution notice) are their own change.
    case paraformer

    /// SenseVoice-Small. Opt-in on the same terms as `paraformer` - the picker
    /// entry and the first-run download are still their own change - but it is
    /// already the engine `defaultChineseDictation` names, so that change offers
    /// it first rather than deciding again.
    case sensevoice

    /// Used when nothing is stored yet and when the stored value is not one we
    /// know, which is what a downgrade after trying a newer engine looks like.
    static let fallback: EngineKind = .whisper

    /// The engine Chinese dictation defaults to.
    ///
    /// Not `fallback`: this is the answer to "the user wants to dictate Chinese",
    /// while `fallback` answers "we do not know what the user wants". Whisper
    /// stays the app-wide default for everyone who has not asked for Chinese.
    ///
    /// SenseVoice wins the default because it punctuates - Paraformer's
    /// `vocab8404` has no punctuation at all, and the app has no second ML
    /// runtime to add it afterwards - and because it also handles Cantonese,
    /// English, Japanese and Korean. It loses on raw Mandarin speed (~8x real
    /// time against ~65x) and slightly on bare-character accuracy, which is what
    /// `chineseAccuracyAlternative` is for. The trade is a product decision, not
    /// a measurement, so it is stated here once rather than re-derived in each
    /// surface that has to pick an engine.
    static let defaultChineseDictation: EngineKind = .sensevoice

    /// The Chinese engine to offer when the default's trade-offs are the wrong
    /// ones: measurably better Mandarin characters, at the price of Mandarin
    /// only and no punctuation.
    static let chineseAccuracyAlternative: EngineKind = .paraformer

    /// Reads a persisted preference value, mapping anything unrecognised onto
    /// `fallback` rather than failing. This preserves the pre-existing
    /// behaviour of `TranscriptionService`, whose `if == "fluidaudio" / else`
    /// chain also treated every unknown tag as Whisper.
    init(stored rawValue: String?) {
        guard let rawValue, let kind = EngineKind(rawValue: rawValue) else {
            self = .fallback
            return
        }
        self = kind
    }

    /// The only construction site for engines. Kept next to the case list so a
    /// new engine cannot be half-added.
    func makeEngine() async -> TranscriptionEngine {
        switch self {
        case .whisper:
            return await WhisperEngine()
        case .fluidaudio:
            return await FluidAudioEngine()
        case .paraformer:
            return await ParaformerEngine()
        case .sensevoice:
            return await SenseVoiceEngine()
        }
    }
}
