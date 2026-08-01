import Foundation

/// The speech-recognition engines the app can run.
///
/// The raw values are the strings persisted in `UserDefaults` under
/// `selectedEngine`, so they are storage format, not display text: renaming one
/// silently resets every existing user's engine choice. User-facing names live
/// in `EngineCatalog`, which both Settings and onboarding read.
///
/// Adding an engine means adding a case here; `makeEngine()` switches
/// exhaustively, so the compiler points at the one place that has to construct
/// it. `LanguageUtil` deliberately switches exhaustively for the same reason.
enum EngineKind: String, CaseIterable {
    case whisper
    case fluidaudio

    /// Paraformer-large (zh). Selectable in Settings and offered in onboarding
    /// to anyone dictating Chinese; how it describes itself in both - a one-row
    /// ~653 MB download, a language control that collapses to Mandarin, the
    /// model attribution notice - is `EngineCatalog`.
    case paraformer

    /// SenseVoice-Small. Selectable in Settings on the same terms as
    /// `paraformer`, and offered before it, because it is the engine
    /// `defaultChineseDictation` names.
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

    /// Whether the whisper.cpp decode controls in Settings do anything for this
    /// engine.
    ///
    /// Beam search, temperature, the no-speech threshold, the initial prompt,
    /// timestamps and blank suppression are `whisper_full_params` fields and
    /// `WhisperEngine` is their only reader. Every other engine has ignored them
    /// silently since Parakeet landed. Settings hides them rather than showing a
    /// slider that changes nothing, and this switches exhaustively so a new
    /// engine has to answer the question instead of inheriting `false`.
    var usesWhisperDecodingSettings: Bool {
        switch self {
        case .whisper:
            return true
        case .fluidaudio, .paraformer, .sensevoice:
            return false
        }
    }

    var isSingleModelDownloaded: Bool? {
        switch self {
        case .sensevoice: return SenseVoiceEngine.isModelDownloaded
        case .paraformer: return ParaformerEngine.isModelDownloaded
        case .whisper, .fluidaudio: return nil
        }
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
