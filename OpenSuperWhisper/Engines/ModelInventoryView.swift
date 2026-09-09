import AppKit
import SwiftUI

/// What the model inventory is showing, and the only thing that changes it.
///
/// It owns no decision: `ModelInventory` measures, `ModelRemoval` decides
/// whether a delete is allowed and what it would cost, `EngineRecommendation`
/// says which engine this Mac would be best served by, and every one of those is
/// a pure function tested without a disk. What lives here is the work those
/// three cannot do - reading the filesystem off the main thread, and performing
/// the delete once a person has agreed to it.
///
/// **Nothing here downloads, deletes or selects on its own.** A recommendation
/// is a sentence beside a row; every byte that moves does so because somebody
/// pressed something.
@MainActor
final class ModelInventoryViewModel: ObservableObject {

    @Published private(set) var entries: [ModelInventoryEntry] = []

    /// What the user's own recordings occupy, beside what the models do. The two
    /// are the whole answer to "what is this app costing me", and showing only
    /// the models would understate it by the larger half on a long history.
    @Published private(set) var recordingsBytes: Int64 = 0

    @Published private(set) var isMeasuring = false

    /// The last thing that went wrong, for the one line under the rows. Cleared
    /// by the next action.
    @Published var failure: String?

    /// The removal the user is being asked about, or `nil`. Held rather than
    /// recomputed at confirmation time: the state it was decided against can
    /// change while the dialog is up, and the sentence the user agreed to is the
    /// one that has to be carried out.
    @Published private(set) var pendingRemoval: PendingRemoval?

    struct PendingRemoval: Equatable {
        let engine: EngineKind
        let consequence: ModelRemoval.Consequence
        var message: String { consequence.message(for: engine) }
    }

    private let service: TranscriptionService

    /// A Settings-driven engine download, which `service.modelPreparation` knows
    /// nothing about: that tracks only the desired engine's background
    /// preparation, while the inventory's own Download button can be fetching a
    /// different engine's weights. The view keeps this current.
    var settingsPreparation: ModelPreparation?

    init(service: TranscriptionService = .shared) {
        self.service = service
    }

    /// Re-measures the disk.
    ///
    /// The enumeration is `Task.detached` because it walks several model caches,
    /// and a Settings pane that stutters while it counts a 1.6 GB directory is a
    /// pane that looks broken. `EngineAvailability.current()` is read on the way
    /// in - it is 0.10 ms and reads no bytes.
    func refresh() {
        guard !isMeasuring else { return }
        isMeasuring = true

        let availability = EngineAvailability.current(
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
        let preparations = [service.modelPreparation, settingsPreparation].compactMap { $0 }

        Task.detached(priority: .utility) {
            let measured = ModelInventory.measure(
                availability: availability, preparing: preparations)
            let recordings = RecordingStore.recordingsDiskUsage()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.entries = measured
                self.recordingsBytes = recordings
                self.isMeasuring = false
            }
        }
    }

    var totalModelBytes: Int64 { ModelInventory.totalBytes(entries) }

    // MARK: - Actions

    func reveal(_ entry: ModelInventoryEntry) {
        // The first directory that exists. A Parakeet that has only ever fetched
        // v3 has an empty v2 path, and opening that would show the user an
        // enclosing folder they did not ask about.
        let existing = entry.cacheDirectories.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let target = existing ?? entry.cacheDirectories.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Asks whether the weights may go, and produces either the question to put
    /// to the user or the reason there is nothing to ask.
    func requestRemoval(of entry: ModelInventoryEntry) {
        failure = nil
        let preferences = AppPreferences.shared
        let decision = ModelRemoval.decide(
            engine: entry.engine,
            installedBytes: entry.installedBytes,
            availability: EngineAvailability.current(
                fluidAudioModelVersion: preferences.fluidAudioModelVersion),
            activeEngine: service.selection.active,
            isTranscribing: service.isTranscribing,
            preparing: [service.modelPreparation?.engine, settingsPreparation?.engine]
                .compactMap { $0 },
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion
        )

        switch decision {
        case .success(let consequence):
            pendingRemoval = PendingRemoval(engine: entry.engine, consequence: consequence)
        case .failure(let refusal):
            failure = refusal.message
        }
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    /// Deletes the weights the user agreed to delete.
    ///
    /// The engine is reloaded afterwards, not before: `EngineSelector` has to be
    /// asked again which engine can transcribe *now*, and until it is, the app
    /// still believes it is running on weights that are gone. Nothing here
    /// writes `selectedEngine` - the user's choice survives the deletion of its
    /// weights, and the status row goes on naming it.
    func confirmRemoval() {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil

        let directories = ModelInventory.cacheDirectories(for: pending.engine)
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for directory in directories {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.failure = failures.first
                self.service.reloadEngine(allowModelDownload: false)
                NotificationCenter.default.post(name: .engineModelStateChanged, object: nil)
                self.refresh()
            }
        }
    }
}

/// Every engine's weights as they exist on this Mac, what they cost, and the
/// safe things to do about them.
///
/// It leads with the **outcome** rather than the model name - "The widest
/// language coverage", not "Whisper" - because the picker above it asks a user
/// to choose an implementation before anything has told them what the
/// implementations are for. The model name is beside it on every row, because
/// keeping it is a licence obligation (`docs/speech-model-attribution.md`).
struct ModelInventoryView: View {

    @StateObject private var viewModel = ModelInventoryViewModel()
    @ObservedObject private var service = TranscriptionService.shared

    /// The engine picker's binding, so a row that is not downloaded can offer
    /// the one safe action there is for a multi-model engine: go and choose one.
    @ObservedObject var settings: SettingsViewModel

    @State private var isConfirmingRemoval = false

    private var machine: EngineRecommendation.Machine { .current() }
    private var recommended: EngineKind { EngineRecommendation.engine(for: machine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 8) {
                ForEach(viewModel.entries) { entry in
                    row(for: entry)
                }
            }

            if let note = EngineRecommendation.memoryNote(for: machine) {
                Label(note, systemImage: "memorychip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = viewModel.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            totals
        }
        .onAppear {
            viewModel.settingsPreparation = settings.engineDownloadPreparation
            viewModel.refresh()
        }
        .onChange(of: service.modelPreparation) { _, _ in viewModel.refresh() }
        .onChange(of: settings.engineDownloadPreparation) { _, preparation in
            viewModel.settingsPreparation = preparation
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .engineModelStateChanged)) { _ in
            viewModel.refresh()
        }
        .onChange(of: viewModel.pendingRemoval) { _, pending in
            isConfirmingRemoval = pending != nil
        }
        .confirmationDialog(
            "Remove downloaded model",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible,
            presenting: viewModel.pendingRemoval
        ) { pending in
            Button(
                "Remove",
                role: pending.consequence.isSevere ? .destructive : nil
            ) {
                viewModel.confirmRemoval()
            }
            Button("Cancel", role: .cancel) { viewModel.cancelRemoval() }
        } message: { pending in
            Text(pending.message)
        }
        .dismissesOnPowerOff($isConfirmingRemoval)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models on this Mac")
                .font(.headline)
            Text(
                "What each engine is for, what it is costing you, and what is safe to remove. "
                    + "Nothing here downloads or deletes anything on its own."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models: \(DirectorySize.describe(viewModel.totalModelBytes))")
                Text("Recordings: \(DirectorySize.describe(viewModel.recordingsBytes))")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Spacer(minLength: 0)

            if viewModel.isMeasuring {
                ProgressView().controlSize(.small)
            } else {
                Button("Recalculate") { viewModel.refresh() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Read the disk again")
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// One row, built outside the `ForEach`.
    ///
    /// Hoisted because the initialiser grew past what the type checker will take
    /// inside a view builder: it failed with "unable to type-check this
    /// expression in reasonable time" rather than with anything about the code.
    private func row(for entry: ModelInventoryEntry) -> some View {
        let isBlocked = settings.isDownloading && settings.downloadingEngine != entry.engine
        return ModelInventoryRow(
            entry: entry,
            isRecommended: entry.engine == recommended,
            isActive: service.selection.active == entry.engine,
            isSelected: settings.selectedEngine == entry.engine,
            recommendationReason: EngineRecommendation.reason(for: machine),
            languages: ModelInventory.languageNames(
                for: entry.engine, fluidAudioModelVersion: settings.fluidAudioModelVersion),
            // Only one transfer runs at a time. A row that is not the one
            // running says so rather than offering a button whose guard returns
            // in silence.
            isBlockedByAnotherDownload: isBlocked,
            download: { Task { await download(entry) } },
            cancel: { cancel(entry) },
            choose: { settings.selectedEngine = entry.engine },
            reveal: { viewModel.reveal(entry) },
            remove: { viewModel.requestRemoval(of: entry) })
    }

    private func download(_ entry: ModelInventoryEntry) async {
        viewModel.failure = nil
        do {
            try await settings.downloadEngineModel(entry.engine)
        } catch {
            viewModel.failure = error.localizedDescription
        }
        viewModel.refresh()
    }

    private func cancel(_ entry: ModelInventoryEntry) {
        let targets = ModelInventoryCancel.targets(
            for: entry.engine,
            servicePreparation: service.modelPreparation?.engine,
            settingsDownload: settings.downloadingEngine)
        if targets.servicePreparation {
            service.cancelDesiredEnginePreparation()
        }
        if targets.settingsDownload {
            settings.cancelDownload()
        }
        viewModel.refresh()
    }
}

/// Which transfers a row's Cancel button stops.
///
/// Two rows can be preparing at once - the desired engine's background
/// preparation and a Settings-driven download of a different engine - and a
/// Cancel pressed on one row must leave the other's transfer running. A row
/// owns a transfer only when that transfer's engine is the row's; the guards in
/// `ModelInventoryView.cancel` are this function rather than two inline
/// comparisons so the two-rows-preparing case is assertable without a service.
enum ModelInventoryCancel {
    struct Targets: Equatable {
        let servicePreparation: Bool
        let settingsDownload: Bool
    }

    static func targets(
        for engine: EngineKind,
        servicePreparation: EngineKind?,
        settingsDownload: EngineKind?
    ) -> Targets {
        Targets(
            servicePreparation: servicePreparation == engine,
            settingsDownload: settingsDownload == engine)
    }
}

/// One engine's row.
///
/// Its own view, taking values rather than the view model, so every state -
/// ready, incomplete, downloading, the recommended one, the active one - can be
/// rendered and read back without a disk. `ModelInventoryRenderTests` does that.
struct ModelInventoryRow: View {

    let entry: ModelInventoryEntry
    let isRecommended: Bool
    let isActive: Bool
    let isSelected: Bool
    let recommendationReason: String

    /// The engine's language coverage, as display names, from
    /// `ModelInventory.languageNames` - an explicit attribute of the row rather
    /// than something left inside the outcome prose.
    let languages: [String]

    /// Whether some *other* row's download is holding the one transfer slot.
    ///
    /// One at a time is the right rule, but a rule enforced by a guard that
    /// returns silently is a button that does nothing when pressed. The row
    /// says which it is instead.
    var isBlockedByAnotherDownload: Bool = false

    let download: () -> Void
    let cancel: () -> Void
    let choose: () -> Void
    let reveal: () -> Void
    let remove: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Whether this engine's weights are one download the app can start on its
    /// own. Whisper and Parakeet pick between several models, so the safe action
    /// for them is to go and choose one rather than to guess.
    private var hasSingleDownload: Bool { entry.expectedMegabytes != nil }

    private var isPreparing: Bool {
        if case .preparing = entry.readiness { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.outcome)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if isRecommended {
                    badge("Recommended", tint: .accentColor)
                }
                if isActive {
                    badge("In use", tint: .green)
                }

                Spacer(minLength: 0)

                Text(entry.readiness.label)
                    .font(.caption)
                    .foregroundColor(readinessColor)
            }

            Text(entry.displayName)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(entry.character)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !languages.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Languages:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FlowLayout(spacing: 4) {
                        ForEach(visibleLanguages, id: \.self) { language in
                            languageTag(language)
                        }
                        if hiddenLanguageCount > 0 {
                            languageTag("+\(hiddenLanguageCount) more")
                                .help(languages.joined(separator: ", "))
                        }
                    }
                }
            }

            Text(entry.sizeSummary)
                .font(.caption)
                .foregroundColor(.secondary)

            if isRecommended {
                Text(recommendationReason)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .preparing(let stage) = entry.readiness {
                progress(stage)
            }

            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isActive ? Color.green.opacity(0.4) : Color.secondary.opacity(0.18),
                    lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.outcome), \(entry.displayName)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [entry.readiness.label, entry.sizeSummary]
        if !languages.isEmpty { parts.append("Languages: \(languages.joined(separator: ", "))") }
        if isRecommended { parts.append("Recommended") }
        if isActive { parts.append("In use") }
        if isBlockedByAnotherDownload {
            parts.append(ModelInventoryRow.blockedByAnotherDownloadHelp)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Long lists (Whisper's nineteen, Parakeet's twenty-five) are cut so the
    /// row stays a row; the overflow chip's tooltip and the accessibility value
    /// both carry the full list.
    private static let maximumVisibleLanguageTags = 6

    private var visibleLanguages: [String] {
        Array(languages.prefix(Self.maximumVisibleLanguageTags))
    }

    private var hiddenLanguageCount: Int {
        languages.count - visibleLanguages.count
    }

    private func languageTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.10)))
    }

    @ViewBuilder private func progress(_ stage: ModelPreparationStage) -> some View {
        if case .downloading(let fraction) = stage {
            ProgressView(value: fraction).controlSize(.small)
        } else {
            // No fraction worth showing: the Neural Engine compile publishes
            // none, and a bar left at its last value reads as a hang.
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch entry.readiness {
            case .preparing:
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .notInstalled where hasSingleDownload:
                transferButton("Download")
            case .incomplete where hasSingleDownload:
                transferButton("Retry")
            case .notInstalled, .incomplete:
                // Whisper and Parakeet: several models, and which one is a
                // choice this row must not make on the user's behalf.
                Button("Choose a model", action: choose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSelected)
                    .help(
                        isSelected
                            ? "The model list for this engine is above"
                            : "Selects this engine so its model list is shown above")
            case .ready, .noWeightsToInstall:
                EmptyView()
            }

            if entry.hasBytesToRemove {
                Button("Reveal", action: reveal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show the weights in Finder")

                // Not offered while the download is running. `ModelRemoval`
                // refuses that case anyway, but an offer the app is going to
                // refuse is a worse answer than not making it: the directory is
                // being written into, and deleting it leaves exactly the
                // half-cache the row above would then report.
                if !isPreparing {
                    Button("Remove", action: remove)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete the downloaded weights. You will be asked first.")
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Download or Retry, disabled while another row owns the one transfer slot
    /// and naming that rather than going quiet.
    private func transferButton(_ title: String) -> some View {
        Button(title, action: download)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBlockedByAnotherDownload)
            .help(
                isBlockedByAnotherDownload
                    ? ModelInventoryRow.blockedByAnotherDownloadHelp
                    : "Fetch this engine's weights")
    }

    static let blockedByAnotherDownloadHelp =
        "Another model is downloading. Kongweh fetches one at a time."

    private var readinessColor: Color {
        switch entry.readiness {
        case .ready: return .green
        case .incomplete: return .orange
        case .notInstalled, .noWeightsToInstall: return .secondary
        case .preparing: return .accentColor
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14)))
    }
}
