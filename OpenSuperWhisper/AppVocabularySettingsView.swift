import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app vocabulary rules, as edited in Settings.
///
/// Every change is written straight through to preferences, the way
/// `AppStyleMappingSettingsModel` does, and the store is reloaded when the pane
/// appears so a change made in another window is not overwritten by a stale copy.
@MainActor
final class AppVocabularySettingsModel: ObservableObject {

    @Published var isEnabled: Bool {
        didSet {
            guard store.isEnabled != isEnabled else { return }
            store.isEnabled = isEnabled
            store.save()
        }
    }

    @Published private(set) var store: AppVocabularyStore

    init(store: AppVocabularyStore = .load()) {
        self.store = store
        self.isEnabled = store.isEnabled
    }

    func reload() {
        store = .load()
        isEnabled = store.isEnabled
    }

    func isEnabled(_ category: AppCategory) -> Bool { store.isEnabled(category) }

    func setEnabled(_ enabled: Bool, for category: AppCategory) {
        store.setEnabled(enabled, for: category)
        store.save()
    }

    var excludedApps: [String] { store.sortedExcludedApps }

    /// Excludes an app the user picks from disk.
    ///
    /// An open panel rather than a text field, for the reason the style pane
    /// uses one: the thing being stored is a bundle identifier and nobody knows
    /// their editor's. Only the identifier is read out of the bundle they chose.
    func excludeApp(at url: URL) {
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        store.exclude(identifier)
        store.save()
    }

    func includeApp(_ bundleIdentifier: String) {
        store.include(bundleIdentifier)
        store.save()
    }

    /// The name of an installed app, resolved when a row is drawn and never
    /// stored: what is persisted stays a bundle identifier.
    func installedName(forBundleIdentifier identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        let withoutExtension = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return withoutExtension.isEmpty ? nil : withoutExtension
    }
}

/// The "App vocabulary" card in Settings → Dictionary & Snippets.
///
/// Every profile is **inspectable**: each row opens onto the exact sample
/// passage and the exact word list that would reach the recognizer. That is not
/// a nicety - a user is being asked to let this app add words to what their
/// recognizer is primed with, and the answer to "what exactly?" has to be on
/// screen rather than in a source file.
struct AppVocabularySettingsView: View {
    @StateObject private var model = AppVocabularySettingsModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded: Set<String>

    /// - Parameter expandedProfiles: which word lists start open, by category
    ///   raw value. None in the app - the lists are there to be consulted rather
    ///   than read - and one in the render test, which exists to check that an
    ///   opened list fits the pane.
    init(expandedProfiles: Set<String> = []) {
        _expanded = State(initialValue: expandedProfiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Vocabulary")
                .font(.headline)
                .foregroundColor(.primary)

            enableToggle

            if model.isEnabled {
                profileList
                excludedAppsSection
            }

            Text("Only the Whisper engine can be shown words before it decodes. Parakeet, SenseVoice and Paraformer take no prompt, so this changes nothing while one of them is selected - and the cloud engine is never shown it at all.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .onAppear { model.reload() }
    }

    private var enableToggle: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use the app I dictate into")
                    .font(.subheadline)
                Text("Primes the recognizer with words and punctuation that suit the app in front of you - code identifiers in an editor, sign-offs in a mail client, headings and links in a notes app. Your own personal terms always come first and are never crowded out. Kongweh reads the frontmost app's identifier and nothing else: no window titles, no documents, no web addresses, and nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $model.isEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
        }
    }

    // MARK: - Profiles

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By kind of app")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 0) {
                ForEach(Array(AppVocabularyCatalog.profiles.enumerated()), id: \.element.id) {
                    index, profile in
                    if index > 0 {
                        Divider().padding(.leading, 10)
                    }
                    profileRow(profile)
                }
            }
            .background(ThemePalette.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
            )
        }
    }

    private func profileRow(_ profile: AppVocabularyProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.category.label)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(profile.category.examples)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)

                // A disclosure rather than a label: the count is the answer to
                // "how much", and the chevron is what says the exact list is one
                // click away. Inspecting it is the point of this pane.
                Button { toggleExpanded(profile) } label: {
                    HStack(spacing: 3) {
                        Text("\(profile.terms.count) words")
                        Image(systemName: isExpanded(profile) ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(
                    isExpanded(profile)
                        ? "Hide the \(profile.category.label) word list"
                        : "Show the \(profile.terms.count) \(profile.category.label) words")

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.isEnabled(profile.category) },
                        set: { model.setEnabled($0, for: profile.category) })
                )
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .accessibilityLabel("Use the \(profile.category.label) vocabulary")
            }

            if isExpanded(profile) {
                profileDetail(profile)
            }
        }
        .padding(10)
        .opacity(model.isEnabled(profile.category) ? 1 : 0.55)
    }

    private func profileDetail(_ profile: AppVocabularyProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample passage")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(profile.hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))

            Text("Words")
                .font(.caption)
                .foregroundColor(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(profile.terms, id: \.self) { term in
                    Text(term)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.07)))
                }
            }
        }
        .padding(.top, 2)
    }

    private func isExpanded(_ profile: AppVocabularyProfile) -> Bool {
        expanded.contains(profile.id)
    }

    private func toggleExpanded(_ profile: AppVocabularyProfile) {
        if expanded.contains(profile.id) {
            expanded.remove(profile.id)
        } else {
            expanded.insert(profile.id)
        }
    }

    // MARK: - Excluded apps

    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Never in these apps")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Add App…", action: chooseApp)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if model.excludedApps.isEmpty {
                Text("An app listed here is dictated into with your own terms alone, whatever kind of app Kongweh thinks it is.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.excludedApps.enumerated()), id: \.element) { index, identifier in
                        if index > 0 {
                            Divider().padding(.leading, 10)
                        }
                        excludedRow(identifier)
                    }
                }
                .background(ThemePalette.cardBackground(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
                )
            }
        }
    }

    private func excludedRow(_ identifier: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.installedName(forBundleIdentifier: identifier) ?? identifier)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(identifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { model.includeApp(identifier) } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Use app vocabulary in this app again")
            .accessibilityLabel("Stop excluding \(identifier)")
        }
        .padding(10)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app that should never get app vocabulary."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.excludeApp(at: url)
    }
}
