import Foundation

/// What pressing the engine shortcut did.
///
/// Four cases rather than an optional engine, because the three that are not a
/// switch are the ones worth saying out loud: the shortcut is pressed with no
/// window open and no pane in front of the user, so a press that changes nothing
/// has to explain itself or it reads as a dead key.
enum EngineSwitchOutcome: Equatable {
    /// The engine changed, now.
    case switched(EngineKind)

    /// A dictation is in flight, so the change was recorded and is applied the
    /// moment that dictation is over. See `EngineSwitcher`.
    case deferred(EngineKind)

    /// There is nothing to cycle to: this engine is the only one that can
    /// transcribe. Carries it so the message can name it.
    case onlyOneEngine(EngineKind)

    /// Nothing on this Mac can transcribe at all, which is
    /// `EngineConfiguration.unavailable` seen from here.
    case noEngineAvailable
}

/// Which engines the engine shortcut cycles through, as a pure function of a
/// snapshot.
///
/// The rule is one sentence: **the shortcut only ever lands on an engine that
/// could transcribe the next dictation as things stand.** Everything below is
/// that sentence applied - which is also why this is separate from
/// `EngineSelector`. That one answers "what can transcribe *now*, given what the
/// user chose"; this one answers "what else could the user choose", and neither
/// may be derived from the other: `EngineSelector` is allowed to stand in with an
/// engine the user did not pick, and this must never offer one they cannot use.
///
/// Free of `AppPreferences`, the filesystem, the Keychain and the network, for the
/// same reason `EngineSelector` and `EngineConfiguration` are: the order, the skip
/// rules and the wrap-around are asserted without a download or a provider.
enum EngineCycle {

    /// The order the shortcut walks, before anything is skipped.
    ///
    /// `EngineCatalog.pickerOrder` first, so pressing the shortcut walks the
    /// engines top to bottom exactly as the Settings picker lists them - the
    /// shortcut is the picker without opening it, and two different orders for one
    /// set of engines would be two things to learn.
    ///
    /// `EngineKind.cloud` is appended rather than being in `pickerOrder`, because
    /// its absence there is a deliberate product decision this must not undo (see
    /// `EngineCatalog.pickerOrder`): it is offered here only once the user has
    /// already made the cloud choice in the Cloud pane and consented to it, which
    /// is what `isCloudSelectable` carries. It is last so that a press cannot land
    /// on the one engine that leaves the Mac before every local one has been
    /// offered.
    static let order: [EngineKind] = EngineCatalog.pickerOrder + [.cloud]

    /// The engines a press may land on, in cycle order.
    ///
    /// Two conditions, and both are about the *next* dictation rather than about
    /// the engine in the abstract:
    ///
    /// 1. It can load. `EngineConfiguration.isConfigured` is the same check
    ///    `EngineSelector` uses, so "downloaded" means the one thing it means
    ///    everywhere else - including for Whisper, where a configuration names a
    ///    file and the stored file has to still exist. A Whisper configuration
    ///    pointing at a deleted model is repaired at launch
    ///    (`EngineConfiguration.recoverIfNeeded`), not by a shortcut: which of
    ///    several Whisper files to use is a choice, and this shortcut changes
    ///    engines rather than making choices.
    /// 2. It can dictate the language the user is dictating. Paraformer does not
    ///    refuse German, it returns fluent Mandarin for it - the same reason
    ///    `EngineSelector` checks its interim tiers against the language. Settings
    ///    may reset the dictation language when the user picks an engine that
    ///    cannot do it, because they are looking at the language control while it
    ///    happens; a shortcut pressed into another app must not change two things
    ///    at once, so an engine that would need the language reset is skipped
    ///    instead.
    ///
    /// Both conditions are asked of the cloud engine too. What differs is only
    /// what "it can load" means for something with no weights - `isCloudSelectable`
    /// - and the language check stays, because a provider is asked for a language
    /// from the same list Whisper offers and choosing it would otherwise reset a
    /// dictation language the provider's list has no entry for.
    ///
    /// - Parameter isCloudSelectable: whether `CloudAccess` would permit
    ///   transcription if the cloud engine were selected - consent recorded, base
    ///   URL usable, model named, key present. Passed in rather than read here so
    ///   this stays pure, and because asking that question is the one part of it
    ///   that touches the Keychain (`CloudAccess.isSelectable`).
    static func available(
        whisperModelPath: String?,
        language: String,
        fluidAudioModelVersion: String,
        availability: EngineAvailability,
        isCloudSelectable: Bool
    ) -> [EngineKind] {
        order.filter { engine in
            // Both conditions apply to every engine; only what "can load" means
            // differs, because the cloud engine has no weights to have downloaded.
            let canLoad = engine.usesCloudProvider
                ? isCloudSelectable
                : EngineConfiguration.isConfigured(
                    engine: engine,
                    whisperModelPath: whisperModelPath,
                    availability: availability
                )
            guard canLoad else { return false }
            return LanguageUtil.supportedLanguages(
                engine: engine,
                fluidAudioModelVersion: fluidAudioModelVersion
            ).contains(language)
        }
    }

    /// The engine one press moves to, or `nil` when a press has nowhere to go.
    ///
    /// `nil` covers exactly two situations and the caller tells them apart by the
    /// cycle being empty: nothing can transcribe, or the only engine that can is
    /// the one already in use.
    ///
    /// An engine that is not in the cycle - a cloud selection that has become
    /// misconfigured, an engine whose weights were deleted while the app ran -
    /// moves to the *first* entry rather than being treated as an error. The user
    /// pressed a key asking for a working engine, and the first one is the answer.
    static func next(after current: EngineKind, in cycle: [EngineKind]) -> EngineKind? {
        guard let first = cycle.first else { return nil }
        guard let index = cycle.firstIndex(of: current) else { return first }
        guard cycle.count > 1 else { return nil }
        return cycle[(index + 1) % cycle.count]
    }

    /// What one press amounts to, before anything is written or shown.
    ///
    /// The mid-dictation rule lives here, in the decision, rather than in the
    /// controller that applies it: a dictation that has started belongs to the
    /// engine it started on, and the words already spoken must be decoded by the
    /// model the user was on when they spoke them. So a press during one is not
    /// refused - refusing would make the shortcut feel broken at the exact moment
    /// someone realises they are on the wrong engine - it is *deferred*, and the
    /// user is told that is what happened.
    static func decide(
        current: EngineKind,
        cycle: [EngineKind],
        isDictationInFlight: Bool
    ) -> EngineSwitchOutcome {
        guard let target = next(after: current, in: cycle) else {
            guard let only = cycle.first else { return .noEngineAvailable }
            return .onlyOneEngine(only)
        }
        return isDictationInFlight ? .deferred(target) : .switched(target)
    }
}

/// One line for the shortcut's overlay, and whether it is about the engine that
/// leaves the Mac.
///
/// The flag is not decoration: the whole app is on-device except for one engine,
/// and a user who has just cycled onto it should be able to see that at a glance
/// rather than by reading a model name. It is a property of the announcement rather
/// than something the view derives from the text, because a view matching on
/// "Cloud" in a string is a rule that breaks the first time the wording changes.
struct EngineSwitchAnnouncement: Equatable {
    let text: String

    /// Whether the engine this is about is `EngineKind.usesCloudProvider`.
    let isCloud: Bool
}

/// What the shortcut's overlay says.
///
/// Kept apart from the view so the wording can be asserted, the same division
/// `CapsuleHUDViewModel` makes for the capsule's messages. Every string here has
/// to survive being read in under two seconds, in the corner of the user's eye,
/// while they carry on typing in another app.
enum EngineSwitchMessage {

    /// How the overlay names an engine.
    ///
    /// The engine's own name comes from `EngineCatalog`, which is the one place
    /// user-facing engine copy lives - and for the two FunASR engines the model
    /// name inside it is a licence obligation, not a label (see
    /// `docs/speech-model-attribution.md`).
    ///
    /// Two engines get more than their name, because their name is not enough to
    /// know what a dictation will run on: Whisper is several files and the cloud
    /// engine is whatever model the provider was asked for.
    static func name(
        for engine: EngineKind,
        whisperModelPath: String?,
        cloudModel: String
    ) -> String {
        switch engine {
        case .cloud:
            let model = cloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "Cloud" : "Cloud - \(model)"
        case .whisper:
            guard let file = whisperModelPath.map({ whisperModelName(path: $0) }), !file.isEmpty else {
                return EngineCatalog.entry(for: .whisper).displayName
            }
            return "\(EngineCatalog.entry(for: .whisper).displayName) - \(file)"
        case .fluidaudio, .sensevoice, .paraformer:
            return EngineCatalog.entry(for: engine).displayName
        }
    }

    /// The line and the flag together, which is what the overlay is handed.
    static func announcement(
        for outcome: EngineSwitchOutcome,
        whisperModelPath: String?,
        cloudModel: String
    ) -> EngineSwitchAnnouncement {
        EngineSwitchAnnouncement(
            text: text(for: outcome, whisperModelPath: whisperModelPath, cloudModel: cloudModel),
            isCloud: engine(in: outcome)?.usesCloudProvider ?? false
        )
    }

    /// The engine an outcome is about, or `nil` for the one outcome that is about
    /// no engine at all.
    private static func engine(in outcome: EngineSwitchOutcome) -> EngineKind? {
        switch outcome {
        case .switched(let engine), .deferred(let engine), .onlyOneEngine(let engine):
            return engine
        case .noEngineAvailable:
            return nil
        }
    }

    static func text(
        for outcome: EngineSwitchOutcome,
        whisperModelPath: String?,
        cloudModel: String
    ) -> String {
        func named(_ engine: EngineKind) -> String {
            name(for: engine, whisperModelPath: whisperModelPath, cloudModel: cloudModel)
        }

        switch outcome {
        case .switched(let engine):
            return "Engine: \(named(engine))"
        // Says both halves: which engine, and that this dictation is not the one
        // it applies to. "Engine: X" alone would be a lie for the words currently
        // being decoded.
        case .deferred(let engine):
            return "Engine: \(named(engine)) after this dictation"
        case .onlyOneEngine(let engine):
            return "\(named(engine)) is the only engine ready"
        case .noEngineAvailable:
            return EngineConfiguration.unavailableShortMessage
        }
    }

    /// `ggml-large-v3-turbo.bin` as `large-v3-turbo`: the part that distinguishes
    /// one Whisper model from another, without the format prefix and extension
    /// every one of them carries.
    private static func whisperModelName(path: String) -> String {
        var name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if name.hasPrefix("ggml-") {
            name.removeFirst("ggml-".count)
        }
        return name
    }
}
