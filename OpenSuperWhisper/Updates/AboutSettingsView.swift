import AppKit
import SwiftUI

/// What the About pane is doing, as one value.
///
/// A single enum rather than a handful of booleans because the states are
/// mutually exclusive and the pane has to be able to say exactly one thing:
/// several independent flags is how "checking" and "up to date" end up on
/// screen together.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(PublishedRelease)
    case downloading(PublishedRelease, fraction: Double)
    case readyToInstall(PublishedRelease, stagedApp: URL)
    case failed(String)
}

/// The About pane's state machine.
///
/// Nothing here happens on its own. There is no timer, no launch-time check and
/// no automatic install: every transition below starts with the user pressing
/// something, and the download and the replacement are two separate presses with
/// the release notes in between. That is the "user-confirmed" part of the
/// requirement, and it is a property of this type rather than of the view.
@MainActor
final class UpdateViewModel: ObservableObject {
    // A staged bundle must not outlive the decision to install it: whenever a
    // `.readyToInstall` state is left behind - "Not Now", a failed install, or
    // starting another check or download - the staged copy it was offering is
    // discarded here. Quitting before installing is instead handled by
    // `UpdateInstaller.removeStaleStagingDirectories()`, since nothing in this
    // view model runs once the app has already quit.
    @Published private(set) var state: UpdateState = .idle {
        didSet {
            if case .readyToInstall(_, let stagedApp) = oldValue {
                discardStagedBundle(stagedApp)
            }
        }
    }

    let identity: AppBuildIdentity

    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let fileManager: FileManager

    init(identity: AppBuildIdentity = .current(),
         checker: UpdateChecker? = nil,
         installer: UpdateInstaller? = nil,
         fileManager: FileManager = .default) {
        self.identity = identity
        self.checker = checker ?? UpdateChecker(current: identity)
        self.installer = installer ?? UpdateInstaller()
        self.fileManager = fileManager
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        case .idle, .upToDate, .available, .readyToInstall, .failed: return false
        }
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                switch try await checker.check() {
                case .upToDate:
                    state = .upToDate
                case .available(let release):
                    state = .available(release)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads and verifies, and stops there. The bundle is staged but nothing
    /// has been replaced, so a user who changes their mind at this point simply
    /// does not press the second button.
    ///
    /// `session` defaults to `.shared`, matching `UpdateInstaller`'s own
    /// default; overriding it is a test seam, not something production code has
    /// a reason to do.
    func download(_ release: PublishedRelease, session: URLSession = .shared) {
        guard !isBusy else { return }
        state = .downloading(release, fraction: 0)
        Task {
            do {
                let staged = try await installer.downloadAndVerify(release, session: session) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(release, fraction: fraction)
                    }
                }
                state = .readyToInstall(release, stagedApp: staged)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// The second press. Replaces the app and quits so the swap can happen; the
    /// detached script reopens it.
    func installAndRelaunch(stagedApp: URL) {
        do {
            try installer.installAndRelaunch(stagedApp: stagedApp)
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismissMessage() {
        state = .idle
    }

    private func discardStagedBundle(_ stagedApp: URL) {
        try? fileManager.removeItem(at: stagedApp.deletingLastPathComponent())
    }
}

/// Which build this is, and the only place in the app that offers to change it.
struct AboutSettingsView: View {
    @StateObject private var viewModel = UpdateViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                identityCard
                updateCard
            }
            .padding()
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About EchoForge")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 10) {
                labelledRow("Version", viewModel.identity.marketingVersion)
                labelledRow("Build", viewModel.identity.buildNumber)
                labelledRow("Identifier", viewModel.identity.bundleIdentifier)
            }

            // Stated here rather than only in the docs: it is the reason the
            // first launch needs a Gatekeeper detour, and the reason an update
            // can be checked for authenticity but not for authorship.
            Text("These builds are signed ad-hoc and are not notarized by Apple.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func labelledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Updates")
                    .font(.headline)
                Spacer()
                Button("Check for Updates") { viewModel.checkForUpdates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isBusy)
            }

            switch viewModel.state {
            case .idle:
                Text("EchoForge never checks or installs updates on its own. Checking, downloading and "
                    + "installing are three things you ask for.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            case .upToDate:
                statusLine(icon: "checkmark.circle.fill", color: .green,
                           text: "You are on the latest published release.")

            case .available(let release):
                releaseDetails(release)
                HStack {
                    Button("Download \(release.version.description)") { viewModel.download(release) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Release Page") { openURL(release.releasePageURL) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .downloading(let release, let fraction):
                Text("Downloading \(release.version.description) — \(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: fraction)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 6)

            case .readyToInstall(let release, let stagedApp):
                statusLine(
                    icon: "checkmark.seal",
                    color: .green,
                    text: "\(release.version.description) downloaded and verified: it identifies itself as "
                        + "EchoForge, reports the version that was offered, and passes signature verification."
                )
                Text("Installing quits EchoForge, replaces it, and opens it again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install and Relaunch") { viewModel.installAndRelaunch(stagedApp: stagedApp) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Not Now") { viewModel.dismissMessage() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .failed(let message):
                statusLine(icon: "exclamationmark.triangle.fill", color: .orange, text: message)
                Button("Dismiss") { viewModel.dismissMessage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func statusLine(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The notes are shown before the download button, not after: deciding
    /// whether to take an update is what they are for.
    private func releaseDetails(_ release: PublishedRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EchoForge \(release.version.description) is available.")
                .font(.subheadline.weight(.medium))

            Text(ByteCountFormatter.string(fromByteCount: Int64(release.sizeInBytes), countStyle: .file))
                .font(.caption)
                .foregroundColor(.secondary)

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(Color(.textBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }
        }
    }
}
