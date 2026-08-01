import Foundation

/// What one row of the onboarding model list downloads.
///
/// Whisper and Parakeet name a specific file or model version because each
/// offers several. `engine` names an `EngineKind` instead: engines with exactly
/// one set of weights are described by `EngineCatalog`, and repeating their
/// name, size or caveats here would be the second copy of the copy that
/// `EngineCatalog` exists to prevent.
enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
    case engine(EngineKind)
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0

    /// The catalog entry behind an `engine` row - its notes, download size and
    /// attribution links - and `nil` for the rows that carry their own copy.
    var catalogEntry: EngineCatalogEntry? {
        guard case .engine(let kind) = type else { return nil }
        return EngineCatalog.entry(for: kind)
    }

    /// The language this row exists to serve, or `nil` for a row that serves
    /// every language.
    ///
    /// Taken from `LanguageUtil.fallbackLanguage`, which is already the answer to
    /// "what is this engine for": Paraformer only does Mandarin and SenseVoice is
    /// reached as the Chinese default, so both answer `zh`. It drives two things
    /// - whether the row is offered at all, and which language selecting it
    /// leaves the user on.
    var preferredLanguage: String? {
        switch type {
        case .whisper, .parakeet:
            return nil
        case .engine(let kind):
            return LanguageUtil.fallbackLanguage(engine: kind)
        }
    }

    /// The badge shown beside the name, or `nil` for a row the app has no
    /// opinion about.
    ///
    /// Only one row carries it, and which one is `EngineKind`'s decision rather
    /// than this file's: `defaultChineseDictation` is where the app states what
    /// it recommends for Chinese and why.
    var recommendation: String? {
        guard case .engine(let kind) = type, kind == EngineKind.defaultChineseDictation else { return nil }
        return "Recommended for Chinese"
    }

    /// What the row costs to download, for the rows that know. `nil` for Whisper
    /// and Parakeet, whose sizes onboarding has never shown.
    var downloadMegabytes: Int? {
        catalogEntry?.download?.megabytes
    }

    /// The line under the row: what the user is waiting for, or would be.
    ///
    /// Only engine rows have one, and it deliberately states the cold start
    /// twice over - the download, then the one-time Neural Engine compile -
    /// because the compile is invisible, takes about a minute, and is otherwise
    /// indistinguishable from the app having hung. Nothing here promises an
    /// instant first transcription, because there is not one.
    func status(isBusy: Bool, isCompiling: Bool) -> String? {
        guard let download = catalogEntry?.download else { return nil }
        if isBusy {
            return isCompiling
                ? "Preparing for the Neural Engine. This takes about a minute the first time."
                : "Downloading \(formatModelSize(megabytes: download.megabytes))…"
        }
        if isDownloaded {
            return "Downloaded and ready."
        }
        // The size is already on the button beside this, so it is not repeated.
        return "Downloads now, then spends about a minute preparing for the Neural Engine "
            + "before your first dictation."
    }

    /// The engine this row selects.
    var engineKind: EngineKind {
        switch type {
        case .whisper: return .whisper
        case .parakeet: return .fluidaudio
        case .engine(let kind): return kind
        }
    }

    /// The language onboarding should be left on once this row is chosen:
    /// `selected` if the engine can do it, and the engine's own fallback if it
    /// cannot.
    ///
    /// Settings has applied this rule since it gained an engine picker
    /// (`resetLanguageIfUnsupported`); onboarding never did, and it matters more
    /// now that a row can be Mandarin-only. Paraformer does not refuse other
    /// languages, it mis-transcribes them, so leaving the picker on German while
    /// Paraformer is selected would be a promise the first dictation breaks.
    func language(after selected: String, fluidAudioModelVersion: String) -> String {
        let supported = LanguageUtil.supportedLanguages(
            engine: engineKind,
            fluidAudioModelVersion: fluidAudioModelVersion
        )
        return supported.contains(selected) ? selected : LanguageUtil.fallbackLanguage(engine: engineKind)
    }

    var huggingFacePageURL: URL? {
        switch type {
        case .whisper(let url, _):
            return makeHuggingFacePageURL(fromDownloadURL: url)
        case .parakeet(let version):
            let repo = version == "v2" ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
            return URL(string: "https://huggingface.co/FluidInference/\(repo)")
        case .engine:
            // The catalog's own links are richer than one repo URL - a model
            // card, the licence and the conversion - and the row renders all
            // three, so there is nothing to duplicate here.
            return nil
        }
    }

    init(name: String, isDownloaded: Bool, description: String, type: OnboardingModelType) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.description = description
        self.type = type
    }

    /// A row for an engine that has exactly one set of weights.
    ///
    /// The name and the one-line summary come from `EngineCatalog` rather than
    /// being written again here. That is a licence matter as much as a tidiness
    /// one: FunASR Model Open Source License v1.1 §2.2 requires the model name to
    /// survive into the UI, and a hand-written onboarding name is exactly how it
    /// would stop doing so.
    init(engine kind: EngineKind) {
        let entry = EngineCatalog.entry(for: kind)
        self.name = entry.displayName
        self.isDownloaded = false
        self.description = entry.summary
        self.type = .engine(kind)
    }
}

struct OnboardingUnifiedModels {
    /// The rows, in the order they are offered.
    ///
    /// The two Chinese engines lead, and are hidden unless the user is actually
    /// dictating Chinese (`isVisible`). Ordering them first is the
    /// recommendation: a user who has just chosen Chinese at the top of this
    /// screen should meet `EngineKind.defaultChineseDictation` before the five
    /// general-purpose models, not below them. For everyone else the list is
    /// unchanged.
    static let availableModels = [
        OnboardingUnifiedModel(engine: EngineKind.defaultChineseDictation),
        OnboardingUnifiedModel(engine: EngineKind.chineseAccuracyAlternative),
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]

    /// Whether a row belongs in front of this user.
    ///
    /// The same rule Settings already applies to the Hebrew fine-tune
    /// (`SettingsDownloadableModels.isVisible`): a row that exists for one
    /// language is offered to the people dictating that language, and to anyone
    /// who has already downloaded it, because hiding a downloaded model would
    /// hide a choice the user already made. Everything else is always offered.
    ///
    /// This is what keeps ~900 MB of Mandarin-only models off an English user's
    /// first screen while still putting them first for a Chinese one.
    static func isVisible(_ model: OnboardingUnifiedModel,
                          selectedLanguage: String,
                          systemLanguage: String) -> Bool {
        guard let language = model.preferredLanguage else { return true }
        if model.isDownloaded { return true }
        return selectedLanguage == language || systemLanguage == language
    }
}
