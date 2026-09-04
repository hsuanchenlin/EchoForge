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

    /// Which kinds the list is showing. Applied in SQL by `RecordingStore`, not
    /// to the loaded page, so it reaches rows paging has not fetched yet.
    @Published var provenanceFilter: HistoryProvenanceFilter = .all

    private var currentPage = 0
    private let pageSize = 100
    /// The phrase the loaded page was fetched for, resolved.
    ///
    /// The resolved value rather than the raw string, because resolving it is
    /// what turns "voice edit" into a badge and "2026-09" into a month, and
    /// doing that once per search rather than once per page keeps a `loadMore`
    /// from re-deciding what the user meant.
    private var currentSearchQuery = HistorySearchQuery("")
    private var currentFilter: HistoryProvenanceFilter = .all
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Gated on this window's own claim, the way the mini indicator's are.
        // `AudioRecorder` publishes to every subscriber, so an ungated sink drew
        // this window as recording - blinking dot, running duration - for the
        // Ask panel's question or a hotkey dictation it had nothing to do with.
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self, self.recordingSession != nil else { return }
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
                guard let self = self, self.recordingSession != nil else { return }
                if isRecording && self.state != .decoding {
                    self.state = .recording
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    // The claim was given back underneath this window - a start
                    // that could not open the microphone - so the session it is
                    // still holding names nothing and must not be presented to
                    // a stop later.
                    self.recordingSession = nil
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
        currentSearchQuery = HistorySearchQuery("")
        currentFilter = provenanceFilter
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    /// Reloads from the top under a new filter.
    ///
    /// The same reset `search(query:)` does, and for the same reason: page,
    /// contents and the "there is more" flag all describe the previous query.
    func applyFilter(_ filter: HistoryProvenanceFilter) {
        provenanceFilter = filter
        currentFilter = filter
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
        let filter = currentFilter
        let offset = page * limit


        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(
                    limit: limit, offset: offset, filter: filter)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(
                    query: query, limit: limit, offset: offset, filter: filter)
            }


            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }

                // Ensure we are still consistent with the request (basic check)
                guard self.currentSearchQuery == query, self.currentFilter == filter else {
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
    
    /// Reloads from the top under a new phrase.
    ///
    /// The phrase is resolved here - once per search rather than once per page -
    /// and the reset is the same one `applyFilter` does, for the same reason:
    /// page, contents and the "there is more" flag all describe the previous
    /// query.
    func search(query: String) {
        currentSearchQuery = HistorySearchQuery(query)
        currentFilter = provenanceFilter
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }
    
    func handleProgressUpdate(
        id: UUID, transcription: String?, rawTranscription: String?,
        clearsAICorrection: Bool, progress: Float, status: RecordingStatus,
        isRegeneration: Bool?
    ) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
                // Empty means "this transcription has no original worth
                // keeping", which is a value, not a missing one.
                recordings[index].rawTranscription = (rawTranscription?.isEmpty ?? true)
                    ? nil : rawTranscription
                if clearsAICorrection {
                    recordings[index].aiCorrectedAt = nil
                }
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
        }
    }
    
    /// Relabels one loaded row.
    ///
    /// A row the current filter no longer admits is left where it is rather than
    /// removed: it is the row the user just spoke, and having it vanish from
    /// under them the moment its outcome is known would hide the answer they
    /// were waiting for. The next reload applies the filter.
    func handleProvenanceUpdate(id: UUID, provenance: RecordingProvenance) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].provenance = provenance
    }

    func handleCorrection(
        id: UUID, transcription: String, rawTranscription: String, aiCorrectedAt: Date
    ) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].transcription = transcription
        recordings[index].rawTranscription = rawTranscription
        recordings[index].aiCorrectedAt = aiCorrectedAt
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

    /// The microphone claim this window holds, or nil when it holds none.
    private var recordingSession: RecordingSession?

    /// Whether **this window** is recording - not whether the microphone is
    /// busy. The record button branches on it, so reading the shared
    /// `recorder.isRecording` drew it as recording while the Ask panel was
    /// listening, and a press then decoded the panel's question as a dictation.
    var isRecording: Bool {
        recordingSession != nil
    }

    func startRecording() {
        guard microphoneService.getActiveMicrophone() != nil else { return }
        // Same claim the mini indicator makes, and for the same reason: this
        // button reaches the one shared recorder, so it must not take a session
        // the Ask panel or a hotkey dictation is already holding. Refused, it
        // leaves the window exactly as it was rather than showing a recording
        // state over nothing.
        guard let claimed = recorder.startRecording() else { return }
        recordingSession = claimed

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
    }

    func startDecoding() {
        guard let session = recordingSession else { return }
        recordingSession = nil

        state = .decoding
        stopBlinking()
        stopDurationTimer()

        IndicatorWindowManager.shared.hide()

        Task { [weak self] in
            guard let self = self else { return }

            if let tempURL = await self.recorder.stopRecording(session) {
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
                        var newRecording = Recording(
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
                        newRecording.provenance = .dictation

                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)

                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                            
                            if !self.currentSearchQuery.isEmpty {
                                self.shouldClearSearch = true
                                self.currentSearchQuery = HistorySearchQuery("")
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
    /// Focus for the search field, so ⌘F can put the caret in it.
    ///
    /// The field is always on screen - this is not a bar that appears - so the
    /// shortcut moves focus rather than revealing anything. It is the one way
    /// into search that needs no pointer, which is why it exists beside a field
    /// that is already visible.
    @FocusState private var isSearchFocused: Bool

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
    
    /// The one action that takes the list back to everything.
    ///
    /// Shared by the field's own clear button, the "Clear search" button on the
    /// no-results state, and the reset the view model asks for after a delete -
    /// three ways in, one behaviour, so a cancelled debounce or a stale
    /// `debouncedSearchText` cannot survive one of them.
    private func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        debouncedSearchText = ""
        viewModel.search(query: "")
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
                    HistorySearchBar(
                        text: $searchText,
                        filter: Binding(
                            get: { viewModel.provenanceFilter },
                            set: { viewModel.applyFilter($0) }
                        ),
                        clear: clearSearch,
                        focus: $isSearchFocused
                    )
                    .onChange(of: searchText) { _, newValue in
                        performSearch(newValue)
                    }
                    .padding([.horizontal, .top])

                    ScrollView(showsIndicators: false) {
                        if viewModel.recordings.isEmpty {
                            VStack(spacing: 16) {
                                if !debouncedSearchText.isEmpty || viewModel.provenanceFilter != .all {
                                    HistoryNoResultsView(
                                        query: debouncedSearchText,
                                        filter: viewModel.provenanceFilter,
                                        clear: clearSearch)
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
                            LazyVStack(spacing: 10) {
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
                            // Measured once, above the rows and inside the
                            // list's own padding: every card lays itself out
                            // for the width it is actually offered rather than
                            // for the width of the window.
                            .historyRowMetricsForContainerWidth()
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
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
            let clearsAICorrection = userInfo["clearsAICorrection"] as? Bool ?? false
            let isRegeneration = userInfo["isRegeneration"] as? Bool

            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                rawTranscription: rawTranscription,
                clearsAICorrection: clearsAICorrection,
                progress: progress,
                status: status,
                isRegeneration: isRegeneration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.loadInitialData()
        }
        // A command's outcome lands a second or two after its words, so the row
        // the user is already looking at is relabelled in place rather than on
        // the next reload.
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProvenanceDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let provenance = userInfo["provenance"] as? RecordingProvenance else { return }
            viewModel.handleProvenanceUpdate(id: id, provenance: provenance)
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingDidCorrectNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let transcription = userInfo["transcription"] as? String,
                  let rawTranscription = userInfo["rawTranscription"] as? String,
                  let aiCorrectedAt = userInfo["aiCorrectedAt"] as? Date else { return }
            viewModel.handleCorrection(
                id: id, transcription: transcription,
                rawTranscription: rawTranscription, aiCorrectedAt: aiCorrectedAt)
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
                searchTask?.cancel()
                searchText = ""
                debouncedSearchText = ""
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
        VStack(alignment: .leading, spacing: 6) {
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
                    // `fixedSize` vertically, not for show: without it the
                    // collapsed transcript takes whatever height the row can
                    // spare and truncates to one line at wide widths, which is
                    // the opposite of what `lineLimit(3)` is asking for.
                    if hasMoreLines {
                        Button(action: { isExpanded.toggle() }) {
                            highlightedText
                                .font(.body)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        highlightedText
                            .font(.body)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            // No inset of its own. The card is what sets this row's left
            // margin, and a transcript indented 8 pt further than the badge,
            // the chips and the timestamp above and below it is the one
            // misalignment a reader notices every time.
            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(ThemePalette.linkText(colorScheme))
                    .font(.footnote)
                }
                .buttonStyle(.plain)
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
    /// Light mode cannot use `NSColor.windowBackgroundColor`: on current macOS
    /// that token resolves to white, which is also the card fill, so a history
    /// list has no canvas for the cards to sit on and a hover wash-out has
    /// nowhere to contrast against. The grouped gray is the canvas; cards stay
    /// white.
    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.underPageBackgroundColor)
            : Color(red: 0.955, green: 0.960, blue: 0.972)
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

    // MARK: - History cards

    /// A history card's fill. Light mode stays white under the pointer: the
    /// hover is the firmer stroke and the elevated shadow, not a fill that
    /// washes the card into the canvas. Dark mode still lifts a shade, because
    /// a white fill there would be a flash.
    ///
    /// The lift is deliberately small. A card is a container for text the user
    /// is reading, and a hover state strong enough to notice out of the corner
    /// of the eye is a hover state that makes the words harder to read.
    /// The dark lift is blended against the token resolved **as dark**, not
    /// against whatever appearance happens to be current. `blended` is not a
    /// dynamic operation: it resolves its receiver there and then, so a blend
    /// written against the bare token reads `controlBackgroundColor` under the
    /// ambient appearance - white in a light-appearance process - and 7% of the
    /// way from white to white is white. That turned the dark hover fill into
    /// the flash this lift exists to avoid. `ThemePaletteTests` pins it.
    static func cardSurface(_ scheme: ColorScheme, hovered: Bool) -> Color {
        guard hovered, scheme == .dark else { return cardBackground(scheme) }
        return Color(nsColor: resolved(NSColor.controlBackgroundColor, in: .darkAqua)
            .blended(withFraction: 0.07, of: .white) ?? .controlBackgroundColor)
    }

    /// A dynamic system colour pinned to one appearance, for the cases that
    /// have to compute with its components rather than hand it to SwiftUI to
    /// resolve at draw time.
    private static func resolved(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        guard let appearance = NSAppearance(named: appearance) else { return color }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// A history card's border. Hover firms it up; a failed row keeps a warm
    /// edge so the state is legible before the badge is read - and the badge
    /// says it in words too, so colour never carries it alone.
    static func cardStroke(_ scheme: ColorScheme, hovered: Bool, failed: Bool) -> Color {
        if failed {
            return failureText(scheme).opacity(hovered ? 0.55 : 0.35)
        }
        if hovered {
            return scheme == .dark
                ? Color.white.opacity(0.22)
                : Color(red: 0.72, green: 0.76, blue: 0.84)
        }
        return cardBorder(scheme)
    }

    /// The drop shadow under a history card. Dark mode gets a deeper, tighter
    /// one because a soft grey shadow over a dark ground reads as a smudge.
    static func cardShadow(_ scheme: ColorScheme, elevated: Bool) -> Color {
        scheme == .dark
            ? Color.black.opacity(elevated ? 0.45 : 0.25)
            : Color(red: 0.35, green: 0.42, blue: 0.55).opacity(elevated ? 0.16 : 0.07)
    }

    /// The fill behind a metadata chip or a hovered action button.
    static func chipSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 0.93, green: 0.94, blue: 0.97)
    }

    /// The fill behind text quoted inside a card - the original transcript, the
    /// comparison - which has to stay distinct from the card under it.
    static func insetSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.05)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }

    /// The failure tint. Not `.red`: system red on white is bright enough to
    /// pull the eye off the transcript, and on a dark ground it vibrates.
    static func failureText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.53, blue: 0.48)
            : Color(red: 0.75, green: 0.18, blue: 0.16)
    }

    static func failureFill(_ scheme: ColorScheme) -> Color {
        failureText(scheme).opacity(scheme == .dark ? 0.18 : 0.10)
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
