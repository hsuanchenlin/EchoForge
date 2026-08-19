import SwiftUI

/// The Cloud pane: the only place in the app where anything can be pointed at a
/// model provider.
///
/// One pane rather than a row in each feature's own tab, and that is the point:
/// a person deciding whether their dictation leaves their Mac should see every
/// part of that decision at once - what is sent, where, with whose key - instead
/// of meeting it twice as an unremarkable toggle among the settings for
/// something else.
///
/// Local is preselected everywhere and nothing here does anything until someone
/// changes it. See `docs/cloud-api.md`.
struct CloudSettingsView: View {
    @StateObject private var viewModel = CloudSettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                featureChoices
                Divider()
                providerFields
                Divider()
                footer
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(12)
        }
        .padding()
        .onAppear { viewModel.refresh() }
        .sheet(item: $viewModel.pendingConsent) { pending in
            CloudConsentSheet(
                copy: pending.copy,
                confirm: { viewModel.acceptConsent(for: pending.feature) },
                cancel: { viewModel.pendingConsent = nil }
            )
        }
        .dismissesOnPowerOff($viewModel.pendingConsent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cloud")
                .font(.headline)
            Text("EchoForge does everything on your Mac unless you change something here. "
                + "Turn a feature on below and it is sent to the provider you configure, using "
                + "your own API key.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featureChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(CloudFeature.allCases, id: \.self) { feature in
                CloudFeatureChoiceRow(feature: feature, viewModel: viewModel)
            }

            // Named because its absence is a promise: someone reading this pane
            // should not have to infer that the other model features stayed put.
            Text("Style rewriting, the Ask panel and screen questions always run on this Mac and "
                + "are not offered here.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Base URL", text: $viewModel.baseURLText)
                    .textFieldStyle(.roundedBorder)
                Text(viewModel.baseURLStatus)
                    .font(.caption2)
                    .foregroundColor(viewModel.baseURLIsUsable ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SecureField("API key", text: $viewModel.apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { viewModel.saveAPIKey() }
                        .disabled(viewModel.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(viewModel.apiKeyStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("whisper-1", text: $viewModel.transcriptionModel)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("gpt-4o-mini", text: $viewModel.translationModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                viewModel.forgetEverything()
            } label: {
                Label("Forget key and turn everything back to on-device", systemImage: "trash")
            }
            .disabled(!viewModel.hasAnythingToForget)

            Link("What is sent, when, and where →", destination: CloudConsent.docsURL)
                .font(.caption)
        }
    }
}

/// One feature's Local/Cloud choice, with the sentence saying what it currently
/// does underneath.
private struct CloudFeatureChoiceRow: View {
    let feature: CloudFeature
    @ObservedObject var viewModel: CloudSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feature.name)
                    .font(.subheadline)
                Spacer(minLength: 12)
                Picker("", selection: viewModel.binding(for: feature)) {
                    Text("On my Mac").tag(false)
                    Text("Cloud").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            Text(viewModel.status(for: feature))
                .font(.caption2)
                .foregroundColor(viewModel.isMisconfigured(feature) ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one-time explanation, shown before a feature is switched to the cloud for
/// the first time.
///
/// A sheet with two plainly worded buttons and no default action: neither button
/// is `.borderedProminent`, so nothing here is nudging. The wording is
/// `CloudConsent.copy`, which is tested.
private struct CloudConsentSheet: View {
    let copy: CloudConsent.Copy
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(copy.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(copy.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .padding(.top, 6)
                            .foregroundColor(.secondary)
                        Text(point)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Link(copy.learnMore, destination: CloudConsent.docsURL)
                .font(.caption)

            HStack {
                Button(copy.cancel, action: cancel)
                Spacer()
                Button(copy.confirm, action: confirm)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A consent sheet waiting to be answered.
struct PendingCloudConsent: Identifiable {
    let feature: CloudFeature
    let copy: CloudConsent.Copy

    var id: String { feature.rawValue }
}

/// The Cloud pane's state.
///
/// It owns three things the view must not do for itself: the consent gate (a
/// feature can only be switched on through `requestCloud`, which either finds a
/// recorded consent or presents the sheet), the Keychain (the key is written
/// through `CloudCredentialStoring` and never held in a preference), and the
/// engine switch, which has to reach `TranscriptionService` the same way the
/// Model pane's picker does.
@MainActor
final class CloudSettingsViewModel: ObservableObject {

    @Published var baseURLText: String {
        didSet { AppPreferences.shared.cloudBaseURL = baseURLText; refresh() }
    }

    @Published var transcriptionModel: String {
        didSet { AppPreferences.shared.cloudTranscriptionModel = transcriptionModel; refresh() }
    }

    @Published var translationModel: String {
        didSet { AppPreferences.shared.cloudTranslationModel = translationModel; refresh() }
    }

    /// What is in the key field. Never persisted from here - `saveAPIKey` is what
    /// writes it, to the Keychain - and cleared as soon as it has been stored, so
    /// the pane never leaves a key sitting in a view's memory or on screen.
    @Published var apiKeyDraft: String = ""

    @Published var pendingConsent: PendingCloudConsent?

    /// Recomputed rather than observed: the underlying values live in
    /// preferences and the Keychain, neither of which publishes changes.
    @Published private(set) var settings: CloudSettings
    @Published private(set) var hasStoredKey: Bool

    private let preferences: AppPreferences
    private let credentials: CloudCredentialStoring

    init(
        preferences: AppPreferences = .shared,
        credentials: CloudCredentialStoring = KeychainCloudCredentialStore()
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.baseURLText = preferences.cloudBaseURL
        self.transcriptionModel = preferences.cloudTranscriptionModel
        self.translationModel = preferences.cloudTranslationModel
        self.settings = CloudSettings.current(preferences: preferences)
        // Deliberately not read here: on macOS a `TabView` builds every tab, so
        // reading it in the initialiser would touch the Keychain whenever anyone
        // opened Settings at all. `onAppear` does it instead, so the first
        // Keychain access happens when the user opens *this* pane.
        self.hasStoredKey = false
    }

    func refresh() {
        settings = CloudSettings.current(preferences: preferences)
        hasStoredKey = credentials.apiKey() != nil
    }

    // MARK: - The choice

    func binding(for feature: CloudFeature) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.settings.isEnabled(feature) ?? false },
            set: { [weak self] wantsCloud in
                guard let self else { return }
                if wantsCloud {
                    self.requestCloud(for: feature)
                } else {
                    self.selectLocal(for: feature)
                }
            }
        )
    }

    /// The only way a feature is switched to the cloud.
    ///
    /// With no recorded consent it does not switch anything: it presents the
    /// sheet and waits. That is what makes the consent the decision rather than a
    /// notice shown after the fact.
    func requestCloud(for feature: CloudFeature) {
        guard settings.hasConsented(to: feature) else {
            let endpoint = try? CloudEndpoint.resolve(baseURLText).get()
            pendingConsent = PendingCloudConsent(
                feature: feature,
                copy: CloudConsent.copy(
                    for: feature,
                    host: endpoint?.host ?? "the provider you configure",
                    isLoopback: endpoint?.isLoopback ?? false
                )
            )
            return
        }
        enable(feature)
    }

    func acceptConsent(for feature: CloudFeature) {
        CloudConsent.grant(feature, preferences: preferences)
        pendingConsent = nil
        enable(feature)
    }

    func selectLocal(for feature: CloudFeature) {
        switch feature {
        case .transcription:
            // Which engine to go back to is `CloudTranscriptionSelection`'s
            // decision; carrying the choice out is `EngineSelectionCommand`'s, the
            // same as the Model pane's picker and the engine shortcut.
            EngineSelectionCommand.select(
                CloudTranscriptionSelection.localEngineToRestore(preferences: preferences),
                preferences: preferences
            )
        case .translation:
            preferences.cloudTranslationEnabled = false
        }
        refresh()
    }

    /// Clears the key and puts every feature back on device.
    ///
    /// Consent goes too, so the next attempt asks again. Someone who presses
    /// this is not saying "pause it", they are saying "forget it".
    func forgetEverything() {
        credentials.setAPIKey(nil)
        // Revoking transcription's consent also takes the cloud engine away
        // (`CloudConsent.revoke`), so this is an engine change like any other and
        // the panes showing the engine have to hear about it.
        CloudConsent.revokeEverything(preferences: preferences)
        apiKeyDraft = ""
        reloadEngine()
        NotificationCenter.default.post(name: .selectedEngineChanged, object: nil)
        refresh()
    }

    var hasAnythingToForget: Bool {
        hasStoredKey || !settings.consentedFeatures.isEmpty
    }

    // MARK: - The key

    func saveAPIKey() {
        credentials.setAPIKey(apiKeyDraft)
        apiKeyDraft = ""
        reloadEngine()
        refresh()
    }

    var apiKeyStatus: String {
        hasStoredKey
            ? "A key is stored in your Keychain. Type a new one above to replace it."
            : "No key stored. It is kept in your Mac's Keychain, never in EchoForge's settings file."
    }

    // MARK: - What the pane says

    var baseURLIsUsable: Bool {
        if case .success = CloudEndpoint.resolve(baseURLText) { return true }
        return false
    }

    var baseURLStatus: String {
        switch CloudEndpoint.resolve(baseURLText) {
        case .success(let endpoint):
            return endpoint.isLoopback
                ? "\(endpoint.host) is on this Mac, so requests do not leave it."
                : "Requests go to \(endpoint.host)."
        case .failure(let error):
            return error.explanation
        }
    }

    func status(for feature: CloudFeature) -> String {
        switch CloudAccess.resolve(feature, settings: settings, credentials: credentials) {
        case .success(let call):
            return "Sent to \(call.endpoint.host) as \(call.model)."
        case .failure(let refusal):
            return refusal.explanation
        }
    }

    func isMisconfigured(_ feature: CloudFeature) -> Bool {
        guard case .failure(let refusal) = CloudAccess.resolve(
            feature, settings: settings, credentials: credentials
        ) else { return false }
        return refusal.isMisconfiguration
    }

    // MARK: - Private

    private func enable(_ feature: CloudFeature) {
        switch feature {
        case .transcription:
            EngineSelectionCommand.select(.cloud, preferences: preferences)
        case .translation:
            preferences.cloudTranslationEnabled = true
        }
        refresh()
    }

    /// The same call the Model pane's picker makes, for the same reason: the
    /// engine in use is chosen by `TranscriptionService`, and a preference
    /// written without telling it leaves the app transcribing on the old one
    /// until something else happens to reload.
    private func reloadEngine() {
        TranscriptionService.shared.reloadEngine()
    }
}
