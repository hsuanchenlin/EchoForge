import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app-to-style rules, as edited in Settings.
///
/// Every change is written straight through to preferences, the way the rest of
/// the Style pane works: there is no Apply button to forget, and the store is
/// reloaded when the pane appears so a rule added in another window is not
/// overwritten by a stale copy.
@MainActor
final class AppStyleMappingSettingsModel: ObservableObject {

    /// Stored and published rather than a window onto `store.isEnabled`, so the
    /// switch binds with `$` and persists in `didSet` - the same shape the rest
    /// of the Style pane uses (`StyleRewriteSettingsModel`).
    @Published var isEnabled: Bool {
        didSet {
            guard store.isEnabled != isEnabled else { return }
            store.isEnabled = isEnabled
            store.save()
        }
    }

    @Published private(set) var store: AppStyleMappingStore

    init(store: AppStyleMappingStore = .load()) {
        self.store = store
        self.isEnabled = store.isEnabled
    }

    func reload() {
        store = .load()
        isEnabled = store.isEnabled
    }

    func assignment(for category: AppCategory) -> AppStyleAssignment {
        store.assignment(for: category)
    }

    func setAssignment(_ assignment: AppStyleAssignment, for category: AppCategory) {
        store.setAssignment(assignment, for: category)
        store.save()
    }

    func setAssignment(_ assignment: AppStyleAssignment, forApp bundleIdentifier: String) {
        store.setAssignment(assignment, forApp: bundleIdentifier)
        store.save()
    }

    func removeApp(_ bundleIdentifier: String) {
        store.removeApp(bundleIdentifier)
        store.save()
    }

    var appRules: [(bundleIdentifier: String, assignment: AppStyleAssignment)] {
        store.sortedAppOverrides
    }

    /// Adds a rule for an app the user picks from disk.
    ///
    /// An open panel rather than a text field, because the thing being stored is
    /// a bundle identifier and no one knows their mail client's. Only the
    /// identifier is read out of the bundle the user chose.
    ///
    /// The new rule starts as whatever that app already resolves to, so adding
    /// one is not itself a change: it puts the app on screen to be changed.
    func addApp(at url: URL) {
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        let target = DictationTargetApp(bundleIdentifier: identifier)
        let existing = target.category.map { store.assignment(for: $0) } ?? .chosenStyle
        setAssignment(existing, forApp: target.bundleIdentifier)
    }

    /// The name of an installed app, for showing a rule as something other than
    /// a reverse-DNS string. Resolved from the identifier when the rule is drawn
    /// and never stored: what is persisted stays a bundle identifier.
    func installedName(forBundleIdentifier identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        // `displayName` is the localized one, which is what a user recognizes -
        // but it keeps the `.app` extension for anyone who asked Finder to show
        // extensions, and "Notes.app" is a filename where a name belongs.
        let name = FileManager.default.displayName(atPath: url.path)
        let withoutExtension = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return withoutExtension.isEmpty ? nil : withoutExtension
    }
}

/// The "Match the app" section of the Style pane.
struct AppStyleMappingSettingsView: View {
    @StateObject private var model = AppStyleMappingSettingsModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            enableToggle

            if model.isEnabled {
                categoryRules
                appRules
            }
        }
        .onAppear { model.reload() }
    }

    private var enableToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Match the style to the app I dictate into", isOn: $model.isEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))

            Text("Dictating into a chat app uses Casual Chat, into a mail client Formal Business, and so on. Your chosen style is used for every app without a rule. EchoForge only ever reads the frontmost app's identifier - never window titles, documents or web addresses - and that identifier never leaves this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Categories

    private var categoryRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By kind of app")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 0) {
                ForEach(Array(AppCategory.allCases.enumerated()), id: \.element.rawValue) { index, category in
                    if index > 0 {
                        Divider().padding(.leading, 10)
                    }
                    ruleRow(
                        title: category.label,
                        subtitle: category.examples,
                        assignment: model.assignment(for: category),
                        onChange: { model.setAssignment($0, for: category) }
                    )
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

    // MARK: - Individual apps

    private var appRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("By app")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Add App…", action: chooseApp)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if model.appRules.isEmpty {
                Text("A rule for one app beats the rule for its kind - a browser you only ever write mail in, a chat app you keep formal.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.appRules.enumerated()), id: \.element.bundleIdentifier) { index, rule in
                        if index > 0 {
                            Divider().padding(.leading, 10)
                        }
                        ruleRow(
                            title: model.installedName(forBundleIdentifier: rule.bundleIdentifier)
                                ?? rule.bundleIdentifier,
                            subtitle: rule.bundleIdentifier,
                            assignment: rule.assignment,
                            onChange: { model.setAssignment($0, forApp: rule.bundleIdentifier) },
                            onRemove: { model.removeApp(rule.bundleIdentifier) }
                        )
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

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to give its own style."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addApp(at: url)
    }

    // MARK: - One rule

    private func ruleRow(
        title: String,
        subtitle: String,
        assignment: AppStyleAssignment,
        onChange: @escaping (AppStyleAssignment) -> Void,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            Picker(
                "",
                selection: Binding(
                    get: { assignment.storedValue },
                    set: { onChange(AppStyleAssignment(storedValue: $0)) }
                )
            ) {
                Text("My chosen style").tag(AppStyleAssignment.chosenStyleStoredValue)
                ForEach(StyleRewriteCatalog.styles) { style in
                    Text(style.name).tag(style.id)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            // Reserved in every row, so the pickers in the two lists line up
            // rather than the category ones sitting a button's width further
            // right than the per-app ones.
            Group {
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this rule")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
