import AppKit
import Foundation
import SwiftUI

/// What one Export press did, in the words the card shows for it.
///
/// Every outcome is named, including the two that are not failures. A cancelled
/// save leaves nothing on the card, because the user already knows what they
/// did; everything else leaves a sentence, because a press that produced no file
/// and said nothing is indistinguishable from one that silently worked.
enum TranscriptExportOutcome: Equatable, Sendable {
    /// Written. Carries the name the user chose, so the card can say where it
    /// went without printing the path they navigated to.
    case saved(fileName: String)
    /// The user dismissed the save panel.
    case cancelled
    /// The row had nothing to write - it is still in the queue, it failed, or
    /// the completed row holds no words.
    case nothingToExport
    /// The write itself was refused: a read-only volume, a folder the app has
    /// no grant for, a disk with no room. Carries the system's own reason,
    /// which is the only description of it the user can act on.
    case failed(reason: String)

    /// The sentence to leave on the card, or nil when there is nothing to say.
    var note: String? {
        switch self {
        case .saved(let fileName):
            return "Exported to “\(fileName)”."
        case .cancelled:
            return nil
        case .nothingToExport:
            return "There is no transcript on this recording to export yet."
        case .failed(let reason):
            return "Export failed: \(reason)"
        }
    }
}

/// The Export press: a save panel, a write, and the sentence it leaves behind.
///
/// **App-lifetime, not row-lifetime**, for the reason
/// `TranscriptCorrectionCoordinator` is: history is a `LazyVStack`, so the card
/// that started an export is torn down the moment the user scrolls past it, and
/// a note held in that card's own `@State` would vanish with it. The same lesson
/// `UpdateViewModel.shared` records for the update pane.
///
/// It owns no data. What it holds is the one thing the store has no place for -
/// the sentence the last press on a row left - and everything it does to the
/// disk goes through the panel the user drove. Three rules carry it:
///
/// - **The destination is the user's, always.** The only writer is
///   `NSSavePanel`'s chosen URL. Nothing is written beside the recording, into
///   Application Support, or anywhere else the user did not point at, and the
///   panel's own overwrite confirmation is the only overwrite there is - this
///   never replaces a file behind it.
/// - **Nothing leaves the device.** The write is a local file write. There is no
///   share sheet, no upload and no network call anywhere in this path.
/// - **Every outcome is answered.** Cancelled, refused, empty and written each
///   have a case in `TranscriptExportOutcome`, and the three that are not a
///   cancellation leave a sentence on the card.
@MainActor
final class TranscriptExportCoordinator: ObservableObject {
    static let shared = TranscriptExportCoordinator()

    /// The sentence to show on a row whose last export said something, keyed by
    /// row. Cleared when that row is exported again or the user dismisses it.
    @Published private(set) var notes: [UUID: String] = [:]

    /// Puts the save panel up and answers with the URL the user chose, or nil if
    /// they dismissed it. Injected so every rule above is testable without a
    /// modal panel - a test supplies a temporary directory and a decision.
    typealias Choosing = @MainActor (_ suggestedName: String, _ format: TranscriptExport.Format)
        -> URL?
    /// Writes the document. Injected for the same reason, and so a refused write
    /// can be exercised without finding a read-only volume.
    typealias Writing = @MainActor (_ text: String, _ url: URL) throws -> Void

    private let choosing: Choosing
    private let writing: Writing

    init(
        choosing: @escaping Choosing = TranscriptExportCoordinator.runSavePanel,
        writing: @escaping Writing = { text, url in
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    ) {
        self.choosing = choosing
        self.writing = writing
    }

    func note(for id: UUID) -> String? { notes[id] }

    func dismissNote(for id: UUID) { notes[id] = nil }

    /// Exports one row, start to finish.
    ///
    /// Returns the outcome as well as recording it, which is what a test asserts
    /// on and what a caller with its own feedback could read instead.
    @discardableResult
    func export(
        _ recording: Recording, format: TranscriptExport.Format = .markdown
    ) -> TranscriptExportOutcome {
        notes[recording.id] = nil

        guard let document = TranscriptExport.document(for: recording) else {
            return record(.nothingToExport, for: recording.id)
        }

        let suggestedName = TranscriptExport.suggestedFileName(for: recording, format: format)
        guard let url = choosing(suggestedName, format) else {
            return record(.cancelled, for: recording.id)
        }

        // The panel decides the extension the user sees, but a user who typed
        // their own name may have left it off, and a `.md` document called
        // `notes` opens in nothing.
        let destination = url.pathExtension.isEmpty
            ? url.appendingPathExtension(format.fileExtension) : url

        do {
            try writing(TranscriptExport.text(for: document, format: format), destination)
        } catch {
            return record(
                .failed(reason: (error as NSError).localizedDescription), for: recording.id)
        }
        return record(.saved(fileName: destination.lastPathComponent), for: recording.id)
    }

    @discardableResult
    private func record(
        _ outcome: TranscriptExportOutcome, for id: UUID
    ) -> TranscriptExportOutcome {
        notes[id] = outcome.note
        return outcome
    }

    /// The real panel.
    ///
    /// `runModal` rather than a sheet, matching `AppStyleMappingSettingsView`'s
    /// own chooser: this runs from a card in the main window in answer to a
    /// press, the user is at the machine while it is up, and its own event loop
    /// is what makes the destination a decision the export can simply wait for.
    private static func runSavePanel(
        suggestedName: String, format: TranscriptExport.Format
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.message = "Choose where to save this transcript."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
