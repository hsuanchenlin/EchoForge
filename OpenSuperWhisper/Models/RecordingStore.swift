import Foundation
import GRDB

/// The app's writer for the recordings database.
///
/// The row, the schema and the two history queries live in `EchoForgeCore`
/// (`Recording`, `RecordingSchema`), because the `echoforge` command-line tool
/// reads the same file and two declarations of a schema are two schemas. This
/// class is the half that stays in the app: it is what *migrates* and what
/// *writes*, and the CLI does neither. The forwarding members below keep
/// `RecordingStore.makeMigrator()` and `RecordingStore.query(…)` reading the way
/// every call site and test already spells them.
@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue

    private init() {
        let appDirectory = AppDataLocation.applicationSupportDirectory()
        let dbPath = AppDataLocation.recordingsDatabaseURL()

        print("Database path: \(dbPath.path)")

        do {
            try FileManager.default.createDirectory(
                at: appDirectory, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: dbPath.path)
            try setupDatabase()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    private nonisolated func setupDatabase() throws {
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// The full schema history of the recordings database, from
    /// `RecordingSchema`. Kept spelled here because every migration test and
    /// every call site names it on the store.
    nonisolated static func makeMigrator() -> DatabaseMigrator {
        RecordingSchema.makeMigrator()
    }

    /// The history query for one filter. See `RecordingSchema.query(matching:)`.
    nonisolated static func query(
        matching filter: HistoryProvenanceFilter
    ) -> QueryInterfaceRequest<Recording> {
        RecordingSchema.query(matching: filter)
    }

    /// The history query for one filter **and** one search phrase.
    /// See `RecordingSchema.query(matching:searching:)`.
    nonisolated static func query(
        matching filter: HistoryProvenanceFilter,
        searching search: HistorySearchQuery
    ) -> QueryInterfaceRequest<Recording> {
        RecordingSchema.query(matching: filter, searching: search)
    }

    /// Neutralises the three characters LIKE reads as syntax.
    /// See `RecordingSchema.escapedForLike`.
    nonisolated static func escapedForLike(_ text: String) -> String {
        RecordingSchema.escapedForLike(text)
    }


    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }
    
    nonisolated func fetchRecordings(
        limit: Int, offset: Int, filter: HistoryProvenanceFilter = .all
    ) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Self.query(matching: filter)
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func getPendingRecordings() -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to get pending recordings: \(error)")
            return []
        }
    }

    func getNextPendingRecording() -> Recording? {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .limit(1)
                    .fetchOne(db)
            }
        } catch {
            print("Failed to get next pending recording: \(error)")
            return nil
        }
    }

    static let recordingsDidUpdateNotification = Notification.Name("RecordingStore.recordingsDidUpdate")

    func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to add recording: \(error)")
            }
        }
    }
    
    /// Keeps a dictation the app was unable to transcribe, with the reason.
    ///
    /// The audio belongs to the user, and a failure to load an engine used to
    /// take it with it: the temporary file was deleted and the only trace was a
    /// line on the console. Kept as a `.failed` recording it stays in history
    /// carrying the message, next to the regenerate button that will transcribe
    /// it once the thing the message asks for is done.
    ///
    /// Returns `nil` only if the audio could not be moved into place, in which
    /// case there is nothing to show and the caller has already reported the
    /// failure itself.
    /// - Parameter provenance: what the press was for. A failed **command**
    ///   capture is filed as a command that opened nothing rather than as a
    ///   failed dictation, because "I pressed the YouTube key and nothing
    ///   happened" and "my dictation did not transcribe" are the same row
    ///   otherwise.
    @discardableResult
    func keepFailedDictation(
        temporaryURL: URL, duration: TimeInterval, reason: String,
        provenance: RecordingProvenance = .dictation
    ) -> Recording? {
        let timestamp = Date()
        var recording = Recording(
            id: UUID(),
            timestamp: timestamp,
            fileName: "\(Int(timestamp.timeIntervalSince1970)).wav",
            transcription: reason,
            duration: duration,
            status: .failed,
            progress: 0.0,
            sourceFileURL: nil
        )
        recording.provenance = provenance

        do {
            try AudioRecorder.shared.moveTemporaryRecording(from: temporaryURL, to: recording.url)
        } catch {
            print("Failed to keep untranscribed dictation: \(error)")
            return nil
        }

        addRecording(recording)
        return recording
    }

    func addRecordingSync(_ recording: Recording) async throws {
        try await insertRecording(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.insert(db)
        }
    }
    
    func updateRecording(_ recording: Recording) {
        Task {
            do {
                try await updateRecordingInDB(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to update recording: \(error)")
            }
        }
    }
    
    func updateRecordingSync(_ recording: Recording) async throws {
        try await updateRecordingInDB(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    func updateRecordingProgressOnly(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus) {
        Task {
            await updateRecordingProgressOnlySync(id, transcription: transcription, progress: progress, status: status)
        }
    }
    
    static let recordingProgressDidUpdateNotification = Notification.Name("RecordingStore.recordingProgressDidUpdate")
    
    /// Updates the in-memory copy and notifies observers without touching the database.
    private func applyLocalProgressUpdate(_ id: UUID, transcription: String? = nil, rawTranscription: String? = nil, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            var updated = recordings[index]
            if let transcription = transcription {
                updated.transcription = transcription
                // Follows the transcription rather than being merged in: a
                // progress tick carries neither, and a new transcription
                // replaces both or the pair would describe different runs.
                updated.rawTranscription = rawTranscription
                // And so does the correction mark, for the same reason and one
                // more: a regeneration replaces these words with the engine's,
                // so a row left carrying "AI Polished" over them would be
                // claiming a model wrote text it never saw.
                updated.aiCorrectedAt = nil
            }
            updated.progress = progress
            updated.status = status
            if let isRegeneration = isRegeneration {
                updated.isRegeneration = isRegeneration
            }
            recordings[index] = updated
        }
        
        var userInfo: [String: Any] = [
            "id": id,
            "progress": progress,
            "status": status
        ]
        if let transcription = transcription {
            userInfo["transcription"] = transcription
            // Sent as the empty string rather than omitted when there is no
            // original: `userInfo` cannot carry nil, and a missing key would be
            // indistinguishable from "leave the previous one alone", which is
            // the one thing it must not mean here.
            userInfo["rawTranscription"] = rawTranscription ?? ""
            userInfo["clearsAICorrection"] = true
        }
        if let isRegeneration = isRegeneration {
            userInfo["isRegeneration"] = isRegeneration
        }
        
        NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
    }
    
    /// Progress ticks are ephemeral UI state: persisting each one caused up to
    /// ~100 SQLite transactions per transcription. Status transitions are still
    /// persisted by the explicit update methods.
    func updateRecordingProgressTransient(_ id: UUID, progress: Float, status: RecordingStatus) {
        applyLocalProgressUpdate(id, progress: progress, status: status)
    }
    
    /// Writes a transcription and its status.
    ///
    /// `rawTranscription` is written on every call, including the `nil` default,
    /// and that is deliberate: it belongs to the transcription being written, so
    /// a regeneration or a failure that replaces the text must not leave the
    /// previous run's original behind describing text that is no longer there.
    /// `aiCorrectedAt` is cleared for the same reason: the row's words are the
    /// engine's again, and a badge saying a model wrote them would be a lie.
    ///
    /// - Returns: whether the write landed. A row that is already gone matches
    ///   nothing and is still a success - it is out of the pending statuses
    ///   either way - while a write that threw leaves the row exactly as it was.
    ///   `TranscriptionQueue` is the caller that cannot do without the answer:
    ///   a swallowed failure here left the row `.pending` and the loop was told
    ///   it had been settled, so the queue handed the same recording back to the
    ///   engine. See `TranscriptionQueueStep`.
    @discardableResult
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, rawTranscription: String? = nil, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async -> Bool {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.transcription.set(to: transcription),
                        Recording.Columns.rawTranscription.set(to: rawTranscription),
                        Recording.Columns.aiCorrectedAt.set(to: nil as Date?),
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            applyLocalProgressUpdate(id, transcription: transcription, rawTranscription: rawTranscription, progress: progress, status: status, isRegeneration: isRegeneration)
            return true
        } catch {
            print("Failed to update recording progress: \(error)")
            return false
        }
    }

    nonisolated func updateSourceFileURL(_ id: UUID, sourceURL: String) async throws {
        // `updateAll` returns the number of rows it changed, which nothing here
        // acts on: the row is looked up by primary key and a miss is not an error
        // worth failing an import over. Discarded explicitly so it is a decision
        // rather than a warning.
        _ = try await dbQueue.write { db in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.sourceFileURL.set(to: sourceURL)
                ])
        }
    }

    /// - Returns: whether the write landed, for the same reason its
    ///   transcription-carrying sibling above does.
    @discardableResult
    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async -> Bool {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            applyLocalProgressUpdate(id, progress: progress, status: status, isRegeneration: isRegeneration)
            return true
        } catch {
            print("Failed to update recording status: \(error)")
            return false
        }
    }

    private nonisolated func updateRecordingInDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.update(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        if recording.isPending {
            TranscriptionQueue.shared.cancelRecording(recording.id)
        }
        
        Task {
            do {
                try await deleteRecordingFromDB(recording)
                try? FileManager.default.removeItem(at: recording.url)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete recording: \(error)")
            }
        }
    }
    
    /// - Returns: whether the row is gone. The audio file is best-effort - a
    ///   file that was already removed is not a failed delete - but the row
    ///   surviving is, and the queue reads this to decide whether the recording
    ///   it just discarded has actually left the pending statuses.
    @discardableResult
    func deleteRecordingSync(_ recording: Recording) async -> Bool {
        do {
            try await deleteRecordingFromDB(recording)
            try? FileManager.default.removeItem(at: recording.url)
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
            return true
        } catch {
            print("Failed to delete recording: \(error)")
            return false
        }
    }

    private nonisolated func deleteRecordingFromDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            _ = try recording.delete(db)
        }
    }

    func deleteAllRecordings() {
        Task {
            do {
                let allRecordings = try await fetchAllRecordings()
                for recording in allRecordings {
                    try? FileManager.default.removeItem(at: recording.url)
                }
                try await deleteAllRecordingsFromDB()
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete all recordings: \(error)")
            }
        }
    }
    
    private nonisolated func deleteAllRecordingsFromDB() async throws {
        try await dbQueue.write { db in
            _ = try Recording.deleteAll(db)
        }
    }

    nonisolated static func retentionCutoffDate(daysToKeep: Int, now: Date = Date()) -> Date? {
        guard daysToKeep > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -daysToKeep, to: now)
    }

    nonisolated static func isDeletableRecordingURL(_ url: URL) -> Bool {
        let recordingsPath = Recording.recordingsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(recordingsPath + "/") && filePath != recordingsPath
    }

    private nonisolated static let pendingStatuses = [
        RecordingStatus.pending.rawValue,
        RecordingStatus.converting.rawValue,
        RecordingStatus.transcribing.rawValue
    ]

    nonisolated func recordingsOlderThan(days: Int) async throws -> (count: Int, oldestDate: Date?) {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return (0, nil) }
        return try await dbQueue.read { db in
            let request = Recording
                .filter(Recording.Columns.timestamp < cutoff)
                .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
            let count = try request.fetchCount(db)
            let oldest = try request
                .order(Recording.Columns.timestamp.asc)
                .limit(1)
                .fetchOne(db)
            return (count, oldest?.timestamp)
        }
    }

    func deleteRecordings(olderThanDays days: Int) async throws {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return }
        let outdated = try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.timestamp < cutoff)
                .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
                .fetchAll(db)
        }
        guard !outdated.isEmpty else { return }

        for recording in outdated where Self.isDeletableRecordingURL(recording.url) {
            try? FileManager.default.removeItem(at: recording.url)
        }
        let ids = outdated.map { $0.id }
        try await dbQueue.write { db in
            _ = try Recording
                .filter(ids.contains(Recording.Columns.id))
                .deleteAll(db)
        }
        NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
    }

    /// Recordings created through the indicator flow used to be saved with
    /// duration = 0. Restores real durations from the audio files on disk.
    nonisolated func backfillMissingDurations() async {
        let zeroDurationRecordings = (try? await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.duration <= 0)
                .filter(Recording.Columns.status == RecordingStatus.completed.rawValue)
                .fetchAll(db)
        }) ?? []
        guard !zeroDurationRecordings.isEmpty else { return }

        var updatedAny = false
        for recording in zeroDurationRecordings {
            guard FileManager.default.fileExists(atPath: recording.url.path) else { continue }
            let duration = await AudioUtil.audioDuration(url: recording.url)
            guard duration > 0 else { continue }
            do {
                try await dbQueue.write { db in
                    _ = try Recording
                        .filter(Recording.Columns.id == recording.id)
                        .updateAll(db, [Recording.Columns.duration.set(to: duration)])
                }
                updatedAny = true
            } catch {
                print("Failed to backfill duration for \(recording.id): \(error)")
            }
        }

        if updatedAny {
            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
            }
        }
    }

    nonisolated static func recordingsDiskUsage() -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Recording.recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    /// One page of the rows a search phrase and a filter admit.
    ///
    /// `nonisolated` and `await`ing the read, which is what keeps typing in the
    /// search field off the main actor: the predicate is built here and SQLite
    /// answers it on GRDB's own queue, so a phrase over a long history never
    /// stalls the keystroke that produced it. The page is what bounds the work -
    /// a query is answered a hundred rows at a time whatever the history holds.
    nonisolated func searchRecordingsAsync(
        query: HistorySearchQuery, limit: Int = 100, offset: Int = 0,
        filter: HistoryProvenanceFilter = .all
    ) async -> [Recording] {
        do {
            return try await dbQueue.read { db in
                try Self.query(matching: filter, searching: query)
                    .order(Recording.Columns.timestamp.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }

    /// Records what became of a command whose words were already stored.
    ///
    /// Its own method rather than a whole-row `update`, for the reason
    /// `updateRecordingProgressOnlySync` is: the row may be being written by the
    /// queue at the same moment, and this must replace three columns without
    /// carrying a stale transcript back over the top of it.
    ///
    /// The in-memory copy and the notification follow, so an open History window
    /// re-labels the row the user is already looking at rather than waiting for
    /// the next reload.
    func updateProvenance(_ id: UUID, to provenance: RecordingProvenance) async {
        let (kind, reason, detail) = provenance.columns

        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.provenanceKind.set(to: kind),
                        Recording.Columns.provenanceReason.set(to: reason),
                        Recording.Columns.provenanceDetail.set(to: detail),
                    ])
            }
        } catch {
            print("Failed to update recording provenance: \(error)")
            return
        }

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].provenance = provenance
        }
        NotificationCenter.default.post(
            name: Self.recordingProvenanceDidUpdateNotification,
            object: nil,
            userInfo: ["id": id, "provenance": provenance]
        )
    }

    static let recordingProvenanceDidUpdateNotification = Notification.Name(
        "RecordingStore.recordingProvenanceDidUpdate")

    /// Writes a "Fix with AI" correction over one row.
    ///
    /// Its own method rather than a whole-row `update`, for the reason
    /// `updateProvenance` is: the row may be being written by the queue at the
    /// same moment, and this must replace three columns without carrying a stale
    /// transcript, status or progress back over the top of them.
    ///
    /// The transcript given to the model is the earliest shared boundary that
    /// can reject every stale result, including a regeneration or another
    /// correction that lands while the model is running.
    ///
    /// It touches nothing else. The audio file, the duration, the provenance and
    /// every other row are exactly as they were - a correction changes the words
    /// on one card and keeps the words it replaced.
    func applyCorrection(
        _ id: UUID, transcription: String, original: String,
        expectedTranscription: String, correctedAt: Date = Date()
    ) async -> CorrectionCommitResult {
        let changed: Int
        do {
            changed = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .filter(Recording.Columns.status == RecordingStatus.completed.rawValue)
                    .filter(Recording.Columns.transcription == expectedTranscription)
                    .updateAll(db, [
                        Recording.Columns.transcription.set(to: transcription),
                        Recording.Columns.rawTranscription.set(to: original),
                        Recording.Columns.aiCorrectedAt.set(to: correctedAt),
                    ])
            }
        } catch {
            print("Failed to store the AI correction: \(error)")
            return .failed
        }

        guard changed == 1 else { return .superseded }

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].transcription = transcription
            recordings[index].rawTranscription = original
            recordings[index].aiCorrectedAt = correctedAt
        }
        NotificationCenter.default.post(
            name: Self.recordingDidCorrectNotification,
            object: nil,
            userInfo: [
                "id": id, "transcription": transcription, "rawTranscription": original,
                "aiCorrectedAt": correctedAt,
            ]
        )
        return .applied
    }

    static let recordingDidCorrectNotification = Notification.Name(
        "RecordingStore.recordingDidCorrect")
}
