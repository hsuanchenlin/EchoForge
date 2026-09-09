import Foundation

/// Whether an engine's weights may be deleted right now, and what deleting them
/// would cost.
///
/// Deleting model weights is the one destructive action the app offers about its
/// own data, and it has two failure modes that are invisible until afterwards:
/// removing the cache a loaded engine is still reading from, and removing the
/// only engine that can transcribe, which leaves the user with an app that
/// accepts dictation and throws it away. Both are decided here, as a pure
/// function, so both can be asserted without a filesystem.
///
/// This decides; it never acts. `ModelInventoryViewModel` performs the delete,
/// and only after the user has answered whatever `Consequence` this returned.
enum ModelRemoval {

    /// Why removal is refused outright. Each is temporary - the user is told to
    /// come back, not that the button is broken.
    enum Refusal: Error, Equatable {
        /// A transcription is running on this engine. Its CoreML models are
        /// mapped and deleting the files under them is how a decode ends in a
        /// crash rather than in a transcript.
        case engineIsInUse

        /// The weights are being fetched or compiled. Cancel that first -
        /// otherwise the download carries on writing into the directory that was
        /// just deleted, and what is left is the half-cache
        /// `ModelReadiness.incomplete` describes.
        case engineIsBeingPrepared

        /// There is nothing on the disk to remove.
        case nothingInstalled

        /// The engine keeps no weights at all. The cloud engine's model is the
        /// provider's.
        case engineHasNoWeights

        /// The sentence shown instead of the button.
        var message: String {
            switch self {
            case .engineIsInUse:
                return "This engine is transcribing right now. Try again when it has finished."
            case .engineIsBeingPrepared:
                return "This model is being prepared. Cancel that first, then remove it."
            case .nothingInstalled:
                return "There is nothing on the disk to remove."
            case .engineHasNoWeights:
                return "This engine keeps no weights on your Mac."
            }
        }
    }

    /// What the user is told before a removal that is allowed.
    ///
    /// The distinction is not decoration. Removing a model the user is not using
    /// costs them a download if they change their mind; removing the one that is
    /// keeping dictation alive costs them dictation, now, until something is
    /// downloaded again - and the app must say which of those it is *before* the
    /// bytes go.
    enum Consequence: Equatable {
        /// Not the engine dictation is running on. Nothing changes today.
        case none

        /// This is the engine dictation runs on, and `fallback` is what would
        /// take over. Dictation carries on.
        case losesTheActiveEngine(fallback: EngineKind)

        /// This is the last engine that can transcribe anything. Removing it
        /// leaves the app unable to dictate until a model is downloaded again.
        case leavesNothingThatCanTranscribe

        /// The sentence the confirmation asks with.
        func message(for engine: EngineKind) -> String {
            let name = EngineCatalog.entry(for: engine).displayName
            switch self {
            case .none:
                return "Remove the downloaded weights for \(name)? You can download them again "
                    + "later."
            case .losesTheActiveEngine(let fallback):
                return "\(name) is what your dictation is running on. Removing it moves dictation "
                    + "to \(EngineCatalog.entry(for: fallback).displayName). You can download "
                    + "\(name) again later."
            case .leavesNothingThatCanTranscribe:
                return "\(name) is the only engine on this Mac that can transcribe. Removing it "
                    + "means Kongweh cannot dictate until you download a model again."
            }
        }

        /// Whether the confirmation should read as destructive rather than as
        /// housekeeping.
        var isSevere: Bool { self == .leavesNothingThatCanTranscribe }
    }

    /// The decision.
    ///
    /// - Parameters:
    ///   - availability: what is downloaded, as a snapshot. The fallback is
    ///     resolved against this **minus** the engine being removed, which is
    ///     the whole point: "what would still work afterwards" is a different
    ///     question from "what works now".
    ///   - activeEngine: what dictation runs on at this moment
    ///     (`EngineSelection.active`), which is not the same as the engine the
    ///     user chose.
    ///   - preparing: the engine whose weights are being fetched, if any.
    static func decide(
        engine: EngineKind,
        installedBytes: Int64,
        availability: EngineAvailability,
        activeEngine: EngineKind?,
        isTranscribing: Bool,
        preparing: EngineKind?,
        language: String,
        fluidAudioModelVersion: String
    ) -> Result<Consequence, Refusal> {
        if ModelInventory.cacheDirectories(for: engine).isEmpty {
            return .failure(.engineHasNoWeights)
        }
        if preparing == engine { return .failure(.engineIsBeingPrepared) }
        if isTranscribing, activeEngine == engine { return .failure(.engineIsInUse) }
        guard installedBytes > 0 else { return .failure(.nothingInstalled) }

        guard activeEngine == engine else { return .success(.none) }

        var remaining = availability.usableEngines
        remaining.remove(engine)
        let after = EngineAvailability(
            usableEngines: remaining,
            whisperModelPaths: engine == .whisper ? [] : availability.whisperModelPaths,
            cloudTranscriptionRefusal: availability.cloudTranscriptionRefusal
        )

        guard let fallback = EngineConfiguration.recoveryCandidate(
            language: language,
            fluidAudioModelVersion: fluidAudioModelVersion,
            availability: after
        ) else {
            return .success(.leavesNothingThatCanTranscribe)
        }
        return .success(.losesTheActiveEngine(fallback: fallback))
    }
}

/// Which engine this Mac would be best served by, said out loud and never acted
/// on.
///
/// The picker asks a user to choose between four model names before anything has
/// told them what the models are for. This is the missing half of that decision,
/// and its whole contract is in what it does **not** do: it never downloads,
/// never deletes, never writes `selectedEngine`, and never proposes the cloud
/// engine - the same rule `EngineSelector` and `EngineConfiguration.recoveryOrder`
/// keep, for the same reason. It produces a name and a sentence; a person acts.
enum EngineRecommendation {

    /// The Mac this recommendation is for, as a value rather than as three
    /// global reads, so the matrix can be asserted on a machine that is none of
    /// these things.
    struct Machine: Equatable {
        /// The language the user dictates in (`whisperLanguage`), including
        /// `auto`.
        var dictationLanguage: String

        /// The system's own language, used only when the dictation language is
        /// `auto` and so says nothing.
        var systemLanguage: String

        /// Physical RAM. Used for one note and never for the choice itself -
        /// see `memoryNote`.
        var physicalMemoryBytes: UInt64

        /// Whether the user says English and Chinese in one sentence. This is
        /// the one input that overrides everything else, because exactly one
        /// engine can do it at all.
        var mixesEnglishAndChinese: Bool

        var fluidAudioModelVersion: String

        static func current(
            preferences: AppPreferences = .shared,
            processInfo: ProcessInfo = .processInfo
        ) -> Machine {
            Machine(
                dictationLanguage: preferences.whisperLanguage,
                systemLanguage: LanguageUtil.getSystemLanguage(),
                physicalMemoryBytes: processInfo.physicalMemory,
                // Read from the engine the user is actually on rather than from a
                // preference of its own: choosing the bilingual engine is how
                // this app's users say they mix languages, and inventing a
                // second switch for it would ask the same question twice.
                mixesEnglishAndChinese: preferences.selectedEngine.transcribesEnglishAndChineseTogether,
                fluidAudioModelVersion: preferences.fluidAudioModelVersion
            )
        }
    }

    /// Below this, the largest Whisper models are a poor trade on this Mac.
    /// 16 GB is where Apple Silicon stops being able to hold a 1.6 GB model plus
    /// a working set without paging.
    static let comfortableMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// The engine to suggest, and why.
    ///
    /// Order is the product decision, stated once:
    ///
    /// 1. **Mixing English into Chinese** ends the question, because
    ///    `EngineKind.bilingualDictation` is the only engine that does it at all.
    /// 2. **Chinese** gets the Chinese default, which punctuates.
    /// 3. **A language Parakeet covers** gets Parakeet, which is the fastest.
    /// 4. **Everything else** gets Whisper, which is the only engine that does
    ///    every language.
    static func engine(for machine: Machine) -> EngineKind {
        if machine.mixesEnglishAndChinese { return EngineKind.bilingualDictation }
        if isChinese(machine) { return EngineKind.defaultChineseDictation }
        if LanguageUtil.supportedLanguages(
            engine: .fluidaudio, fluidAudioModelVersion: machine.fluidAudioModelVersion
        ).contains(effectiveLanguage(machine)) {
            return .fluidaudio
        }
        return EngineKind.fallback
    }

    /// The sentence beside the recommendation. It names the reason and the cost,
    /// because a recommendation with neither is an instruction.
    static func reason(for machine: Machine) -> String {
        let recommended = engine(for: machine)
        let entry = EngineCatalog.entry(for: recommended)
        let size = entry.download.map { "; about \($0.megabytes) MB" } ?? ""

        if machine.mixesEnglishAndChinese {
            return "Best for English and Chinese in one sentence - the only engine here that "
                + "transcribes both\(size)."
        }
        if isChinese(machine) {
            return "Best for Chinese dictation, and the only Chinese engine that punctuates\(size)."
        }
        if recommended == .fluidaudio {
            return "Fastest for \(languageName(effectiveLanguage(machine))). Pick a model below."
        }
        return "The widest language coverage, which is what \(languageName(effectiveLanguage(machine))) "
            + "needs here. Pick a model below."
    }

    /// The one place the Mac's memory is used, and it is a note rather than a
    /// choice.
    ///
    /// Memory does not decide which *engine* fits - all four run on any Apple
    /// Silicon Mac - it decides whether Whisper's largest models are a good
    /// trade. So it is said where that decision is made and nowhere else, rather
    /// than being folded into a recommendation the user cannot see the reasoning
    /// behind.
    static func memoryNote(for machine: Machine) -> String? {
        guard machine.physicalMemoryBytes < comfortableMemoryBytes else { return nil }
        let gigabytes = Int((Double(machine.physicalMemoryBytes) / 1_073_741_824).rounded())
        return "This Mac has \(gigabytes) GB of memory. Whisper's largest models will run, but a "
            + "smaller one will be markedly faster here."
    }

    private static func effectiveLanguage(_ machine: Machine) -> String {
        machine.dictationLanguage == "auto" ? machine.systemLanguage : machine.dictationLanguage
    }

    private static func isChinese(_ machine: Machine) -> Bool {
        effectiveLanguage(machine) == LanguageUtil.fallbackLanguage(
            engine: EngineKind.defaultChineseDictation)
    }

    private static func languageName(_ code: String) -> String {
        LanguageUtil.languageNames[code] ?? code
    }
}
