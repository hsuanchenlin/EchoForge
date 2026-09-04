import Foundation
import Combine

@MainActor
class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecordingId: UUID?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?

    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                self.recordingStore.updateRecordingProgressTransient(
                    recordingId,
                    progress: newProgress,
                    status: .transcribing
                )
            }
    }

    /// What a cancelled item's row is left saying.
    ///
    /// It is written even though the only caller of `cancelRecording` today
    /// deletes the row a moment later: the delete is asynchronous, and until the
    /// row is gone it is still a `.converting` row that
    /// `getNextPendingRecording` counts as pending. Writing it out of the queue
    /// is what stops the loop picking it straight back up and transcribing the
    /// recording the user just cancelled. On a row that has already been
    /// deleted the write matches nothing and costs nothing.
    static let cancelledMessage = "Transcription cancelled"

    /// What a row the queue could not write out of the pending statuses is left
    /// saying. See `TranscriptionQueueStep`.
    static let abandonedMessage = "Transcription stopped. Try regenerating this recording."

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            transcriptionService.cancelTranscription()
            currentTranscriptionTask?.cancel()
        }
    }

    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }

    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }

    func startProcessingQueue() {
        guard !isProcessing else { return }

        isProcessing = true

        processingTask = Task { [weak self] in
            guard let self else { return }
            // In a `defer` so the queue stops being busy however the loop ends,
            // including a cancellation of this task. `isProcessing` gates
            // `IndicatorViewModel.isTranscriptionBusy`, which refuses to start a
            // dictation at all - so a queue left busy is not a stuck row, it is
            // an app that no longer dictates.
            defer {
                self.isProcessing = false
                self.processingTask = nil
                // Nothing is pending, so no id in here can still be waiting to
                // be cancelled. Left alone, the set only ever grew.
                self.cancelledRecordingIds.removeAll()
            }
            await self.cleanupMissingFiles()
            await self.processQueue()
        }
    }

    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()

        let recordingsToDelete = await Task.detached(priority: .utility) {
            var toDelete: [Recording] = []
            for recording in pendingRecordings {
                guard let sourceURLString = recording.sourceFileURL,
                      !sourceURLString.isEmpty else {
                    toDelete.append(recording)
                    continue
                }

                let sourceURL = URL(fileURLWithPath: sourceURLString)
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    toDelete.append(recording)
                }
            }
            return toDelete
        }.value
        
        for recording in recordingsToDelete {
            recordingStore.deleteRecording(recording)
        }
    }

    /// - Parameter provenance: what this audio is. A dropped file, an
    ///   open-with and a file the user pointed at are `.fileTranscription`; the
    ///   one caller with something else to say is the live session whose audio
    ///   was queued because the engine was busy
    ///   (`IndicatorViewModel.queuedProvenance`). Nothing here routes a spoken
    ///   intent, so nothing queued can become a command however it is worded.
    func addFileToQueue(
        url: URL, provenance: RecordingProvenance = .fileTranscription
    ) async {
        do {
            let durationInSeconds = await AudioUtil.audioDuration(url: url)

            let timestamp = Date()
            let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
            let id = UUID()

            var recording = Recording(
                id: id,
                timestamp: timestamp,
                fileName: fileName,
                transcription: "",
                duration: durationInSeconds,
                status: .pending,
                progress: 0.0,
                sourceFileURL: url.path
            )
            recording.provenance = provenance

            try await recordingStore.addRecordingSync(recording)

            startProcessingQueue()
        } catch {
            print("Failed to add file to queue: \(error)")
        }
    }

    func requeueRecording(_ recording: Recording) async {
        let sourceURL: URL? = await Task.detached(priority: .userInitiated) {
            if let existingSource = recording.sourceFileURL,
               !existingSource.isEmpty,
               FileManager.default.fileExists(atPath: existingSource) {
                return URL(fileURLWithPath: existingSource)
            } else if FileManager.default.fileExists(atPath: recording.url.path) {
                return recording.url
            }
            return nil
        }.value
        
        guard let sourceURL = sourceURL else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        // A command row is about to get a different transcript, and its stored
        // sentence quotes the old one. See `RecordingProvenance.reTranscribed`.
        let reTranscribed = recording.provenance.reTranscribed()
        if reTranscribed != recording.provenance {
            await recordingStore.updateProvenance(recording.id, to: reTranscribed)
        }

        do {
            try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
        } catch {
            print("Failed to update source URL: \(error)")
        }

        startProcessingQueue()
    }

    nonisolated static func shouldDiscardEmptyDictation(text: String, sourceURL: URL) -> Bool {
        text.isEmpty && sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path)
    }

    private func processQueue() async {
        var previous: TranscriptionQueueStep.Previous?

        while true {
            let pending = recordingStore.getNextPendingRecording()
            switch TranscriptionQueueStep.next(pending?.id, after: previous) {
            case .finished:
                return

            case .abandon(let id):
                await recordingStore.updateRecordingProgressOnlySync(
                    id,
                    transcription: Self.abandonedMessage,
                    progress: 0.0,
                    status: .failed
                )
                previous = .init(id: id, settled: false, abandoned: true)

            case .process(let id):
                // `pending` is non-nil on this branch by construction: `.process`
                // is only produced for an id that came out of it.
                guard let recording = pending else { return }
                currentRecordingId = id
                let settled = await processRecording(recording)
                currentRecordingId = nil
                previous = .init(id: id, settled: settled)
            }
        }
    }

    /// Runs one recording through the engine.
    ///
    /// - Returns: whether the row was left out of the queue's pending statuses -
    ///   completed, failed, or deleted. Every path here settles it, and the
    ///   caller's guard exists for the one case this cannot promise: a database
    ///   write that failed and was swallowed. See `TranscriptionQueueStep`.
    @discardableResult
    private func processRecording(_ recording: Recording) async -> Bool {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            // Written out of the queue rather than simply skipped. Left
            // `.pending` the row came straight back round and was transcribed
            // after all, which is the opposite of what cancelling means.
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: Self.cancelledMessage,
                progress: 0.0,
                status: .failed
            )
            return true
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return true
        }

        let sourceURL = URL(fileURLWithPath: sourceURLString)

        let sourceExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: sourceURL.path)
        }.value
        
        guard sourceExists else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return true
        }

        let isRegeneration = !recording.transcription.isEmpty && 
            recording.transcription != "In queue..." && 
            recording.transcription != "Starting transcription..."

        if isRegeneration {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "",
                progress: 0.0,
                status: .converting
            )
        }

        // Carries the inner task's answer out to the caller: the task itself is
        // `Task<Void, Never>` because `currentTranscriptionTask` is what
        // `cancelRecording` cancels, and giving it a value would mean awaiting a
        // cancelled task's result from the cancel path.
        var settled = false

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    settled = await self.settleCancelled(recording.id)
                    return
                }

                let settings = Settings()
                let styled = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings)
                let text = styled.final

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    settled = await self.settleCancelled(recording.id)
                    return
                }

                if Self.shouldDiscardEmptyDictation(text: text, sourceURL: sourceURL) {
                    await Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: sourceURL)
                    }.value
                    await recordingStore.deleteRecordingSync(recording)
                    settled = true
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        // Our own temp recordings are moved (no disk duplication);
                        // user-provided files must stay in place, so they are copied.
                        if sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path) {
                            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                        } else {
                            try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                        }
                    }
                }.value

                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    rawTranscription: styled.originalWorthKeeping,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false
                )
                settled = true

            } catch {
                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    settled = await self.settleCancelled(recording.id)
                } else {
                    await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "Failed to transcribe: \(error.localizedDescription)",
                        progress: 0.0,
                        status: .failed,
                        isRegeneration: false
                    )
                    settled = true
                }
            }
        }

        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
        return settled
    }

    /// Writes a cancelled row out of the queue.
    ///
    /// Always `true`: the row is either updated or already gone, and either way
    /// it is no longer something the loop should hand back. Kept as one function
    /// because a cancellation can be noticed at three different points in a pass
    /// and all three have to leave the same state behind.
    private func settleCancelled(_ id: UUID) async -> Bool {
        await recordingStore.updateRecordingProgressOnlySync(
            id,
            transcription: Self.cancelledMessage,
            progress: 0.0,
            status: .failed
        )
        return true
    }

}
