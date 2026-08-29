import Foundation

/// The in-flight state of every "Fix with AI" press, for the cards that draw it.
///
/// It is **app-lifetime, not row-lifetime**, and that is the whole reason it
/// exists rather than a `@State` inside `RecordingRow`. History is a
/// `LazyVStack`: a card the user scrolls past is torn down, and a correction
/// started from a card's own state would be cancelled by scrolling away from it
/// - which is exactly what somebody does while waiting several seconds for a
/// model. The same lesson `UpdateViewModel.shared` records for the update pane.
///
/// It owns no data. The row's words live in `RecordingStore` and are written
/// there; what this holds is the two things the store has no place for - which
/// rows have a press in flight, and the sentence a press that changed nothing
/// left behind for the card to show.
///
/// One press per row, and a second press while the first is running is ignored
/// rather than queued: there is nothing for it to do that the first press is not
/// already doing, and two corrections racing to write the same row would decide
/// the winner by which model call returned first.
@MainActor
final class TranscriptCorrectionCoordinator: ObservableObject {
    static let shared = TranscriptCorrectionCoordinator()

    /// The rows with a correction running right now.
    @Published private(set) var inFlight: Set<UUID> = []
    /// The sentence to show on a row whose last press changed nothing, keyed by
    /// row. Cleared when that row is pressed again or the user dismisses it.
    @Published private(set) var notes: [UUID: String] = [:]

    /// Runs one correction. Injected so every rule here - the guard against a
    /// second press, what is written and when, what is left on the card - is
    /// testable without a model or a database.
    typealias Correcting = @MainActor (TranscriptCorrectionRequest) async -> StyledTranscript
    /// Writes an accepted correction to the row it came from.
    typealias Committing = @MainActor (UUID, String, String) async -> Void

    private let correcting: Correcting
    private let committing: Committing

    init(
        correcting: @escaping Correcting = { request in
            await TranscriptCorrection.apply(
                to: request,
                settings: Settings(),
                terms: PersonalTermsStore.shared.activeTerms
            )
        },
        committing: @escaping Committing = { id, text, original in
            await RecordingStore.shared.applyCorrection(
                id, transcription: text, original: original)
        }
    ) {
        self.correcting = correcting
        self.committing = committing
    }

    func isCorrecting(_ id: UUID) -> Bool { inFlight.contains(id) }

    func note(for id: UUID) -> String? { notes[id] }

    func dismissNote(for id: UUID) { notes[id] = nil }

    /// Starts a correction for one row, if there is one to start.
    ///
    /// Returns whether a press was accepted, which is what a test asserts on and
    /// what the row uses to decide nothing at all: a row that is already being
    /// corrected, or that has no transcript to correct, is silently left alone,
    /// because the button offering the press is drawn from the same rule
    /// (`TranscriptCorrection.request(for:)`).
    @discardableResult
    func correct(_ recording: Recording) -> Bool {
        guard let request = TranscriptCorrection.request(for: recording) else { return false }
        guard !inFlight.contains(request.recordingID) else { return false }

        let id = request.recordingID
        inFlight.insert(id)
        notes[id] = nil

        Task { @MainActor in
            let styled = await correcting(request)
            let outcome = TranscriptCorrection.outcome(of: styled, request: request)
            // Written before the spinner comes down, so the card never shows a
            // finished press over the words it is about to replace.
            if case .corrected(let text, let original) = outcome {
                await committing(id, text, original)
            }
            notes[id] = outcome.note
            inFlight.remove(id)
        }
        return true
    }
}
