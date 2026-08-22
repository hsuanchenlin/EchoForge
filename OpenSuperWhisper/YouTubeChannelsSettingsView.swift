import KeyboardShortcuts
import SwiftUI

/// Editing surface for the YouTube channel allowlist, shown under Dictionary &
/// Snippets beside the voice snippets.
///
/// It sits there rather than in a tab of its own because it is the same kind of
/// thing: a short list of the user's own words that changes what a dictation
/// does. A new tab would also change the Settings tab bar, whose width is a
/// single decision shared with every other title (`SettingsSheetLayout`).
@MainActor
final class YouTubeChannelsViewModel: ObservableObject {
    @Published private(set) var channels: [YouTubeChannel]
    @Published var saveError: String?

    @Published var youTubeLatestVideoEnabled: Bool {
        didSet { AppPreferences.shared.youTubeLatestVideoEnabled = youTubeLatestVideoEnabled }
    }

    /// Whether a name neither deterministic tier could place may be handed to the
    /// on-device model to pick from this list. Off by default; the hint beside
    /// it says what the model is given and what it can answer.
    @Published var channelModelMatchEnabled: Bool {
        didSet {
            AppPreferences.shared.youTubeChannelModelMatchEnabled = channelModelMatchEnabled
        }
    }

    /// How the YouTube command key currently reads - "⌥Y" - or nil when the
    /// user has cleared it, which leaves no way to use the feature at all.
    ///
    /// Read rather than written, the same rule `EngineShortcutHint` follows:
    /// nothing in this pane may change a binding, and re-read whenever the pane
    /// appears so changing the key in the Shortcuts tab and coming back here
    /// cannot leave a stale sentence on screen.
    @Published private(set) var commandShortcut: String?

    private let store: YouTubeChannelStore

    init(store: YouTubeChannelStore = .shared) {
        self.store = store
        self.channels = store.channels
        self.youTubeLatestVideoEnabled = AppPreferences.shared.youTubeLatestVideoEnabled
        self.channelModelMatchEnabled = AppPreferences.shared.youTubeChannelModelMatchEnabled
        self.commandShortcut = Self.boundShortcut()
    }

    @MainActor
    private static func boundShortcut() -> String? {
        KeyboardShortcuts.getShortcut(for: .youTubeCommand)?.description
    }

    var loadFailure: String? { store.loadFailure }
    var canMutate: Bool { store.canMutate }

    func refresh() {
        channels = store.channels
        commandShortcut = Self.boundShortcut()
        channelModelMatchEnabled = AppPreferences.shared.youTubeChannelModelMatchEnabled
    }

    func upsert(_ channel: YouTubeChannel) {
        perform { try store.upsert(channel) }
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
        channels = store.channels
        saveError = nil
    }

    /// What is wrong with a draft, for the editor to show while it is being
    /// typed. The same function the store refuses a save with, so the editor
    /// cannot disagree with what actually happens on Save.
    func problems(with draft: YouTubeChannel) -> [YouTubeChannelProblem] {
        YouTubeChannelAllowlist.problems(with: draft, against: channels)
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            channels = store.channels
            saveError = nil
        } catch {
            saveError = "Could not save your channels: \(error.localizedDescription)"
        }
    }
}

struct YouTubeChannelsSettingsView: View {
    @StateObject private var viewModel = YouTubeChannelsViewModel()
    @State private var selection: Set<UUID> = []
    @State private var editedChannel: YouTubeChannel?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let failure = viewModel.loadFailure {
                loadFailureNotice(failure)
            }
            if let saveError = viewModel.saveError {
                warning(saveError)
            }
            // How the command is invoked, said before anything about the list.
            // It is its own key, and the sentence also says what the dictation
            // key still does - which is the distinction the whole feature rests
            // on and the one a user is most likely to have wrong.
            shortcutHint

            if viewModel.channels.isEmpty {
                emptyState
            } else {
                channelList
                Text(YouTubeChannelHelpText.usage(exampleChannel: exampleName))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelMatchSection
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .onAppear { viewModel.refresh() }
        .sheet(item: $editedChannel) { channel in
            YouTubeChannelEditorView(
                channel: channel,
                problems: { viewModel.problems(with: $0) }
            ) { edited in
                viewModel.upsert(edited)
            }
        }
        .dismissesOnPowerOff($editedChannel)
    }

    /// The name the hint sentence is written around: the user's own first
    /// channel, so the example is something they can actually say.
    private var exampleName: String {
        viewModel.channels.first(where: \.isValid)?.displayName ?? "Veritasium"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube Channels")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(YouTubeChannelHelpText.sectionSubtitle)
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
                .help("Remove the selected channels")
                .disabled(!viewModel.canMutate)
            }

            Button {
                editedChannel = YouTubeChannel(displayName: "", channelID: "")
            } label: {
                Label("Add Channel", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .help("Allowlist a YouTube channel")
            .disabled(!viewModel.canMutate)

            Toggle("", isOn: $viewModel.youTubeLatestVideoEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .help("Open a listed channel's latest video when you say so")
                .accessibilityLabel("Open the latest YouTube video by voice")
                // Clear of the buttons beside it: the switch is the section's,
                // not the Add button's.
                .padding(.leading, 8)
        }
    }

    private var channelList: some View {
        List(selection: $selection) {
            ForEach(viewModel.channels) { channel in
                YouTubeChannelRow(
                    channel: channel,
                    canMutate: viewModel.canMutate,
                    onToggle: { viewModel.setEnabled($0, for: channel.id) },
                    onEdit: { editedChannel = channel }
                )
                .contextMenu {
                    Button("Edit…") { editedChannel = channel }
                        .disabled(!viewModel.canMutate)
                    Button("Remove", role: .destructive) {
                        viewModel.remove([channel.id])
                        selection.remove(channel.id)
                    }
                    .disabled(!viewModel.canMutate)
                }
                .tag(channel.id)
            }
        }
        .frame(height: 160)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .opacity(viewModel.youTubeLatestVideoEnabled ? 1 : 0.5)
        .accessibilityLabel("Allowlisted YouTube channels")
    }

    /// The command's own key, named from the binding actually in force.
    private var shortcutHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundColor(viewModel.commandShortcut == nil ? .orange : .accentColor)
            Text(YouTubeChannelHelpText.shortcutWorkflow(shortcut: viewModel.commandShortcut))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
    }

    /// The one setting in this pane that can put a model in the path, with the
    /// disclosure that has to travel with it.
    ///
    /// Shaped as a title-plus-switch row rather than a checkbox, which is what
    /// every other setting row in Settings looks like - and what a `.checkbox`
    /// toggle cannot be made to look like: its AppKit label ignores `.font`, so
    /// it draws at body size beside `.subheadline` titles everywhere else.
    private var modelMatchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.top, 2)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(YouTubeChannelHelpText.modelMatchToggleTitle)
                        .font(.subheadline)
                    Text(YouTubeChannelHelpText.modelMatchHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $viewModel.channelModelMatchEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
                    .disabled(!viewModel.youTubeLatestVideoEnabled)
                    .accessibilityLabel(YouTubeChannelHelpText.modelMatchToggleTitle)
            }
            Text(YouTubeChannelHelpText.modelMatchDisclosure)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(viewModel.youTubeLatestVideoEnabled ? 1 : 0.5)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No channels yet.")
                .font(.subheadline)
            Text(YouTubeChannelHelpText.emptyState)
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
            Button("Reset Channels", role: .destructive) {
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
        .accessibilityElement(children: .combine)
    }
}

private struct YouTubeChannelRow: View {
    let channel: YouTubeChannel
    let canMutate: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { channel.isEnabled }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(channel.isEnabled ? "Can be opened by voice" : "Kept but not opened")
                .accessibilityLabel("Enable \(channel.displayName)")
                .disabled(!canMutate)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName.isEmpty ? "(no name)" : channel.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(Self.subtitle(for: channel))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !channel.isValid {
                    Text("Incomplete - needs a name you can say and a valid UC… channel ID.")
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
            .help("Edit this channel")
            .accessibilityLabel("Edit \(channel.displayName)")
            .disabled(!canMutate)
        }
        .opacity(channel.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// The id, and the other names this channel answers to - the two things the
    /// user needs to check when a command did not do what they expected.
    static func subtitle(for channel: YouTubeChannel) -> String {
        let id = channel.channelID.isEmpty ? "(no channel ID)" : channel.channelID
        guard !channel.aliases.isEmpty else { return id }
        return "\(id) · also “\(channel.aliases.joined(separator: "”, “"))”"
    }
}

/// Add / edit sheet for one channel.
private struct YouTubeChannelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: YouTubeChannel
    /// The aliases as one line the user types, which is how a short list is
    /// edited without a table inside a sheet.
    @State private var aliasText: String
    private let problems: (YouTubeChannel) -> [YouTubeChannelProblem]
    private let onSave: (YouTubeChannel) -> Void

    init(
        channel: YouTubeChannel,
        problems: @escaping (YouTubeChannel) -> [YouTubeChannelProblem],
        onSave: @escaping (YouTubeChannel) -> Void
    ) {
        _draft = State(initialValue: channel)
        _aliasText = State(initialValue: channel.aliases.joined(separator: ", "))
        self.problems = problems
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YouTube Channel")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline)
                TextField("Veritasium", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Channel name")
                Text(YouTubeChannelHelpText.nameHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Also called")
                    .font(.subheadline)
                TextField("veritassium, vera tasium", text: $aliasText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Other spoken names, separated by commas")
                Text(YouTubeChannelHelpText.aliasHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Channel ID")
                    .font(.subheadline)
                TextField("UCHnyfMqiRRG1u-2MsSQLbXA", text: $draft.channelID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("YouTube channel ID")
                    .onChange(of: draft.channelID) { _, pasted in
                        // A pasted /channel/UC… URL is already the ID with
                        // scenery around it, so it is accepted and trimmed down.
                        // Nothing else is: a handle URL does not contain the ID
                        // and this app never asks YouTube to resolve one.
                        if let extracted = YouTubeChannelID.extract(from: pasted),
                           extracted != pasted {
                            draft.channelID = extracted
                        }
                    }
                Text(YouTubeChannelHelpText.channelIDInstructions)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(currentProblems, id: \.self) { problem in
                Text(problem.message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Problem: \(problem.message)")
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
                .disabled(!currentProblems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var currentProblems: [YouTubeChannelProblem] {
        problems(normalizedDraft)
    }

    /// The draft as it would be stored: trimmed, with the alias line split and
    /// deduplicated the same way the store does it.
    private var normalizedDraft: YouTubeChannel {
        var channel = draft
        channel.aliases = aliasText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return channel.deduplicated
    }
}
