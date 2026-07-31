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

    /// Used when nothing is stored yet and when the stored value is not one we
    /// know, which is what a downgrade after trying a newer engine looks like.
    static let fallback: EngineKind = .whisper

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
        }
    }
}
