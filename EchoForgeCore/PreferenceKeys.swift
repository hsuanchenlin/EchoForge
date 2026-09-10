import Foundation

/// The names every preference is stored under.
///
/// They were string literals inside `AppPreferences`' property wrappers, which
/// was fine while the app was the only thing that read them. It stopped being
/// fine when `echoforge settings` began reporting them from another process: a
/// key spelled twice is a key that can be spelled differently, and the failure
/// is silent - the CLI reads a key nobody writes and reports "not set" forever.
///
/// These are **storage format**. Renaming one resets that setting for every
/// existing user, exactly as renaming an `EngineKind` raw value does.
enum PreferenceKeys {
    // Engine and model
    static let selectedEngine = "selectedEngine"
    static let selectedWhisperModelPath = "selectedWhisperModelPath"
    static let lastReadyEngine = "lastReadyEngine"
    static let lastReadyWhisperModelPath = "lastReadyWhisperModelPath"
    static let pendingEnginePreparation = "pendingEnginePreparation"
    static let fluidAudioModelVersion = "fluidAudioModelVersion"

    // Transcription
    static let whisperLanguage = "whisperLanguage"
    static let suppressBlankAudio = "suppressBlankAudio"
    static let showTimestamps = "showTimestamps"
    static let temperature = "temperature"
    static let noSpeechThreshold = "noSpeechThreshold"
    static let initialPrompt = "initialPrompt"
    static let useBeamSearch = "useBeamSearch"
    static let beamSize = "beamSize"
    static let debugMode = "debugMode"

    // Overlays and spoken commands
    static let playSoundOnRecordStart = "playSoundOnRecordStart"
    static let capsuleHUDEnabled = "capsuleHUDEnabled"
    static let spokenIntentsEnabled = "spokenIntentsEnabled"
    static let spokenCorrectionsEnabled = "spokenCorrectionsEnabled"
    static let fillerWordRemovalEnabled = "fillerWordRemovalEnabled"
    static let voiceSnippetsEnabled = "voiceSnippetsEnabled"
    static let youTubeLatestVideoEnabled = "youTubeLatestVideoEnabled"
    static let youTubeChannelModelMatchEnabled = "youTubeChannelModelMatchEnabled"
    static let youTubeChannelPickerEnabled = "youTubeChannelPickerEnabled"

    // Cloud. None of these is the key itself - that lives only in the Keychain
    // (`CloudCredentialStore`), which is why there is no constant for it here.
    static let cloudTranslationEnabled = "cloudTranslationEnabled"
    static let cloudBaseURL = "cloudBaseURL"
    static let cloudTranscriptionModel = "cloudTranscriptionModel"
    static let cloudTranslationModel = "cloudTranslationModel"
    static let cloudConsentedFeatures = "cloudConsentedFeatures"
    static let cloudPreviousLocalEngine = "cloudPreviousLocalEngine"

    // Text post-processing
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let useAsianAutocorrect = "useAsianAutocorrect"
    static let chineseOutputScript = "chineseOutputScript"
    static let safeCorrectionEnabled = "safeCorrectionEnabled"
    static let styleRewriteEnabled = "styleRewriteEnabled"
    static let styleRewriteStyleID = "styleRewriteStyleID"
    static let styleRewriteCustomPrompt = "styleRewriteCustomPrompt"
    static let appAwareStyleEnabled = "appAwareStyleEnabled"
    static let appStyleMappings = "appStyleMappings"
    static let appStyleCategoryStyles = "appStyleCategoryStyles"
    static let appVocabularyEnabled = "appVocabularyEnabled"
    static let appVocabularyCategories = "appVocabularyCategories"
    static let appVocabularyExcludedApps = "appVocabularyExcludedApps"

    // Input and behaviour
    static let selectedMicrophoneData = "selectedMicrophoneData"
    static let modifierOnlyHotkey = "modifierOnlyHotkey"
    static let lastModifierOnlyHotkey = "lastModifierOnlyHotkey"
    static let mouseButtonHotkey = "mouseButtonHotkey"
    static let holdToRecord = "holdToRecord"
    static let doublePressToTrigger = "doublePressToTrigger"
    static let addSpaceAfterSentence = "addSpaceAfterSentence"
    static let autoCopyToClipboard = "autoCopyToClipboard"
    static let autoPasteTranscription = "autoPasteTranscription"
    static let escCancelWithoutConfirmation = "escCancelWithoutConfirmation"
    static let startHiddenInMenuBar = "startHiddenInMenuBar"
    static let autoDeleteRecordingsEnabled = "autoDeleteRecordingsEnabled"
    static let autoDeleteRecordingsAfterDays = "autoDeleteRecordingsAfterDays"
    static let screenRecordingAccessRequested = "screenRecordingAccessRequested"

    /// Every key above.
    ///
    /// `PreferenceKeyCoverageTests` reads the `key:` literals out of
    /// `AppPreferences.swift` and fails if one of them is missing here, so a
    /// preference added without a constant is caught at test time rather than by
    /// a CLI that silently reports it as unset.
    static let all: Set<String> = [
        selectedEngine, selectedWhisperModelPath, lastReadyEngine, lastReadyWhisperModelPath,
        pendingEnginePreparation, fluidAudioModelVersion,
        whisperLanguage, suppressBlankAudio, showTimestamps, temperature, noSpeechThreshold,
        initialPrompt, useBeamSearch, beamSize, debugMode,
        playSoundOnRecordStart, capsuleHUDEnabled, spokenIntentsEnabled, voiceSnippetsEnabled,
        spokenCorrectionsEnabled, fillerWordRemovalEnabled,
        youTubeLatestVideoEnabled, youTubeChannelModelMatchEnabled, youTubeChannelPickerEnabled,
        cloudTranslationEnabled, cloudBaseURL, cloudTranscriptionModel, cloudTranslationModel,
        cloudConsentedFeatures, cloudPreviousLocalEngine,
        hasCompletedOnboarding, useAsianAutocorrect, chineseOutputScript, safeCorrectionEnabled,
        styleRewriteEnabled, styleRewriteStyleID, styleRewriteCustomPrompt, appAwareStyleEnabled,
        appStyleMappings, appStyleCategoryStyles,
        appVocabularyEnabled, appVocabularyCategories, appVocabularyExcludedApps,
        selectedMicrophoneData, modifierOnlyHotkey, lastModifierOnlyHotkey, mouseButtonHotkey,
        holdToRecord, doublePressToTrigger, addSpaceAfterSentence, autoCopyToClipboard,
        autoPasteTranscription, escCancelWithoutConfirmation, startHiddenInMenuBar,
        autoDeleteRecordingsEnabled, autoDeleteRecordingsAfterDays, screenRecordingAccessRequested,
    ]
}
