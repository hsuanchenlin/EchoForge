import Foundation

/// The one question Settings could not answer: **is Kongweh ready?**
///
/// Eight panes expose this app's capability by subsystem, which is the right
/// shape for changing a setting and the wrong shape for finding out whether the
/// settings you already have add up to a working dictation. A user had to
/// understand engines, models, languages, permissions, shortcuts and the cloud
/// boundary before they could tell whether the next press of a key was going to
/// produce text.
///
/// This is that answer, and its whole discipline is in what it is not:
///
/// - **It reads.** Nothing on this path writes a preference, downloads a model,
///   selects an engine or grants a permission. Where a Settings pane owns a
///   fix, the row links there and a person makes the change.
/// - **It duplicates no facts.** Engine names and caveats come from
///   `EngineCatalog`, readiness and disk from `ModelInventory`, the active
///   engine from `EngineSelection`, the trigger from `DictationTrigger`, the
///   cloud position from `CloudAccess`. A second copy of any of them would be a
///   second thing to keep true.
/// - **It is a pure function of a snapshot**, so every combination of readiness
///   can be asserted without a microphone, a model or a TCC grant.
enum SetupHealthStatus: Equatable, Comparable {
    /// Dictation cannot happen until this is fixed.
    case blocked
    /// Dictation works, but this is worth knowing.
    case attention
    /// Nothing to do.
    case ok

    /// Worst first for summaries; rows themselves remain in stable topic order.
    static func < (lhs: SetupHealthStatus, rhs: SetupHealthStatus) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ status: SetupHealthStatus) -> Int {
        switch status {
        case .blocked: return 0
        case .attention: return 1
        case .ok: return 2
        }
    }

    var symbolName: String {
        switch self {
        case .blocked: return "exclamationmark.octagon.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle.fill"
        }
    }
}

/// What one row is about. Stable identifiers, so a test can name a row without
/// matching its prose.
enum SetupHealthTopic: String, CaseIterable, Identifiable {
    case engine
    case model
    case language
    case microphone
    case permissions
    case shortcut
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engine: return "Transcription engine"
        case .model: return "Model"
        case .language: return "Language"
        case .microphone: return "Microphone"
        case .permissions: return "Permissions"
        case .shortcut: return "Dictation shortcut"
        case .privacy: return "Where your speech goes"
        }
    }
}

/// One finding.
struct SetupHealthCheck: Equatable, Identifiable {
    let topic: SetupHealthTopic
    let status: SetupHealthStatus

    /// The finding, in a sentence. Never an instruction on its own - the pane
    /// link is the instruction.
    let detail: String

    /// A second line, when there is one more thing worth saying. `nil` far more
    /// often than not: a healthy install should read as seven short lines.
    let note: String?

    /// The pane that fixes it, or `nil` when there is nothing to fix.
    let destination: SettingsTab?

    var id: String { topic.rawValue }
    var title: String { topic.title }
}

/// Everything the report is built from, as one value.
///
/// A struct rather than seven parameters so a test can describe a Mac by
/// changing one field of a healthy one - which is how the interesting cases are
/// written, since almost all of them are "everything is fine except…".
struct SetupHealthInputs {
    var selection: EngineSelection
    var preparation: ModelPreparation?
    var preparationFailure: String?

    /// The engine's weights, from `ModelInventory`. Only the active and desired
    /// engines are read from it, but the whole list is carried so the disk total
    /// is the same number the Model pane shows.
    var inventory: [ModelInventoryEntry]

    var dictationLanguage: String
    var chineseOutputScript: ChineseScriptVariant
    var fluidAudioModelVersion: String

    var microphoneCount: Int
    var currentMicrophoneName: String?

    var isMicrophoneGranted: Bool
    var isAccessibilityGranted: Bool
    var isScreenRecordingGranted: Bool

    var trigger: DictationTrigger
    var shortcutConflicts: [ShortcutConflict]

    /// Whether this build has a cloud path at all
    /// (`Scripts/build_release.sh --offline-only` produces one that does not).
    var cloudIsCompiledIn: Bool
    /// Whether the cloud engine is the selected one.
    var cloudTranscriptionSelected: Bool
    /// Whether cloud translation is switched on.
    var cloudTranslationEnabled: Bool
    /// The provider's host, for the sentence that names where audio would go.
    /// Never a key, never a path - `CloudRedaction` owns that rule.
    var cloudHost: String?
}

/// The report.
enum SetupHealth {

    /// The headline above the rows: one sentence about the whole install.
    static func summary(for checks: [SetupHealthCheck]) -> String {
        if checks.contains(where: { $0.status == .blocked }) {
            return "Kongweh cannot dictate yet."
        }
        if checks.contains(where: { $0.status == .attention }) {
            return "Kongweh is ready, with a few things worth knowing."
        }
        return "Kongweh is ready."
    }

    static func worstStatus(in checks: [SetupHealthCheck]) -> SetupHealthStatus {
        checks.map(\.status).min() ?? .ok
    }

    /// Every check, in topic order.
    ///
    /// Deliberately **not** sorted worst-first. The topics are a fixed list a
    /// user learns the shape of, and a pane whose rows reorder themselves as the
    /// state changes is one nobody can scan. The summary above carries the
    /// urgency instead.
    static func checks(_ inputs: SetupHealthInputs) -> [SetupHealthCheck] {
        [
            engine(inputs), model(inputs), language(inputs), microphone(inputs),
            permissions(inputs), shortcut(inputs), privacy(inputs),
        ]
    }

    // MARK: - The engine the user chose, and the one that is running

    private static func engine(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        let desired = EngineCatalog.entry(for: inputs.selection.desired).displayName

        guard let active = inputs.selection.active else {
            return SetupHealthCheck(
                topic: .engine, status: .blocked,
                detail: "Nothing on this Mac can transcribe. \(desired) is chosen and cannot load.",
                note: EngineConfiguration.unavailableMessage,
                destination: .model)
        }

        guard inputs.selection.isDesiredEnginePending else {
            return SetupHealthCheck(
                topic: .engine, status: .ok,
                detail: "\(desired) is chosen and running.",
                note: nil, destination: .model)
        }

        // The gap this whole area exists to make a state rather than a failure:
        // the user's choice is being prepared and something else is standing in.
        let activeName = EngineCatalog.entry(for: active).displayName
        let reason: String
        switch inputs.selection.interimReason {
        case .previousModel:
            reason = "\(activeName) is standing in - it is what you were dictating with before."
        case .starterModel:
            reason = "\(activeName) is standing in - it is the model that came with the app."
        case nil:
            reason = "\(activeName) is standing in."
        }

        var note: String?
        if !inputs.selection.activeTranscribesEnglishAndChineseTogether,
            inputs.selection.desired.transcribesEnglishAndChineseTogether {
            note = "Until \(desired) is ready, English mixed into Mandarin will not transcribe - "
                + "the recording is kept so you can regenerate it."
        }

        return SetupHealthCheck(
            topic: .engine, status: .attention,
            detail: "\(desired) is chosen and still being prepared. \(reason)",
            note: note, destination: .model)
    }

    // MARK: - Its weights

    private static func model(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        let total = ModelInventory.totalBytes(inputs.inventory)
        let disk = total > 0 ? " Models are using \(DirectorySize.describe(total))." : ""

        if let preparation = inputs.preparation {
            return SetupHealthCheck(
                topic: .model, status: .attention,
                detail: preparation.statusLine + ".",
                note: "Dictation carries on meanwhile.\(disk)", destination: .model)
        }

        if let failure = inputs.preparationFailure, inputs.selection.isDesiredEnginePending {
            return SetupHealthCheck(
                topic: .model, status: .attention,
                detail: "Preparing \(EngineCatalog.entry(for: inputs.selection.desired).displayName) "
                    + "did not finish: \(failure)",
                note: "Retry it in the Model tab.\(disk)", destination: .model)
        }

        let desiredEntry = inputs.inventory.first { $0.engine == inputs.selection.desired }
        if let desiredEntry, desiredEntry.readiness == .incomplete {
            return SetupHealthCheck(
                topic: .model, status: .attention,
                detail: "\(desiredEntry.displayName) has files on the disk that will not load.",
                note: "Remove them and download again in the Model tab.\(disk)",
                destination: .model)
        }

        guard let active = inputs.selection.active else {
            return SetupHealthCheck(
                topic: .model, status: .blocked,
                detail: "No model is downloaded.",
                note: "Download one in the Model tab.\(disk)", destination: .model)
        }

        let name = EngineCatalog.entry(for: active).displayName
        return SetupHealthCheck(
            topic: .model, status: .ok,
            detail: active.usesCloudProvider
                ? "\(name) needs no model on this Mac."
                : "\(name)'s model is ready.",
            note: disk.isEmpty ? nil : String(disk.dropFirst()), destination: .model)
    }

    // MARK: - What it is listening for

    private static func language(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        let name = LanguageUtil.languageNames[inputs.dictationLanguage] ?? inputs.dictationLanguage
        var detail = "Dictating in \(name)."

        // Only where it changes anything: Chinese, and auto-detect, which may
        // turn out to be Chinese. The same predicate the Transcription pane
        // shows the control with, and the same one the normalizer applies.
        if ChineseScriptVariant.mayBeChinese(languageCode: inputs.dictationLanguage) {
            let script = inputs.chineseOutputScript == .traditional
                ? ChineseOutputScriptSetting.traditionalLabel
                : ChineseOutputScriptSetting.simplifiedLabel
            detail += " Chinese is written in \(script)."
        }

        let supported = LanguageUtil.supportedLanguages(
            engine: inputs.selection.desired, fluidAudioModelVersion: inputs.fluidAudioModelVersion)
        guard supported.contains(inputs.dictationLanguage) else {
            return SetupHealthCheck(
                topic: .language, status: .attention,
                detail: detail,
                note: "\(EngineCatalog.entry(for: inputs.selection.desired).displayName) does not "
                    + "transcribe \(name).",
                destination: .transcription)
        }

        return SetupHealthCheck(
            topic: .language, status: .ok, detail: detail, note: nil, destination: .transcription)
    }

    // MARK: - The microphone

    private static func microphone(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        guard inputs.isMicrophoneGranted else {
            return SetupHealthCheck(
                topic: .microphone, status: .blocked,
                detail: "Kongweh is not allowed to use the microphone.",
                note: "Grant it in System Settings → Privacy & Security → Microphone.",
                destination: nil)
        }
        guard inputs.microphoneCount > 0 else {
            return SetupHealthCheck(
                topic: .microphone, status: .blocked,
                detail: "No microphone is available.",
                note: "Connect one, or check it is not disabled in System Settings → Sound.",
                destination: nil)
        }
        let name = inputs.currentMicrophoneName ?? "the system default input"
        return SetupHealthCheck(
            topic: .microphone, status: .ok,
            detail: "Recording from \(name).",
            note: inputs.microphoneCount > 1
                ? "\(inputs.microphoneCount) inputs available. Test it below, or change it from the "
                    + "menu bar."
                : "Test it below.",
            destination: nil)
    }

    // MARK: - Permissions

    /// Two are required and two are conditional, and the difference is stated
    /// rather than implied: Input Monitoring and Screen Recording must never
    /// gate the app (`PermissionsManager.isMissingRequiredPermission`), so a
    /// missing one is a fact about a feature and not a fault.
    private static func permissions(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        guard inputs.isAccessibilityGranted else {
            return SetupHealthCheck(
                topic: .permissions, status: .blocked,
                detail: "Accessibility is not granted, so Kongweh cannot paste what you say.",
                note: "Grant it in System Settings → Privacy & Security → Accessibility.",
                destination: nil)
        }
        guard inputs.isScreenRecordingGranted else {
            return SetupHealthCheck(
                topic: .permissions, status: .ok,
                detail: "Accessibility is granted.",
                note: "Screen Recording is not, which only affects asking about the screen. It is "
                    + "requested the first time you use that shortcut.",
                destination: .shortcuts)
        }
        return SetupHealthCheck(
            topic: .permissions, status: .ok,
            detail: "Accessibility and Screen Recording are both granted.",
            note: nil, destination: nil)
    }

    // MARK: - The key

    private static func shortcut(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        guard inputs.trigger.isBound else {
            return SetupHealthCheck(
                topic: .shortcut, status: .attention,
                detail: "No dictation shortcut is set.",
                note: "Set one in the Shortcuts tab, or start dictation from the menu bar.",
                destination: .shortcuts)
        }
        guard inputs.shortcutConflicts.isEmpty else {
            return SetupHealthCheck(
                topic: .shortcut, status: .attention,
                detail: "\(inputs.trigger.longDescription) starts a dictation.",
                note: inputs.shortcutConflicts.map(\.message).joined(separator: " "),
                destination: .shortcuts)
        }
        return SetupHealthCheck(
            topic: .shortcut, status: .ok,
            detail: "\(inputs.trigger.longDescription) starts a dictation.",
            note: nil, destination: .shortcuts)
    }

    // MARK: - Where the speech goes

    /// The row that has to be exactly right, because it is the only place the
    /// whole privacy position is stated in one line.
    ///
    /// It reports **configuration**, not intent: "the cloud engine is selected"
    /// is a fact, and it is stated whether or not the user thinks of it as on.
    /// A build with no cloud path at all says so, because that is a stronger
    /// claim than a default and the user is entitled to know which build they
    /// have. See `docs/cloud-api.md`.
    private static func privacy(_ inputs: SetupHealthInputs) -> SetupHealthCheck {
        guard inputs.cloudIsCompiledIn else {
            return SetupHealthCheck(
                topic: .privacy, status: .ok,
                detail: "Everything stays on this Mac. This build has no cloud path at all.",
                note: nil, destination: nil)
        }

        var uses: [String] = []
        if inputs.cloudTranscriptionSelected { uses.append("your recordings") }
        if inputs.cloudTranslationEnabled { uses.append("text you ask to translate") }

        guard !uses.isEmpty else {
            return SetupHealthCheck(
                topic: .privacy, status: .ok,
                detail: "Everything stays on this Mac. No cloud feature is switched on.",
                note: nil, destination: .cloud)
        }

        let host = inputs.cloudHost.map { " (\($0))" } ?? ""
        return SetupHealthCheck(
            topic: .privacy, status: .attention,
            detail: "Kongweh sends \(uses.joined(separator: " and ")) to the provider you "
                + "configured\(host).",
            note: "Everything else - rewriting, corrections, Ask, screen queries and voice edit - "
                + "stays on this Mac.",
            destination: .cloud)
    }
}
