import Foundation

/// One link the app owes a model it downloads but does not own.
///
/// Not decoration. The FunASR Model Open Source License v1.1 §2.2 requires
/// attributing the source and author and retaining the model name, so a Chinese
/// engine that ships without a reachable model card, licence and conversion-repo
/// link is a licence problem rather than a documentation gap.
/// `docs/speech-model-attribution.md` is the long form; this is the in-app
/// equivalent that file says it needs.
struct ModelAttributionLink: Identifiable, Hashable {
    let label: String
    let url: URL

    var id: URL { url }
}

/// What the app fetches for an engine whose weights it downloads whole.
///
/// Only engines with exactly one set of weights have this. Whisper and Parakeet
/// offer several models each and keep their own download rows.
struct EngineModelDownload {
    /// The upstream model name, retained verbatim because the licence requires
    /// it - this is the string §2.2 means, and it must survive any later
    /// rewording of the copy around it.
    let modelName: String

    /// Roughly what a cold machine fetches, in decimal MB, as measured against
    /// the pinned FluidAudio rather than read off a config constant.
    let megabytes: Int

    /// Where `initialize()` puts it, so Settings can show and reveal it.
    let cacheDirectory: URL
}

/// Everything a user needs in order to choose an engine, written once.
///
/// Settings and onboarding are separate surfaces describing the same engines,
/// and the parts worth keeping honest - Paraformer emits no punctuation,
/// SenseVoice rewrites spoken numbers, both models write Simplified Chinese - are
/// exactly the parts a second, hand-written copy of the copy quietly drops. So
/// the copy lives next to the engines it describes.
///
/// Nothing here is a marketing claim. Each note is a measured property of the
/// pinned model; provenance is in the engine's own documentation comment,
/// `docs/upstream-issues.md` and `docs/speech-model-attribution.md`.
struct EngineCatalogEntry {
    /// Shown in the picker. For the two FunASR engines this keeps the upstream
    /// model name inside it, which the model licence requires and which is why
    /// "Chinese (fast)" would not be an acceptable rename.
    let displayName: String

    /// One line, shown under the name in the picker row.
    let summary: String

    /// Credit line for a model the app did not train. `nil` for engines whose
    /// individual model rows already carry their own attribution.
    let attributionCredit: String?

    /// The honest parts. Each is a sentence a user would rather read here than
    /// discover in their own transcript.
    let notes: [String]

    /// `nil` when the engine's weights are picked model by model instead.
    let download: EngineModelDownload?

    let attribution: [ModelAttributionLink]
}

/// The engine descriptions, and the order they are offered in.
enum EngineCatalog {

    /// Picker order, which is deliberately not `EngineKind.allCases`.
    ///
    /// `allCases` is declaration order - a storage concern - and it puts
    /// Paraformer above SenseVoice. Here the two general-purpose engines come
    /// first because most users want one of them, and among the Chinese pair the
    /// default (`EngineKind.defaultChineseDictation`) is offered before the
    /// alternative it is the default over.
    ///
    /// `EngineKind.cloud` is deliberately absent, and its absence is a product
    /// decision rather than an omission: every row in this picker can be selected
    /// with one tap, and one tap must not be all it takes to start sending
    /// dictation to a company. The cloud engine is first selected from the Cloud
    /// pane, where the consent sheet is (`CloudConsent`), and the picker shows a
    /// banner saying so while it is the engine in use; only after that consent
    /// does the engine shortcut offer it (`EngineCycle`). `EngineCatalogTests`
    /// pins this.
    static let pickerOrder: [EngineKind] = [
        .whisper, .fluidaudio, EngineKind.defaultChineseDictation, EngineKind.chineseAccuracyAlternative,
    ]

    /// Switched exhaustively on purpose: a new engine has to say how it presents
    /// itself rather than inheriting someone else's description.
    static func entry(for kind: EngineKind) -> EngineCatalogEntry {
        switch kind {
        case .whisper: return whisper
        case .fluidaudio: return parakeet
        case .sensevoice: return senseVoice
        case .paraformer: return paraformer
        case .cloud: return cloud
        }
    }

    /// Both Chinese engines installed at once, for the one figure a user
    /// comparing them actually asks for. 240 + 653, and it is not a coincidence
    /// that it is worth stating: they are separate downloads and keeping both
    /// costs both.
    static var bothChineseEnginesMegabytes: Int {
        SenseVoiceEngine.approximateDownloadMegabytes + ParaformerEngine.approximateDownloadMegabytes
    }

    /// The engine to suggest for `language`, or `nil` when the selected engine
    /// is already a reasonable answer.
    ///
    /// This is where `EngineKind.defaultChineseDictation` becomes visible to a
    /// user who never sees onboarding: picking Chinese while on Whisper is a
    /// legitimate choice, not a mistake, so this offers the default rather than
    /// switching to it. Only Chinese has a specialised engine to offer, which is
    /// why nothing else does.
    static func suggestedEngine(forLanguage language: String, selected: EngineKind) -> EngineKind? {
        guard language == "zh" else { return nil }
        guard selected != EngineKind.defaultChineseDictation,
            selected != EngineKind.chineseAccuracyAlternative
        else { return nil }
        return EngineKind.defaultChineseDictation
    }

    // MARK: - The bilingual path

    /// The engine to name to someone who dictates English and Chinese in one
    /// sentence, and the two sentences Settings says it in.
    ///
    /// It is a statement rather than a suggestion, which is why it has no
    /// `selected:` parameter the way `suggestedEngine(forLanguage:selected:)`
    /// does. The engine rows are directly above it and each is one tap; what a
    /// user cannot work out from four names is *which* of them survives a
    /// sentence that switches language halfway through, and that is the only
    /// thing this says. Shown unconditionally for the same reason - a user who
    /// has not started mixing languages yet is exactly the one who does not know
    /// the app can.
    ///
    /// The name is read from the entry rather than written out, so the model
    /// name the FunASR licence requires cannot be dropped from this surface
    /// while it survives in the picker (`docs/speech-model-attribution.md`).
    static var bilingualHint: String {
        "Mixed English and Chinese: use \(entry(for: EngineKind.bilingualDictation).displayName)"
    }

    /// The second line, which is what makes the first one a fact rather than a
    /// preference: the other three local engines do not have a worse answer
    /// here, they have no answer.
    static let bilingualHintDetail =
        "It is the only engine here that transcribes both in one recording - Whisper settles on one "
        + "language per recording, Parakeet has no Chinese, and Paraformer refuses English rather "
        + "than guess at it. Your Chinese still comes out in the script you chose."

    /// Where this engine's weights came from, in the sentence that follows the
    /// credit line.
    ///
    /// It is not decoration and it is not always the same. Until a build shipped
    /// with a starter model, the honest answer for every engine was "downloaded
    /// to your Mac, not bundled with the app" - and that sentence was itself part
    /// of the licence position recorded in `docs/speech-model-attribution.md`. A
    /// build that packages the starter weights redistributes them, which is a
    /// different claim, so it makes a different one rather than leaving the old
    /// sentence standing where it is no longer true.
    ///
    /// - Parameter isBundled: whether *this build* carries the weights. Asked of
    ///   `StarterModel` rather than assumed, because the same source produces
    ///   builds with and without them.
    static func provenanceLine(for kind: EngineKind,
                               isBundled: Bool = StarterModel.isBundledWithThisBuild) -> String {
        guard isBundled, kind == StarterModel.engine else {
            return "Downloaded to your Mac, not bundled with the app."
        }
        return "Included with this build of Kongweh and installed on your Mac on first launch, "
            + "under the model licence linked below."
    }

    /// The engine's language scope, phrased for a settings row.
    ///
    /// Derived from `LanguageUtil` rather than written out, because the language
    /// picker collapses to the same list: a hand-written summary here is a
    /// second source of truth that would eventually disagree with the control
    /// directly below it.
    static func languageSummary(for kind: EngineKind, fluidAudioModelVersion: String) -> String {
        let codes = LanguageUtil.supportedLanguages(engine: kind, fluidAudioModelVersion: fluidAudioModelVersion)
        let auto = codes.contains("auto")
        let named = codes.filter { $0 != "auto" }

        // Short lists read better named than counted, and both Chinese engines
        // are short lists - which is the point of showing this at all.
        let body: String
        if named.count == 1 {
            body = "\(displayName(named[0])) only"
        } else if named.count <= 6 {
            body = named.map(displayName).joined(separator: ", ")
        } else {
            body = "\(named.count) languages"
        }
        return auto ? "\(body), or auto-detect" : body
    }

    // MARK: - Private

    /// `zh` is "Chinese" in the language picker, which is the right label while
    /// it is the only Chinese entry there. In a summary that also lists
    /// Cantonese it is not - both are Chinese - so the summary says Mandarin.
    private static let summaryLanguageNames = ["zh": "Mandarin"]

    private static func displayName(_ code: String) -> String {
        summaryLanguageNames[code] ?? LanguageUtil.languageNames[code] ?? code
    }

    /// The one engine that is not on this Mac.
    ///
    /// Its notes are the disclosure, not a feature list, and they are written to
    /// the same standard as the two Chinese engines' - each one is a thing a user
    /// would rather read here than discover afterwards. The first is the one that
    /// matters: this is the only engine in the app for which the audio leaves the
    /// machine, and no amount of surrounding copy may bury that.
    private static let cloud = EngineCatalogEntry(
        displayName: "Cloud (OpenAI-compatible)",
        summary: "Transcribes with a provider you choose, using your own API key. Off unless you turn it on.",
        attributionCredit: nil,
        notes: [
            "Your recordings are uploaded to the provider you configure. Nothing else in Kongweh "
                + "sends audio anywhere.",
            "You need an account and an API key with that provider, and they bill you for what you use.",
            "It needs a working connection. With none, the dictation fails and the recording is kept "
                + "so it can be transcribed later.",
            "Recordings over 25 MB - about thirteen minutes of dictation - are refused before upload.",
        ],
        download: nil,
        attribution: []
    )

    private static let whisper = EngineCatalogEntry(
        displayName: "Whisper",
        summary: "General purpose, and the widest language coverage. Pick a model below.",
        attributionCredit: nil,
        notes: [],
        download: nil,
        attribution: []
    )

    private static let parakeet = EngineCatalogEntry(
        displayName: "Parakeet",
        summary: "Fastest, for English and European languages. Pick a model below.",
        attributionCredit: nil,
        notes: [],
        download: nil,
        attribution: []
    )

    /// The Chinese default. Every note is reproduced by
    /// `SenseVoiceEngineIntegrationTests` against the real weights.
    private static let senseVoice = EngineCatalogEntry(
        displayName: "SenseVoice-Small",
        summary: "The default for Chinese, and the one to use when you mix English into Mandarin. "
            + "Punctuates, and also handles Cantonese, Japanese and Korean.",
        attributionCredit: "SenseVoiceSmall by FunASR / FunAudioLLM",
        notes: [
            // The wording of this one matters. Punctuation and inverse text
            // normalisation are a single switch in the pinned runtime, so the
            // conversion cannot be declined; and the meaning-changing failure it
            // can cause is real but was not reproducible here, so this says
            // "occasionally" rather than quoting an example that did not
            // reproduce. See docs/upstream-issues.md.
            "Adds punctuation, and writes spoken numbers as digits - say 三點二十分 and it transcribes 3點20分. "
                + "Upstream these are one switch, so punctuation is not available without the conversion, "
                + "and it can occasionally turn a bare numeral into the wrong number.",
            "The model writes Simplified Chinese; Kongweh writes your transcript in Traditional "
                + "unless you choose otherwise in Settings \u{2192} Transcription.",
            "About 8x faster than real time, so a 30-second recording takes a few seconds.",
            // The bilingual note. It is last because it is the one a user goes
            // looking for rather than trips over, and it is here at all because
            // no other local engine can do it - see `EngineKind.bilingualDictation`.
            "English and Chinese in one sentence stay in one sentence - say 把 PR 開到 feature/login "
                + "再 @James and the English words come back as they were, while the Chinese half is "
                + "written in your chosen script. No other engine here transcribes both at once.",
        ],
        download: EngineModelDownload(
            modelName: "SenseVoiceSmall",
            megabytes: SenseVoiceEngine.approximateDownloadMegabytes,
            cacheDirectory: SenseVoiceEngine.modelCacheDirectory
        ),
        attribution: [
            ModelAttributionLink(
                label: "Model card",
                url: URL(string: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall")!
            ),
            ModelAttributionLink(
                label: "Model licence",
                url: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!
            ),
            ModelAttributionLink(
                label: "CoreML conversion",
                url: URL(string: "https://huggingface.co/FluidInference/sensevoice-small-coreml")!
            ),
        ]
    )

    /// The accuracy alternative. Every note is reproduced by
    /// `ParaformerEngineIntegrationTests` against the real weights.
    private static let paraformer = EngineCatalogEntry(
        displayName: "Paraformer-large (zh)",
        summary: "More accurate on Mandarin characters, at the price of Mandarin only and no punctuation.",
        attributionCredit: "Paraformer-large (zh) by FunASR / FunAudioLLM",
        notes: [
            "Produces no punctuation at all - its vocabulary contains none, and nothing here invents any.",
            "Mandarin only, and the model refuses nothing - so English comes back as tokeniser fragments. "
                + "Kongweh catches those and keeps the recording instead of inserting them, leaving you to "
                + "switch engine and regenerate. If you mix English into Mandarin, use "
                + "\(EngineCatalog.entry(for: EngineKind.bilingualDictation).displayName) instead.",
            "Cantonese is the case nothing can catch: it comes back as fluent but wrong Mandarin, which reads "
                + "like a real transcript.",
            "The model writes Simplified Chinese - Kongweh writes your transcript in the script you "
                + "chose - and it spells numbers as spoken: 三點二十分, not 3點20分.",
            "Long recordings are split into short pieces before the model sees them, because it silently "
                + "truncates anything longer.",
        ],
        download: EngineModelDownload(
            modelName: "Paraformer-large (zh)",
            megabytes: ParaformerEngine.approximateDownloadMegabytes,
            cacheDirectory: ParaformerEngine.modelCacheDirectory
        ),
        attribution: [
            ModelAttributionLink(
                label: "Model card",
                url: URL(
                    string:
                        "https://www.modelscope.cn/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
                )!
            ),
            ModelAttributionLink(
                label: "Model licence",
                url: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!
            ),
            ModelAttributionLink(
                label: "CoreML conversion",
                url: URL(string: "https://huggingface.co/FluidInference/paraformer-large-zh-coreml")!
            ),
        ]
    )
}
