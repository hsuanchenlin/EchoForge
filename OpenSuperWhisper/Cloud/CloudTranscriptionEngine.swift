import Foundation

/// Speech transcription by an OpenAI-compatible provider, behind the same
/// protocol as the four engines that run on this Mac.
///
/// It is an alternative implementation of `TranscriptionEngine`, not a second
/// path beside it, and that is the whole integration: `TranscriptionService`,
/// the post-processing pipeline, the queue, history and both HUDs go on working
/// exactly as they did, because none of them can tell which engine answered.
///
/// Three things about it are deliberately unlike the local engines:
///
/// - **It has no weights**, so `EngineConfiguration.isPreparable` says false and
///   there is nothing for `EngineWeightsPreparation` to fetch. What stands in for
///   "downloaded" is `CloudAccess`: consent, a key and a usable base URL.
/// - **It is never a stand-in.** `EngineSelector` skips it in both interim tiers
///   (`EngineKind.usesCloudProvider`), so it transcribes only when the user chose
///   it. Falling back onto a cloud engine would mean a dictation left the Mac
///   because a local download had not finished, which is not a decision this app
///   makes on anyone's behalf.
/// - **It reports no meaningful progress.** One request is atomic from here: the
///   bytes go out and the transcript comes back. So it reports the start and the
///   end and nothing in between, rather than animating a bar that knows nothing -
///   the same honesty `DownloadProgressText` exists for.
final class CloudTranscriptionEngine: TranscriptionEngine {

    /// The largest file that is offered to the provider.
    ///
    /// OpenAI's documented limit for this endpoint is 25 MB and the compatible
    /// providers follow it. At the 16 kHz mono 16-bit WAV `AudioRecorder`
    /// produces (32 kB/s) that is about thirteen minutes of dictation; a dropped
    /// file can be anything. Checked here rather than left to a 413 so the user
    /// is told before their upload rather than after it, and so the recording is
    /// kept.
    static let maximumUploadBytes = 25 * 1000 * 1000

    var engineName: String { "Cloud" }

    var onProgressUpdate: ((Float) -> Void)?

    /// Whether a transcription would be attempted at all.
    ///
    /// The cloud equivalent of "the weights are loaded": no model is held in
    /// memory, so what this answers is whether the gate would let a request out.
    /// Read without touching the Keychain - `isCloudSelected` stops before it.
    var isModelLoaded: Bool { CloudAccess.isCloudSelected(.transcription, settings: settings()) }

    private let client: CloudClient
    private let settings: @Sendable () -> CloudSettings
    private let credentials: CloudCredentialStoring
    private let readAudio: @Sendable (URL) throws -> Data

    /// The request in flight, so `cancelTranscription()` can stop it.
    ///
    /// A box rather than a plain property because the protocol's cancel is
    /// synchronous and may be called from anywhere, while the task is created
    /// inside an `async` call. Cancelling the task cancels the `URLSession` task
    /// underneath it, which is what actually stops the upload.
    private let inFlight = CancellableWork()

    /// - Parameters:
    ///   - settings: read per transcription rather than captured once, because
    ///     the user can change the key, the model or the provider while the app
    ///     runs and the next dictation should use what they chose.
    ///   - readAudio: injected so a test can hand the engine bytes without
    ///     writing an audio file.
    init(
        client: CloudClient = CloudClient(),
        settings: @escaping @Sendable () -> CloudSettings = { CloudSettings.current() },
        credentials: CloudCredentialStoring = KeychainCloudCredentialStore(),
        readAudio: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) {
        self.client = client
        self.settings = settings
        self.credentials = credentials
        self.readAudio = readAudio
    }

    /// Checks the configuration, and nothing else.
    ///
    /// No round trip: a request that only exists to prove the key works would
    /// cost the user money on every launch and every engine switch, and would
    /// still not prove the next one succeeds. A misconfiguration surfaces on the
    /// first dictation instead, where the message can name the fix and the audio
    /// is kept.
    func initialize() async throws {
        _ = try permittedCall()
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let call = try permittedCall()

        let audio: Data
        do {
            audio = try readAudio(url)
        } catch {
            throw TranscriptionError.audioConversionFailed
        }
        guard audio.count <= Self.maximumUploadBytes else {
            throw CloudRequestError.audioTooLarge(bytes: audio.count, limit: Self.maximumUploadBytes)
        }

        onProgressUpdate?(0.05)

        let client = self.client
        // `auto` is this app's word for "detect it", not a value any provider
        // knows; sending it would be a request for a language called "auto".
        let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage
        let prompt = settings.initialPrompt
        let fileName = url.lastPathComponent
        let mimeType = CloudRequests.mimeType(forExtension: url.pathExtension)

        let task = Task {
            try await client.transcribe(
                call,
                audio: audio,
                fileName: fileName,
                mimeType: mimeType,
                language: language,
                prompt: prompt
            )
        }
        inFlight.hold(task)
        defer { inFlight.release() }

        let text = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }

        onProgressUpdate?(1.0)
        return text
    }

    func cancelTranscription() {
        inFlight.cancel()
    }

    /// Every language the provider's speech model is asked about.
    ///
    /// `LanguageUtil.availableLanguages` - the Whisper list - because that is
    /// what the endpoint this speaks to was built for, and because the picker
    /// offering fewer languages than the provider supports is a smaller mistake
    /// than offering more.
    func getSupportedLanguages() -> [String] {
        LanguageUtil.supportedLanguages(engine: .cloud, fluidAudioModelVersion: "")
    }

    private func permittedCall() throws -> CloudCall {
        switch CloudAccess.resolve(.transcription, settings: settings(), credentials: credentials) {
        case .success(let call):
            return call
        case .failure(let refusal):
            throw CloudRequestError.notPermitted(refusal)
        }
    }
}

/// Holds whatever is in flight so a synchronous `cancel` can reach it.
///
/// Type-erased to `Task<Void, Never>` deliberately: the box only ever has to
/// cancel, never to await, and erasing keeps it usable by any caller regardless
/// of what its task returns.
final class CancellableWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelCurrent: (() -> Void)?

    func hold<Success, Failure>(_ task: Task<Success, Failure>) {
        lock.lock()
        cancelCurrent = { task.cancel() }
        lock.unlock()
    }

    func release() {
        lock.lock()
        cancelCurrent = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let cancelCurrent = self.cancelCurrent
        lock.unlock()
        cancelCurrent?()
    }
}
