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

    /// Puts the save panel up and answers with the destination the user chose -
    /// where the file goes *and* which format they left the panel's format
    /// control on - or nil if they dismissed it.
    ///
    /// Both halves, because the panel is where the format is chosen: the caller
    /// only says which one it opens on. Injected so every rule above is testable
    /// without a modal panel - a test supplies a temporary directory and a
    /// decision.
    typealias Choosing = @MainActor (_ suggestedName: String, _ format: TranscriptExport.Format)
        -> TranscriptExport.Destination?
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
    /// `format` is the format the panel **opens** on, not the format that is
    /// written: the user picks that in the panel, and what comes back decides
    /// both the bytes and the name. Reconciling the two is
    /// `TranscriptExport.destination(for:chosenFormat:)`'s job and it is applied
    /// here rather than only inside the real panel, so no chooser - injected or
    /// otherwise - can hand this a `.txt` name for a Markdown body.
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
        guard let chosen = choosing(suggestedName, format) else {
            return record(.cancelled, for: recording.id)
        }

        let destination = TranscriptExport.destination(
            for: chosen.url, chosenFormat: chosen.format)

        do {
            try writing(
                TranscriptExport.text(for: document, format: destination.format), destination.url)
        } catch {
            return record(
                .failed(reason: (error as NSError).localizedDescription), for: recording.id)
        }
        return record(.saved(fileName: destination.url.lastPathComponent), for: recording.id)
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
    ///
    /// The format is chosen here, in an accessory control, rather than by
    /// handing the panel both content types: a panel given several types will
    /// *accept* several extensions but shows no way to pick one, and a choice
    /// the user cannot see is not a choice.
    private static func runSavePanel(
        suggestedName: String, format: TranscriptExport.Format
    ) -> TranscriptExport.Destination? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.message = "Choose where to save this transcript."

        let chooser = SavePanelFormatChooser(panel: panel, selected: format)
        panel.accessoryView = chooser.view

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return TranscriptExport.destination(for: url, chosenFormat: chooser.selected)
    }
}

/// The save panel's format control: a popup listing every format a transcript
/// can be written as, and the one place a change to it reaches the panel.
///
/// Setting `allowedContentTypes` to the picked type is what keeps the name field
/// honest - the panel then enforces that extension - and the name is rewritten
/// alongside it rather than left to that enforcement, so what the user reads in
/// the field is what the popup says at every moment.
///
/// It is retained for the life of `runModal` by the caller that reads
/// `selected` after it returns.
@MainActor
private final class SavePanelFormatChooser: NSObject {
    static let label = "Format:"
    static let accessibilityLabel = "Export format"

    private let formats = TranscriptExport.Format.allCases
    private weak var panel: NSSavePanel?

    /// What the popup is on now, and therefore what the export is written as
    /// unless the name the user typed says otherwise.
    private(set) var selected: TranscriptExport.Format

    let view: NSView

    init(panel: NSSavePanel, selected: TranscriptExport.Format) {
        self.panel = panel
        self.selected = selected

        let caption = NSTextField(labelWithString: Self.label)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: formats.map(\.label))
        popUp.selectItem(at: formats.firstIndex(of: selected) ?? 0)
        popUp.setAccessibilityLabel(Self.accessibilityLabel)

        let stack = NSStackView(views: [caption, popUp])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = stack

        super.init()
        popUp.target = self
        popUp.action = #selector(formatChanged(_:))
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
        selected = formats[sender.indexOfSelectedItem]
        guard let panel else { return }
        panel.allowedContentTypes = [selected.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(selected.fileExtension)"
    }
}
