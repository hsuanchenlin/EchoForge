import Foundation
import FluidAudio

/// The single FluidAudio call this engine makes, behind a protocol.
///
/// It exists so the chunking loop - the part of this engine that can silently
/// lose a user's words - is testable without 653 MB of downloaded weights.
/// `ParaformerManager` is the only production conformer.
protocol ParaformerTranscribing {
    func transcribe(audio: [Float]) async throws -> String
}

extension ParaformerManager: ParaformerTranscribing {}

/// Paraformer-large (zh), by FunASR/FunAudioLLM, run through the FluidAudio
/// version this app already pins - no new dependency and no bundled weights.
/// Attribution and licence live in `docs/speech-model-attribution.md`.
///
/// Three things about this model shape the engine, all measured on the pinned
/// FluidAudio 0.15.4 rather than read off its config constants:
///
/// - **It cannot be handed a whole recording.** The shared CoreML preprocessor
///   accepts 3,200...480,000 samples (0.2...30.0 s) and *throws* outside that,
///   and the decoder's fixed `[1, 128, 8404]` output shape clamps to 128 tokens
///   with no log and no error - which on dense Mandarin binds after ~18-21 s,
///   well before the 30 s ceiling. A 28.1 s clip came back as 127 characters of
///   a 200-character script, degenerating into repetition, at 35.8 % CER; the
///   same clip chunked measured 0.53 %. So every recording goes through
///   `AudioChunkSource` with the token-derived `.paraformerZh` budget, and the
///   engine never calls the model with anything it did not chunk.
/// - **It is Mandarin-only and degrades silently.** English leaks raw `@@` BPE
///   continuation markers and Cantonese comes back as plausible-looking but
///   wrong Mandarin, so the language is hard-locked to `zh` in `LanguageUtil`
///   rather than left to degrade.
/// - **It has no no-speech gate.** 30 s of digital silence transcribes as
///   `嗯嗯嗯嗯嗯…`. The empty chunk list `AudioChunkSource` returns for silence is
///   therefore an empty transcript, never a padded call.
///
/// The output is bare characters: vocab8404 carries no punctuation, so this
/// engine emits none and nothing here invents any.
final class ParaformerEngine: TranscriptionEngine {
    var engineName: String { "Paraformer" }

    /// int8 encoder/decoder. Byte-identical output to fp16 on CJK in testing,
    /// half the RAM, same speed. It does not change the download: unlike
    /// SenseVoice, Paraformer's repo is fetched whole (~653 MB) whatever
    /// precision is asked for, so precision is a load-time choice only.
    private static let precision: ParaformerPrecision = .int8

    /// Where `initialize()` downloads to, for anything that has to show or clear
    /// the ~653 MB the user paid for.
    ///
    /// Asked of FluidAudio rather than rebuilt from the repo slug, because the
    /// two differ: `Repo.folderName` strips `-coreml`, so the cache is
    /// `paraformer-large-zh`, not `paraformer-large-zh-coreml`.
    static var modelCacheDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .paraformerLargeZh)
    }

    /// What a cold machine fetches, in decimal MB, for Settings to state before
    /// the user commits to it.
    ///
    /// Unlike SenseVoice this does not vary with `precision`: the repo is
    /// fetched whole, both precisions included, whatever is asked for. So there
    /// is one download row here and no smaller number to advertise.
    static let approximateDownloadMegabytes = 653

    /// Whether `initialize()` would be a warm load rather than a download.
    static var isModelDownloaded: Bool {
        ParaformerModels.modelsExist(at: modelCacheDirectory, precision: precision)
    }

    /// Downloads the weights and pays the Neural Engine compile up front.
    ///
    /// The same work `initialize()` does, offered at a moment the user chose
    /// rather than in the middle of their first dictation. The loaded models are
    /// discarded because the point is the populated cache; the engine's own load
    /// afterwards is ~0.15 s.
    static func prepareModels(progressHandler: @escaping DownloadUtils.ProgressHandler) async throws {
        _ = try await ParaformerModels.downloadAndLoad(precision: precision, progressHandler: progressHandler)
    }

    private let chunkSource: AudioChunkProviding
    private let loadTranscriber: () async throws -> ParaformerTranscribing

    private var transcriber: ParaformerTranscribing?
    private let abortFlag = AbortFlag()

    var onProgressUpdate: ((Float) -> Void)?

    var isModelLoaded: Bool { transcriber != nil }

    /// - Parameters:
    ///   - chunkSource: the shared decode/VAD/chunk path. One instance per
    ///     engine, so the VAD model is loaded once rather than per recording.
    ///   - loadTranscriber: how `initialize()` obtains the model. Injected only
    ///     by tests; production always downloads from Hugging Face at runtime.
    init(
        chunkSource: AudioChunkProviding = AudioChunkSource(),
        loadTranscriber: @escaping () async throws -> ParaformerTranscribing = ParaformerEngine.loadFluidAudioModels
    ) {
        self.chunkSource = chunkSource
        self.loadTranscriber = loadTranscriber
    }

    /// Downloads the weights on first use and loads them onto the Neural Engine.
    ///
    /// Both halves are slow the first time - roughly 653 MB of repo, then a
    /// one-time ANE compile of about a minute - and neither is bundled into the
    /// app: the CoreML conversion asserts no licence of its own, so the user
    /// fetches it from Hugging Face directly. Warm loads are ~0.15 s.
    func initialize() async throws {
        transcriber = try await loadTranscriber()
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let transcriber else {
            throw TranscriptionError.contextInitializationFailed
        }

        abortFlag.isSet = false
        onProgressUpdate?(0.02)

        let chunks = try await chunkSource.chunks(for: url, budget: .paraformerZh)
        try checkCancellation()

        // No speech: the model would answer silence with hallucinated text.
        guard !chunks.isEmpty else {
            onProgressUpdate?(1.0)
            return ""
        }

        onProgressUpdate?(0.05)

        // Per chunk, because that is the only honest progress available:
        // ParaformerManager exposes no progress stream, and one call is
        // atomic from here.
        var pieces: [String] = []
        pieces.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try checkCancellation()
            let text = try await transcriber.transcribe(audio: chunk.samples)
            pieces.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            onProgressUpdate?(0.05 + 0.90 * Float(index + 1) / Float(chunks.count))
        }

        try checkCancellation()

        // Joined with nothing between them. Mandarin has no word spaces and this
        // model emits no punctuation, so any separator would be text the user
        // did not say. Shared transcript post-processing runs once afterwards,
        // in TextPostProcessor via TranscriptionService.
        let text = pieces.filter { !$0.isEmpty }.joined()

        onProgressUpdate?(1.0)
        return text
    }

    func cancelTranscription() {
        abortFlag.isSet = true
    }

    /// Mandarin only, and the caller is expected to honour it: the model takes
    /// no language parameter, so a non-Mandarin recording is not rejected, it is
    /// mis-transcribed.
    func getSupportedLanguages() -> [String] {
        LanguageUtil.supportedLanguages(
            engine: .paraformer,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
    }

    /// The production `loadTranscriber`. Not private only because it is this
    /// initialiser's default argument.
    static func loadFluidAudioModels() async throws -> ParaformerTranscribing {
        ParaformerManager(models: try await ParaformerModels.downloadAndLoad(precision: precision))
    }

    // MARK: - Private

    private func checkCancellation() throws {
        if abortFlag.isSet { throw CancellationError() }
        try Task.checkCancellation()
    }
}
