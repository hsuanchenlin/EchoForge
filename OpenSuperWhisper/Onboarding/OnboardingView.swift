//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI
import FluidAudio

enum OnboardingShortcutOption: String, CaseIterable {
    case keyCombination
    case rightOption
}

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var selectedShortcut: OnboardingShortcutOption {
        didSet {
            switch selectedShortcut {
            case .keyCombination:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            case .rightOption:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
                AppPreferences.shared.lastModifierOnlyHotkey = ModifierKey.rightOption.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var unifiedModels: [OnboardingUnifiedModel] = []
    @Published var selectedModelId: UUID?
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?

    /// True once a download has finished moving bytes and CoreML has started
    /// compiling for the Neural Engine. That phase publishes no fraction and is
    /// the longer half of a cold start, so the row swaps to an indeterminate bar
    /// rather than sitting at 100 % looking hung.
    @Published var isCompilingModel: Bool = false

    private let modelManager = WhisperModelManager.shared
    private var downloadTask: Task<Void, Error>?

    /// Whether a row's weights are already on this Mac.
    ///
    /// Injectable so the two rules this screen has to keep - which row is
    /// auto-selected, and that selecting one persists its engine - can be tested
    /// without a 900 MB download and without depending on whichever caches
    /// happen to be on the machine running the tests.
    typealias DownloadStateReader = (OnboardingModelType) -> Bool

    static let downloadStateFromDisk: DownloadStateReader = { type in
        switch type {
        case .whisper(let url, _):
            return WhisperModelManager.shared.isModelDownloaded(name: url.lastPathComponent)
        case .parakeet(let version):
            return EngineAvailability.isFluidAudioDownloaded(version: version)
        case .engine(let kind):
            // The engine answers this, because it is the one that knows which
            // precision it loads and therefore which files count.
            return kind.isSingleModelDownloaded ?? false
        }
    }

    private let isDownloaded: DownloadStateReader

    init(isDownloaded: @escaping DownloadStateReader = OnboardingViewModel.downloadStateFromDisk) {
        self.isDownloaded = isDownloaded

        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        
        let currentHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if currentHotkey == .none && !AppPreferences.shared.hasCompletedOnboarding {
            // Default to key combination mode — does NOT require Input Monitoring permission.
            // Users can switch to single modifier key mode later in Settings if they prefer.
            self.selectedShortcut = .keyCombination
            AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        } else {
            self.selectedShortcut = currentHotkey == .rightOption ? .rightOption : .keyCombination
        }
        
        initializeUnifiedModels()
    }

    func initializeUnifiedModels() {
        unifiedModels = OnboardingUnifiedModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isDownloaded(model.type)
            return updatedModel
        }

        // A row that is already downloaded is auto-selected, and that goes
        // through `selectModel` like every other selection: the row draws
        // itself with the green checkmark and `canContinue` lets the user
        // through, so the engine behind it has to be the one actually
        // persisted. Setting only `selectedModelId` here is what left users
        // past onboarding with no `selectedEngine` at all - every dictation
        // then failed to load an engine and was discarded in silence.
        if selectedModelId == nil, let firstDownloaded = unifiedModels.first(where: { $0.isDownloaded }) {
            selectModel(firstDownloaded)
        }
    }

    /// The languages the top-of-screen picker offers, scoped to the currently
    /// selected row's engine so an incompatible pairing can never be picked.
    var offeredLanguages: [String] {
        let selectedModel = unifiedModels.first { $0.id == selectedModelId }
        return OnboardingUnifiedModels.offeredLanguages(
            selectedModel: selectedModel,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
    }
    
    var canContinue: Bool {
        guard let selectedId = selectedModelId else { return false }
        return unifiedModels.contains { $0.id == selectedId && $0.isDownloaded }
    }

    /// Persists the selected row once more and answers whether onboarding may
    /// be considered finished.
    ///
    /// `selectModel` already writes on every selection, including the automatic
    /// one; this is the same write at the one moment that decides whether the
    /// user is ever shown this screen again. It is the guard, not the mechanism:
    /// no future path can reach `hasCompletedOnboarding = true` leaving the app
    /// with an engine it cannot load.
    func commitSelectedModel() -> Bool {
        guard let selected = unifiedModels.first(where: { $0.id == selectedModelId }),
              isDownloaded(selected.type)
        else {
            return false
        }
        selectModel(selected)
        return true
    }

    func selectModel(_ model: OnboardingUnifiedModel) {
        selectedModelId = model.id

        switch model.type {
        case .whisper(let url, _):
            AppPreferences.shared.selectedEngine = .whisper
            let modelPath = modelManager.modelsDirectory.appendingPathComponent(url.lastPathComponent).path
            AppPreferences.shared.selectedWhisperModelPath = modelPath
        case .parakeet(let version):
            AppPreferences.shared.selectedEngine = .fluidaudio
            AppPreferences.shared.fluidAudioModelVersion = version
        case .engine(let kind):
            AppPreferences.shared.selectedEngine = kind
        }

        // The engine may not do the language the user picked at the top of this
        // screen; `language(after:)` is where that is decided.
        let language = model.language(
            after: selectedLanguage,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
        if language != selectedLanguage {
            selectedLanguage = language
        }
    }

    @MainActor
    func downloadModel(_ model: OnboardingUnifiedModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        isCompilingModel = false
        downloadingModelName = model.name
        downloadProgress = 0.0

        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
            unifiedModels[index].downloadProgress = 0.0
        }

        switch model.type {
        case .whisper(let url, _):
            try await downloadWhisperModel(model: model, url: url)
        case .parakeet(let version):
            try await downloadParakeetModel(model: model, version: version)
        case .engine(let kind):
            try await downloadEngineModel(model: model, kind: kind)
        }
    }

    /// Fetches the weights for an engine that has exactly one set of them, and
    /// pays the Neural Engine compile here rather than during the user's first
    /// recording.
    ///
    /// The engine owns the work - this only drives the progress UI - and
    /// `ModelLoadCoordinator` inside it collapses this download with any other
    /// request for the same weights, so nothing is fetched twice if Settings is
    /// somehow open behind onboarding.
    @MainActor
    private func downloadEngineModel(model: OnboardingUnifiedModel, kind: EngineKind) async throws {
        let modelId = model.id

        downloadTask = Task {
            defer {
                Task { @MainActor in
                    self.isDownloading = false
                    self.isCompilingModel = false
                    self.downloadingModelName = nil
                    self.downloadProgress = 0.0
                }
            }

            let onProgress: DownloadUtils.ProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, let task = self.downloadTask, !task.isCancelled else { return }
                    self.downloadProgress = progress.fractionCompleted
                    if let index = self.unifiedModels.firstIndex(where: { $0.id == modelId }) {
                        self.unifiedModels[index].downloadProgress = progress.fractionCompleted
                    }
                    if case .compiling = progress.phase {
                        self.isCompilingModel = true
                    }
                }
            }

            switch kind {
            case .sensevoice:
                try await SenseVoiceEngine.prepareModels(progressHandler: onProgress)
            case .paraformer:
                try await ParaformerEngine.prepareModels(progressHandler: onProgress)
            case .whisper, .fluidaudio:
                // Unreachable: these engines pick between several models, so they
                // reach this screen as `.whisper` / `.parakeet` rows instead.
                return
            }

            try Task.checkCancellation()

            await MainActor.run {
                if let index = self.unifiedModels.firstIndex(where: { $0.id == modelId }) {
                    self.unifiedModels[index].isDownloaded = true
                    self.unifiedModels[index].downloadProgress = 1.0
                }
                self.selectModel(model)
            }
        }

        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Manual cancellation, not a failure to report.
        }
    }
    
    @MainActor
    private func downloadWhisperModel(model: OnboardingUnifiedModel, url: URL) async throws {
        downloadTask = Task {
            do {
                let filename = url.lastPathComponent
                
                try await modelManager.downloadModel(url: url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.unifiedModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 0.0
                    }
                    selectModel(model)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    @MainActor
    private func downloadParakeetModel(model: OnboardingUnifiedModel, version: String) async throws {
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let modelId = model.id
                let models = try await AsrModels.downloadAndLoad(version: asrVersion) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        self.downloadProgress = progress.fractionCompleted
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == modelId }) {
                            self.unifiedModels[index].downloadProgress = progress.fractionCompleted
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 1.0
                    }
                    selectModel(model)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if !wasCancelled {
                throw error
            }
        }
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if let model = unifiedModels.first(where: { $0.name == modelName }) {
                if case .whisper(let url, _) = model.type {
                    let filename = url.lastPathComponent
                    modelManager.cancelDownload(name: filename)
                }
            }
            if let index = unifiedModels.firstIndex(where: { $0.name == modelName }) {
                unifiedModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        isCompilingModel = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var appState: AppState
    @State private var showError = false
    @State private var errorMessage = ""

    /// The view model is injectable so the screen can be rendered in a known
    /// state - a Chinese user's first screen, say - by a preview or a
    /// screenshot. It stays an autoclosure so the default is built once by
    /// `StateObject`, and not again on every re-render: `OnboardingViewModel`'s
    /// initialiser writes the language and hotkey preferences, so constructing a
    /// spare one is not free.
    init(viewModel: @autoclosure @escaping () -> OnboardingViewModel = OnboardingViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    private let keyboardLayoutInfo: KeyboardLayoutInfo? = KeyboardLayoutProvider.shared.resolveInfo()

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient background
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Text("EchoForge")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(
                            .white
                        )
                }
                .padding(.bottom, 8)
                
                // Language Selection
                HStack(spacing: 8) {
                    
                    Picker("Language", selection: $viewModel.selectedLanguage) {
                        ForEach(viewModel.offeredLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code)
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    // 150 pt left the label and the menu fighting over the same
                    // space, and "Chinese" came out as "Chine…" on the first
                    // screen of the users this engine work is for.
                    .frame(width: 220)
                }
                
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    Toggle(isOn: $viewModel.useAsianAutocorrect) {
                        Text("Use Asian Autocorrect")
                            .font(.caption)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.white.opacity(0.03),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            Divider()
            
            // Content - Scrollable area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Shortcut Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shortcut")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Choose how to trigger recording")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if let layoutInfo = keyboardLayoutInfo {
                            OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut, layoutInfo: layoutInfo)
                        }
                        
                        HStack(spacing: 8) {
                            OnboardingShortcutCard(
                                title: "⌥ + ~",
                                subtitle: "Key Combination",
                                isSelected: viewModel.selectedShortcut == .keyCombination
                            ) {
                                viewModel.selectedShortcut = .keyCombination
                            }
                            
                            OnboardingShortcutCard(
                                title: "Right ⌥",
                                subtitle: "Single Modifier Key",
                                isSelected: viewModel.selectedShortcut == .rightOption
                            ) {
                                viewModel.selectedShortcut = .rightOption
                            }
                        }
                        
                        if viewModel.selectedShortcut == .rightOption {
                            Text("⚠️ Single modifier key mode requires Input Monitoring permission (macOS needs it to detect modifier keys globally). Only modifier key events are monitored — no regular keystrokes.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }

                        Text("You can change this later in Settings")
                            .font(.caption2)
                            .foregroundColor(Color(.tertiaryLabelColor))
                    }
                    
                    // Model Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Download a model to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if offersChineseEngines {
                            // Written in English with the Chinese terms in
                            // Traditional characters, because that is the reader
                            // this paragraph is for: the app's interface is
                            // English, and the one thing a Traditional-Chinese
                            // user has to know before downloading either engine
                            // is that neither writes 繁體字.
                            Text("Dictating Chinese (中文)? The Mandarin (國語) engines below run on your Mac. "
                                + "Both write Simplified Chinese (簡體字) and the app does not convert it to "
                                + "Traditional (繁體字); the notes under each say what else they do to your text.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 8) {
                            // The Chinese engines are only offered to someone
                            // dictating Chinese - see
                            // `OnboardingUnifiedModels.isVisible`, which is the
                            // rule Settings already uses for the Hebrew model.
                            ForEach($viewModel.unifiedModels) { $model in
                                if OnboardingUnifiedModels.isVisible(
                                    model,
                                    selectedLanguage: viewModel.selectedLanguage,
                                    systemLanguage: LanguageUtil.getSystemLanguage()
                                ) {
                                    OnboardingUnifiedModelItemView(model: $model, viewModel: viewModel)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            // Footer with Continue button
            HStack {
                Spacer()
                Button(action: {
                    handleContinueButtonTap()
                }) {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canContinue || viewModel.isDownloading)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(.windowBackgroundColor)
                
                // Subtle gradient overlay
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.02),
                        Color.clear,
                        Color.purple.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        // The row's own download failures are reported by the row; this one is
        // the screen's, raised when Continue cannot be honoured.
        .alert("Model Unavailable", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func handleContinueButtonTap() {
        guard viewModel.commitSelectedModel() else {
            // Only reachable if the model went missing between selecting it and
            // pressing Continue. Re-reading the rows puts the screen back in
            // step with the disk rather than sending the user on with an engine
            // that cannot load.
            viewModel.initializeUnifiedModels()
            errorMessage = "That model is no longer on this Mac. Download one to continue."
            showError = true
            return
        }
        appState.hasCompletedOnboarding = true
    }

    /// Whether the Chinese engines are on screen, which is what the paragraph
    /// above them is explaining. Asked of the same visibility rule the rows use
    /// so the two cannot disagree.
    private var offersChineseEngines: Bool {
        viewModel.unifiedModels.contains { model in
            model.preferredLanguage == "zh"
                && OnboardingUnifiedModels.isVisible(
                    model,
                    selectedLanguage: viewModel.selectedLanguage,
                    systemLanguage: LanguageUtil.getSystemLanguage()
                )
        }
    }
}

struct OnboardingUnifiedModelItemView: View {
    @Binding var model: OnboardingUnifiedModel
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showError = false
    @State private var errorMessage = ""

    var isSelected: Bool {
        viewModel.selectedModelId == model.id
    }

    private var isBusy: Bool {
        viewModel.isDownloading && viewModel.downloadingModelName == model.name
    }

    var body: some View {
        // An engine row's status line and caveats run the full width of the row
        // rather than sharing a column with the download button: they are
        // sentences, and half a 450 pt sheet turns them into a ladder of three
        // and four words.
        VStack(alignment: .leading, spacing: 10) {
            summaryRow

            if let entry = model.catalogEntry {
                VStack(alignment: .leading, spacing: 8) {
                    if isBusy {
                        progressBar
                    }

                    if let status = model.status(isBusy: isBusy, isCompiling: viewModel.isCompilingModel) {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    OnboardingEngineNotesView(entry: entry)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.selectModel(model)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var summaryRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let recommendation = model.recommendation {
                        Text(recommendation)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }

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
                    .fixedSize(horizontal: false, vertical: true)

                // Engine rows put their bar full width below instead, beside
                // the status line that explains what it is doing.
                if isBusy && model.catalogEntry == nil {
                    progressBar
                        .padding(.top, 4)
                }
            }

            Spacer()

            actionControl
        }
    }

    /// Indeterminate once CoreML starts compiling: that phase publishes no
    /// fraction and is the longer half of a cold start, so a bar frozen at 100 %
    /// would read as a hang.
    @ViewBuilder
    private var progressBar: some View {
        if viewModel.isCompilingModel {
            ProgressView()
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
        } else {
            ProgressView(value: model.downloadProgress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        if isBusy {
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
                    viewModel.selectModel(model)
                }) {
                    Text("Select")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                // Only the engine rows state a size. The Whisper and Parakeet
                // rows never have, and this is not the change that starts - but
                // 240 MB against 653 MB is most of the choice between the two
                // Chinese engines, so those two say it.
                if let megabytes = model.downloadMegabytes {
                    Text(formatModelSize(megabytes: megabytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

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
}

/// The honest part of an engine row: what the model will do to the user's text,
/// and who made it.
///
/// Every string here comes from `EngineCatalog`, which is also what Settings
/// renders. That is not only tidiness: FunASR Model Open Source License v1.1
/// §2.2 requires the credit and the links, and a second hand-written copy of
/// this block in onboarding is how one of them would quietly go missing.
struct OnboardingEngineNotesView: View {
    let entry: EngineCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            if let credit = entry.attributionCredit {
                Text("\(credit). Downloaded to your Mac, not bundled with the app.")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                HStack(spacing: 12) {
                    ForEach(entry.attribution) { link in
                        Link(link.label, destination: link.url)
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyCap: View {
    let label: String
    let w: CGFloat
    let h: CGFloat
    let highlighted: Bool
    
    var body: some View {
        Text(label)
            .font(.system(size: w > 20 ? 9 : 7, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? Color.accentColor.opacity(0.35) : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(highlighted ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .foregroundColor(highlighted ? .white : .secondary)
    }
}

struct OnboardingKeyboardView: View {
    let selectedShortcut: OnboardingShortcutOption
    let layoutInfo: KeyboardLayoutInfo
    
    private let gap: CGFloat = 2
    private let pad: CGFloat = 6
    private let refUnits: CGFloat = 14.5
    private let refGaps: CGFloat = 13
    
    private static let row0Keycodes: [UInt16] = [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    private static let row1Keycodes: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]
    private static let row2Keycodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]
    private static let row3Keycodes: [UInt16] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]
    
    private func isHighlighted(_ id: String) -> Bool {
        switch selectedShortcut {
        case .keyCombination:
            return id == "leftOption" || id == "tilde"
        case .rightOption:
            return id == "rightOption"
        }
    }
    
    private func label(_ keycode: UInt16) -> String {
        layoutInfo.labels[keycode] ?? ""
    }
    
    private func u(for width: CGFloat) -> CGFloat {
        (width - pad * 2 - gap * refGaps) / refUnits
    }
    
    private func wideKey(singleCount: Int, wideCount: Int, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let totalGaps = CGFloat(singleCount + wideCount - 1) * gap
        return (rowWidth - singleWidth - totalGaps) / CGFloat(wideCount)
    }
    
    private func spaceWidth(singleCount: Int, cmdWidth: CGFloat, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let cmds = cmdWidth * 2
        let totalGaps = CGFloat(singleCount + 3) * gap
        return rowWidth - singleWidth - cmds - totalGaps
    }
    
    var body: some View {
        GeometryReader { geo in
            let u = u(for: geo.size.width)
            let h = u
            
            let backspace = refUnits * u + refGaps * gap - 13 * u - 13 * gap
            let tab = backspace
            let caps = wideKey(singleCount: 11, wideCount: 2, u: u)
            let shift = wideKey(singleCount: 10, wideCount: 2, u: u)
            let cmd = u * 1.25
            let space = spaceWidth(singleCount: 7, cmdWidth: cmd, u: u)
            
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    KeyCap(label: label(50), w: u, h: h, highlighted: isHighlighted("tilde"))
                    ForEach(Array(Self.row0Keycodes.dropFirst()), id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⌫", w: backspace, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇥", w: tab, h: h, highlighted: false)
                    ForEach(Self.row1Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: label(42), w: u, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇪", w: caps, h: h, highlighted: false)
                    ForEach(Self.row2Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⏎", w: caps, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                    ForEach(Self.row3Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "fn", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌃", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("leftOption"))
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "", w: space, h: h, highlighted: false)
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("rightOption"))
                    KeyCap(label: "←", w: u, h: h, highlighted: false)
                    VStack(spacing: 1) {
                        KeyCap(label: "↑", w: u, h: h / 2 - 0.5, highlighted: false)
                        KeyCap(label: "↓", w: u, h: h / 2 - 0.5, highlighted: false)
                    }
                    KeyCap(label: "→", w: u, h: h, highlighted: false)
                }
            }
            .padding(pad)
        }
        .frame(height: heightForWidth(450 - 24))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor).opacity(0.3))
        )
        .animation(.easeInOut(duration: 0.2), value: selectedShortcut)
    }
    
    private func heightForWidth(_ width: CGFloat) -> CGFloat {
        let u = u(for: width)
        return pad * 2 + u * 5 + gap * 4
    }
}

struct OnboardingShortcutCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                    .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView()
}

