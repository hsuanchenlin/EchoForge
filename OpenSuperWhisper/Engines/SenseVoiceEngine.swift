import Foundation
import FluidAudio

/// The single FluidAudio-backed transcription call this engine makes, behind a
/// protocol.
///
/// It exists so the chunking and joining loop - the part of this engine that can
/// silently lose or mangle a user's words - is testable without 240 MB of
/// downloaded weights. The production conformer is `SenseVoiceCoreMLTranscriber`
/// (`SenseVoiceDecoding.swift`); `SenseVoiceManager` remains for the integration
/// test that pins the app-side decode to upstream's output.
protocol SenseVoiceTranscribing {
    func transcribe(audio: [Float]) async throws -> String
}

/// How the model is to be configured for one recording.
///
/// Both fields are encoder *inputs*, not load-time settings, which is why they
/// are a separate value from the weights: switching language costs a struct, not
/// a reload.
struct SenseVoiceModelOptions: Equatable {
    let language: SenseVoiceLanguage

    /// Text-normalisation embed index. See `SenseVoiceEngine.textNorm`.
    let textNorm: Int32
}

/// Builds a configured transcriber over weights that are already loaded.
///
/// The split matters: loading costs a ~240 MB download and a one-time Neural
/// Engine compile of about 90 s, while configuring costs nothing. So
/// `initialize()` loads once and each recording configures.
protocol SenseVoiceTranscriberFactory {
    func makeTranscriber(_ options: SenseVoiceModelOptions) -> SenseVoiceTranscribing
}

/// SenseVoice-Small, by FunASR/FunAudioLLM, run through the FluidAudio version
/// this app already pins - no new dependency, no second ML runtime, and no
/// bundled weights. Attribution and licence live in
/// `docs/speech-model-attribution.md`.
///
/// This is the default Chinese dictation engine (`EngineKind.defaultChineseDictation`).
/// What it buys over Paraformer is punctuation and more than Mandarin; what it
/// costs is speed. Four measured properties shape the implementation, all taken
/// from the pinned FluidAudio 0.15.4 rather than read off its config constants:
///
/// - **It cannot be handed a whole recording.** The CoreML preprocessor accepts
///   3,200...480,000 samples (0.2...30.0 s) and *throws* outside that, so every
///   recording goes through `AudioChunkSource` with the shared
///   `.senseVoiceSmall` budget. `SenseVoiceConfig.maxFrames = 1800` (~108 s) is
///   unreachable from the audio path; do not design around it.
/// - **It has no no-speech gate.** 30 s of digital silence transcribes as `我.`.
///   The empty chunk list `AudioChunkSource` returns for silence is therefore an
///   empty transcript, never a padded call.
/// - **Its punctuation is a decode-time flag that is off by default.** See
///   `textNorm` - this is the one-line, silent way to ship the wrong engine.
/// - **Its decode is app-owned.** The pinned FluidAudio decodes fp16 logits one
///   boxed `NSNumber` per element - over 90 % of a warm transcription's wall
///   time (~20 s of a 36 s recording, sampled in the shipped app; far worse
///   under memory pressure). `SenseVoiceCoreMLTranscriber` runs the same three
///   model stages and decodes with a vDSP argmax instead
///   (`SenseVoiceDecoding.swift`), the same fix upstream later made on main;
///   the integration tests pin the two outputs byte-for-byte. Progress is
///   still reported per chunk.
final class SenseVoiceEngine: TranscriptionEngine {
    var engineName: String { "SenseVoice" }

    /// int8 encoder. Byte-identical output to fp16 on CJK in testing, half the
    /// RAM, same speed - and unlike Paraformer, precision here also halves the
    /// download, because SenseVoice's repo is variant-filtered: 240 MB rather
    /// than 473 MB. Switching precision later *adds* to the cache and re-pays
    /// the Neural Engine compile, so this is not a setting to offer lightly.
    private static let precision: SenseVoiceEncoderPrecision = .int8

    /// `14` = withitn: punctuation **and** inverse text normalisation.
    ///
    /// Fixed, deliberately, and not a user setting. In FluidAudio 0.15.4 the two
    /// are one switch - `15` = neither, and there is no third value - so the
    /// choice is "punctuated text with Arabic numerals" or "no punctuation at
    /// all", and punctuation is the whole reason this engine is the Chinese
    /// default. `SenseVoiceConfig.defaultTextNorm` is `15`, and
    /// `SenseVoiceManager.load()` hardcodes it, which is why this engine
    /// constructs the manager directly: taking the convenient entry point ships
    /// an unpunctuated engine and nothing fails to make that visible.
    ///
    /// The cost is honest and worth stating: ITN is right on times, prices and
    /// dates (`3点20分`, `1250块钱`, `2026年7月30号`) but can silently change a
    /// bare Chinese numeral into the wrong value. No heuristic here tries to
    /// undo that - it is one model switch, and rewriting model output to guess
    /// at it would be worse. The observed, non-universal failure is documented
    /// in `docs/upstream-issues.md`.
    static let textNorm: Int32 = 14

    private static let modelLoadCoordinator = ModelLoadCoordinator<SenseVoiceTranscriberFactory>()

    /// Where `initialize()` downloads to, for anything that has to show or clear
    /// the ~240 MB the user paid for.
    ///
    /// Asked of FluidAudio rather than rebuilt from the repo slug, because the
    /// two differ: `Repo.folderName` strips `-coreml`, so the cache is
    /// `sensevoice-small`, not `sensevoice-small-coreml`.
    static var modelCacheDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall)
    }

    /// What a cold machine fetches, in decimal MB, for Settings to state before
    /// the user commits to it.
    ///
    /// Kept next to `precision` because it is a consequence of it: this repo is
    /// variant-filtered on Hugging Face, so precision decides the *download* and
    /// not just the load - 240 MB of int8 against 473 MB of fp16. Measured
    /// against the pinned FluidAudio, not read off a manifest.
    static let approximateDownloadMegabytes = 240

    /// Whether `initialize()` would be a warm load rather than a download.
    static var isModelDownloaded: Bool {
        SenseVoiceModels.modelsExist(at: modelCacheDirectory, precision: precision)
    }

    /// The entries `modelCacheDirectory` has to contain for `isModelDownloaded`
    /// to be true, as file names.
    ///
    /// Exists so `StarterModel` can install the weights that ship with the app
    /// without holding a second opinion about which files those are - the
    /// encoder among them is decided by `precision`, which is private on
    /// purpose. `SenseVoiceModels.modelsExist` is the authority and this list is
    /// pinned against it by `StarterModelTests`.
    static var requiredCacheEntries: [String] {
        let encoder: String
        switch precision {
        case .fp16: encoder = ModelNames.SenseVoice.encoderFile
        case .int8: encoder = ModelNames.SenseVoice.encoderInt8File
        case .fp32: encoder = ModelNames.SenseVoice.encoderFp32File
        }
        return [
            ModelNames.SenseVoice.preprocessorFile,
            encoder,
            ModelNames.SenseVoice.vocabularyFile,
        ]
    }

    /// Downloads the weights and pays the Neural Engine compile up front.
    ///
    /// The same work `initialize()` does, offered at a moment the user chose
    /// rather than in the middle of their first dictation - which is otherwise
    /// about four minutes of a recording apparently doing nothing. The loaded
    /// models are discarded because the point is the populated cache; the
    /// engine's own load afterwards is ~0.15 s.
    static func prepareModels(progressHandler: @escaping DownloadUtils.ProgressHandler) async throws {
        _ = try await modelLoadCoordinator.run(progressHandler: progressHandler) {
            try await loadFluidAudioModels()
        }
    }

    private let chunkSource: AudioChunkProviding
    private let loadFactory: () async throws -> SenseVoiceTranscriberFactory

    private var factory: SenseVoiceTranscriberFactory?
    private let abortFlag = AbortFlag()

    var onProgressUpdate: ((Float) -> Void)?

    var isModelLoaded: Bool { factory != nil }

    /// - Parameters:
    ///   - chunkSource: the shared decode/VAD/chunk path. One instance per
    ///     engine, so the VAD model is loaded once rather than per recording.
    ///   - loadFactory: how `initialize()` obtains the weights. Injected only by
    ///     tests; production always downloads from Hugging Face at runtime.
    init(
        chunkSource: AudioChunkProviding = AudioChunkSource(),
        loadFactory: @escaping () async throws -> SenseVoiceTranscriberFactory = SenseVoiceEngine.loadFluidAudioModels
    ) {
        self.chunkSource = chunkSource
        self.loadFactory = loadFactory
    }

    /// Downloads the weights on first use and loads them onto the Neural Engine.
    ///
    /// Both halves are slow the first time - about 240 MB of int8 weights, then
    /// a one-time Neural Engine compile of roughly 90 s during which nothing is
    /// downloading and nothing is printing - and neither is bundled into the
    /// app: the CoreML conversion asserts no licence of its own, so the user
    /// fetches it from Hugging Face directly. Warm loads are ~0.15 s.
    func initialize() async throws {
        factory = try await Self.modelLoadCoordinator.run(loadFactory)
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let factory else {
            throw TranscriptionError.contextInitializationFailed
        }

        abortFlag.isSet = false
        onProgressUpdate?(0.02)

        let chunks = try await chunkSource.chunks(for: url, budget: .senseVoiceSmall)
        try checkCancellation()

        // No speech: the model would answer silence with hallucinated text.
        guard !chunks.isEmpty else {
            onProgressUpdate?(1.0)
            return ""
        }

        onProgressUpdate?(0.05)

        let transcriber = factory.makeTranscriber(
            SenseVoiceModelOptions(
                language: SenseVoiceLanguage(languageCode: settings.selectedLanguage),
                textNorm: Self.textNorm
            )
        )

        // Per chunk, because that is the only honest progress available: one
        // transcriber call is atomic from here.
        // The pieces are joined by `CommittedTranscript`, which owns the seam
        // rule (Han-Han without a space, Latin-Latin with one) and drops a
        // chunk that decoded to nothing. Shared transcript post-processing
        // runs once afterwards, in TextPostProcessor via TranscriptionService.
        var transcript = CommittedTranscript()
        for (index, chunk) in chunks.enumerated() {
            try checkCancellation()
            transcript.append(try await transcriber.transcribe(audio: chunk.samples))
            onProgressUpdate?(0.05 + 0.90 * Float(index + 1) / Float(chunks.count))
        }

        try checkCancellation()

        onProgressUpdate?(1.0)
        return transcript.text
    }

    func cancelTranscription() {
        abortFlag.isSet = true
    }

    func getSupportedLanguages() -> [String] {
        LanguageUtil.supportedLanguages(
            engine: .sensevoice,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
    }

    /// The production `loadFactory`. Not private only because it is this
    /// initialiser's default argument.
    static func loadFluidAudioModels() async throws -> SenseVoiceTranscriberFactory {
        FluidAudioSenseVoiceFactory(
            models: try await loadFluidAudioModelWeights()
        )
    }

    /// The raw loaded weights, exposed for the integration test that pins the
    /// app-side decode against FluidAudio's own manager on the same tensors.
    static func loadFluidAudioModelWeights() async throws -> SenseVoiceModels {
        try await SenseVoiceModels.downloadAndLoad(
            precision: precision,
            progressHandler: { progress in
                Task { await modelLoadCoordinator.reportProgress(progress) }
            }
        )
    }

    // MARK: - Private

    private func checkCancellation() throws {
        if abortFlag.isSet { throw CancellationError() }
        try Task.checkCancellation()
    }
}

/// The production factory: one set of loaded weights, configured per recording.
///
/// Builds the app's own transcriber rather than FluidAudio's `SenseVoiceManager`
/// because the pinned manager's fp16 decode is the transcription's dominant cost
/// by an order of magnitude - see `SenseVoiceGreedyDecode`.
private struct FluidAudioSenseVoiceFactory: SenseVoiceTranscriberFactory {
    let models: SenseVoiceModels

    func makeTranscriber(_ options: SenseVoiceModelOptions) -> SenseVoiceTranscribing {
        SenseVoiceCoreMLTranscriber(
            models: models,
            language: options.language.embedIndex,
            textNorm: options.textNorm
        )
    }
}
