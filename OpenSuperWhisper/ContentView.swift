//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var recordings: [Recording] = []
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    @Published var shouldClearSearch = false

    /// Mirrored out of `TranscriptionService` rather than read through it:
    /// SwiftUI does not republish a nested `ObservableObject`, so a banner
    /// driven straight off `transcriptionService.isEngineConfigured` would only
    /// appear the next time something else redrew this view.
    @Published var isEngineConfigured = true

    /// The same mirroring for the model-preparation state, which is what makes
    /// preparation non-modal: it is a strip above the record button, not a sheet
    /// over the history. The list below stays scrollable, searchable and
    /// playable throughout.
    @Published var selection: EngineSelection?
    @Published var modelPreparation: ModelPreparation?
    @Published var preparationFailure: String?

    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && self.state != .decoding {
                    self.state = .connecting
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording && self.state != .decoding {
                    self.state = .recording
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)

        transcriptionService.$isEngineConfigured
            .receive(on: RunLoop.main)
            .sink { [weak self] isConfigured in
                self?.isEngineConfigured = isConfigured
            }
            .store(in: &cancellables)

        transcriptionService.$selection
            .receive(on: RunLoop.main)
            .sink { [weak self] selection in
                self?.selection = selection
            }
            .store(in: &cancellables)

        transcriptionService.$modelPreparation
            .receive(on: RunLoop.main)
            .sink { [weak self] preparation in
                self?.modelPreparation = preparation
            }
            .store(in: &cancellables)

        transcriptionService.$preparationFailure
            .receive(on: RunLoop.main)
            .sink { [weak self] failure in
                self?.preparationFailure = failure
            }
            .store(in: &cancellables)
    }
    
    func loadInitialData() {
        currentSearchQuery = ""
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        
        // Capture current state for async task
        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let offset = page * limit
        
        
        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }
            
            
            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }
                
                // Ensure we are still consistent with the request (basic check)
                guard self.currentSearchQuery == query else { 
                    return 
                }
                
                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }
                
                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }
    
    func search(query: String) {
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }
    
    func handleProgressUpdate(id: UUID, transcription: String?, rawTranscription: String?, progress: Float, status: RecordingStatus, isRegeneration: Bool?) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
                // Empty means "this transcription has no original worth
                // keeping", which is a value, not a missing one.
                recordings[index].rawTranscription = (rawTranscription?.isEmpty ?? true)
                    ? nil : rawTranscription
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
    }
    
    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
    }

    var isRecording: Bool {
        recorder.isRecording
    }
    
    func startRecording() {
        guard microphoneService.getActiveMicrophone() != nil else { return }

        if microphoneService.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopBlinking()
            stopDurationTimer()
            recordingDuration = 0
        } else {
            state = .recording
            startBlinking()
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
        }
        
        recorder.startRecording()
    }

    func startDecoding() {
        state = .decoding
        stopBlinking()
        stopDurationTimer()
        
        IndicatorWindowManager.shared.hide()

        Task { [weak self] in
            guard let self = self else { return }
            
            if let tempURL = await self.recorder.stopRecording() {
                let duration = await AudioUtil.audioDuration(url: tempURL)
                do {
                    print("start decoding...")
                    let styled = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    let text = styled.final

                    if text.isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        print("No speech detected, dictation discarded")
                    } else {
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        let newRecording = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: duration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil,
                            rawTranscription: styled.originalWorthKeeping
                        )

                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)

                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                            
                            if !self.currentSearchQuery.isEmpty {
                                self.shouldClearSearch = true
                                self.currentSearchQuery = ""
                            }
                            self.recordings.insert(newRecording, at: 0)
                        }

                        print("Transcription result: \(text)")
                    }
                } catch {
                    print("Error transcribing audio: \(error)")

                    switch DictationFailureOutcome.forError(error) {
                    case .keep(let reason, _):
                        // The recording lands in the list carrying the reason;
                        // the banner above says what to do about it, and the
                        // row's regenerate button transcribes it once that is
                        // done.
                        await MainActor.run {
                            if let kept = self.recordingStore.keepFailedDictation(
                                temporaryURL: tempURL,
                                duration: duration,
                                reason: reason
                            ) {
                                self.recordings.insert(kept, at: 0)
                            }
                        }
                    case .discard:
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                }

                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            } else {
                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
    
    private func startDurationTimerIfNeeded() {
        guard durationTimer == nil else { return }
        if recordingStartTime == nil {
            recordingStartTime = Date()
            recordingDuration = 0
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let startTime = Date()
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = startTime.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showDeleteConfirmation = false
    @State private var searchTask: Task<Void, Never>? = nil

    private var currentShortcutDescription: String {
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none
        if mouseButton != .none {
            return mouseButton.shortSymbol
        }
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if modifierKey != .none {
            return modifierKey.shortSymbol
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return ""
    }
    
    private func performSearch(_ query: String) {
        searchTask?.cancel()
        
        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }

    var body: some View {
        VStack {
            if permissionsManager.isMissingRequiredPermission {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .onChange(of: searchText) { _, newValue in
                                performSearch(newValue)
                            }

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                debouncedSearchText = ""
                                searchTask?.cancel()
                                viewModel.search(query: "")
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(ThemePalette.panelSurface(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                    )
                    .cornerRadius(20)
                    .padding([.horizontal, .top])

                    ScrollView(showsIndicators: false) {
                        if viewModel.recordings.isEmpty {
                            VStack(spacing: 16) {
                                if !debouncedSearchText.isEmpty {
                                    // Show "no results" for search
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No results found")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Try different search terms")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                } else {
                                    // Show "start recording" tip
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No recordings yet")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Tap the record button below to get started")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)

                                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                        VStack(spacing: 8) {
                                            Text("Pro Tip:")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)

                                            HStack(spacing: 4) {
                                                Text("Press")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                                Text(shortcut.description)
                                                    .font(.system(size: 16, weight: .medium))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color.secondary.opacity(0.2))
                                                    .cornerRadius(6)
                                                Text("anywhere")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }

                                            Text("to quickly record and paste text")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 16)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(viewModel.recordings) { recording in
                                    RecordingRow(
                                        recording: recording,
                                        searchQuery: debouncedSearchText,
                                        onDelete: {
                                            viewModel.deleteRecording(recording)
                                        },
                                        onRegenerate: {
                                            Task {
                                                await TranscriptionQueue.shared.requeueRecording(recording)
                                            }
                                        }
                                    )
                                    .id(recording.id)
                                    .onAppear {
                                        if recording.id == viewModel.recordings.last?.id {
                                            viewModel.loadMore()
                                        }
                                    }
                                }
                                
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 16)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.recordings.count)
                    .animation(.easeInOut(duration: 0.2), value: debouncedSearchText.isEmpty)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        ThemePalette.windowBackground(colorScheme).opacity(1),
                                        ThemePalette.windowBackground(colorScheme).opacity(0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 20)
                    }

                    VStack(spacing: 16) {
                        // Above the record button rather than in place of it,
                        // and never over the history: preparing a model is a
                        // strip of status here, and everything below stays
                        // scrollable, searchable and playable while it runs.
                        if !viewModel.isEngineConfigured {
                            EngineUnavailableBanner(
                                openSettings: { isSettingsPresented = true },
                                retry: { viewModel.transcriptionService.retryPreparingDesiredEngine() }
                            )
                            .padding(.top, 12)
                        } else if let preparation = viewModel.modelPreparation {
                            ModelPreparationBanner(
                                preparation: preparation,
                                activeEngine: viewModel.selection?.active,
                                cancel: { viewModel.transcriptionService.cancelDesiredEnginePreparation() }
                            )
                            .padding(.top, 12)
                        } else if let failure = viewModel.preparationFailure,
                                  let selection = viewModel.selection,
                                  selection.isDesiredEnginePending {
                            ModelPreparationFailedBanner(
                                engine: selection.desired,
                                message: failure,
                                retry: { viewModel.transcriptionService.retryPreparingDesiredEngine() }
                            )
                            .padding(.top, 12)
                        }

                        Button(action: {
                            if viewModel.isRecording {
                                viewModel.startDecoding()
                            } else {
                                viewModel.startRecording()
                            }
                        }) {
                            if viewModel.state == .decoding || viewModel.state == .connecting {
                                ProgressView()
                                    .scaleEffect(1.0)
                                    .frame(width: 48, height: 48)
                                    .contentTransition(.symbolEffect(.replace))
                            } else {
                                MainRecordButton(isRecording: viewModel.isRecording)
                            }
                        }
                        .buttonStyle(.plain)
                        // Preparing a model deliberately does not appear here:
                        // dictation is disabled only when there is no ready
                        // model at all, which is what `isEngineConfigured` now
                        // means. A download running in the background is not a
                        // reason to take the record button away.
                        .disabled(!viewModel.isEngineConfigured || viewModel.transcriptionService.isTranscribing || viewModel.transcriptionQueue.isProcessing || viewModel.state == .decoding || viewModel.microphoneService.availableMicrophones.isEmpty)
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)

                        // Нижняя панель с подсказкой и кнопками управления
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                // Подсказка о шорткате
                                HStack(spacing: 6) {
                                    Text(currentShortcutDescription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("to show mini recorder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)

                                // Подсказка о drag-n-drop
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .foregroundColor(.secondary)
                                        .imageScale(.medium)
                                    Text("Drop audio file here to transcribe")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)
                            }

                            Spacer()

                            HStack(spacing: 12) {
                                MicrophonePickerIconView(microphoneService: viewModel.microphoneService)
                                
                                if !viewModel.recordings.isEmpty {
                                    Button(action: {
                                        showDeleteConfirmation = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.title3)
                                            .foregroundColor(.secondary)
                                            .frame(width: 32, height: 32)
                                            .background(ThemePalette.panelSurface(colorScheme))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                                            )
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete all recordings")
                                    .confirmationDialog(
                                        "Delete All Recordings",
                                        isPresented: $showDeleteConfirmation,
                                        titleVisibility: .visible
                                    ) {
                                        Button("Delete All", role: .destructive) {
                                            viewModel.deleteAllRecordings()
                                        }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                                    }
                                    .dismissesOnPowerOff($showDeleteConfirmation)
                                    .interactiveDismissDisabled()
                                }
                                
                                Button(action: {
                                    isSettingsPresented.toggle()
                                }) {
                                    Image(systemName: "gear")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                        .frame(width: 32, height: 32)
                                        .background(ThemePalette.panelSurface(colorScheme))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                                        )
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("Settings")
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
        .background(ThemePalette.windowBackground(colorScheme))
        .onAppear {
            viewModel.loadInitialData()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }
            
            let transcription = userInfo["transcription"] as? String
            let rawTranscription = userInfo["rawTranscription"] as? String
            let isRegeneration = userInfo["isRegeneration"] as? Bool

            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                rawTranscription: rawTranscription,
                progress: progress,
                status: status,
                isRegeneration: isRegeneration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.loadInitialData()
        }
        // There used to be a full-window scrim here whenever a model was
        // loading - "Loading Whisper Model..." over a dimmed, unusable history.
        // It is gone on purpose. Loading a model is background work the user did
        // not ask to watch, and it now takes minutes rather than seconds when a
        // download is involved, so it says what it is doing in the status strip
        // above the record button and leaves the window alone.
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .dismissesOnPowerOff($isSettingsPresented)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            isSettingsPresented = true
        }
        .onChange(of: viewModel.shouldClearSearch) { _, shouldClear in
            if shouldClear {
                searchText = ""
                debouncedSearchText = ""
                searchTask?.cancel()
                viewModel.shouldClearSearch = false
            }
        }
    }
}

/// The main window's statement that nothing can transcribe, and the one action
/// that fixes it.
///
/// The dictation indicator has room for four words and a recording that failed
/// has room for a sentence; this is where the user is actually looking, so this
/// is where the button lives.
struct EngineUnavailableBanner: View {
    let openSettings: () -> Void
    let retry: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 3) {
                Text("No transcription engine is ready")
                    .font(.subheadline.weight(.semibold))

                Text("Dictation is off until a model is ready. Try again, or choose one in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Settings", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

/// What the app is fetching, while it carries on working.
///
/// Non-modal by design: this is a strip above the record button, not a sheet.
/// The bar is determinate only while bytes are moving - the Neural Engine
/// compile that follows publishes no fraction and is the longer half of a cold
/// start, so it switches to an indeterminate bar and says `Preparing model…`
/// rather than freezing a number that has stopped meaning anything.
struct ModelPreparationBanner: View {
    let preparation: ModelPreparation
    let activeEngine: EngineKind?
    let cancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Which engine is doing the transcribing meanwhile. Named rather than
    /// implied: dictating on a different model than the one you just chose is
    /// exactly the kind of thing a user should not have to infer from results.
    private var meanwhileLine: String? {
        guard let activeEngine, activeEngine != preparation.engine else { return nil }
        return "Dictation is using \(EngineCatalog.entry(for: activeEngine).displayName) until it is ready."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.accentColor)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 5) {
                Text(preparation.statusLine)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let meanwhileLine {
                    Text(meanwhileLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Group {
                    if case .downloading(let fraction) = preparation.stage {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
            }

            Spacer(minLength: 8)

            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(ThemePalette.panelSurface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

/// A preparation that stopped short, and the way back.
///
/// Separate from `EngineUnavailableBanner` because the app is still working:
/// something is transcribing, it is just not the model that was asked for.
struct ModelPreparationFailedBanner: View {
    let engine: EngineKind
    let message: String
    let retry: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.orange)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(EngineCatalog.entry(for: engine).displayName) is not ready yet")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: {
                    permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(ThemePalette.panelSurface(colorScheme))
        .cornerRadius(10)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var showOriginal = false
    @State private var showComparison = false
    /// Compared once, when the comparison is opened.
    ///
    /// The row rebuilds on hover, and a transcript of a long dictation is a lot
    /// of words to line up against another one; doing it in `body` would put
    /// that work behind every mouse move across the history.
    @State private var comparisonSegments: [TextDiffSegment] = []
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    /// What the engine heard, when post-processing changed it into something
    /// else.
    ///
    /// This is the half of the rewriting feature that makes it safe to use: the
    /// styled text is what the app pasted, and the words the user actually said
    /// are still here, one click away, in the row next to it.
    private var originalTranscription: String? {
        guard let original = recording.rawTranscription, !original.isEmpty,
              original != recording.transcription else { return nil }
        return original
    }

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }
    
    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }
    
    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }
    
    private var statusText: String {
        switch recording.status {
        case .pending:
            return "In queue..."
        case .converting:
            return "Converting..."
        case .transcribing:
            return "Transcribing..."
        case .completed:
            return ""
        case .failed:
            return "Failed"
        }
    }
    
    private var displayText: String {
        if recording.transcription.isEmpty || recording.transcription == "Starting transcription..." || recording.transcription == "In queue..." {
            return ""
        }
        return recording.transcription
    }

    /// The two collapsed disclosures under a post-processed row: what the engine
    /// heard, and what post-processing did to it.
    ///
    /// Both are collapsed by default because the styled text is the answer the
    /// user asked for. "Show original" is present at all because it is the only
    /// copy of what they said; "Compare" is what turns that copy into an answer
    /// to the question the row actually raises - which of these words are mine?
    @ViewBuilder
    private func originalTranscriptionSection(_ original: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                disclosureButton(
                    title: showOriginal ? "Hide original" : "Show original",
                    isExpanded: showOriginal,
                    help: "What the transcription engine heard, before post-processing"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showOriginal.toggle()
                    }
                }

                disclosureButton(
                    title: showComparison ? "Hide comparison" : "Compare",
                    isExpanded: showComparison,
                    help: "The original with the words post-processing dropped struck through"
                ) {
                    if !showComparison {
                        comparisonSegments = TextDiffUtil.compare(
                            original: original, revised: displayText
                        )
                    }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showComparison.toggle()
                    }
                }

                if showOriginal {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(original, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the original")
                    .transition(.opacity)
                }

                Spacer(minLength: 0)
            }

            if showOriginal {
                Text(original)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(ThemePalette.panelSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .transition(.opacity)
            }

            if showComparison {
                VStack(alignment: .leading, spacing: 6) {
                    TextDiffView(segments: comparisonSegments, font: .caption)
                        .padding(8)
                        .background(ThemePalette.panelSurface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if TextDiffUtil.hasVisibleChanges(in: comparisonSegments) {
                        TextDiffLegend()
                    } else {
                        // CJK spacing is a real post-processing change that the
                        // comparison deliberately does not mark up, and a panel
                        // with nothing struck through in it and no explanation
                        // reads as a bug.
                        Label("Only spacing or capitalisation changed here.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // A regeneration replaces the transcript underneath an open comparison
        // - sometimes only the raw side, when the final text lands unchanged -
        // and a comparison against text the row no longer shows is worse than
        // none.
        .onChange(of: recording.transcription) { _, _ in
            refreshComparison(against: original)
        }
        .onChange(of: recording.rawTranscription) { _, _ in
            refreshComparison(against: original)
        }
    }

    private func refreshComparison(against original: String) {
        guard showComparison else { return }
        comparisonSegments = TextDiffUtil.compare(original: original, revised: displayText)
    }

    private func disclosureButton(
        title: String, isExpanded: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPending && !isRegenerating {
                VStack(alignment: .leading, spacing: 4) {
                    if let sourceFileName = recording.sourceFileName {
                        Text(sourceFileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack(spacing: 6) {
                        if recording.status == .pending {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                           
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(recording.progress))
                                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.1), value: recording.progress)
                            }
                            .frame(width: 16, height: 16)

                            Text("\(Int(recording.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .contentTransition(.numericText())
                                .animation(.linear(duration: 0.1), value: recording.progress)
                        }
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            
            if recording.status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text("Transcription failed")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if !recording.transcription.isEmpty {
                        Text(recording.transcription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, isPending && !isRegenerating ? 4 : 8)
            } else if !displayText.isEmpty {
                ZStack(alignment: .topLeading) {
                    TranscriptionView(
                        transcribedText: displayText,
                        searchQuery: searchQuery,
                        isExpanded: $showTranscription
                    )
                    
                    if isRegenerating {
                        ShimmerOverlay()
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, isPending && !isRegenerating ? 4 : 8)

                if let original = originalTranscription {
                    originalTranscriptionSection(original)
                }
            } else if !isPending {
                Text("No speech detected")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.timestamp, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Text(recording.timestamp, style: .time)
                        Text("·")
                        Text(TextUtil.formatDuration(recording.duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                if isRegenerating {
                    Spacer()
                        .frame(width: 2)
                    HStack(spacing: 6) {
                        if recording.status == .pending {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(recording.progress))
                                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.1), value: recording.progress)
                            }
                            .frame(width: 16, height: 16)

                            Text("\(Int(recording.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .contentTransition(.numericText())
                                .animation(.linear(duration: 0.1), value: recording.progress)
                        }
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity)
                
                }

                Spacer()

                HStack(spacing: 16) {
                    if !isPending && recording.status != .failed && (isHovered || isPlaying) {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            } else {
                                audioRecorder.playRecording(url: recording.url)
                            }
                        }) {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isPlaying ? .red : ThemePalette.iconAccent(colorScheme))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                recording.transcription, forType: .string
                            )
                        }) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")
                        .transition(.opacity)
                    }

                    if (recording.status == .completed || recording.status == .failed) && isHovered {
                        Button(action: {
                            onRegenerate()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate transcription")
                        .transition(.opacity)
                    }

                    if isHovered || isPlaying || (isPending && !isRegenerating) || recording.status == .failed {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            }
                            onDelete()
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .animation(.easeInOut(duration: 0.2), value: isPlaying)
                .animation(.easeInOut(duration: 0.2), value: isRegenerating)
            }
            .animation(.easeInOut(duration: 0.2), value: isRegenerating)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(ThemePalette.cardBackground(colorScheme))
        }
        .background(ThemePalette.cardBackground(colorScheme))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.vertical, 4)
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.clear,
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    let searchQuery: String
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var highlightedAttributedString: AttributedString?
    @State private var computeTask: Task<Void, Never>?
    
    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }
    
    private var highlightedText: Text {
        guard !searchQuery.isEmpty else {
            return Text(transcribedText)
        }
        if let attributed = highlightedAttributedString {
            return Text(attributed)
        }
        return Text(transcribedText)
    }
    
    private func computeHighlighting() {
        computeTask?.cancel()
        
        guard !searchQuery.isEmpty else {
            highlightedAttributedString = nil
            return
        }
        
        let text = transcribedText
        let query = searchQuery
        
        computeTask = Task.detached(priority: .userInitiated) {
            var attributedString = AttributedString(text)
            let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            
            var searchStartIndex = text.startIndex
            while let range = text.range(of: query, options: searchOptions, range: searchStartIndex..<text.endIndex) {
                guard !Task.isCancelled else { return }
                if let attributedRange = Range(range, in: attributedString) {
                    attributedString[attributedRange].backgroundColor = .yellow
                    attributedString[attributedRange].foregroundColor = .black
                }
                searchStartIndex = range.upperBound
            }
            
            guard !Task.isCancelled else { return }

            let highlighted = attributedString
            await MainActor.run {
                self.highlightedAttributedString = highlighted
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isExpanded {
                    ScrollView {
                        highlightedText
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                if hasMoreLines {
                                    isExpanded.toggle()
                                }
                            }
                    )
                } else {
                    if hasMoreLines {
                        Button(action: { isExpanded.toggle() }) {
                            highlightedText
                                .font(.body)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        highlightedText
                            .font(.body)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(ThemePalette.linkText(colorScheme))
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            computeHighlighting()
        }
        .onChange(of: searchQuery) { _, _ in
            computeHighlighting()
        }
        .onChange(of: transcribedText) { _, _ in
            computeHighlighting()
        }
        .onDisappear {
            computeTask?.cancel()
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false
    @Environment(\.colorScheme) private var colorScheme
    
    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }
    
    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }
    
    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(ThemePalette.panelSurface(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(externalMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 200)
            .padding(.vertical, 8)
        }
    }
}

struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var buttonColor: Color {
        ThemePalette.recordButtonBase(colorScheme)
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        isRecording ? Color.red.opacity(0.8) : buttonColor.opacity(0.8),
                        isRecording ? Color.red : buttonColor.opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 48, height: 48)
            .shadow(
                color: isRecording ? .red.opacity(0.5) : buttonColor.opacity(0.3),
                radius: 12,
                x: 0,
                y: 0
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                isRecording ? .red.opacity(0.6) : buttonColor.opacity(0.6),
                                isRecording ? .red.opacity(0.3) : buttonColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(isRecording ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

enum ThemePalette {
    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.underPageBackgroundColor)
            : .white
    }

    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.gray.opacity(0.1)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }

    static func panelBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.gray.opacity(0.2)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.controlBackgroundColor)
            : Color.white
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.separatorColor)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
    }

    static func recordButtonBase(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? .white
            : Color(red: 0.35, green: 0.60, blue: 0.92)
    }

    static func iconAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .accentColor : .primary
    }

    static func linkText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .blue : .primary
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
