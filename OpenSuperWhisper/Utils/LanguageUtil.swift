import Foundation
class LanguageUtil {

    static let availableLanguages = [
        "auto", "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar",
        "he", "sv", "it", "id", "hi", "fi",
    ]

    static let parakeetV2Languages = ["en"]

    static let parakeetV3Languages = [
        "en", "de", "es", "ru", "fr", "pt", "pl", "nl", "sv", "it", "fi",
        "bg", "hr", "cs", "da", "el", "et", "hu", "lv", "lt", "mt", "ro", "sk", "sl", "uk",
    ]

    static let languageNames = [
        "auto": "Auto-detect",
        "en": "English",
        "zh": "Chinese",
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
        }
    }

    static func fallbackLanguage(engine: EngineKind) -> String {
        switch engine {
        case .whisper:
            return "auto"
        case .fluidaudio:
            return "en"
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
