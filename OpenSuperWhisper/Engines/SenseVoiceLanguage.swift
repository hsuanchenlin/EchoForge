import Foundation

/// The languages SenseVoice-Small can actually be asked for, and the encoder
/// embedding index each one is.
///
/// This mapping lives in the app on purpose. FluidAudio takes the language as a
/// bare `Int32` embed index, publishes no enum for it, and **does not validate
/// it**: measured on the pinned 0.15.4, `99` and `-1` neither throw nor clamp -
/// they silently produce whatever the unconditioned model felt like, and a
/// wrong-but-legal index quietly degrades the transcript (asking for English on
/// Mandarin speech turned `开放时间早上9点至下午5点。` into `开放时间早9至下5点.`).
/// So the app never passes a `LanguageUtil` code through to the model; it maps
/// here or falls back to auto-detect.
///
/// The model's vocabulary carries 100+ `<|lang|>` tags, which is where
/// FluidAudio's "50+ languages" comment comes from. It is not true of the
/// embedding: only these six indices are meaningful, and all six were verified
/// end-to-end on the upstream example clips - Cantonese came back with 唔/嘅
/// intact, not as Mandarin.
enum SenseVoiceLanguage: String, CaseIterable {

    /// The model picks. Correct on the fixtures, and the only honest choice for
    /// a language code the model has no embedding for.
    case auto

    case zh
    case yue
    case en
    case ja

    /// Verified working, with visibly imperfect word spacing (`조 금만 생각을  하`).
    case ko

    /// Index into the encoder's language embedding table. Not contiguous, and
    /// not ours to renumber: these are FunASR's `lid_dict` values, published on
    /// the conversion card and confirmed against the downloaded vocabulary.
    var embedIndex: Int32 {
        switch self {
        case .auto: return 0
        case .zh: return 3
        case .en: return 4
        case .yue: return 7
        case .ja: return 11
        case .ko: return 12
        }
    }

    /// Maps one of the app's language codes onto an embedding.
    ///
    /// Anything the model has no embedding for becomes `.auto` rather than an
    /// invented index. That happens when a stored language predates the engine
    /// switch - the Settings picker resets an unsupported language, but a
    /// recording can reach an engine before that has been observed.
    init(languageCode: String) {
        self = SenseVoiceLanguage(rawValue: languageCode) ?? .auto
    }
}
