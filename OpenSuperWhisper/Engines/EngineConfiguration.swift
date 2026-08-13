import Foundation
import FluidAudio

/// Which engines could actually transcribe right now, as one value.
///
/// Read from disk once and passed around rather than queried per engine, so
/// every decision below is a pure function of a snapshot: the rules can be
/// tested without a filesystem, a network or a 240 MB download.
struct EngineAvailability: Equatable {
    /// Engines whose weights are on this Mac. Whisper is in here whenever any
    /// `.bin` is, which is not the same as the user's *stored* Whisper model
    /// still existing - see `whisperModelPaths`.
    let usableEngines: Set<EngineKind>

    /// The Whisper model files present, in the order `WhisperModelManager`
    /// lists them. A stored `selectedWhisperModelPath` that is not in here
    /// points at a file the user has since deleted.
    let whisperModelPaths: [String]

    /// Why `CloudAccess` refused transcription, when it did - `nil` when the
    /// cloud engine is usable or when the snapshot never asked. Carried because
    /// the decisions below need to tell two unusable-cloud states apart: a
    /// selection the user half-configured, which must stay selected and fail
    /// out loud, and a build with no cloud path, which recovery may repair.
    let cloudTranscriptionRefusal: CloudAccessRefusal?

    init(usableEngines: Set<EngineKind>,
         whisperModelPaths: [String],
         cloudTranscriptionRefusal: CloudAccessRefusal? = nil) {
        self.usableEngines = usableEngines
        self.whisperModelPaths = whisperModelPaths
        self.cloudTranscriptionRefusal = cloudTranscriptionRefusal
    }

    func isUsable(_ kind: EngineKind) -> Bool { usableEngines.contains(kind) }

    /// Reads the current state of the caches each engine downloads into.
    ///
    /// Deliberately filesystem-truth rather than a remembered preference: the
    /// user can delete any of these caches from the folder Settings offers to
    /// open, and a preference claiming "downloaded" afterwards is exactly the
    /// lie this whole type exists to stop believing.
    ///
    /// The cloud engine has no cache, so what stands in for "downloaded" is
    /// `CloudAccess`: the feature selected, its consent given, a usable base URL
    /// and a key present. Reading it here rather than at each call site is what
    /// keeps every decision below a pure function of this snapshot - and the gate
    /// stops before the Keychain unless the user has actually chosen the cloud,
    /// so the default install pays nothing for the question.
    static func current(fluidAudioModelVersion: String = AppPreferences.shared.fluidAudioModelVersion)
        -> EngineAvailability {
        let whisperModelPaths = WhisperModelManager.shared.getAvailableModels().map(\.path)

        var usable: Set<EngineKind> = []
        if !whisperModelPaths.isEmpty { usable.insert(.whisper) }
        if isFluidAudioDownloaded(version: fluidAudioModelVersion) { usable.insert(.fluidaudio) }
        for kind in EngineKind.allCases where kind.isSingleModelDownloaded == true {
            usable.insert(kind)
        }
        var cloudRefusal: CloudAccessRefusal?
        switch CloudAccess.resolve(.transcription) {
        case .success: usable.insert(.cloud)
        case .failure(let refusal): cloudRefusal = refusal
        }

        return EngineAvailability(
            usableEngines: usable,
            whisperModelPaths: whisperModelPaths,
            cloudTranscriptionRefusal: cloudRefusal
        )
    }

    static func isFluidAudioDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: asrVersion), version: asrVersion)
    }
}

/// What the stored engine preferences amount to, once checked against what is
/// actually downloaded.
enum EngineConfigurationOutcome: Equatable {
    /// The stored choice can transcribe. Nothing to write.
    case usable(EngineKind)

    /// The stored choice cannot transcribe and this downloaded engine was put
    /// in its place. `whisperModelPath` is set only when the replacement is
    /// Whisper, the one engine that also needs a file chosen; `language` is the
    /// dictation language the replacement leaves the user on, which is the
    /// stored one unless the replacement cannot do it.
    case recovered(engine: EngineKind, whisperModelPath: String?, language: String)

    /// The stored choice cannot transcribe *yet*, because its weights were still
    /// being fetched when the app last quit. Nothing is written: an unfinished
    /// download is a choice in progress, not a stale configuration, and
    /// overruling it would mean that quitting during a 240 MB fetch silently
    /// undid the selection that started it. The download is resumed instead, and
    /// `EngineSelector` keeps dictation running on something else meanwhile.
    case preparing(EngineKind)

    /// The stored choice is the cloud engine and `CloudAccess` refuses it for a
    /// reason the user can fix - no key, no model, an unusable base URL, a
    /// consent another build never recorded. Nothing is written: that selection
    /// was made deliberately - in the Cloud pane, or with the engine shortcut,
    /// which only offers the cloud while it would work - so it stays exactly as
    /// made and the refusal surfaces on each dictation instead
    /// (`CloudRequestError.notPermitted`), naming the field to fix.
    case cloudMisconfigured(CloudAccessRefusal)

    /// Nothing on this Mac can transcribe. The app has to say so rather than
    /// accept dictation it will silently throw away.
    case unavailable
}

/// The single answer to "can this app transcribe, and with what?".
///
/// It exists because there are three ways to end up with `hasCompletedOnboarding`
/// true and no engine that works - onboarding that auto-selected a downloaded row
/// without persisting it (fixed in `OnboardingViewModel`), a model cache the user
/// deleted, and a stored engine from a build that had one this build does not -
/// and all three used to end the same way: a recording that decoded into nothing,
/// printed a line to the console and deleted the audio.
enum EngineConfiguration {
    /// The message the user is shown when nothing can transcribe. One sentence,
    /// naming the single action that fixes it.
    static let unavailableMessage = "No transcription engine is set up. Choose one in Settings."

    /// The short form of the same thing, for the dictation indicator - a 200 pt
    /// card that cannot hold the sentence above.
    static let unavailableShortMessage = "No engine set up"

    /// Whether a transcription failed because nothing is set up to transcribe
    /// with - the one failure worth keeping the user's audio for, since setting
    /// an engine up is all it takes to get the transcript.
    static func isNotConfigured(_ error: Error) -> Bool {
        (error as? TranscriptionError) == .engineNotConfigured
    }

    /// Whether this engine, with this stored Whisper path, can transcribe now.
    ///
    /// Switched exhaustively so a new engine has to say how its weights are
    /// checked instead of inheriting an answer.
    static func isConfigured(engine: EngineKind,
                             whisperModelPath: String?,
                             availability: EngineAvailability) -> Bool {
        switch engine {
        case .whisper:
            // Whisper is the only engine that picks between several files, so
            // it is the only one where "downloaded" is not enough: the stored
            // path has to still be one of them.
            guard let whisperModelPath else { return false }
            return availability.whisperModelPaths.contains(whisperModelPath)
        case .fluidaudio, .sensevoice, .paraformer:
            return availability.isUsable(engine)
        case .cloud:
            // Same question, different answer to what "downloaded" means: the
            // snapshot carries whether `CloudAccess` would permit a call.
            return availability.isUsable(engine)
        }
    }

    /// Whether the app can fetch this engine's weights on its own, given time.
    ///
    /// True for every engine whose weights are one identified download the app
    /// can start unattended, which is what background preparation needs in order
    /// to make a just-chosen engine ready without the user driving it.
    ///
    /// Whisper is the exception, and switched exhaustively so a new engine has to
    /// answer rather than inherit: a Whisper configuration names a *file*, and
    /// when that file is gone the app cannot tell whether the user wants the
    /// 1.6 GB Turbo Large back or something else. That is a choice, so it is left
    /// to Settings - and it is why a Whisper model deleted from disk is still a
    /// stale configuration for `resolve` to recover from.
    static func isPreparable(engine: EngineKind) -> Bool {
        switch engine {
        case .whisper:
            return false
        case .cloud:
            // Nothing to fetch: it has no weights. What it is missing when it
            // cannot transcribe is consent, a key or a base URL, none of which
            // the app can supply on the user's behalf.
            return false
        case .fluidaudio, .sensevoice, .paraformer:
            return true
        }
    }

    /// The order recovery tries engines in, for someone dictating `language`.
    ///
    /// Whisper leads because it is `EngineKind.fallback` - the app-wide default
    /// and the only engine that does every language. Chinese is the one language
    /// the app holds an opinion about, and `EngineKind.defaultChineseDictation`
    /// is where that opinion lives, so a Chinese user meets the two Chinese
    /// engines first instead - the same order onboarding offers them in.
    ///
    /// `EngineKind.cloud` is not in either list and must not be added to one.
    /// Recovery repairs a broken configuration silently, at launch, without
    /// asking; recovering *onto* an engine that uploads the user's audio would
    /// make that the one change this app makes behind someone's back. The same
    /// rule holds in `EngineSelector`'s interim tiers, and `usesCloudProvider` is
    /// where it is stated once.
    static func recoveryOrder(for language: String) -> [EngineKind] {
        let general: [EngineKind] = [EngineKind.fallback, .fluidaudio]
        let chinese: [EngineKind] = [EngineKind.defaultChineseDictation, EngineKind.chineseAccuracyAlternative]
        let chineseDictation = LanguageUtil.fallbackLanguage(engine: EngineKind.defaultChineseDictation)
        return language == chineseDictation ? chinese + general : general + chinese
    }

    /// The engine to fall back to, or `nil` when nothing is downloaded.
    ///
    /// Among the downloaded engines, one that can do the user's language wins
    /// over one that cannot; the caller resets the language for the latter.
    static func recoveryCandidate(language: String,
                                  fluidAudioModelVersion: String,
                                  availability: EngineAvailability) -> EngineKind? {
        let usable = recoveryOrder(for: language).filter { availability.isUsable($0) }
        let capable = usable.first {
            LanguageUtil.supportedLanguages(engine: $0, fluidAudioModelVersion: fluidAudioModelVersion)
                .contains(language)
        }
        return capable ?? usable.first
    }

    /// - Parameter pendingEngine: the engine whose download was in flight when
    ///   the app last quit (`AppPreferences.pendingEnginePreparation`). It is the
    ///   one thing that distinguishes "this configuration is stale" from "this
    ///   configuration is still arriving", and without it a quit during a model
    ///   download reads as the former.
    static func resolve(selectedEngine: EngineKind,
                        whisperModelPath: String?,
                        language: String,
                        fluidAudioModelVersion: String,
                        availability: EngineAvailability,
                        pendingEngine: EngineKind? = nil) -> EngineConfigurationOutcome {
        if isConfigured(engine: selectedEngine, whisperModelPath: whisperModelPath, availability: availability) {
            return .usable(selectedEngine)
        }

        if selectedEngine.usesCloudProvider,
           let refusal = availability.cloudTranscriptionRefusal,
           refusal.isMisconfiguration {
            return .cloudMisconfigured(refusal)
        }

        if pendingEngine == selectedEngine, let pendingEngine {
            return .preparing(pendingEngine)
        }

        guard let replacement = recoveryCandidate(
            language: language,
            fluidAudioModelVersion: fluidAudioModelVersion,
            availability: availability
        ) else {
            return .unavailable
        }

        // The rule onboarding and Settings both already apply: an engine is
        // never left paired with a language it only mis-transcribes.
        let supported = LanguageUtil.supportedLanguages(
            engine: replacement,
            fluidAudioModelVersion: fluidAudioModelVersion
        )
        return .recovered(
            engine: replacement,
            whisperModelPath: replacement == .whisper ? availability.whisperModelPaths.first : nil,
            language: supported.contains(language) ? language : LanguageUtil.fallbackLanguage(engine: replacement)
        )
    }

    /// Resolves the stored preferences and writes back whatever recovery chose.
    ///
    /// Called once at launch, before anything constructs an engine, to repair a
    /// configuration left over from a previous session. Deliberately not called
    /// again before each transcription: by then any "not configured" state is
    /// either a fresh, deliberate selection still waiting on its download or a
    /// cache the user removed while the app was running, and both must surface
    /// as the visible `engineNotConfigured` error rather than silently rewrite
    /// what the user chose - see `TranscriptionService.engineForTranscription()`.
    ///
    /// Nor does it fire for a selection whose download had simply not finished:
    /// `AppPreferences.pendingEnginePreparation` marks that case and it comes
    /// back as `.preparing`, leaving the preference exactly as the user set it
    /// while `EngineSelector` keeps dictation running on whatever is ready.
    @discardableResult
    static func recoverIfNeeded(preferences: AppPreferences = .shared,
                                availability: EngineAvailability? = nil) -> EngineConfigurationOutcome {
        let availability = availability
            ?? EngineAvailability.current(fluidAudioModelVersion: preferences.fluidAudioModelVersion)

        let outcome = resolve(
            selectedEngine: preferences.selectedEngine,
            whisperModelPath: preferences.selectedWhisperModelPath,
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion,
            availability: availability,
            pendingEngine: preferences.pendingEnginePreparation
        )

        if case .recovered(let engine, let whisperModelPath, let language) = outcome {
            preferences.selectedEngine = engine
            if let whisperModelPath {
                preferences.selectedWhisperModelPath = whisperModelPath
            }
            preferences.whisperLanguage = language
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
            print("Recovered engine configuration: \(engine) (\(language))")
        }

        return outcome
    }
}
