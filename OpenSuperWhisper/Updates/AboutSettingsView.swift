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
    /// The request has been made and nothing has come back yet. Its own state
    /// because the alternative is what shipped: rendering it as "0%", which is
    /// also what the first 1.1 MB of a 212 MB download renders as, so a user
    /// could not tell an unanswered request from a slow one. Carries the
    /// progress it will resume from, which is not always zero.
    case connecting(PublishedRelease, DownloadProgress)
    case downloading(PublishedRelease, DownloadProgress)
    /// The bytes are down and the disk image is being mounted, checked and
    /// copied. Its own state because it is the one stretch with no fraction to
    /// report: a bar left sitting at 100% is indistinguishable from the stalled
    /// download the watchdog now catches, and this says which one it is.
    case verifying(PublishedRelease)
    case readyToInstall(PublishedRelease, stagedApp: URL)
    /// The swap script has been launched and the app is on its way out. A state
    /// of its own because it is the one moment the staged bundle must *not* be
    /// discarded: it belongs to the detached script from here on.
    case installing(PublishedRelease, stagedApp: URL)
    /// `retryable` is the release the failure was about, when there is one to
    /// offer again. A failed *check* has none - "Check for Updates" is already
    /// on screen - but a failed download does, and having to reopen the pane to
    /// get back to it is how a transient network fault reads as a dead end.
    case failed(String, retryable: PublishedRelease?)

    /// Whether something is in flight that a second press must not start over.
    /// On the state rather than the view model because the card is drawn from
    /// the state alone (`UpdateCardView`), and its buttons have to agree with
    /// the view model about what "busy" means.
    var isBusy: Bool {
        switch self {
        case .checking, .connecting, .downloading, .verifying, .installing: return true
        case .idle, .upToDate, .available, .readyToInstall, .failed: return false
        }
    }
}

/// How the app is asked to go away so the swap script can replace its bundle.
///
/// A seam for two reasons: a test must not terminate the test runner, and the
/// ordinary `NSApplication.terminate` is not on its own enough (see
/// `RunningApplicationTerminator`).
@MainActor
protocol AppTerminating {
    func terminate()
}

struct RunningApplicationTerminator: AppTerminating {
    /// How long the ordinary termination sequence is given before the backstop
    /// below forces the exit. Long enough that a normal quit always wins it.
    static let gracePeriod: TimeInterval = 3

    func terminate() {
        NSApplication.shared.terminate(nil)

        // `terminate(nil)` is a *request*, not an exit: it runs the termination
        // sequence on a later runloop pass, and any window delegate, sheet or
        // unsaved-changes prompt can delay or refuse it. By this point the
        // detached swap script is already spinning on `kill -0` waiting for this
        // pid, so a delayed termination is not a slower install - it is a
        // stalled one that leaves the user looking at an app that said it was
        // quitting. This is the backstop.
        //
        // Scheduled on a global queue rather than the main one because a modal
        // run loop - exactly the thing that delays termination - would not
        // service a main-queue timer.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.gracePeriod) {
            exit(0)
        }
    }
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
    //
    // `.installing` is the one exception, and leaving it out is what broke
    // "Install and Relaunch": the detached swap script waits for this process to
    // exit before it renames the staged bundle into place, so anything that
    // deleted the bundle on the way to quitting deleted it out from under a
    // script that had not run yet. The script then failed its `mv`, its rollback
    // trap restored the old bundle, and the app reopened on the old version.
    // From `.readyToInstall` to `.installing` the bundle belongs to the script.
    @Published private(set) var state: UpdateState = .idle {
        didSet {
            switch (oldValue, state) {
            case (.readyToInstall(_, let stagedApp), .installing(_, let handedOver))
                where stagedApp == handedOver:
                break
            case (.readyToInstall(_, let stagedApp), _),
                 (.installing(_, let stagedApp), _):
                // Leaving `.installing` at all means the script was never
                // launched - `installAndRelaunch` threw - so the staged bundle
                // is this view model's to clean up again.
                discardStagedBundle(stagedApp)
            default:
                break
            }
        }
    }

    let identity: AppBuildIdentity

    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let fileManager: FileManager
    private let terminator: AppTerminating
    /// The in-flight download, kept only so the user can call it off. Cancelling
    /// it cancels the `URLSession` task with it.
    private var downloadTask: Task<Void, Never>?

    init(identity: AppBuildIdentity = .current(),
         checker: UpdateChecker? = nil,
         installer: UpdateInstaller? = nil,
         fileManager: FileManager = .default,
         terminator: AppTerminating? = nil) {
        self.identity = identity
        self.checker = checker ?? UpdateChecker(current: identity)
        self.installer = installer ?? UpdateInstaller()
        self.fileManager = fileManager
        self.terminator = terminator ?? RunningApplicationTerminator()
    }

    var isBusy: Bool { state.isBusy }

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
                state = .failed(error.localizedDescription, retryable: nil)
            }
        }
    }

    /// Downloads and verifies, and stops there. The bundle is staged but nothing
    /// has been replaced, so a user who changes their mind at this point simply
    /// does not press the second button.
    ///
    /// A failure here always names the release it was about, so the pane can
    /// offer it again: the commonest reason to land in `.failed` is a network
    /// that went quiet, and the answer to that is one press, not a reopened pane
    /// and another check.
    ///
    /// `settings` carries the session and the stall interval and defaults to the
    /// shipped ones; overriding it is a test seam, not something production code
    /// has a reason to do.
    func download(_ release: PublishedRelease, settings: UpdateDownloadSettings = UpdateDownloadSettings()) {
        guard !isBusy else { return }
        state = .connecting(release, DownloadProgress(receivedBytes: 0, totalBytes: Int64(release.sizeInBytes)))
        downloadTask = Task { [weak self] in
            do {
                guard let installer = self?.installer else { return }
                let staged = try await installer.downloadAndVerify(release, settings: settings) { progress in
                    Task { @MainActor [weak self] in
                        self?.report(progress, for: release)
                    }
                }
                guard let self else { return }
                // Cancelled while the last of the verification ran: the bundle
                // was staged for a decision nobody is waiting on any more, so it
                // is discarded here rather than left beside the app.
                guard !Task.isCancelled else { return self.discardStagedBundle(staged) }
                self.state = .readyToInstall(release, stagedApp: staged)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription, retryable: release)
            }
        }
    }

    /// Calls off an in-flight download and puts the offer back.
    ///
    /// Only a download is cancellable. Once the bytes are down, verification is
    /// a short run of `hdiutil`, `codesign` and `ditto` that has to reach its own
    /// `defer` to unmount the image, so it is left to finish rather than torn
    /// down half way.
    ///
    /// What is *not* thrown away is the partial file: cancelling and starting
    /// again is now a resume, so a user who stops a download to get on with
    /// something else does not pay for it twice.
    func cancelDownload() {
        let release: PublishedRelease
        switch state {
        case .connecting(let cancelled, _), .downloading(let cancelled, _): release = cancelled
        default: return
        }
        downloadTask?.cancel()
        downloadTask = nil
        state = .available(release)
    }

    /// Moves the pane along with a download that is still the one it is showing.
    /// A report from a cancelled or superseded download arrives on the main
    /// actor after the state has already moved on, and must not pull it back.
    ///
    /// The accepted transitions are written out rather than defaulted, because
    /// the one that matters is the one that must *not* happen: a late report
    /// from a finished download re-entering `.downloading` from `.verifying`
    /// would put a moving bar back over work that has no fraction.
    private func report(_ progress: UpdateProgress, for release: PublishedRelease) {
        switch (state, progress) {
        case (.connecting, .connecting(let downloadProgress)):
            state = .connecting(release, downloadProgress)
        case (.connecting, .downloading(let downloadProgress)),
             (.downloading, .downloading(let downloadProgress)):
            state = .downloading(release, downloadProgress)
        case (.connecting, .verifying), (.downloading, .verifying):
            state = .verifying(release)
        default:
            break
        }
    }

    /// The second press. Replaces the app and quits so the swap can happen; the
    /// detached script reopens it.
    ///
    /// The state moves to `.installing` *before* the script is launched, not
    /// after: from that moment the staged bundle is the script's, and the
    /// transition is what tells `didSet` above to stop treating it as a leak to
    /// sweep up on the way out.
    func installAndRelaunch(_ release: PublishedRelease, stagedApp: URL) {
        guard case .readyToInstall = state else { return }
        state = .installing(release, stagedApp: stagedApp)
        do {
            try installer.installAndRelaunch(stagedApp: stagedApp)
        } catch {
            state = .failed(error.localizedDescription, retryable: release)
            return
        }
        terminator.terminate()
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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                identityCard
                UpdateCardView(
                    state: viewModel.state,
                    checkForUpdates: { viewModel.checkForUpdates() },
                    download: { viewModel.download($0) },
                    cancelDownload: { viewModel.cancelDownload() },
                    installAndRelaunch: { viewModel.installAndRelaunch($0, stagedApp: $1) },
                    dismiss: { viewModel.dismissMessage() }
                )
            }
            .padding()
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About Kongweh")
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

}

/// The Updates card, drawn from an explicit `UpdateState`.
///
/// Separate from `AboutSettingsView` because the card is a pure function of
/// that state, and most of its states only exist while bytes are moving: a
/// test cannot hold a real download at "resuming from 115 MB" long enough to
/// look at it, but it can construct the state and render this view directly
/// (`UpdateCardRenderTests`). The buttons remain the pane's: every action is a
/// closure the pane points at its view model.
struct UpdateCardView: View {
    let state: UpdateState
    let checkForUpdates: () -> Void
    let download: (PublishedRelease) -> Void
    let cancelDownload: () -> Void
    let installAndRelaunch: (PublishedRelease, URL) -> Void
    let dismiss: () -> Void

    @Environment(\.openURL) private var openURL

    /// The line that says what the pane is doing, one per state, exactly as
    /// the body shows it. Composed here rather than inline in the body so a
    /// test can hold the words against what each state must say without
    /// keeping a second copy of them; the transfer wording itself belongs to
    /// `DownloadProgressText`.
    static func statusText(for state: UpdateState) -> String {
        switch state {
        case .idle:
            return "Kongweh never checks or installs updates on its own. Checking, downloading and "
                + "installing are three things you ask for."
        case .checking:
            return "Checking…"
        case .upToDate:
            return "You are on the latest published release."
        case .available(let release):
            return "Kongweh \(release.version.description) is available."
        case .connecting(let release, let progress):
            return progress.receivedBytes > 0
                ? "Connecting… resuming \(release.version.description) from "
                    + "\(DownloadProgressText.bytes(progress))"
                : "Connecting…"
        case .downloading(let release, let progress):
            // The bytes lead and the percentage follows. A percentage on its
            // own is what let a live download and a dead one render
            // identically; a number that visibly climbs cannot.
            return "Downloading \(release.version.description) - \(DownloadProgressText.summary(progress))"
        case .verifying(let release):
            return "Verifying \(release.version.description)…"
        case .readyToInstall(let release, _):
            return "\(release.version.description) downloaded and verified: it identifies itself as "
                + "Kongweh, reports the version that was offered, and passes signature verification."
        case .installing(let release, _):
            return "Installing \(release.version.description). Kongweh will quit and open again."
        case .failed(let message, _):
            return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Updates")
                    .font(.headline)
                Spacer()
                Button("Check for Updates") { checkForUpdates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isBusy)
            }

            switch state {
            case .idle:
                Text(Self.statusText(for: state))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.statusText(for: state))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            case .upToDate:
                statusLine(icon: "checkmark.circle.fill", color: .green,
                           text: Self.statusText(for: state))

            case .available(let release):
                releaseDetails(release)
                HStack {
                    Button("Download \(release.version.description)") { download(release) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Release Page") { openURL(release.releasePageURL) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.statusText(for: state))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Cancel") { cancelDownload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

            case .downloading(_, let progress):
                Text(Self.statusText(for: state))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 6)
                Button("Cancel") { cancelDownload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.statusText(for: state))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            case .readyToInstall(let release, let stagedApp):
                statusLine(icon: "checkmark.seal", color: .green,
                           text: Self.statusText(for: state))
                Text("Installing quits Kongweh, replaces it, and opens it again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install and Relaunch") { installAndRelaunch(release, stagedApp) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Not Now") { dismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.statusText(for: state))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .failed(_, let retryable):
                statusLine(icon: "exclamationmark.triangle.fill", color: .orange,
                           text: Self.statusText(for: state))
                HStack {
                    if let retryable {
                        Button("Retry") { download(retryable) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
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
            Text("Kongweh \(release.version.description) is available.")
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
