import Foundation

/// Which of the three committed menu-bar images is showing, and how big they are
/// drawn.
///
/// Three silhouettes and no animation. A menu-bar icon that moves is a menu-bar
/// icon that is noticed all day, and the app has nothing to say continuously -
/// what it has is three facts a glance should answer: it is listening, it is
/// switched off, or it is fine. `Scripts/GenerateTrayIcon.swift` is the artwork
/// and `TrayIconArtworkTests` reads the committed files.
enum MenuBarIcon: String, Equatable {
    case idle
    case recording
    case paused

    static let idleAssetName = "tray_icon"
    static let recordingAssetName = "tray_icon_recording"
    static let pausedAssetName = "tray_icon_paused"

    /// What `NSStatusItem` draws at. The asset's own media box is this, so the
    /// image needs no resizing - the previous code set a 48 pt size on an 18 pt
    /// slot.
    static let pointSize: CGFloat = 18

    var assetName: String {
        switch self {
        case .idle: return Self.idleAssetName
        case .recording: return Self.recordingAssetName
        case .paused: return Self.pausedAssetName
        }
    }

    /// The fallback when an asset is missing from the bundle, and the
    /// accessibility description either way. SF Symbols, so a broken build still
    /// has something in the menu bar rather than an invisible status item.
    var systemSymbolFallback: String {
        switch self {
        case .idle: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .paused: return "waveform.slash"
        }
    }
}

/// What the app is doing, as one value.
///
/// The menu used to be built straight out of four services, which meant the only
/// way to find out what it says in any given state was to put a Mac into that
/// state. This is the decision on its own: a pure function of a snapshot, so the
/// state matrix is asserted without a microphone, a model or a TCC grant.
enum MenuBarState: Equatable {
    /// Capturing right now.
    case recording

    /// The audio has stopped and text is being made - a dictation decoding, or
    /// the file queue working.
    case processing

    /// Something the app needs and does not have. Microphone or Accessibility;
    /// the two conditional grants are never this, the same rule
    /// `PermissionsManager.isMissingRequiredPermission` keeps.
    case permissionNeeded

    /// Nothing on this Mac can transcribe.
    case noEngine

    /// The user switched the global keys off from this menu.
    case shortcutsPaused

    /// A model is being fetched or compiled in the background. Dictation still
    /// works meanwhile, which is why this ranks below everything above it.
    case preparingModel(ModelPreparation)

    case ready

    /// The icon this state shows.
    ///
    /// Only three, and the two that are not "fine" are the two the user can act
    /// on: it is listening, or it is not going to answer a key press. A model
    /// downloading in the background is not either of those - dictation carries
    /// on - so it keeps the ordinary icon and says so in the menu.
    var icon: MenuBarIcon {
        switch self {
        case .recording: return .recording
        case .shortcutsPaused, .permissionNeeded, .noEngine: return .paused
        case .processing, .preparingModel, .ready: return .idle
        }
    }

    /// The first line of the menu, which is a status rather than an action.
    var title: String {
        switch self {
        case .recording: return "Recording"
        case .processing: return "Transcribing…"
        case .permissionNeeded: return "Permission needed"
        case .noEngine: return EngineConfiguration.unavailableShortMessage
        case .shortcutsPaused: return "Shortcuts paused"
        case .preparingModel(let preparation): return preparation.statusLine
        case .ready: return "Ready"
        }
    }

    /// Whether the user has something to fix. Drives nothing but the wording;
    /// the icon is decided above.
    var isProblem: Bool {
        switch self {
        case .permissionNeeded, .noEngine: return true
        case .recording, .processing, .shortcutsPaused, .preparingModel, .ready: return false
        }
    }

    /// The order is the product decision, stated once.
    ///
    /// What is happening **now** wins over what is wrong, because a user who is
    /// mid-dictation can see for themselves that their permissions are fine. A
    /// missing permission wins over a pause, because the pause is reversible from
    /// this menu and the permission is not. And a model preparing in the
    /// background is last of all, since it is the only state in this list that
    /// does not stop or change anything.
    static func resolve(
        isRecording: Bool,
        isProcessing: Bool,
        isMissingRequiredPermission: Bool,
        canTranscribe: Bool,
        shortcutsPaused: Bool,
        preparation: ModelPreparation?
    ) -> MenuBarState {
        if isRecording { return .recording }
        if isProcessing { return .processing }
        if isMissingRequiredPermission { return .permissionNeeded }
        if !canTranscribe { return .noEngine }
        if shortcutsPaused { return .shortcutsPaused }
        if let preparation { return .preparingModel(preparation) }
        return .ready
    }
}

/// One line of the recent-transcripts section.
///
/// A value rather than a `Recording`, because what the menu shows is not the row:
/// it is one line of it, collapsed and cut. `Copy` puts the **whole** transcript
/// on the pasteboard, which is why the full text travels alongside the preview.
struct MenuBarTranscript: Equatable, Identifiable {
    let id: UUID
    /// The single line shown in the menu.
    let preview: String
    /// What Copy puts on the pasteboard.
    let full: String

    /// How many are offered. Three, because the menu is a glance and a list of
    /// recent text is a job History already does properly.
    static let count = 3

    /// How long a preview may be. A menu item wider than this pushes the whole
    /// menu out to the width of somebody's longest paragraph.
    static let maximumPreviewCharacters = 46

    /// Whether a stored row is one of these.
    ///
    /// Two rules. It has to have **finished with words**: a failed or pending row
    /// has nothing to copy, and offering it would be offering an empty string.
    /// And it has to be a row whose transcript is *text the user wanted* - a
    /// YouTube command's transcript is a channel name that was spoken to open a
    /// video, and an Ask capture's is a question whose answer is not in this
    /// column at all. Both would be nonsense on a Copy item.
    static func isOffered(status: RecordingStatus, provenance: RecordingProvenance, transcription: String)
        -> Bool {
        guard status == .completed else { return false }
        guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch provenance.kind {
        case .dictation, .fileTranscription, .selectionEdit, .unknown:
            return true
        case .ask, .youTubeCommandOpened, .youTubeCommandNotOpened:
            return false
        }
    }

    /// One line, cut to length.
    ///
    /// Newlines and runs of whitespace collapse to single spaces: a menu item
    /// draws a newline as a box, and a dictation with a paragraph break in it
    /// would otherwise put one in the menu bar.
    static func preview(of transcription: String) -> String {
        let collapsed = transcription
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumPreviewCharacters else { return collapsed }
        return String(collapsed.prefix(maximumPreviewCharacters - 1)) + "…"
    }

    /// The rows a store page turns into menu items, newest first and capped.
    static func offered(from recordings: [Recording]) -> [MenuBarTranscript] {
        recordings
            .filter {
                isOffered(
                    status: $0.status, provenance: $0.provenance, transcription: $0.transcription)
            }
            .prefix(count)
            .map {
                MenuBarTranscript(
                    id: $0.id, preview: preview(of: $0.transcription), full: $0.transcription)
            }
    }
}

/// Everything the menu draws, as one value.
struct MenuBarSnapshot: Equatable {
    let state: MenuBarState

    /// The engine the user chose and the one dictation is running on. Shown
    /// separately only while they differ - the whole reason `EngineSelection`
    /// keeps them apart.
    let desiredEngine: EngineKind
    let activeEngine: EngineKind?

    /// The engines a pick from this menu may safely land on, from
    /// `EngineCycle.available`. Empty while nothing can transcribe.
    let selectableEngines: [EngineKind]

    /// False while a dictation is in flight, when changing the engine would
    /// change the model decoding words that have already been spoken.
    let canChangeEngine: Bool

    let trigger: DictationTrigger
    let shortcutsPaused: Bool
    let preparationFailure: String?
    let recentTranscripts: [MenuBarTranscript]

    /// The line under the engine name while a stand-in is running, or `nil`.
    ///
    /// Read from `EngineSelection` rather than reconstructed, so the menu and the
    /// Setup Health pane cannot end up describing the same gap two ways.
    var fallbackNotice: String? {
        guard let activeEngine, activeEngine != desiredEngine else { return nil }
        return "Using \(EngineCatalog.entry(for: activeEngine).displayName) until "
            + "\(EngineCatalog.entry(for: desiredEngine).displayName) is ready"
    }

    /// What the Start item says. It ends a dictation that is running, because one
    /// item that starts and stops is the same thing the dictation key is.
    var dictationActionTitle: String {
        state == .recording ? "Stop Dictation" : "Start Dictation"
    }

    /// What the pause item says. **Shortcuts**, never the microphone: this app
    /// does not own the system's input and must not be read as switching it off.
    var pauseActionTitle: String {
        shortcutsPaused ? "Resume Kongweh Shortcuts" : "Pause Kongweh Shortcuts"
    }

    /// The sentence under the pause item while it is on, so nobody has to guess
    /// what a paused app still does.
    static let pausedExplanation =
        "Kongweh's keys are switched off. Your microphone is untouched and nothing else changed."
}
