import SwiftUI

/// Editing surface for the voice snippets, shown under Dictionary & Snippets.
///
/// Wraps `VoiceSnippetStore` the way `PersonalTermsViewModel` wraps the terms
/// store: the store is read on the dictation path and holds no state of its
/// own, so the observable layer lives here.
@MainActor
final class VoiceSnippetsViewModel: ObservableObject {
    @Published private(set) var snippets: [VoiceSnippet]
    @Published var saveError: String?

    @Published var voiceSnippetsEnabled: Bool {
        didSet { AppPreferences.shared.voiceSnippetsEnabled = voiceSnippetsEnabled }
    }

    /// Whether spoken commands are on at all. Snippets are one of the things
    /// that routing does, so a pane that let the user build macros without
    /// saying they will never fire would be lying by omission.
    @Published private(set) var spokenIntentsEnabled: Bool

    private let store: VoiceSnippetStore

    init(store: VoiceSnippetStore = .shared) {
        self.store = store
        self.snippets = store.snippets
        self.voiceSnippetsEnabled = AppPreferences.shared.voiceSnippetsEnabled
        self.spokenIntentsEnabled = AppPreferences.shared.spokenIntentsEnabled
    }

    var loadFailure: String? { store.loadFailure }
    var canMutate: Bool { store.canMutate }

    func refresh() {
        snippets = store.snippets
        spokenIntentsEnabled = AppPreferences.shared.spokenIntentsEnabled
    }

    func upsert(_ snippet: VoiceSnippet) {
        perform { try store.upsert(snippet) }
    }

    func remove(_ ids: Set<UUID>) {
        perform { try store.remove(ids) }
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        perform { try store.setEnabled(isEnabled, for: id) }
    }

    /// Throws away a document that could not be read. The only repair there is,
    /// and the user presses it after being told what it costs.
    func reset() {
        store.reset()
        snippets = store.snippets
        saveError = nil
    }

    /// Whether another snippet already answers to `keyword`, so the editor can
    /// say so before a second one is saved into a trigger it will never win.
    func hasConflict(with snippet: VoiceSnippet) -> Bool {
        let key = VoiceSnippetTrigger.normalize(snippet.keyword)
        guard !key.isEmpty else { return false }
        return snippets.contains { $0.id != snippet.id && $0.triggerKey == key }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            snippets = store.snippets
            saveError = nil
        } catch {
            saveError = "Could not save your snippets: \(error.localizedDescription)"
        }
    }
}

struct VoiceSnippetsSettingsView: View {
    @StateObject private var viewModel = VoiceSnippetsViewModel()
    @State private var selection: Set<UUID> = []
    @State private var editedSnippet: VoiceSnippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let failure = viewModel.loadFailure {
                loadFailureNotice(failure)
            }
            if let saveError = viewModel.saveError {
                warning(saveError)
            }
            if !viewModel.spokenIntentsEnabled {
                warning("Snippets only fire while Spoken commands is on, in Shortcuts → Ask & Spoken Commands.")
            }

            if viewModel.snippets.isEmpty {
                emptyState
            } else {
                snippetList
                Text("Say “insert \(exampleKeyword)”, or just “\(exampleKeyword)” on its own; in Chinese, “插入” works the same way. The template is inserted exactly as you typed it - blank lines and all - and is never rewritten by the Style pane.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .onAppear { viewModel.refresh() }
        .sheet(item: $editedSnippet) { snippet in
            VoiceSnippetEditorView(
                snippet: snippet,
                hasConflict: { viewModel.hasConflict(with: $0) }
            ) { edited in
                viewModel.upsert(edited)
            }
        }
        .dismissesOnPowerOff($editedSnippet)
    }

    /// The trigger the hint sentence is written around: the user's own first
    /// one, so the example is something they can actually say.
    private var exampleKeyword: String {
        viewModel.snippets.first(where: \.isValid)?.keyword ?? "email signoff"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Snippets & Macros")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("Say a trigger, get the text you stored for it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                .help("Remove the selected snippets")
                .disabled(!viewModel.canMutate)
            }

            Button {
                editedSnippet = VoiceSnippet(keyword: "", expansion: "")
            } label: {
                Label("Add Snippet", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .help("Add a voice snippet")
            .disabled(!viewModel.canMutate)

            Toggle("", isOn: $viewModel.voiceSnippetsEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .help("Expand snippet triggers while dictating")
                .accessibilityLabel("Expand voice snippets")
                // Clear of the buttons beside it: the switch is the section's,
                // not the Add button's.
                .padding(.leading, 8)
        }
    }

    private var snippetList: some View {
        List(selection: $selection) {
            ForEach(viewModel.snippets) { snippet in
                VoiceSnippetRow(
                    snippet: snippet,
                    canMutate: viewModel.canMutate,
                    onToggle: { viewModel.setEnabled($0, for: snippet.id) },
                    onEdit: { editedSnippet = snippet }
                )
                .contextMenu {
                    Button("Edit…") { editedSnippet = snippet }
                        .disabled(!viewModel.canMutate)
                    Button("Remove", role: .destructive) {
                        viewModel.remove([snippet.id])
                        selection.remove(snippet.id)
                    }
                    .disabled(!viewModel.canMutate)
                }
                .tag(snippet.id)
            }
        }
        .frame(height: 180)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .opacity(viewModel.voiceSnippetsEnabled ? 1 : 0.5)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No snippets yet.")
                .font(.subheadline)
            Text("Store the boilerplate you retype: a signoff, a meeting template, an address. Then say “insert” and its trigger while dictating.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadFailureNotice(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            warning(failure + " Nothing was overwritten; resetting discards what is stored and starts again.")
            Button("Reset Snippets", role: .destructive) {
                viewModel.reset()
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
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
}

private struct VoiceSnippetRow: View {
    let snippet: VoiceSnippet
    let canMutate: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(snippet.isEnabled ? "Expanded while dictating" : "Kept but not expanded")
                .disabled(!canMutate)

            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.keyword.isEmpty ? "(no trigger)" : snippet.keyword)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(Self.preview(of: snippet.expansion))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !snippet.isValid {
                    Text("Incomplete - not expanded until it has both a trigger and a template.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit this snippet")
            .disabled(!canMutate)
        }
        .opacity(snippet.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
    }

    /// One line of a template that is usually several, with the line breaks
    /// made visible rather than silently flattened - a row that showed
    /// "Best regards, [your name]" would be describing a template nobody stored.
    static func preview(of expansion: String) -> String {
        guard !expansion.isEmpty else { return "(no template)" }
        return expansion
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ⏎ ")
    }
}

/// Add / edit sheet for one snippet.
private struct VoiceSnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: VoiceSnippet
    private let hasConflict: (VoiceSnippet) -> Bool
    private let onSave: (VoiceSnippet) -> Void

    init(
        snippet: VoiceSnippet,
        hasConflict: @escaping (VoiceSnippet) -> Bool,
        onSave: @escaping (VoiceSnippet) -> Void
    ) {
        _draft = State(initialValue: snippet)
        self.hasConflict = hasConflict
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice Snippet")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Trigger")
                    .font(.subheadline)
                TextField("email signoff", text: $draft.keyword)
                    .textFieldStyle(.roundedBorder)
                Text("Case, punctuation and Traditional or Simplified script do not have to match what you say. Keep it distinctive: saying the trigger on its own expands it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasConflict(normalizedDraft) {
                    Text("Another snippet already uses this trigger, and the one higher in the list wins.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Expands into")
                    .font(.subheadline)
                TextEditor(text: $draft.expansion)
                    .font(.body)
                    .frame(height: 120)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                Text("Inserted exactly as typed here, line breaks and spacing included. Nothing rewrites it.")
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
        .frame(width: 460)
    }

    /// Trims the trigger, which is matched loosely anyway - and leaves the
    /// template completely alone, because its whitespace is the whole point.
    private var normalizedDraft: VoiceSnippet {
        var snippet = draft
        snippet.keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet
    }
}
