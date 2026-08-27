import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: EngineKind {
        didSet {
            // Not while catching up with a change made elsewhere - the engine
            // shortcut, the Cloud pane - or the pane would carry out again the
            // selection it is only being told about.
            guard !isSyncingFromPreferences else { return }
            // Captured now rather than read when the task runs: an engine change
            // arriving from elsewhere in that window syncs this property back,
            // and the task must carry out the click, not the sync.
            let chosen = selectedEngine
            Task { @MainActor in
                // One call rather than the four things it does. Choosing an engine
                // in this pane and choosing it with the shortcut have to be the
                // same act, down to the language that follows it and the download
                // it starts, so both go through `EngineSelectionCommand`.
                EngineSelectionCommand.select(chosen)
                // The pane's own catching up: which model list to show, and the
                // language control, which the command may just have changed.
                refreshModelState(for: chosen)
                syncLanguageFromPreferences()
            }
        }
    }

    /// True while the published values are being brought into line with what is
    /// stored, so the `didSet`s above act as observers rather than as commands.
    private var isSyncingFromPreferences = false

    private var selectedEngineObserver: NSObjectProtocol?

    /// Catches up with an engine chosen somewhere other than this pane.
    ///
    /// The engine shortcut can be pressed with Settings open and in front of the
    /// user, and a picker still showing the previous engine would be a second
    /// answer to the question this pane exists to answer.
    private func syncFromPreferences() {
        let stored = AppPreferences.shared.selectedEngine
        if stored != selectedEngine {
            isSyncingFromPreferences = true
            selectedEngine = stored
            isSyncingFromPreferences = false
            refreshModelState(for: stored)
        }
        syncLanguageFromPreferences()
    }

    /// Mirrors the stored dictation language onto the picker without writing it
    /// back: the language may have been reset by whoever chose the engine.
    private func syncLanguageFromPreferences() {
        let stored = AppPreferences.shared.whisperLanguage
        guard stored != selectedLanguage else { return }
        isSyncingFromPreferences = true
        selectedLanguage = stored
        isSyncingFromPreferences = false
    }

    /// Refreshes whichever download list the engine actually shows.
    ///
    /// Switched exhaustively rather than `if whisper { … } else { … }`, which is
    /// what it was while there were two engines and what would have quietly
    /// pointed the Chinese engines at Parakeet's model list.
    private func refreshModelState(for engine: EngineKind) {
        switch engine {
        case .whisper:
            loadAvailableModels()
        case .fluidaudio:
            initializeFluidAudioModels()
        case .sensevoice, .paraformer:
            refreshDownloadedEngineModels()
        case .cloud:
            // No model list of any kind: the weights are the provider's. What
            // stands in for this pane is Settings → Cloud.
            break
        }
    }

    /// Which single-model engines already have their weights on disk.
    ///
    /// Read from the filesystem rather than remembered in preferences: the user
    /// can delete the cache from the folder this pane offers to open, and a
    /// preference that said "downloaded" afterwards would be a lie that turns
    /// into a surprise 653 MB fetch mid-dictation.
    @Published var downloadedEngineModels: Set<EngineKind> = []

    func refreshDownloadedEngineModels() {
        var downloaded: Set<EngineKind> = []
        if SenseVoiceEngine.isModelDownloaded { downloaded.insert(.sensevoice) }
        if ParaformerEngine.isModelDownloaded { downloaded.insert(.paraformer) }
        downloadedEngineModels = downloaded
    }

    /// True while a download has finished and the Neural Engine compile has not.
    ///
    /// Its own flag because it is its own kind of waiting: the compile reports no
    /// progress and takes 65-88 s the first time, so a bar left sitting at 100 %
    /// reads as a hang. See `docs/upstream-issues.md` for where the time goes.
    @Published var isCompilingModel: Bool = false
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            if selectedEngine == .fluidaudio {
                Task { @MainActor in
                    TranscriptionService.shared.reloadEngine()
                }
            }
            initializeFluidAudioModels()
            resetLanguageIfUnsupported()
        }
    }
    
    var supportedLanguages: [String] {
        LanguageUtil.supportedLanguages(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
    }

    /// Whether the whisper.cpp decode controls apply to the selected engine.
    /// The decision itself belongs to `EngineKind`, which switches exhaustively.
    var usesWhisperDecodingSettings: Bool { selectedEngine.usesWhisperDecodingSettings }
    
    private func resetLanguageIfUnsupported() {
        if !supportedLanguages.contains(selectedLanguage) {
            selectedLanguage = LanguageUtil.fallbackLanguage(engine: selectedEngine)
        } else {
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }
    
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    /// User-initiated model selection. Persists the model and, if the model declares a
    /// preferred language (e.g. the ivrit.ai Hebrew model), switches the language to it.
    /// Do not call from init/restore - only in response to an explicit user action.
    func selectModel(_ url: URL) {
        selectedModelURL = url
        if let lang = SettingsDownloadableModels.preferredLanguage(forFilename: url.lastPathComponent),
           selectedLanguage != lang {
            selectedLanguage = lang
        }
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    
    @Published var selectedLanguage: String {
        didSet {
            // Same rule as `selectedEngine`: a value being mirrored from
            // preferences is already stored, and announcing it again would send
            // `TranscriptionService` off to re-resolve for nothing.
            guard !isSyncingFromPreferences else { return }
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }

    @Published var capsuleHUDEnabled: Bool {
        didSet {
            AppPreferences.shared.capsuleHUDEnabled = capsuleHUDEnabled
            // Warms the panel up now rather than during the appear animation of
            // the first dictation after the switch. A no-op once it exists.
            Task { @MainActor in
                CapsuleHUDWindowController.shared.warmUp()
            }
        }
    }

    @Published var spokenIntentsEnabled: Bool {
        didSet {
            AppPreferences.shared.spokenIntentsEnabled = spokenIntentsEnabled
        }
    }

    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }

    /// Which Chinese every Chinese transcription is written in. See
    /// `ChineseScriptNormalizer`; it changes nothing for any other language.
    @Published var chineseOutputScript: ChineseScriptVariant {
        didSet {
            AppPreferences.shared.chineseOutputScript = chineseOutputScript
        }
    }

    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            if modifierOnlyHotkey != .none {
                AppPreferences.shared.lastModifierOnlyHotkey = modifierOnlyHotkey.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var mouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.mouseButtonHotkey = mouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }

    @Published var doublePressToTrigger: Bool {
        didSet {
            AppPreferences.shared.doublePressToTrigger = doublePressToTrigger
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var escCancelWithoutConfirmation: Bool {
        didSet {
            AppPreferences.shared.escCancelWithoutConfirmation = escCancelWithoutConfirmation
        }
    }

    @Published var startHiddenInMenuBar: Bool {
        didSet {
            AppPreferences.shared.startHiddenInMenuBar = startHiddenInMenuBar
        }
    }
    
    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteTranscription: Bool {
        didSet {
            AppPreferences.shared.autoPasteTranscription = autoPasteTranscription
        }
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.capsuleHUDEnabled = prefs.capsuleHUDEnabled
        self.spokenIntentsEnabled = prefs.spokenIntentsEnabled
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.chineseOutputScript = prefs.chineseOutputScript
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.mouseButtonHotkey = MouseButton(rawValue: prefs.mouseButtonHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.doublePressToTrigger = prefs.doublePressToTrigger
        self.escCancelWithoutConfirmation = prefs.escCancelWithoutConfirmation
        self.startHiddenInMenuBar = prefs.startHiddenInMenuBar
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
        refreshDownloadedEngineModels()

        if !supportedLanguages.contains(selectedLanguage) {
            let fallback = LanguageUtil.fallbackLanguage(engine: selectedEngine)
            selectedLanguage = fallback
            AppPreferences.shared.whisperLanguage = fallback
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }

        // The engine can be changed while this pane is open - by the engine
        // shortcut, or by the Cloud pane's toggle - and the picker has to follow.
        selectedEngineObserver = NotificationCenter.default.addObserver(
            forName: .selectedEngineChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncFromPreferences()
        }
    }

    deinit {
        if let selectedEngineObserver {
            NotificationCenter.default.removeObserver(selectedEngineObserver)
        }
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        
        // Используем правильный путь к кэшу согласно документации:
        // ~/Library/Application Support/FluidAudio/Models/<version-folder>/
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        
        // Проверяем наличие всех необходимых файлов модели
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.filename
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        downloadTask = Task {
            do {
                let filename = model.filename
                
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectModel(URL(fileURLWithPath: modelPath))
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == .whisper, let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.filename
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        isCompilingModel = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }

    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let modelId = model.id
                let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                    print("[ParakeetProgress] fraction=\(progress.fractionCompleted) phase=\(progress.phase)")
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        self.downloadProgress = progress.fractionCompleted
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == modelId }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = progress.fractionCompleted
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }

    /// Fetches and prepares the weights for an engine that has exactly one set
    /// of them.
    ///
    /// The engine owns the work - this only drives the progress UI. It exists
    /// because the alternative is that the first recording after picking a
    /// Chinese engine blocks for minutes behind a download and a Neural Engine
    /// compile the user never asked for and cannot see.
    @MainActor
    func downloadEngineModel(_ kind: EngineKind) async throws {
        guard !isDownloading, let download = EngineCatalog.entry(for: kind).download else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()

        isDownloading = true
        isCompilingModel = false
        downloadingModelName = download.modelName
        downloadProgress = 0.0

        downloadTask = Task {
            defer {
                Task { @MainActor in
                    self.isDownloading = false
                    self.isCompilingModel = false
                    self.downloadingModelName = nil
                    self.downloadProgress = 0.0
                    self.refreshDownloadedEngineModels()
                }
            }

            let onProgress: DownloadUtils.ProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, let task = self.downloadTask, !task.isCancelled else { return }
                    self.downloadProgress = progress.fractionCompleted
                    // The compile is the phase with nothing to show: FluidAudio
                    // names the model it is compiling but reports no fraction
                    // while it does, and it is the longer half of a cold start.
                    if case .compiling = progress.phase {
                        self.isCompilingModel = true
                    }
                }
            }

            // Through the shared preparer, never straight to the engine: it is
            // what installs a published model pack instead of fetching the same
            // weights unverified. `.whisper` and `.fluidaudio` cannot reach it -
            // `EngineCatalog` gives them no single download, so the guard above
            // already returned.
            try await EngineWeightsPreparation.production.prepare(kind, progressHandler: onProgress)

            try Task.checkCancellation()

            // The engine may already have failed to load these weights before
            // they existed, so it is reloaded rather than left holding that.
            await MainActor.run {
                TranscriptionService.shared.reloadEngine()
            }
        }

        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Manual cancellation, not a failure to report.
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0
    let filename: String
    let preferredLanguage: String?

    var sizeString: String {
        formatModelSize(megabytes: size)
    }

    var huggingFacePageURL: URL? {
        makeHuggingFacePageURL(fromDownloadURL: url)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 Hebrew",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew fine-tune of Turbo V3 by ivrit.ai. Sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }

    static func isVisible(_ model: SettingsDownloadableModel,
                          selectedLanguage: String,
                          systemLanguage: String) -> Bool {
        guard let lang = model.preferredLanguage else { return true }
        if model.isDownloaded { return true }
        return selectedLanguage == lang || systemLanguage == lang
    }
}

func countLabel(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "\(count) \(singular)" : "\(count) \(plural)"
}

func formatModelSize(megabytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(megabytes) * 1000000)
}

func makeHuggingFacePageURL(fromDownloadURL url: URL) -> URL? {
    let absoluteString = url.absoluteString
    guard let range = absoluteString.range(of: "/resolve/") else { return nil }
    return URL(string: String(absoluteString[..<range.lowerBound]))
}

/// The Hugging Face owner (user / organization) from a model page URL,
/// e.g. https://huggingface.co/ivrit-ai/whisper-... -> "ivrit-ai".
func huggingFaceOwner(fromPageURL url: URL) -> String? {
    url.pathComponents.first { $0 != "/" }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    /// Which Chinese this transcript is written in, whichever script the engine
    /// returned. Deterministic, offline, and applied to every engine's output at
    /// the same choke point - see `ChineseScriptNormalizer`.
    ///
    /// It is also the fallback the model-backed stages take when a Chinese
    /// transcript's own characters do not say which variant it is: the script
    /// the user chose is a better answer than the one their Mac's region
    /// implies, and it is the script the transcript was just written in.
    var chineseOutputScript: ChineseScriptVariant
    /// Whether the deterministic terms stage runs. Independent of every
    /// language gate and of any later style-rewriting setting.
    var safeCorrectionEnabled: Bool
    /// The style rewriting stage, which runs after the deterministic ones and
    /// may decline to change anything at all. See `StyleRewriteService`.
    var styleRewrite: StyleRewriteConfiguration

    /// Whether this transcription is read for a spoken command - "Ask: …",
    /// "Translate to Spanish: …" - before anything is done with it.
    ///
    /// Two conditions, and both have to hold: the user switched the feature on,
    /// **and** the caller is a path where a command makes sense. Only live
    /// dictation is. A dropped file, a queued recording, a regenerate from
    /// history and the Ask panel's own voice follow-up all take the plain path,
    /// so a transcript that happens to open with the word "ask" cannot open a
    /// panel nobody was looking at. See `SpokenIntentPipeline`.
    var routesSpokenIntents: Bool

    /// The voice snippets this transcription may fire.
    ///
    /// Resolved here rather than read by the pipeline so the whole decision -
    /// routing off, snippets off, or nothing stored - is made in one place and
    /// the router stays a pure function of "these words, these snippets".
    /// Empty whenever `routesSpokenIntents` is false, so a dropped file or a
    /// regenerate from history cannot expand a macro.
    var voiceSnippets: [VoiceSnippet]

    /// What this recording session was captured for. See `DictationPurpose`.
    ///
    /// It is the switch the whole pipeline turns on, and the two purposes have
    /// no path into each other: a `.dictation` session can only produce text and
    /// a `.youTubeCommand` session can only produce a channel to open.
    var purpose: DictationPurpose

    /// The YouTube channels this utterance may open a video from, or `nil` when
    /// it may open none.
    ///
    /// `nil` and empty are deliberately different answers, which is why this is
    /// not `[YouTubeChannel]` the way `voiceSnippets` is. `nil` means no channel
    /// is reachable at all - every `.dictation` session, and a command session
    /// on an install where the feature is switched off - while an empty
    /// allowlist means the command is on and nothing has been allowlisted yet,
    /// which the user is told rather than left to guess at.
    var youTubeChannels: YouTubeChannelAllowlist?

    /// Whether a spoken channel name the deterministic tiers could not place may
    /// be handed to the on-device model to pick from `youTubeChannels`.
    ///
    /// Resolved here, alongside the list itself, so both switches in front of it
    /// - the YouTube command and this one - are answered in one place and the
    /// stage stays a pure function of what it is given. False on every path that
    /// is not a command capture, so no dictation, dropped file or regenerate
    /// from history can ever ask a model about a channel name.
    var youTubeChannelModelMatch: Bool

    /// Whether a spoken channel name nothing could place may offer the user
    /// their own list to choose from.
    ///
    /// Resolved here beside the allowlist for the same reason as the switch
    /// above: false on every path that is not a command capture, so nothing but
    /// a press of the command key can raise a picker - not a dictation however
    /// worded, not a dropped file, and not a regenerate from History.
    var youTubeChannelPicker: Bool

    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }
    
    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }
    
    /// - Parameters:
    ///   - dictationTarget: the app this dictation is being typed into,
    ///     captured once when the session started. `nil` - the default - is
    ///     every other transcription: a dropped file, a queued recording, a
    ///     regenerate from history, or dictation into Kongweh's own window.
    ///     Those have no app to match, so the style the user chose is what they
    ///     use.
    ///   - routesSpokenIntents: whether this path reads the transcript for a
    ///     spoken command. Only live dictation passes `true`; see the property.
    ///   - purpose: what the session was captured for. `.dictation` - the
    ///     default - is every path in the app but one: the YouTube command
    ///     hotkey, which is the only caller that passes `.youTubeCommand`.
    init(
        purpose: DictationPurpose = .dictation,
        dictationTarget: DictationTargetApp? = nil,
        routesSpokenIntents: Bool = false
    ) {
        let prefs = AppPreferences.shared
        self.purpose = purpose
        // A command capture is never dictation and never routes one: it cannot
        // ask, translate or expand a snippet, because none of those end anywhere
        // but the user's document and this utterance is not going there.
        self.routesSpokenIntents =
            purpose == .dictation && routesSpokenIntents && prefs.spokenIntentsEnabled
        self.voiceSnippets = (self.routesSpokenIntents && prefs.voiceSnippetsEnabled)
            ? VoiceSnippetStore.shared.activeSnippets
            : []
        // Only the command hotkey can reach a channel, and only while the
        // feature is on. Dictation gets `nil` on every path and in every
        // configuration, which is what makes "normal dictation never opens a
        // browser" a property of the type rather than of the grammar.
        self.youTubeChannels = (purpose == .youTubeCommand && prefs.youTubeLatestVideoEnabled)
            ? YouTubeChannelStore.shared.allowlist
            : nil
        self.youTubeChannelModelMatch =
            self.youTubeChannels != nil && prefs.youTubeChannelModelMatchEnabled
        self.youTubeChannelPicker =
            self.youTubeChannels != nil && prefs.youTubeChannelPickerEnabled
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.chineseOutputScript = prefs.chineseOutputScript
        self.safeCorrectionEnabled = prefs.safeCorrectionEnabled
        let chosen = StyleRewriteConfiguration.resolve(
            isEnabled: prefs.styleRewriteEnabled,
            storedStyleID: prefs.styleRewriteStyleID,
            customPrompt: prefs.styleRewriteCustomPrompt
        )
        // The app being dictated into may change which style runs, never
        // whether one does: `configuration` passes the toggle and the custom
        // prompt through untouched. See `AppStyleMappingStore`.
        self.styleRewrite = AppStyleMappingStore.load(from: prefs)
            .configuration(chosen, for: dictationTarget)
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab: SettingsTab = .shortcuts
    @State private var previousModelURL: URL?

    /// The tab titles and the sheet's size are one decision, and it is made in
    /// `SettingsSheetLayout` so a test can check that they still agree.
    private var sheetSize: CGSize { SettingsSheetLayout.current }
    
    var body: some View {
        // The tab bar is Kongweh's own control, not the `NSSegmentedControl` a
        // SwiftUI `TabView` renders in a sheet: that one drew its keyboard focus
        // ring from different geometry than its selection, and no width or
        // containment above it could make the two agree. `SettingsTabBar` draws
        // the fill, the focus frame and the hit target from one frame per tab.
        //
        // Every tab title comes from `SettingsTab`, which is also what the
        // sheet's width is measured against - see `SettingsSheetLayout`.
        //
        // Only the selected pane is built - stricter than the tab view, which
        // built every tab whenever Settings opened and only deferred each
        // pane's `onAppear` until it was displayed. That timing carries over,
        // so the `onAppear` refreshes several panes rely on still run exactly
        // when they did; what is new is that a pane nobody opens is never
        // built at all, which keeps the Cloud pane from reading anything on a
        // sheet that never visits it.
        //
        // The pane carries `.settingsPane()`, and that is not decoration: it is
        // what keeps a pane wider than the sheet from laying itself out over the
        // sheet's edge. See `SettingsSheetLayout`.
        VStack(spacing: SettingsSheetLayout.tabBarToPaneSpacing) {
            SettingsTabBar(selection: $selectedTab)

            pane(for: selectedTab)
                .settingsPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(
                        cornerRadius: SettingsSheetLayout.paneCornerRadius, style: .continuous
                    )
                    .fill(SettingsSheetLayout.paneBackground)
                )
        }
        .padding()
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") {
                    if viewModel.selectedEngine == .whisper {
                        if viewModel.selectedModelURL != previousModelURL, let modelPath = viewModel.selectedModelURL?.path {
                            TranscriptionService.shared.reloadModel(with: modelPath)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                Spacer()
                
                // Kongweh's own source. Credit for the upstream project this
                // forked from lives in the README and LICENSE, which travel with it.
                Link(destination: URL(string: "https://github.com/hsuanchenlin/EchoForge")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == .fluidaudio {
                viewModel.initializeFluidAudioModels()
            }
            // Unconditional: the picker shows a downloaded badge for every
            // engine, not only the selected one, and the cache can have changed
            // since the pane was last open.
            viewModel.refreshDownloadedEngineModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .engineModelStateChanged)) { _ in
            viewModel.refreshDownloadedEngineModels()
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == .fluidaudio {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == .whisper, let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }
    
    /// The one pane that is showing.
    ///
    /// The order of the cases is the order `SettingsTab` draws the tabs in, so
    /// this list and the bar cannot drift apart without the compiler saying so.
    @ViewBuilder private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .shortcuts:
            shortcutSettings
        case .model:
            modelSettings
        case .transcription:
            transcriptionSettings
        case .dictionary:
            // The personal terms dictionary, and the voice snippets beneath it.
            PersonalTermsSettingsView()
        case .style:
            // Style rewriting - the one stage that can change what the words
            // mean, so it gets its own pane rather than a row in Transcription.
            StyleRewriteSettingsView()
        case .advanced:
            advancedSettings
        case .cloud:
            // The one pane that can point anything at a provider. Absent
            // entirely from an offline-only build, which is what makes that
            // build's promise checkable rather than a claim about defaults -
            // `SettingsTab.visible` has no Cloud tab there, so this case cannot
            // be reached either.
            if CloudBuild.isCompiledIn {
                CloudSettingsView()
            }
        case .about:
            // Which build this is, and the only place that offers to change it.
            AboutSettingsView()
        }
    }

    /// The catalog entry for the selected engine when that engine has exactly one
    /// set of weights, which is what decides whether the pane below the picker is
    /// a model list or a single download row.
    private var engineDownloadEntry: EngineCatalogEntry? {
        let entry = EngineCatalog.entry(for: viewModel.selectedEngine)
        return entry.download == nil ? nil : entry
    }

    private var modelSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speech Recognition Engine")
                    .font(.headline)
                    .foregroundColor(.primary)

                // Above the picker rather than under it: the shortcut is the same
                // decision this pane exists for, made without the trip here, and a
                // user who has already scrolled past the rows has made the trip.
                EngineShortcutHintView()

                // While the cloud engine is in use none of the rows below is the
                // selected one, and a picker with nothing selected is a bug
                // unless it says why. Tapping a row still switches back to that
                // local engine, which is the safe direction and needs no consent.
                if viewModel.selectedEngine == .cloud {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "cloud")
                            .foregroundColor(.accentColor)
                        Text("Speech is being transcribed by a cloud provider, set up in the Cloud tab. "
                            + "Choose one of these to go back to transcribing on this Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }

                // A list rather than the segmented control this used to be: four
                // engines do not fit legibly across 550 pt, and the two Chinese
                // ones cannot be chosen from a name alone - "no punctuation" and
                // "Mandarin only" are the whole decision.
                VStack(spacing: 8) {
                    ForEach(EngineCatalog.pickerOrder, id: \.self) { kind in
                        EngineChoiceRow(kind: kind, viewModel: viewModel)
                    }
                }
                .padding(.bottom, 8)

                if let entry = engineDownloadEntry {
                    EngineModelSectionView(
                        kind: viewModel.selectedEngine,
                        entry: entry,
                        viewModel: viewModel
                    )
                } else if viewModel.selectedEngine == .cloud {
                    // Nothing to download and no models directory: the model is
                    // the provider's and is named in the Cloud tab. Falling
                    // through to the Parakeet list below - which is what an
                    // `else` would do - would offer downloads for an engine the
                    // user is not using.
                    EmptyView()
                } else if viewModel.selectedEngine == .whisper {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Whisper Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableModels) { $model in
                                if SettingsDownloadableModels.isVisible(model,
                                        selectedLanguage: viewModel.selectedLanguage,
                                        systemLanguage: LanguageUtil.getSystemLanguage()) {
                                    ModelDownloadItemView(model: $model, viewModel: viewModel)
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Models Directory:")
                                    .font(.subheadline)
                                Button(action: {
                                    NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                                }) {
                                    Label("Open Folder", systemImage: "folder")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                                .help("Open models directory")
                            }
                            Text(WhisperModelManager.shared.modelsDirectory.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Parakeet Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Models Directory:")
                                    .font(.subheadline)
                                Button(action: {
                                    let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                                    let parentDir = cacheDir.deletingLastPathComponent()
                                    NSWorkspace.shared.open(parentDir)
                                }) {
                                    Label("Open Folder", systemImage: "folder")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                                .help("Open models directory")
                            }
                            Text(AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(12)
        }
        .padding()
    }
    
    private var transcriptionSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(.subheadline)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(viewModel.supportedLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if let suggested = EngineCatalog.suggestedEngine(
                            forLanguage: viewModel.selectedLanguage,
                            selected: viewModel.selectedEngine
                        ) {
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: "lightbulb")
                                    .foregroundColor(.secondary)
                                Text(
                                    "\(EngineCatalog.entry(for: suggested).displayName) is the recommended "
                                        + "engine for Chinese - it punctuates."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 0)

                                Button("Switch") { viewModel.selectedEngine = suggested }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(.top, 4)
                        }

                        if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                            HStack {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.useAsianAutocorrect)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }
                            .padding(.top, 4)
                        }

                        // Shown for the languages this can actually change:
                        // Chinese, and auto-detect, which may turn out to be
                        // Chinese. `ChineseScriptVariant.mayBeChinese` is the
                        // same test the normalizer itself applies, so the
                        // control appears exactly when it does something.
                        if ChineseScriptVariant.mayBeChinese(
                            languageCode: viewModel.selectedLanguage
                        ) {
                            ChineseOutputScriptSetting(script: $viewModel.chineseOutputScript)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.usesWhisperDecodingSettings {
                            HStack {
                                Text("Show Timestamps")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.showTimestamps)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }

                            HStack {
                                Text("Suppress Blank Audio")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.suppressBlankAudio)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Space After Sentence")
                                    .font(.subheadline)
                                Text("Appends a space when transcription ends with punctuation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.addSpaceAfterSentence)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Clipboard & Paste
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clipboard & Paste")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copy to Clipboard")
                                    .font(.subheadline)
                                Text("Keep transcription in clipboard after recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoCopyToClipboard)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-paste Transcription")
                                    .font(.subheadline)
                                Text("Automatically paste into the focused app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoPasteTranscription)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Initial Prompt
                if viewModel.usesWhisperDecodingSettings {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Initial Prompt")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $viewModel.initialPrompt)
                                .frame(height: 60)
                                .padding(6)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )

                            Text("Optional text to guide the model's transcription")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                }

                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }
                        
                        Text(Recording.recordingsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                RecordingStorageSettingsView()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private var advancedSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Decoding Strategy. Whisper-only, along with Model Parameters
                // below: these are whisper.cpp decode parameters and no other
                // engine reads them, so showing them for one that does not is a
                // control that silently does nothing.
                if viewModel.usesWhisperDecodingSettings {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Decoding Strategy")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Use Beam Search")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.useBeamSearch)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                                    .help("Beam search can provide better results but is slower")
                            }

                            if viewModel.useBeamSearch {
                                HStack {
                                    Text("Beam Size:")
                                        .font(.subheadline)
                                    Spacer()
                                    Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                                        .help("Number of beams to use in beam search")
                                        .frame(width: 120)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)

                    // Model Parameters
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Model Parameters")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Temperature:")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.2f", viewModel.temperature))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                    .help("Higher values make the output more random")
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("No Speech Threshold:")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                    .help("Threshold for detecting speech vs. silence")
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                }

                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text("Debug Mode")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                            .help("Enable additional logging and debugging information")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private enum TriggerMode: Hashable {
        case keyCombo
        case modifier
        case mouse
    }

    @ViewBuilder
    private func permissionWarning(message: String, isGranted: Bool, grantAction: @escaping () -> Void) -> some View {
        if permissionsManager.hasCompletedInitialCheck && !isGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                
                Button("Grant Permission") {
                    grantAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private var triggerMode: TriggerMode {
        if viewModel.mouseButtonHotkey != .none { return .mouse }
        if viewModel.modifierOnlyHotkey != .none { return .modifier }
        return .keyCombo
    }
    
    private var shortcutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: Binding(
                            get: { triggerMode },
                            set: { newMode in
                                switch newMode {
                                case .keyCombo:
                                    viewModel.mouseButtonHotkey = .none
                                    viewModel.modifierOnlyHotkey = .none
                                case .modifier:
                                    viewModel.mouseButtonHotkey = .none
                                    if viewModel.modifierOnlyHotkey == .none {
                                        viewModel.modifierOnlyHotkey =
                                            ModifierKey(rawValue: AppPreferences.shared.lastModifierOnlyHotkey) ?? .leftCommand
                                    }
                                case .mouse:
                                    viewModel.modifierOnlyHotkey = .none
                                    if viewModel.mouseButtonHotkey == .none {
                                        viewModel.mouseButtonHotkey = .middle
                                    }
                                }
                            }
                        )) {
                            Text("Key Combination").tag(TriggerMode.keyCombo)
                            Text("Single Modifier Key").tag(TriggerMode.modifier)
                            Text("Mouse Button").tag(TriggerMode.mouse)
                        }
                        .pickerStyle(.segmented)

                        switch triggerMode {
                        case .modifier:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Modifier Key")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.modifierOnlyHotkey) {
                                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                            Text(key.displayName).tag(key)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text(viewModel.doublePressToTrigger
                                     ? "Double-tap to toggle recording"
                                     : "One-tap to toggle recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Double Tap to Trigger")
                                            .font(.subheadline)
                                        Text("Require two quick taps to avoid accidental activation")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $viewModel.doublePressToTrigger)
                                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                permissionWarning(
                                    message: "⚠️ This mode requires Input Monitoring permission. macOS requires this to detect single modifier key presses globally. Only modifier key events (⌘, ⌥, ⇧, ⌃, Fn) are monitored - no regular keystrokes are captured.",
                                    isGranted: permissionsManager.isInputMonitoringPermissionGranted
                                ) {
                                    permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .mouse:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Mouse Button")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.mouseButtonHotkey) {
                                        ForEach(MouseButton.allCases.filter { $0 != .none }) { button in
                                            Text(button.displayName).tag(button)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text("Click to toggle recording, or hold when Hold to Record is on. The left and right buttons are reserved - pick the middle or an extra (thumb) button.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                permissionWarning(
                                    message: "⚠️ This mode requires Accessibility permission so the button can be detected globally and used only as a recording trigger. Only the selected mouse button is intercepted - no other clicks or keystrokes are captured.",
                                    isGranted: permissionsManager.isAccessibilityPermissionGranted
                                ) {
                                    permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .keyCombo:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.subheadline)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                        .frame(width: 150)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                if isRecordingNewShortcut {
                                    Text("Press your new shortcut combination...")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Recording Behavior
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Behavior")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hold to Record")
                                    .font(.subheadline)
                                Text("Hold the shortcut to record, release to stop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.holdToRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Play sound when recording starts")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Play a notification sound when recording begins")
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Floating capsule HUD")
                                    .font(.subheadline)
                                Text("Show one capsule at the top of the screen - level, timer, progress - instead of the card beside the cursor")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.capsuleHUDEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancel without confirmation")
                                    .font(.subheadline)
                                Text("Skip the double-Esc confirmation for recordings longer than 10 seconds")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.escCancelWithoutConfirmation)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Ask & spoken commands. Its own section rather than a row in
                // Recording Behavior: one of these changes where a dictation
                // ends up, which is a different kind of setting from how the
                // recording is triggered or drawn.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask & Spoken Commands")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ask panel shortcut")
                                    .font(.subheadline)
                                Text("Opens a floating panel and starts listening. Say your question, press again to finish, and it is answered on this Mac. Esc closes the panel.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .askPanel)
                                .frame(width: 150)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ask about the screen")
                                    .font(.subheadline)
                                Text("Captures the window you are looking at and answers a spoken question about it. Needs Screen Recording permission, which is asked for the first time you use it.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .askAboutScreen)
                                .frame(width: 150)
                        }

                        permissionWarning(
                            message: "Screen Recording is not granted, so asking about the screen will not work.",
                            isGranted: permissionsManager.isScreenRecordingPermissionGranted
                        ) {
                            permissionsManager.requestScreenRecordingPermissionOrOpenSystemPreferences()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spoken commands")
                                    .font(.subheadline)
                                Text("Start a dictation with \"Ask:\" to send it to the Ask panel, or \"Translate to Spanish:\" to translate it. Anything else is dictated as usual. Opening a YouTube video is not one of these - it has its own key below, and no dictation can trigger it.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.spokenIntentsEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        Text("Both use the same on-device model as rewriting, so they need macOS 26 with Apple Intelligence. Nothing is sent anywhere.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // The YouTube command. Its own section and its own key, and
                // that separation is the feature's safety story rather than a
                // layout choice: this key opens a browser, the dictation key
                // types text, and nothing either one captures can do the
                // other's job. See `docs/youtube-latest-video.md`.
                VStack(alignment: .leading, spacing: 16) {
                    Text("YouTube Command")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(YouTubeChannelHelpText.shortcutName)
                                    .font(.subheadline)
                                Text("Hold it, name a channel you allowlisted, and let go: its newest video opens in Chrome. This key records a command and never types anything, and your dictation shortcut never opens a browser.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .youTubeCommand)
                                .frame(width: 150)
                        }

                        Text("The channels it can reach are the ones you list in Dictionary & Snippets → YouTube Channels, and it can reach nothing else. \(YouTubeChannelHelpText.autoplayNote)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Switching engine. Its own section beside the other shortcuts
                // rather than in the Models pane: it is a shortcut, and it is
                // pressed while working somewhere else - the pane it changes is
                // the one place the user is not when they use it.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Switch Engine")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next engine shortcut")
                                    .font(.subheadline)
                                Text("Moves dictation to the next engine that is ready and names it on screen. Engines that are not downloaded, and ones that cannot dictate your language, are skipped. Cloud is included once it is set up in the Cloud tab.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .cycleEngine)
                                .frame(width: 150)
                        }

                        Text("Pressed during a dictation, it takes effect once that dictation has finished - the words you have already spoken are transcribed by the engine you spoke them to.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Application
                VStack(alignment: .leading, spacing: 16) {
                    Text("Application")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start hidden in menu bar")
                                .font(.subheadline)
                            Text("Launch without opening the main window; use the menu bar icon to open it")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.startHiddenInMenuBar)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
        // Screen Recording is not part of the polled check - see
        // `PermissionsManager.isScreenRecordingPermissionGranted` - so this pane
        // reads it when it appears, which is when it has something to say about it.
        .onAppear { permissionsManager.checkScreenRecordingPermission() }
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    let size: Int
    var downloadProgress: Double = 0.0

    var sizeString: String {
        formatModelSize(megabytes: size)
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 483
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 464
        )
    ]
}

// The onboarding model list used to live here. It is
// `OpenSuperWhisper/Onboarding/OnboardingModelCatalog.swift` now, next to the
// screen that shows it.

struct FluidAudioModelDownloadItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.fluidAudioModelVersion = model.version
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        Task {
                            do {
                                try await viewModel.downloadFluidAudioModel(model)
                            } catch is CancellationError {
                                // Don't show error for manual cancellation
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.fluidAudioModelVersion = model.version
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

/// One selectable engine in the Model pane.
///
/// Carries the language scope and a downloaded badge next to the name because
/// both are part of choosing: an engine that only does Mandarin, or that would
/// cost 653 MB the moment it is used, is not interchangeable with the one above
/// it, and neither fact survives being left to a name.
struct EngineChoiceRow: View {
    let kind: EngineKind
    @ObservedObject var viewModel: SettingsViewModel

    private var entry: EngineCatalogEntry { EngineCatalog.entry(for: kind) }
    private var isSelected: Bool { viewModel.selectedEngine == kind }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.filled.circle" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .imageScale(.medium)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if kind == EngineKind.defaultChineseDictation {
                        Text("Default for Chinese")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }

                    if entry.download != nil && viewModel.downloadedEngineModels.contains(kind) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .help("Model downloaded")
                    }
                }

                Text(entry.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(EngineCatalog.languageSummary(
                    for: kind,
                    fluidAudioModelVersion: viewModel.fluidAudioModelVersion
                ))
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(isSelected ? 0.9 : 0.4))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isSelected { viewModel.selectedEngine = kind }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The download, the caveats and the attribution for an engine with one model.
///
/// The notes are not garnish. Both FunASR engines have behaviour a user will
/// otherwise meet first in their own transcript - no punctuation at all, or
/// spoken numbers silently rewritten as digits - and the attribution links are
/// what the model licence requires of an app that ships these weights at all
/// (`docs/speech-model-attribution.md`).
struct EngineModelSectionView: View {
    let kind: EngineKind
    let entry: EngineCatalogEntry
    @ObservedObject var viewModel: SettingsViewModel

    /// The background preparation this pane has to reflect but does not own.
    ///
    /// Choosing an engine now starts fetching its weights whether or not this
    /// pane is open, so the row has two possible sources of "busy": the Download
    /// button next to it, and the preparation that the selection itself started.
    /// `ModelLoadCoordinator` makes them the same piece of work, so the row shows
    /// whichever one is reporting.
    @ObservedObject private var transcriptionService = TranscriptionService.shared

    @State private var showError = false
    @State private var errorMessage = ""

    private var download: EngineModelDownload? { entry.download }
    private var isDownloaded: Bool { viewModel.downloadedEngineModels.contains(kind) }

    private var backgroundPreparation: ModelPreparation? {
        guard let preparation = transcriptionService.modelPreparation, preparation.engine == kind else { return nil }
        return preparation
    }

    private var isBusy: Bool {
        (viewModel.isDownloading && viewModel.downloadingModelName == download?.modelName)
            || backgroundPreparation != nil
    }

    /// True while the phase in progress has no fraction worth showing - the
    /// Neural Engine compile, or listing the repository.
    private var isIndeterminate: Bool {
        if let backgroundPreparation { return !backgroundPreparation.stage.isDeterminate }
        return viewModel.isCompilingModel
    }

    private var determinateFraction: Double {
        if case .downloading(let fraction)? = backgroundPreparation?.stage { return fraction }
        return viewModel.downloadProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let download {
                Text("\(entry.displayName) Model")
                    .font(.headline)
                    .foregroundColor(.primary)

                downloadRow(download)

                if !entry.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(note)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                }

                attributionFooter

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Models Directory:")
                            .font(.subheadline)
                        Button(action: {
                            NSWorkspace.shared.open(download.cacheDirectory.deletingLastPathComponent())
                        }) {
                            Label("Open Folder", systemImage: "folder")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .help("Open models directory")
                    }
                    Text(download.cacheDirectory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                }
                .padding(.top, 4)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private func downloadRow(_ download: EngineModelDownload) -> some View {
        // Name and action on one line, explanation on its own full-width line
        // below: the explanation is two sentences, and sharing a row with the
        // button squeezes it into a column half the pane wide.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(download.modelName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if isBusy {
                    Button("Cancel") { cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                        .help("Downloaded - this engine is ready to use")
                } else {
                    HStack(spacing: 8) {
                        Text(formatModelSize(megabytes: download.megabytes))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: startDownload) {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isDownloading)
                    }
                }
            }

            Text(statusLine(download))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                // Determinate while bytes are moving, indeterminate once
                // FluidAudio starts compiling: that phase publishes no fraction
                // and is the longer half of a cold start, so a bar frozen at
                // 100 % would read as a hang.
                Group {
                    if isIndeterminate {
                        ProgressView()
                    } else {
                        ProgressView(value: determinateFraction)
                    }
                }
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    /// What the user is actually waiting for, or would be. Deliberately states
    /// the cold-start cost twice over - the download and the one-time Neural
    /// Engine compile - because the compile is invisible, takes over a minute,
    /// and is otherwise indistinguishable from the app having hung.
    private func statusLine(_ download: EngineModelDownload) -> String {
        if isBusy {
            if isIndeterminate {
                return "\(ModelPreparationStage.preparingMessage) Preparing for the Neural Engine takes about a "
                    + "minute the first time."
            }
            // The percentage is the point of showing it at all: without one this
            // row said "Downloading 240 MB…" for four minutes and never moved.
            return "Downloading \(formatModelSize(megabytes: download.megabytes)) - "
                + "\(Int((determinateFraction * 100).rounded()))%"
        }
        if isDownloaded {
            return "Downloaded and ready."
        }
        // The size is already on the button beside this, so it is not repeated.
        return "Downloads the first time you dictate with this engine, then takes about a minute to prepare "
            + "for the Neural Engine. Keeping both "
            + "\(EngineCatalog.entry(for: EngineKind.defaultChineseDictation).displayName) and "
            + "\(EngineCatalog.entry(for: EngineKind.chineseAccuracyAlternative).displayName) uses about "
            + "\(formatModelSize(megabytes: EngineCatalog.bothChineseEnginesMegabytes))."
    }

    /// Stops whichever piece of work is running. The row cannot tell the two
    /// apart on purpose - `ModelLoadCoordinator` makes them one download - so it
    /// cancels both rather than guessing.
    private func cancel() {
        viewModel.cancelDownload()
        TranscriptionService.shared.cancelDesiredEnginePreparation()
    }

    @ViewBuilder
    private var attributionFooter: some View {
        if let credit = entry.attributionCredit {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(credit). \(EngineCatalog.provenanceLine(for: kind))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    ForEach(entry.attribution) { link in
                        Link(link.label, destination: link.url)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private func startDownload() {
        Task {
            do {
                try await viewModel.downloadEngineModel(kind)
            } catch is CancellationError {
                // Manual cancellation.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

struct RecordingStorageSettingsView: View {
    @State private var autoDeleteEnabled = AppPreferences.shared.autoDeleteRecordingsEnabled
    @State private var retentionDays = AppPreferences.shared.autoDeleteRecordingsAfterDays
    @State private var diskUsage: Int64 = 0
    @State private var showConfirmation = false
    @State private var pendingDays = 0
    @State private var pendingCount = 0
    @State private var pendingOldestDate: Date?

    private let dayOptions = [1, 7, 14, 30, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History Storage")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recordings on disk:")
                        .font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Delete recordings older than")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { retentionDays },
                        set: { newValue in
                            if autoDeleteEnabled {
                                requestAutoDelete(days: newValue)
                            } else {
                                retentionDays = newValue
                                AppPreferences.shared.autoDeleteRecordingsAfterDays = newValue
                            }
                        }
                    )) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text(countLabel(days, singular: "day", plural: "days")).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-delete old recordings")
                            .font(.subheadline)
                        Text("Removes both audio files and their transcriptions from history")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { autoDeleteEnabled },
                        set: { newValue in
                            if newValue {
                                requestAutoDelete(days: retentionDays)
                            } else {
                                autoDeleteEnabled = false
                                AppPreferences.shared.autoDeleteRecordingsEnabled = false
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
                    .help("Automatically delete recordings and their transcriptions older than the selected number of days")
                }
            }
        }
        .onAppear {
            refreshDiskUsage()
        }
        .alert("Delete Old Recordings?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive) {
                confirmAutoDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(countLabel(pendingCount, singular: "recording", plural: "recordings")) with \(pendingCount == 1 ? "its transcription" : "their transcriptions") starting from \(formattedDate(pendingOldestDate)) will be deleted.")
        }
    }

    private func requestAutoDelete(days: Int) {
        Task { @MainActor in
            let result: (count: Int, oldestDate: Date?) = (try? await RecordingStore.shared.recordingsOlderThan(days: days)) ?? (count: 0, oldestDate: nil)
            if result.count > 0 {
                pendingDays = days
                pendingCount = result.count
                pendingOldestDate = result.oldestDate
                showConfirmation = true
            } else {
                applyAutoDelete(days: days)
            }
        }
    }

    private func confirmAutoDelete() {
        applyAutoDelete(days: pendingDays)
    }

    private func applyAutoDelete(days: Int) {
        retentionDays = days
        autoDeleteEnabled = true
        AppPreferences.shared.autoDeleteRecordingsAfterDays = days
        AppPreferences.shared.autoDeleteRecordingsEnabled = true
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
            refreshDiskUsage()
        }
    }

    private func refreshDiskUsage() {
        Task.detached {
            let usage = RecordingStore.recordingsDiskUsage()
            await MainActor.run {
                diskUsage = usage
            }
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct ModelDownloadItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        if let selectedURL = viewModel.selectedModelURL {
            let filename = model.filename
            return selectedURL.lastPathComponent == filename
        }
        return false
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let pageURL = model.huggingFacePageURL,
                       let owner = huggingFaceOwner(fromPageURL: pageURL) {
                        Link(owner, destination: pageURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("View on Hugging Face")
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                        viewModel.selectModel(URL(fileURLWithPath: modelPath))
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        Task {
                            do {
                                try await viewModel.downloadModel(model)
                            } catch is CancellationError {
                                // Don't show error for manual cancellation
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                viewModel.selectModel(URL(fileURLWithPath: modelPath))
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}
