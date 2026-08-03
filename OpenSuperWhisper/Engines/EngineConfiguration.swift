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

    init(usableEngines: Set<EngineKind>, whisperModelPaths: [String]) {
        self.usableEngines = usableEngines
        self.whisperModelPaths = whisperModelPaths
    }

    func isUsable(_ kind: EngineKind) -> Bool { usableEngines.contains(kind) }

    /// Reads the current state of the caches each engine downloads into.
    ///
    /// Deliberately filesystem-truth rather than a remembered preference: the
    /// user can delete any of these caches from the folder Settings offers to
    /// open, and a preference claiming "downloaded" afterwards is exactly the
    /// lie this whole type exists to stop believing.
    static func current(fluidAudioModelVersion: String = AppPreferences.shared.fluidAudioModelVersion)
        -> EngineAvailability {
        let whisperModelPaths = WhisperModelManager.shared.getAvailableModels().map(\.path)

        var usable: Set<EngineKind> = []
        if !whisperModelPaths.isEmpty { usable.insert(.whisper) }
        if isFluidAudioDownloaded(version: fluidAudioModelVersion) { usable.insert(.fluidaudio) }
        for kind in EngineKind.allCases where kind.isSingleModelDownloaded == true {
            usable.insert(kind)
        }

        return EngineAvailability(usableEngines: usable, whisperModelPaths: whisperModelPaths)
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
        }
    }

    /// The order recovery tries engines in, for someone dictating `language`.
    ///
    /// Whisper leads because it is `EngineKind.fallback` - the app-wide default
    /// and the only engine that does every language. Chinese is the one language
    /// the app holds an opinion about, and `EngineKind.defaultChineseDictation`
    /// is where that opinion lives, so a Chinese user meets the two Chinese
    /// engines first instead - the same order onboarding offers them in.
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

    static func resolve(selectedEngine: EngineKind,
                        whisperModelPath: String?,
                        language: String,
                        fluidAudioModelVersion: String,
                        availability: EngineAvailability) -> EngineConfigurationOutcome {
        if isConfigured(engine: selectedEngine, whisperModelPath: whisperModelPath, availability: availability) {
            return .usable(selectedEngine)
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
            availability: availability
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
