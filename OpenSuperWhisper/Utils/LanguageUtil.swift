import Foundation
class LanguageUtil {

    static let availableLanguages = [
        "auto", "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar",
        "he", "sv", "it", "id", "hi", "fi",
    ]

    static let parakeetV2Languages = ["en"]

    /// Paraformer-large (zh) is Mandarin-only, and it does not fail on anything
    /// else - it mis-transcribes it. English comes back with raw `@@` BPE
    /// continuation markers in it and Cantonese comes back as wrong Mandarin, so
    /// the lock is here rather than left to the user to discover.
    static let paraformerLanguages = ["zh"]

    /// SenseVoice-Small's six language embeddings, in picker order with the
    /// Chinese pair first: this engine is reached as the Chinese default.
    ///
    /// Derived from the embedding rather than written out, because the mapping
    /// is what the model actually honours - see `SenseVoiceLanguage`, which also
    /// explains why the model's 100+ `<|lang|>` vocabulary tags are not this
    /// list.
    static let senseVoiceLanguages = SenseVoiceLanguage.allCases.map(\.rawValue)

    static let parakeetV3Languages = [
        "en", "de", "es", "ru", "fr", "pt", "pl", "nl", "sv", "it", "fi",
        "bg", "hr", "cs", "da", "el", "et", "hu", "lv", "lt", "mt", "ro", "sk", "sl", "uk",
    ]

    static let languageNames = [
        "auto": "Auto-detect",
        "en": "English",
        "zh": "Chinese",
        // Cantonese is a SenseVoice language, not a Whisper one, so it has a
        // display name without being in `availableLanguages`.
        "yue": "Cantonese",
        "de": "German",
        "es": "Spanish",
        "ru": "Russian",
        "ko": "Korean",
        "fr": "French",
        "ja": "Japanese",
        "pt": "Portuguese",
        "tr": "Turkish",
        "pl": "Polish",
        "ca": "Catalan",
        "nl": "Dutch",
        "ar": "Arabic",
        "he": "Hebrew",
        "sv": "Swedish",
        "it": "Italian",
        "id": "Indonesian",
        "hi": "Hindi",
        "fi": "Finnish",
        "bg": "Bulgarian",
        "hr": "Croatian",
        "cs": "Czech",
        "da": "Danish",
        "el": "Greek",
        "et": "Estonian",
        "hu": "Hungarian",
        "lv": "Latvian",
        "lt": "Lithuanian",
        "mt": "Maltese",
        "ro": "Romanian",
        "sk": "Slovak",
        "sl": "Slovenian",
        "uk": "Ukrainian",
    ]

    /// Switched exhaustively on purpose: a new engine must state its language
    /// scope rather than silently inheriting Whisper's full list.
    static func supportedLanguages(engine: EngineKind, fluidAudioModelVersion: String) -> [String] {
        switch engine {
        case .whisper:
            return availableLanguages
        case .fluidaudio:
            return fluidAudioModelVersion == "v2" ? parakeetV2Languages : parakeetV3Languages
        case .paraformer:
            return paraformerLanguages
        case .sensevoice:
            return senseVoiceLanguages
        }
    }

    static func fallbackLanguage(engine: EngineKind) -> String {
        switch engine {
        case .whisper:
            return "auto"
        case .fluidaudio:
            return "en"
        case .paraformer:
            return "zh"
        case .sensevoice:
            // Mandarin, not auto-detect, even though the model offers both: this
            // engine is selected to dictate Chinese, and `zh` is also what keeps
            // `Settings.isAsianLanguage` - and with it the CJK autocorrect
            // stage - switched on. A user who wants the other four languages can
            // still pick `auto`.
            return "zh"
        }
    }

    static func getSystemLanguage() -> String {
        if let preferredLanguage = Locale.preferredLanguages.first {
            let preferredLanguage = preferredLanguage.prefix(2).lowercased()
            return availableLanguages.contains(preferredLanguage) ? preferredLanguage : "en"
        } else {
            return "eng"
        }
    }
}
