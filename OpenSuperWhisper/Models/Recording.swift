import Foundation
import GRDB

enum RecordingStatus: String, Codable {
    case pending
    case converting
    case transcribing
    case completed
    case failed
}

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    var transcription: String
    let duration: TimeInterval
    var status: RecordingStatus
    var progress: Float
    var sourceFileURL: String?
    /// The transcript exactly as the engine produced it, before post-processing.
    ///
    /// Nil for every recording stored so far: nothing writes this yet. It exists
    /// so a later stage can persist `ProcessedText.raw` and fall back to what the
    /// user originally said when post-processing turns out to be wrong.
    var rawTranscription: String?

    /// When the user last pressed "Fix with AI" on this row and the correction
    /// landed. Nil until somebody presses it, and cleared again by anything that
    /// replaces the transcript with the engine's own words.
    ///
    /// Its own column rather than a `RecordingProvenance` case, and that is a
    /// decision rather than an omission: provenance records *which way of
    /// listening* produced a row and fails closed about what became of it, so
    /// filing a corrected dictation as something other than a dictation would
    /// overwrite the one fact that record exists to keep. A correction is
    /// something that happened to a row afterwards, and it is stored as such.
    /// See `TranscriptCorrection` and `docs/history-ai-fix.md`.
    var aiCorrectedAt: Date?

    /// Which of the app's ways of listening produced this row, as the stored
    /// discriminator. Nil for every row written before provenance existed, and
    /// read back as `RecordingProvenance.unknown` rather than guessed at.
    var provenanceKind: String?

    /// The refusal class of a YouTube command that opened nothing. Nil for every
    /// other kind.
    var provenanceReason: String?

    /// The sentence shown under the label: what was opened, or what to do about
    /// a command that opened nothing. Never a URL, a channel id or a credential
    /// - `HistoryProvenancePrivacyTests` holds that.
    var provenanceDetail: String?

    var isRegeneration: Bool = false

    /// Whether a correction has been applied to this row.
    var wasCorrectedByAI: Bool { aiCorrectedAt != nil }

    /// What "Fix with AI" must keep as this row's original.
    ///
    /// The engine's own words wherever the row already has them - a row whose
    /// transcript was restyled at dictation time keeps that copy, and a second
    /// press must not overwrite it with the text the first press produced. That
    /// copy is the only record of what was actually said.
    var originalTranscriptionForCorrection: String {
        guard let rawTranscription, !rawTranscription.isEmpty else { return transcription }
        return rawTranscription
    }

    /// The three columns read back as one value.
    ///
    /// Every surface goes through here rather than at the columns, so "a kind
    /// this build does not know is an older recording" is decided once. See
    /// `RecordingProvenance.stored`.
    var provenance: RecordingProvenance {
        get {
            RecordingProvenance.stored(
                kind: provenanceKind, reason: provenanceReason, detail: provenanceDetail)
        }
        set {
            (provenanceKind, provenanceReason, provenanceDetail) = newValue.columns
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL
        case rawTranscription
        case aiCorrectedAt
        case provenanceKind, provenanceReason, provenanceDetail
    }

    /// Equality over the fields a row is *redrawn* for, which is what this is
    /// for. Provenance is one of them: a command's outcome lands a second after
    /// its words, and a row that compares equal to its own previous self would
    /// keep showing "did not finish" over a video that opened.
    static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id &&
               lhs.status == rhs.status &&
               lhs.progress == rhs.progress &&
               lhs.transcription == rhs.transcription &&
               // Both halves of what the card draws under the transcript: the
               // "Show original" disclosure and the "AI Polished" chip. A
               // correction that only added the chip - or only the original -
               // would otherwise compare equal to the row it replaced and never
               // be drawn.
               lhs.rawTranscription == rhs.rawTranscription &&
               lhs.aiCorrectedAt == rhs.aiCorrectedAt &&
               lhs.isRegeneration == rhs.isRegeneration &&
               lhs.provenanceKind == rhs.provenanceKind &&
               lhs.provenanceReason == rhs.provenanceReason &&
               lhs.provenanceDetail == rhs.provenanceDetail
    }

    static var recordingsDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        return appDirectory.appendingPathComponent("recordings")
    }

    var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }
    
    var isPending: Bool {
        status == .pending || status == .converting || status == .transcribing
    }
    
    var sourceFileName: String? {
        guard let sourceFileURL = sourceFileURL else { return nil }
        return URL(fileURLWithPath: sourceFileURL).lastPathComponent
    }

    static let databaseTableName = "recordings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
        static let status = Column(CodingKeys.status)
        static let progress = Column(CodingKeys.progress)
        static let sourceFileURL = Column(CodingKeys.sourceFileURL)
        static let rawTranscription = Column(CodingKeys.rawTranscription)
        static let aiCorrectedAt = Column(CodingKeys.aiCorrectedAt)
        static let provenanceKind = Column(CodingKeys.provenanceKind)
        static let provenanceReason = Column(CodingKeys.provenanceReason)
        static let provenanceDetail = Column(CodingKeys.provenanceDetail)
    }
}

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        let dbPath = appDirectory.appendingPathComponent("recordings.sqlite")

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

    /// The full schema history of the recordings database.
    ///
    /// Exposed separately from `setupDatabase()` so migrations can be exercised
    /// against a throwaway database instead of the user's real one.
    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
        
        migrator.registerMigration("v2_add_status") { db in
            let columns = try db.columns(in: Recording.databaseTableName)
            let columnNames = columns.map { $0.name }
            
            if !columnNames.contains("status") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "status", .text).notNull().defaults(to: "completed")
                }
            }
            if !columnNames.contains("progress") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "progress", .double).notNull().defaults(to: 1.0)
                }
            }
            if !columnNames.contains("sourceFileURL") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "sourceFileURL", .text)
                }
            }
        }

        migrator.registerMigration("v3_add_raw_transcription") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            if !columnNames.contains("rawTranscription") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "rawTranscription", .text)
                }
            }
        }

        /// Provenance: what kind of session produced a row, and what became of
        /// it (`RecordingProvenance`).
        ///
        /// All three columns are nullable with no default, and that is the
        /// migration's whole safety story: every recording a user already has
        /// gets NULL, reads back as `.unknown`, and is shown as "Older
        /// recording". Back-filling them with `'dictation'` would have been one
        /// `UPDATE` and would have written the app's guess into the user's
        /// record - including onto every YouTube command they ran before this
        /// existed, which is exactly the history they are trying to read.
        migrator.registerMigration("v4_add_provenance") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            for column in ["provenanceKind", "provenanceReason", "provenanceDetail"]
            where !columnNames.contains(column) {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: column, .text)
                }
            }
        }

        /// When "Fix with AI" last corrected a row (`TranscriptCorrection`).
        ///
        /// Nullable with no default, for the reason every column added here is:
        /// every recording a user already has gets NULL and reads back as a row
        /// nobody has corrected, which is exactly what it is. Nothing is
        /// back-filled and nothing is inferred.
        migrator.registerMigration("v5_add_ai_correction") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }

            if !columnNames.contains("aiCorrectedAt") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "aiCorrectedAt", .datetime)
                }
            }
        }

        return migrator
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

    /// The history query for one filter.
    ///
    /// In SQL rather than over the loaded page, because history is paged: a
    /// filter applied to the hundred rows that happen to be in memory would
    /// quietly hide every older row that matches, which is the opposite of what
    /// somebody looking for a command that failed last week is asking for.
    ///
    /// The NULL arm is the load-bearing part. Every recording made before
    /// provenance existed has no kind stored, and `provenanceKind IN (...)` is
    /// false for NULL in SQL - so "Older recording" has to ask for the NULL
    /// explicitly, and every other filter has to leave it out.
    nonisolated static func query(
        matching filter: HistoryProvenanceFilter
    ) -> QueryInterfaceRequest<Recording> {
        guard let kinds = filter.kinds else { return Recording.all() }
        let raw = kinds.map(\.rawValue)
        let named = raw.contains(Recording.Columns.provenanceKind)
        return Recording.filter(
            filter.includesUnrecorded ? (named || Recording.Columns.provenanceKind == nil) : named
        )
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
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, rawTranscription: String? = nil, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
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
        } catch {
            print("Failed to update recording progress: \(error)")
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

    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
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
        } catch {
            print("Failed to update recording status: \(error)")
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
    
    func deleteRecordingSync(_ recording: Recording) async {
        do {
            try await deleteRecordingFromDB(recording)
            try? FileManager.default.removeItem(at: recording.url)
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        } catch {
            print("Failed to delete recording: \(error)")
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

    func searchRecordings(query: String) -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .limit(100)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
    
    nonisolated func searchRecordingsAsync(
        query: String, limit: Int = 100, offset: Int = 0,
        filter: HistoryProvenanceFilter = .all
    ) async -> [Recording] {
        do {
            return try await dbQueue.read { db in
                try Self.query(matching: filter)
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
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
