import AppKit
import SwiftUI

/// Settings → Setup: is Kongweh ready, and if not, where is the thing to change.
///
/// The pane is a reader. `SetupHealth` decides every word of every row and is a
/// pure function of a snapshot; this gathers the snapshot, draws it, and hands
/// the user a link to the pane that owns whatever needs changing. The single
/// thing here that *does* something is the microphone test, and it does not
/// write anything either - it records five seconds and throws them away.
struct SetupHealthView: View {

    /// Where a row's "Open" button sends the sheet. Owned by `SettingsView`,
    /// which is the only thing that can change the selected tab.
    @Binding var selectedTab: SettingsTab

    @ObservedObject private var service = TranscriptionService.shared
    @ObservedObject private var microphoneService = MicrophoneService.shared
    @ObservedObject var permissions: PermissionsManager

    @StateObject private var test = MicrophoneTestViewModel()
    @StateObject private var inventory = ModelInventoryViewModel()

    /// Re-read when the pane appears and whenever something below changes, so a
    /// user who fixes something in another tab and comes back sees it.
    @State private var checks: [SetupHealthCheck] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                rows
                MicrophoneTestCard(test: test)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .onAppear {
            inventory.refresh()
            permissions.refreshAfterPossibleSystemSettingsChange()
            _ = permissions.checkScreenRecordingPermission()
            refresh()
        }
        .onDisappear { test.cancel() }
        .onChange(of: service.selection) { _, _ in refresh() }
        .onChange(of: service.modelPreparation) { _, _ in refresh() }
        .onChange(of: inventory.entries) { _, _ in refresh() }
        .onChange(of: microphoneService.availableMicrophones) { _, _ in refresh() }
        .onChange(of: permissions.isAccessibilityPermissionGranted) { _, _ in refresh() }
        .onChange(of: permissions.isMicrophonePermissionGranted) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .appPreferencesLanguageChanged)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectedEngineChanged)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = permissions.checkScreenRecordingPermission()
            refresh()
        }
    }

    private var worst: SetupHealthStatus { SetupHealth.worstStatus(in: checks) }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: worst.symbolName)
                .foregroundStyle(color(for: worst))
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(SetupHealth.summary(for: checks))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Everything here is read, not changed. Each line links to the tab that owns it."
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(checks) { check in
                SetupHealthRow(check: check) { destination in
                    selectedTab = destination
                }
            }
        }
    }

    private func color(for status: SetupHealthStatus) -> Color {
        switch status {
        case .blocked: return .red
        case .attention: return .orange
        case .ok: return .green
        }
    }

    /// Gathers the snapshot the report is a function of.
    ///
    /// Every value here is read from the thing that already owns it. The one
    /// judgement call is `cloudHost`, which comes from `CloudEndpoint` and is a
    /// host and nothing else - never a path, never a key (`CloudRedaction`).
    private func refresh() {
        let preferences = AppPreferences.shared
        let resolvedCloud = CloudEndpoint.resolve(preferences.cloudBaseURL)
        let host: String?
        if case .success(let endpoint) = resolvedCloud {
            host = endpoint.host
        } else {
            host = nil
        }

        checks = SetupHealth.checks(
            SetupHealthInputs(
                selection: service.selection,
                preparation: service.modelPreparation,
                preparationFailure: service.preparationFailure,
                inventory: inventory.entries,
                dictationLanguage: preferences.whisperLanguage,
                chineseOutputScript: preferences.chineseOutputScript,
                fluidAudioModelVersion: preferences.fluidAudioModelVersion,
                microphoneCount: microphoneService.availableMicrophones.count,
                currentMicrophoneName: microphoneService.currentMicrophone?.displayName,
                isMicrophoneGranted: permissions.isMicrophonePermissionGranted,
                isAccessibilityGranted: permissions.isAccessibilityPermissionGranted,
                isScreenRecordingGranted: permissions.isScreenRecordingPermissionGranted,
                trigger: DictationTrigger.current(preferences: preferences),
                shortcutConflicts: ShortcutConflicts.conflicts(
                    in: ShortcutConflicts.current(preferences: preferences)),
                cloudIsCompiledIn: CloudBuild.isCompiledIn,
                cloudTranscriptionSelected: preferences.selectedEngine == .cloud,
                cloudTranslationEnabled: preferences.cloudTranslationEnabled,
                cloudHost: host))
    }
}

/// One finding, and the way to act on it.
///
/// Its own view taking a value, so `SetupHealthRenderTests` can draw every
/// status without a Mac that is in that state.
struct SetupHealthRow: View {

    let check: SetupHealthCheck
    let open: (SettingsTab) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbolName)
                .foregroundStyle(tint)
                .font(.system(size: 13))
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.subheadline.weight(.medium))
                Text(check.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = check.note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(check.status == .ok ? .secondary : tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let destination = check.destination {
                Button(destination.title) { open(destination) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Go to the \(destination.title) tab")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.7))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(check.title)
        .accessibilityValue([check.detail, check.note].compactMap { $0 }.joined(separator: " "))
    }

    private var tint: Color {
        switch check.status {
        case .blocked: return .red
        case .attention: return .orange
        case .ok: return .green
        }
    }
}

/// The five-second test.
struct MicrophoneTestCard: View {

    @ObservedObject var test: MicrophoneTestViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Microphone test")
                .font(.headline)
            Text(
                "Records for five seconds and throws the audio away. It uses the same reading your "
                    + "dictations do, so what it says here is what they will do."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                button

                CapsuleHUDWaveform(
                    levels: test.levels,
                    sampleCount: MicrophoneTestViewModel.sampleCount,
                    tint: CapsuleHUDWaveform.tint(for: test.signal)
                )

                Spacer(minLength: 0)
            }

            verdict
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    @ViewBuilder private var button: some View {
        switch test.state {
        case .running(let remaining):
            Button("Stop (\(Int(remaining.rounded(.up))))") { test.stop() }
                .buttonStyle(.bordered)
        case .idle, .finished, .refused, .tooShortToTell:
            Button("Test microphone") { test.start() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var verdict: some View {
        switch test.state {
        case .idle:
            EmptyView()
        case .running:
            Text(MicrophoneTestCard.liveText(for: test.signal))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(let signal):
            Label {
                Text(MicrophoneTestCard.verdictText(for: signal))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: signal.symbolName ?? "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundColor(signal.isDiagnostic ? .orange : .green)
        case .refused(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        // Not a verdict, and deliberately not styled as a problem: the
        // microphone may well be fine, and the app simply did not listen for
        // long enough to have an opinion.
        case .tooShortToTell:
            Label(MicrophoneTestCard.tooShortText, systemImage: "clock")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What is said while it is running: the state, with no advice yet, because
    /// the user is still talking and the verdict can still improve.
    static func liveText(for signal: MicrophoneSignal) -> String {
        signal.shortLabel ?? "Listening. Say a sentence."
    }

    /// What a test stopped inside the grace interval says.
    ///
    /// It reports the absence of a measurement rather than a measurement of
    /// absence. Saying "No signal" here would send somebody who just spoke
    /// clearly off to check an input that is working.
    static let tooShortText =
        "Stopped too soon to tell. Let it run for a couple of seconds while you say something."

    /// What is said afterwards: the state and what to do about it, or the one
    /// sentence that means nothing needs doing.
    static func verdictText(for signal: MicrophoneSignal) -> String {
        guard let label = signal.shortLabel, let advice = signal.advice else {
            return "That sounded fine. This microphone will transcribe well."
        }
        return "\(label). \(advice)"
    }
}
