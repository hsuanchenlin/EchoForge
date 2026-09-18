import Foundation
import GRDB

// One history row, and the columns it is stored in.
//
// This file is in `EchoForgeCore/` rather than beside `RecordingStore` because
// the `echoforge` command-line tool reads the same database, and a second
// declaration of these columns is a second schema: the day one of them gained a
// column the other did not, the CLI would either fail to decode a row the app
// had written or write one the app could not read. `RecordingSchema` holds the
// migrations and the queries for the same reason. The *store* stays in the app,
// because it migrates and writes; the CLI opens the same file read-only.

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
        AppDataLocation.recordingsDirectory()
    }

    /// This row's audio, in the app's recordings directory. `fileName` is
    /// resolved as stored, whatever scheme named it - see `newRow`.
    var url: URL {
        audioURL(in: Self.recordingsDirectory)
    }

    /// This row's audio inside `directory`. `url` is this against the app's
    /// own recordings directory; a test resolves against a directory of its
    /// own, which is what lets the file half of history be exercised without
    /// touching the user's recordings.
    func audioURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
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

// MARK: - Making a new row

extension Recording {
    /// The one way a **new** history row is made, and so the one place its
    /// audio file is named.
    ///
    /// The name is the row's own id, `<UUID>.wav`. It used to be the timestamp
    /// to the second, computed inline at each of the five places a row was
    /// built - and files dropped together are added within a millisecond of
    /// each other, so three rows pointed at one `.wav`, the queue's copy
    /// replaced the earlier recordings with the last, and deleting any one of
    /// the three rows removed the audio of all of them. A name derived from
    /// the id cannot collide while ids do not. `RecordingRowFactoryTests`
    /// holds that, and a source scan there keeps every new row coming through
    /// here: the memberwise initialiser still exists, because reading a row
    /// back and modelling an older one in a test need it, but nothing that
    /// *creates* history may name a file itself.
    ///
    /// Rows written before this keep their second-granularity names and
    /// nothing renames them: `fileName` is a stored column, `url` resolves
    /// whatever it holds, and an older row is read, played and deleted exactly
    /// as it was. Two such rows that already share a file still share it; only
    /// new rows are guaranteed one each.
    ///
    /// Every field a caller passes is stored as passed - `timestamp` included,
    /// since a row's time is when it was made, not when it was inserted.
    static func newRow(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        transcription: String,
        duration: TimeInterval,
        status: RecordingStatus,
        progress: Float,
        sourceFileURL: String? = nil,
        rawTranscription: String? = nil,
        provenance: RecordingProvenance
    ) -> Recording {
        var row = Recording(
            id: id,
            timestamp: timestamp,
            fileName: audioFileName(for: id),
            transcription: transcription,
            duration: duration,
            status: status,
            progress: progress,
            sourceFileURL: sourceFileURL,
            rawTranscription: rawTranscription
        )
        row.provenance = provenance
        return row
    }

    /// The `.wav` a new row's audio is kept under: the row's id, so the name is
    /// unique for as long as the id is, and a single path component with
    /// nothing in it a file system could read as a directory.
    static func audioFileName(for id: UUID) -> String {
        "\(id.uuidString).wav"
    }
}
