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

    /// The engine that last actually loaded and transcribed, which is not the
    /// same thing as `selectedEngine`.
    ///
    /// `selectedEngine` is what the user asked for and is written only when they
    /// ask; this is written only when a load succeeds. Keeping them apart is
    /// what lets the app keep dictating on the previous model while a newly
    /// chosen one downloads, without a fallback ever overwriting the choice -
    /// see `EngineSelector`. Optional because a fresh install has no such engine
    /// yet, which is the case the bundled starter answers.
    @OptionalUserDefault(key: "lastReadyEngine")
    var lastReadyEngineRawValue: String?

    var lastReadyEngine: EngineKind? {
        get { lastReadyEngineRawValue.flatMap(EngineKind.init(rawValue:)) }
        set { lastReadyEngineRawValue = newValue?.rawValue }
    }

    /// The Whisper file that was loaded alongside `lastReadyEngine`, for the one
    /// engine where naming the engine is only half of a configuration.
    @OptionalUserDefault(key: "lastReadyWhisperModelPath")
    var lastReadyWhisperModelPath: String?

    /// The engine whose weights were being fetched when the app last quit.
    ///
    /// It exists for exactly one decision: launch-time recovery
    /// (`EngineConfiguration.recoverIfNeeded`) must not treat a selection whose
    /// download had simply not finished as a stale configuration to repair. A
    /// download interrupted by a quit is resumed, not overruled - otherwise
    /// quitting during a 240 MB fetch would silently undo the choice that
    /// started it.
    @OptionalUserDefault(key: "pendingEnginePreparation")
    var pendingEnginePreparationRawValue: String?

    var pendingEnginePreparation: EngineKind? {
        get { pendingEnginePreparationRawValue.flatMap(EngineKind.init(rawValue:)) }
        set { pendingEnginePreparationRawValue = newValue?.rawValue }
    }

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

    /// Whether a dictation is shown as the floating capsule at the top of the
    /// screen instead of the card beside the caret.
    ///
    /// One overlay or the other, never both: they are two presentations of the
    /// same session, and two of them on screen at once is duplicated feedback
    /// rather than more of it. See `CapsuleHUDWindowController`.
    ///
    /// Off by default. Every existing install already has feedback where its
    /// owner learned to look for it, and moving it to the top of the screen is
    /// their choice to make rather than a default to change under them.
    @UserDefault(key: "capsuleHUDEnabled", defaultValue: false)
    var capsuleHUDEnabled: Bool

    /// Whether a dictation is read for a spoken command - "Ask: …",
    /// "Translate to Spanish: …" - before the words are inserted.
    ///
    /// Off by default, for the same reason `capsuleHUDEnabled` and
    /// `appAwareStyleEnabled` are: it changes what happens to the user's words,
    /// and an install where dictation already goes where its owner expects must
    /// keep doing that. The Ask panel's own shortcut works either way - it is
    /// this routing, not the panel, that the toggle is about.
    /// See `SpokenIntentRouter` and `docs/spoken-intents.md`.
    @UserDefault(key: "spokenIntentsEnabled", defaultValue: false)
    var spokenIntentsEnabled: Bool

    /// Whether a spoken snippet trigger - "insert email signoff", "插入會議記錄" -
    /// expands into the template the user stored for it.
    ///
    /// On by default, and unlike the settings around it that is not a change to
    /// anyone's dictation: snippets ride on `spokenIntentsEnabled`, which is
    /// off, so this switches the macro family off *within* spoken commands
    /// without also switching off Ask and Translate. See `VoiceSnippetStore`.
    @UserDefault(key: "voiceSnippetsEnabled", defaultValue: true)
    var voiceSnippetsEnabled: Bool

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

    /// Whether the transcript is rewritten into a style after the deterministic
    /// stages have run.
    ///
    /// Off by default, and it stays off on its own merits: it is the one stage
    /// that can change the meaning of what the user said, it needs an on-device
    /// model most Macs running this app do not have, and everything above it
    /// works without it. Turning it off must never turn off
    /// `safeCorrectionEnabled` - they are peers, not parent and child.
    @UserDefault(key: "styleRewriteEnabled", defaultValue: false)
    var styleRewriteEnabled: Bool

    /// The chosen style's identifier, from `StyleRewriteCatalog`.
    ///
    /// A plain string rather than an enum because the catalog is data: an
    /// identifier written by a newer build reads back as the default style
    /// instead of leaving the app with none - see
    /// `StyleRewriteCatalog.style(forStoredID:)`.
    @UserDefault(key: "styleRewriteStyleID", defaultValue: StyleRewriteCatalog.defaultStyleID)
    var styleRewriteStyleID: String

    /// The user's own rewriting instruction, used by the custom style.
    ///
    /// Kept even while another style is selected, so switching away and back
    /// does not silently discard something they wrote.
    @UserDefault(key: "styleRewriteCustomPrompt", defaultValue: "")
    var styleRewriteCustomPrompt: String

    /// Whether the app being dictated into may choose the rewriting style.
    ///
    /// Off by default, and for the same reason `capsuleHUDEnabled` is: an
    /// install that already has a style chosen must keep using it. Switching
    /// this on is the user saying that Slack and Mail should not get the same
    /// words, and it changes nothing at all while `styleRewriteEnabled` is off.
    /// See `AppStyleMappingStore`.
    @UserDefault(key: "appAwareStyleEnabled", defaultValue: false)
    var appAwareStyleEnabled: Bool

    /// Per-app rules: normalized bundle identifier -> style identifier, with the
    /// empty string meaning "use the style I chose".
    ///
    /// Bundle identifiers and style identifiers, and nothing else - no window
    /// titles, document names or addresses are read, so none can be stored here.
    /// `AppStyleMappingTests` asserts that about what actually lands in the
    /// domain.
    @UserDefault(key: "appStyleMappings", defaultValue: [:])
    var appStyleMappings: [String: String]

    /// Per-category rules: `AppCategory` raw value -> style identifier, same
    /// encoding. Absent entries take `AppStyleMappingStore.builtInCategoryStyles`.
    @UserDefault(key: "appStyleCategoryStyles", defaultValue: [:])
    var appStyleCategoryStyles: [String: String]

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

    /// Whether macOS has ever been asked for Screen Recording on this install.
    ///
    /// macOS shows that permission dialog once per app and never again, and has
    /// no API that says which side of the once an app is on. Written whenever
    /// the request is actually made (`SystemScreenRecordingAuthorizer`), so a
    /// refused screen query can tell the first press - the OS dialog is on
    /// screen, leave it alone - from every later one, where System Settings is
    /// the only door left. See `AskPanelWindowController.screenRecordingRefusal`.
    @UserDefault(key: "screenRecordingAccessRequested", defaultValue: false)
    var screenRecordingAccessRequested: Bool
}
