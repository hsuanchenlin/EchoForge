import Foundation

/// Where every preference below is stored.
///
/// `UserDefaults.standard` in the app, and redirectable to a throwaway suite by
/// a test. That matters because the tests run in several parallel host
/// processes against one real defaults domain: one of them clearing
/// `selectedEngine` while another is loading an engine from it is a flake, not
/// a test. Nothing in the app ever writes this.
enum PreferenceStore {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
}

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get { PreferenceStore.defaults.object(forKey: key) as? T ?? defaultValue }
        set { PreferenceStore.defaults.set(newValue, forKey: key) }
    }
}

/// Stores an enum as its raw string, so the on-disk format stays the plain
/// string it has always been. Anything unreadable - a value written by a newer
/// build, a hand-edited key - reads back as `defaultValue` instead of crashing
/// or leaving the app with no engine.
@propertyWrapper
struct RawRepresentableUserDefault<T: RawRepresentable> where T.RawValue == String {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get { T(rawValue: PreferenceStore.defaults.string(forKey: key) ?? "") ?? defaultValue }
        set { PreferenceStore.defaults.set(newValue.rawValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { PreferenceStore.defaults.object(forKey: key) as? T }
        set { PreferenceStore.defaults.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        migrateOldPreferences()
    }
    
    private func migrateOldPreferences() {
        if let oldPath = PreferenceStore.defaults.string(forKey: "selectedModelPath"),
           PreferenceStore.defaults.string(forKey: "selectedWhisperModelPath") == nil {
            PreferenceStore.defaults.set(oldPath, forKey: "selectedWhisperModelPath")
        }
    }
    
    // Engine settings
    @RawRepresentableUserDefault(key: "selectedEngine", defaultValue: EngineKind.fallback)
    var selectedEngine: EngineKind

    // Model settings
    var selectedModelPath: String? {
        get {
            if selectedEngine == .whisper {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == .whisper {
                selectedWhisperModelPath = newValue
            }
        }
    }
    
    @OptionalUserDefault(key: "selectedWhisperModelPath")
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool

    /// Deterministic safe correction: the personal terms dictionary and the
    /// formatting passes around it.
    ///
    /// On by default and a peer of any later style-rewriting setting, never its
    /// child. It depends on nothing - no model, no network, no macOS version -
    /// so it must keep working when rewriting is off, unavailable or rejected.
    @UserDefault(key: "safeCorrectionEnabled", defaultValue: true)
    var safeCorrectionEnabled: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    var modifierOnlyHotkey: String
    
    /// Last non-none modifier key, used to restore the user's choice
    /// when switching back to Single Modifier Key mode.
    @UserDefault(key: "lastModifierOnlyHotkey", defaultValue: "leftCommand")
    var lastModifierOnlyHotkey: String
    
    @UserDefault(key: "mouseButtonHotkey", defaultValue: "none")
    var mouseButtonHotkey: String


    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool

    @UserDefault(key: "doublePressToTrigger", defaultValue: false)
    var doublePressToTrigger: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: false)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool

    @UserDefault(key: "escCancelWithoutConfirmation", defaultValue: false)
    var escCancelWithoutConfirmation: Bool

    @UserDefault(key: "startHiddenInMenuBar", defaultValue: false)
    var startHiddenInMenuBar: Bool

    @UserDefault(key: "autoDeleteRecordingsEnabled", defaultValue: false)
    var autoDeleteRecordingsEnabled: Bool

    @UserDefault(key: "autoDeleteRecordingsAfterDays", defaultValue: 30)
    var autoDeleteRecordingsAfterDays: Int
}
