import AppKit
import SwiftUI

/// Editing surface for `terms.json` and the safe-correction toggle.
///
/// Wraps the plain `PersonalTermsStore` singleton the way `SettingsViewModel`
/// wraps `AppPreferences`: the store is read by the transcription pipeline from
/// a background task, so the observable layer lives here rather than in it.
@MainActor
final class PersonalTermsViewModel: ObservableObject {
    @Published private(set) var terms: [PersonalTerm]
    @Published var saveError: String?

    @Published var safeCorrectionEnabled: Bool {
        didSet {
            AppPreferences.shared.safeCorrectionEnabled = safeCorrectionEnabled
        }
    }

    private let store: PersonalTermsStore

    init(store: PersonalTermsStore = .shared) {
        self.store = store
        self.terms = store.terms
        self.safeCorrectionEnabled = AppPreferences.shared.safeCorrectionEnabled
    }

    var fileURL: URL { store.fileURL }

    /// Set when `terms.json` exists but could not be read. Surfaced rather than
    /// swallowed, because the alternative is a screen that looks like the
    /// user's dictionary was lost.
    var loadFailure: String? { store.loadFailure }
    var canMutate: Bool { loadFailure == nil }

    func reload() {
        store.reload()
        terms = store.terms
    }

    func upsert(_ term: PersonalTerm) {
        guard canMutate else { return }
        var updated = terms
        if let index = updated.firstIndex(where: { $0.id == term.id }) {
            updated[index] = term
        } else {
            updated.append(term)
        }
        persist(updated)
    }

    func remove(_ ids: Set<UUID>) {
        guard canMutate, !ids.isEmpty else { return }
        persist(terms.filter { !ids.contains($0.id) })
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard canMutate,
              let index = terms.firstIndex(where: { $0.id == id }) else { return }
        var updated = terms
        updated[index].isEnabled = isEnabled
        persist(updated)
    }

    private func persist(_ updated: [PersonalTerm]) {
        do {
            try store.replaceAll(updated)
            terms = store.terms
            saveError = nil
        } catch {
            saveError = "Could not save terms.json: \(error.localizedDescription)"
        }
    }
}

struct PersonalTermsSettingsView: View {
    @StateObject private var viewModel = PersonalTermsViewModel()
    @State private var selection: Set<UUID> = []
    @State private var editedTerm: PersonalTerm?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                safeCorrectionCard
                termsCard
                // The other thing a user's own words do to a transcription:
                // the dictionary corrects what they said, snippets replace it
                // with what they stored. Same pane, separate stages.
                VoiceSnippetsSettingsView()
                // The third list of the user's own words that changes what a
                // dictation does - and the only one that leaves the app - so it
                // is listed beside them rather than hidden behind a tab of its
                // own. See `docs/youtube-latest-video.md`.
                YouTubeChannelsSettingsView()
                fileCard
            }
            .padding()
        }
        .sheet(item: $editedTerm) { term in
            PersonalTermEditorView(term: term) { edited in
                viewModel.upsert(edited)
            }
        }
        .dismissesOnPowerOff($editedTerm)
    }

    // MARK: - Safe correction

    private var safeCorrectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Safe Correction")
                .font(.headline)
                .foregroundColor(.primary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply Safe Correction")
                        .font(.subheadline)
                    Text("Runs your personal terms on every transcription. Entirely on-device and rule-based: no AI model, no network, no macOS upgrade.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $viewModel.safeCorrectionEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - Terms

    private var termsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Personal Terms")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                if !selection.isEmpty {
                    Button(role: .destructive) {
                        viewModel.remove(selection)
                        selection = []
                    } label: {
                        Label("Remove", systemImage: "minus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the selected entries")
                    .disabled(!viewModel.canMutate)
                }

                Button {
                    editedTerm = PersonalTerm(kind: .replacement, match: "")
                } label: {
                    Label("Add Term", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help("Add a dictionary entry")
                .disabled(!viewModel.canMutate)
            }

            if let failure = viewModel.loadFailure {
                warning(failure + " The file was left untouched; fix or move it, then reopen Settings.")
            }
            if let saveError = viewModel.saveError {
                warning(saveError)
            }

            if viewModel.terms.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(viewModel.terms) { term in
                        PersonalTermRow(
                            term: term,
                            canMutate: viewModel.canMutate,
                            onToggle: { viewModel.setEnabled($0, for: term.id) },
                            onEdit: { editedTerm = term }
                        )
                        .contextMenu {
                            Button("Edit…") { editedTerm = term }
                                .disabled(!viewModel.canMutate)
                            Button("Remove", role: .destructive) {
                                viewModel.remove([term.id])
                                selection.remove(term.id)
                            }
                            .disabled(!viewModel.canMutate)
                        }
                        .tag(term.id)
                    }
                }
                .frame(height: 220)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

                Text("Longer entries win over shorter ones, so 臺北市 is matched before 臺北. Traditional and Simplified match each other; what gets written is always the spelling you typed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No terms yet.")
                .font(.subheadline)
            Text("Add the names, jargon and spellings the recognizer keeps getting wrong, or mark text it should never touch.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - File

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictionary File")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Plain JSON you can back up, sync or hand-edit.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Reload") {
                        viewModel.reload()
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .help("Re-read terms.json after editing it outside the app")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([viewModel.fileURL])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal terms.json")
                }

                Text(viewModel.fileURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }
}

private struct PersonalTermRow: View {
    let term: PersonalTerm
    let canMutate: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { term.isEnabled }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(term.isEnabled ? "Applied to transcriptions" : "Kept but not applied")
                .disabled(!canMutate)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(term.match.isEmpty ? "(empty)" : term.match)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if term.kind.substitutesText {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(term.replacement.isEmpty ? "(empty)" : term.replacement)
                            .font(.subheadline)
                    }
                }

                if let hint = term.contextHint {
                    Text("only when the dictation also contains \(hint)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !term.isValid {
                    Text("Incomplete - not applied until it has both fields.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            Text(term.kind.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.controlBackgroundColor).opacity(0.8))
                .cornerRadius(4)

            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit this entry")
            .disabled(!canMutate)
        }
        .opacity(term.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
    }
}

/// Add / edit sheet for one entry.
private struct PersonalTermEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PersonalTerm
    private let onSave: (PersonalTerm) -> Void

    init(term: PersonalTerm, onSave: @escaping (PersonalTerm) -> Void) {
        _draft = State(initialValue: term)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal Term")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(PersonalTermKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                Text(draft.kind.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(draft.kind == .protect ? "Text to keep exactly" : "What is transcribed")
                    .font(.subheadline)
                TextField("頂頂群", text: $draft.match)
                    .textFieldStyle(.roundedBorder)
                Text("Matched in Traditional or Simplified Chinese, and anywhere inside a sentence - no spaces needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.kind.substitutesText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Replace it with")
                        .font(.subheadline)
                    TextField("釘釘群", text: $draft.replacement)
                        .textFieldStyle(.roundedBorder)
                    Text("Written out exactly as you type it here. Your script is never converted for you.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Only when the dictation also contains (optional)")
                    .font(.subheadline)
                TextField("開會", text: Binding(
                    get: { draft.contextHint ?? "" },
                    set: { draft.contextHint = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Text("Use this for homophones. Without a hint the entry applies to every dictation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Enabled", isOn: $draft.isEnabled)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedDraft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!normalizedDraft.isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Trims whitespace the user did not mean to type, and drops a replacement
    /// left over from switching the kind to never-correct.
    private var normalizedDraft: PersonalTerm {
        var term = draft
        term.match = term.match.trimmingCharacters(in: .whitespacesAndNewlines)
        term.replacement = term.kind.substitutesText
            ? term.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if let hint = term.contextHint?.trimmingCharacters(in: .whitespacesAndNewlines) {
            term.contextHint = hint.isEmpty ? nil : hint
        }
        return term
    }
}
