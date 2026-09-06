import Foundation

/// One setting `echoforge settings` reports.
struct InspectablePreference: Equatable {
    enum Kind: Equatable {
        case boolean
        case text
        case number
        case list
        case mapping

        /// A value stored as bytes rather than as something to read - the
        /// selected microphone's opaque device data. Reported as present or
        /// absent and never decoded, because printing it would be printing a
        /// blob nobody can act on.
        case opaque
    }

    /// The section it is listed under, which is roughly the Settings tab it
    /// lives in.
    let section: String

    /// What the tool calls it. Deliberately close to the Settings label rather
    /// than to the key, so somebody reading the output can find the switch.
    let label: String

    /// The defaults key, from `PreferenceKeys` - never a literal, so the app and
    /// this tool cannot drift.
    let key: String

    let kind: Kind
}

/// What `echoforge settings` shows, and the two rules about what it does not.
///
/// **It reports what is stored, never what the app would do.** A preference the
/// user has not touched is reported as not set, and the tool does not fill in
/// the default. Those defaults live beside the property wrappers in
/// `AppPreferences` next to the reasons they were chosen, and several are not
/// simple values - `selectedModelPath` depends on the selected engine,
/// `styleRewriteStyleID` is resolved through a catalog that maps an unknown
/// identifier back to the default style. A tool that printed its own copy of
/// those would be right until one of them changed, and would then be confidently
/// wrong. "Not set" is a true statement about the user's machine; a guessed
/// default is not.
///
/// **Nothing here is a credential**, and that is enforced twice. The API key
/// lives only in the Keychain (`CloudCredentialStore`), which this tool never
/// opens - so there is no key to leak rather than a key that is filtered.
/// `PreferenceKeyCoverageTests` asserts no preference is even *named* like a
/// credential, and `SettingsCommand` still prints the Keychain row as
/// `<redacted>` so the absence is visible rather than silent.
enum PreferenceInventory {

    static let all: [InspectablePreference] = [
        // Engine and model
        .init(section: "Engine", label: "Selected engine", key: PreferenceKeys.selectedEngine, kind: .text),
        .init(section: "Engine", label: "Last engine that loaded", key: PreferenceKeys.lastReadyEngine, kind: .text),
        .init(section: "Engine", label: "Preparation in flight", key: PreferenceKeys.pendingEnginePreparation, kind: .text),
        .init(section: "Engine", label: "Whisper model", key: PreferenceKeys.selectedWhisperModelPath, kind: .text),
        .init(section: "Engine", label: "FluidAudio model version", key: PreferenceKeys.fluidAudioModelVersion, kind: .text),

        // Language and script
        .init(section: "Language", label: "Dictation language", key: PreferenceKeys.whisperLanguage, kind: .text),
        .init(section: "Language", label: "Chinese output script", key: PreferenceKeys.chineseOutputScript, kind: .text),
        .init(section: "Language", label: "Asian autocorrect", key: PreferenceKeys.useAsianAutocorrect, kind: .boolean),

        // Text post-processing
        .init(section: "Text", label: "Safe correction", key: PreferenceKeys.safeCorrectionEnabled, kind: .boolean),
        .init(section: "Text", label: "Style rewriting", key: PreferenceKeys.styleRewriteEnabled, kind: .boolean),
        .init(section: "Text", label: "Style", key: PreferenceKeys.styleRewriteStyleID, kind: .text),
        .init(section: "Text", label: "App-aware style", key: PreferenceKeys.appAwareStyleEnabled, kind: .boolean),
        .init(section: "Text", label: "Per-app style rules", key: PreferenceKeys.appStyleMappings, kind: .mapping),
        .init(section: "Text", label: "Per-category style rules", key: PreferenceKeys.appStyleCategoryStyles, kind: .mapping),
        .init(section: "Text", label: "Add space after sentence", key: PreferenceKeys.addSpaceAfterSentence, kind: .boolean),

        // Shortcuts and recording behaviour
        .init(section: "Shortcuts", label: "Modifier-only hotkey", key: PreferenceKeys.modifierOnlyHotkey, kind: .text),
        .init(section: "Shortcuts", label: "Mouse-button hotkey", key: PreferenceKeys.mouseButtonHotkey, kind: .text),
        .init(section: "Shortcuts", label: "Hold to record", key: PreferenceKeys.holdToRecord, kind: .boolean),
        .init(section: "Shortcuts", label: "Double press to trigger", key: PreferenceKeys.doublePressToTrigger, kind: .boolean),
        .init(section: "Shortcuts", label: "Esc cancels without confirming", key: PreferenceKeys.escCancelWithoutConfirmation, kind: .boolean),
        .init(section: "Shortcuts", label: "Floating capsule HUD", key: PreferenceKeys.capsuleHUDEnabled, kind: .boolean),
        .init(section: "Shortcuts", label: "Sound on record start", key: PreferenceKeys.playSoundOnRecordStart, kind: .boolean),
        .init(section: "Shortcuts", label: "Selected microphone", key: PreferenceKeys.selectedMicrophoneData, kind: .opaque),

        // Spoken commands
        .init(section: "Commands", label: "Spoken intents", key: PreferenceKeys.spokenIntentsEnabled, kind: .boolean),
        .init(section: "Commands", label: "Voice snippets", key: PreferenceKeys.voiceSnippetsEnabled, kind: .boolean),
        .init(section: "Commands", label: "YouTube latest video", key: PreferenceKeys.youTubeLatestVideoEnabled, kind: .boolean),
        .init(section: "Commands", label: "YouTube channel picker", key: PreferenceKeys.youTubeChannelPickerEnabled, kind: .boolean),
        .init(section: "Commands", label: "YouTube channel model match", key: PreferenceKeys.youTubeChannelModelMatchEnabled, kind: .boolean),

        // Output
        .init(section: "Output", label: "Copy to clipboard", key: PreferenceKeys.autoCopyToClipboard, kind: .boolean),
        .init(section: "Output", label: "Paste transcription", key: PreferenceKeys.autoPasteTranscription, kind: .boolean),
        .init(section: "Output", label: "Start hidden in menu bar", key: PreferenceKeys.startHiddenInMenuBar, kind: .boolean),
        .init(section: "Output", label: "Delete old recordings", key: PreferenceKeys.autoDeleteRecordingsEnabled, kind: .boolean),
        .init(section: "Output", label: "Delete recordings after (days)", key: PreferenceKeys.autoDeleteRecordingsAfterDays, kind: .number),

        // Cloud. The enable flags and the consent record, and no credential.
        .init(section: "Cloud", label: "Cloud translation", key: PreferenceKeys.cloudTranslationEnabled, kind: .boolean),
        .init(section: "Cloud", label: "Base URL", key: PreferenceKeys.cloudBaseURL, kind: .text),
        .init(section: "Cloud", label: "Transcription model", key: PreferenceKeys.cloudTranscriptionModel, kind: .text),
        .init(section: "Cloud", label: "Translation model", key: PreferenceKeys.cloudTranslationModel, kind: .text),
        .init(section: "Cloud", label: "Consented features", key: PreferenceKeys.cloudConsentedFeatures, kind: .list),

        // Onboarding
        .init(section: "Setup", label: "Onboarding completed", key: PreferenceKeys.hasCompletedOnboarding, kind: .boolean),
    ]

    /// Settings that exist, are user-facing, and are deliberately **not** read.
    ///
    /// Listed rather than omitted, so the output says the key exists and that
    /// this tool will not print it. An omitted row reads as "there is no API
    /// key"; a `<redacted>` row reads as "there may be one, and I did not
    /// look" - which is the truth, since nothing here opens the Keychain.
    static let secrets: [(section: String, label: String, reason: String)] = [
        (
            "Cloud", "API key",
            "stored in the Keychain by CloudCredentialStore; this tool never opens it"
        )
    ]

    /// The two personal-content stores this tool does not print either.
    ///
    /// Not secrets, and not settings: the terms dictionary and the snippet
    /// templates are things the user *wrote*, and `settings` is a report about
    /// switches. `terms.json` is a plain file they can open themselves.
    static let withheldContent: [(section: String, label: String, reason: String)] = [
        (
            "Text", "Personal terms",
            "a dictionary the user wrote; read terms.json in the app's Application Support folder"
        ),
        (
            "Commands", "Voice snippets",
            "templates the user wrote; shown in Settings → Snippets"
        ),
        (
            "Text", "Custom style instruction",
            "prose the user wrote; shown in Settings → Style"
        ),
    ]
}
