import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The row that says this app transcribes files, and the one place to start one
/// without a drag.
///
/// File transcription has worked for a long time - multiple files at once, Finder
/// Open With, Dock drops, a queue that resumes across launches, cancellation, and
/// a history row per file. None of that was **findable**. The only affordance was
/// eight words of grey caption at the bottom of the window, and the drop overlay
/// that explains what to do appears once a drag is already in flight, which is
/// after the moment somebody needed to know it was possible.
///
/// So this is deliberately a *visible* target: a dashed well that is already
/// there before any drag, with a button beside it for the users who would never
/// have thought to drag. It replaces the caption rather than being added to it -
/// a 450 pt window has no room for both, and two ways of saying the same thing
/// is how the caption ended up unread.
///
/// It decides nothing. `FileDropHandler` still owns the drop, `TranscriptionQueue`
/// still owns the queue and its provenance, and the "Show" button applies the
/// filter that already existed.
struct FileImportRow: View {

    /// What the queue is doing, which is the other half of discoverability: a
    /// user who dropped four files needs to be able to find them again.
    let queuedFileCount: Int

    /// Whether the list is already showing only file transcriptions, so the lens
    /// button reads as a toggle rather than as a dead end.
    let isShowingFiles: Bool

    /// Applies - or clears - the file transcription filter on the list below.
    let showFiles: () -> Void

    /// Queues whatever the user picked. Passed in so this view never touches the
    /// queue itself.
    let open: ([URL]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    static let prompt = "Drop audio files here to transcribe"
    static let openButtonTitle = "Open Files…"
    static let accessibilityHint =
        "Transcribes audio files. Drop them here, or choose them with Open Files."

    /// What the row says while the queue has work in it.
    ///
    /// Counted, because "transcribing…" over four files reads as one file that is
    /// taking a very long time.
    static func queueSummary(count: Int) -> String {
        count == 1 ? "1 file in the queue" : "\(count) files in the queue"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: queuedFileCount > 0 ? "clock.arrow.circlepath" : "arrow.down.doc")
                .font(.system(size: 15))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
                .accessibilityHidden(true)

            Text(queuedFileCount > 0 ? Self.queueSummary(count: queuedFileCount) : Self.prompt)
                .font(.caption)
                .foregroundColor(isTargeted ? .accentColor : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if queuedFileCount > 0 {
                Button(isShowingFiles ? "Show all" : "Show") { showFiles() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(
                        isShowingFiles
                            ? "Show every kind of history entry again"
                            : "Show only file transcriptions")
            }

            Button(Self.openButtonTitle) { chooseFiles() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Choose audio files to transcribe")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isTargeted
                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
                        : Color.clear)
        )
        .overlay(
            // Dashed, because that is what a drop target looks like everywhere
            // else on this platform and the whole point is that it is recognised
            // before anything is dragged.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : ThemePalette.panelBorder(colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [4, 3]))
        )
        .onDrop(of: [.audio], isTargeted: $isTargeted) { providers in
            Task { await FileDropHandler.shared.handleDrop(of: providers) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            queuedFileCount > 0 ? Self.queueSummary(count: queuedFileCount) : Self.prompt)
        .accessibilityHint(Self.accessibilityHint)
    }

    /// The panel, restricted to what the queue can actually decode.
    ///
    /// `runModal` runs its own event loop, which is why this is the one
    /// presentation in the app outside `PowerOffPresentationGuard`'s reach - the
    /// same knowing exception `AppStyleMappingSettingsView` already carries. It
    /// is transient and the user is standing at the machine while it is up.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Transcribe"
        panel.message = "Choose audio files to transcribe. They are queued one at a time."

        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }
}
