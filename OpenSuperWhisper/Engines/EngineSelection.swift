import Foundation

/// Which engine dictation actually runs on right now, which is not the same
/// question as which engine the user has chosen.
///
/// Before this existed the two were one value - `AppPreferences.selectedEngine`
/// was read as both "what the user wants" and "what we can transcribe with" -
/// and every gap between them had to be an error. Choosing a 240 MB engine meant
/// several minutes during which dictation simply failed, and the only way to
/// avoid that was for recovery to overwrite the choice the user had just made.
///
/// Splitting them makes the gap a state instead of a failure: `desired` is
/// whatever the user last chose and is never written here, while `active` is the
/// best engine that can transcribe *now*. When they differ, the desired one is
/// being prepared in the background and the app says so.
struct EngineSelection: Equatable {
    /// The engine the user chose. Read from preferences, never written back by
    /// anything in this file - that is the whole guarantee.
    let desired: EngineKind

    /// The engine dictation runs on now, or `nil` when nothing on this Mac can
    /// transcribe the current language at all.
    let active: EngineKind?

    /// The Whisper file `active` should load. Set only when `active` is Whisper,
    /// the one engine that also picks between files.
    let activeWhisperModelPath: String?

    /// Why `active` is not `desired`, or `nil` when it is.
    let interimReason: InterimReason?

    /// The reasons the app runs on something other than the user's choice. Two
    /// cases rather than a bool because they are two different sentences to the
    /// user: one is "carry on as you were", the other is "this is what came with
    /// the app".
    enum InterimReason: Equatable {
        /// The model the user was dictating with before they changed their mind.
        /// Kept running so the change costs them nothing.
        case previousModel

        /// The starter model - the weights this build ships with, or the same
        /// model already in the cache - standing in because nothing else is
        /// ready. This is a first launch, or a launch after the cache was
        /// cleared.
        case starterModel
    }

    /// Whether dictation can happen at all.
    var canTranscribe: Bool { active != nil }

    /// Whether the desired engine still needs preparing. True exactly when the
    /// user's choice is not what is running - including when nothing is running.
    var isDesiredEnginePending: Bool { active != desired }
}

/// The rules that pick the active engine, as a pure function of a snapshot.
///
/// Deliberately free of `AppPreferences`, the filesystem and the network, so the
/// order can be asserted without a 240 MB download - the same reason
/// `EngineConfiguration` takes an `EngineAvailability` rather than reading disk.
enum EngineSelector {

    /// The engine whose weights a build can ship with (`StarterModel`).
    ///
    /// It is `EngineKind.defaultChineseDictation` because that is the engine the
    /// app already recommends and already downloads for Chinese, and because it
    /// is the only one of the four that covers five languages in a single
    /// 240 MB download. Bundling a second engine would mean carrying two sets of
    /// weights to answer one question.
    static let starterEngine: EngineKind = EngineKind.defaultChineseDictation

    /// Picks the engine to transcribe with, without ever proposing a change to
    /// the stored selection.
    ///
    /// The order is the product decision, stated once:
    ///
    /// 1. **The user's choice**, whenever it can load. Nothing else is
    ///    considered - a working desired engine ends the question, and in
    ///    particular an engine the user picked is never passed over because
    ///    another one is "better".
    /// 2. **The model they were last dictating with**, so choosing a new engine
    ///    costs them nothing while it downloads. This is the case that used to
    ///    be an error.
    /// 3. **The starter model**, so a first launch can dictate before any
    ///    network round trip.
    /// 4. Nothing, which the app says out loud rather than discovering at the
    ///    end of a recording.
    ///
    /// Tiers 2 and 3 additionally have to *fit*: an engine that does not do the
    /// language being dictated is not a stand-in, it is a different kind of
    /// failure. Paraformer does not refuse German, it returns fluent Mandarin
    /// for it, and silently doing that to someone whose Whisper download had not
    /// finished would be worse than telling them to wait.
    ///
    /// And they have to be **on this Mac**. `EngineKind.usesCloudProvider` is
    /// excluded from both interim tiers, because standing in is something this
    /// function does without asking: a dictation must never be uploaded to a
    /// provider because some other engine's download had not finished. The cloud
    /// engine transcribes when the user chose it - tier 1 - and never otherwise.
    ///
    /// - Parameters:
    ///   - lastReady: the engine that was last actually loaded and used, from
    ///     `AppPreferences.lastReadyEngine`. Distinct from the desired engine and
    ///     written only when a load succeeds.
    ///   - language: the dictation language, which the interim tiers are checked
    ///     against. The desired engine is not checked - Settings and onboarding
    ///     already keep that pairing legal.
    static func resolve(
        desired: EngineKind,
        desiredWhisperModelPath: String?,
        lastReady: EngineKind?,
        lastReadyWhisperModelPath: String?,
        language: String,
        fluidAudioModelVersion: String,
        availability: EngineAvailability
    ) -> EngineSelection {
        func isConfigured(_ engine: EngineKind, whisperModelPath: String?) -> Bool {
            EngineConfiguration.isConfigured(
                engine: engine,
                whisperModelPath: whisperModelPath,
                availability: availability
            )
        }

        func canDictateTheLanguage(_ engine: EngineKind) -> Bool {
            LanguageUtil.supportedLanguages(
                engine: engine,
                fluidAudioModelVersion: fluidAudioModelVersion
            ).contains(language)
        }

        if isConfigured(desired, whisperModelPath: desiredWhisperModelPath) {
            return EngineSelection(
                desired: desired,
                active: desired,
                activeWhisperModelPath: desired == .whisper ? desiredWhisperModelPath : nil,
                interimReason: nil
            )
        }

        if let lastReady, lastReady != desired, !lastReady.usesCloudProvider,
            isConfigured(lastReady, whisperModelPath: lastReadyWhisperModelPath),
            canDictateTheLanguage(lastReady) {
            return EngineSelection(
                desired: desired,
                active: lastReady,
                activeWhisperModelPath: lastReady == .whisper ? lastReadyWhisperModelPath : nil,
                interimReason: .previousModel
            )
        }

        if starterEngine != desired,
            isConfigured(starterEngine, whisperModelPath: nil),
            canDictateTheLanguage(starterEngine) {
            return EngineSelection(
                desired: desired,
                active: starterEngine,
                activeWhisperModelPath: nil,
                interimReason: .starterModel
            )
        }

        return EngineSelection(
            desired: desired,
            active: nil,
            activeWhisperModelPath: nil,
            interimReason: nil
        )
    }
}
