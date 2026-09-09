import AppKit
import Combine
import Foundation
import KeyboardShortcuts

/// The status item: what the app is doing, and the handful of things worth doing
/// from a menu.
///
/// It replaces a menu that opened the app, chose a language, chose a microphone
/// and quit - four items that answered none of the questions a user has between
/// dictations. Which engine is running, whether it is ready, what key is live,
/// whether anything was inserted: all of those were only visible by opening the
/// main window, which for a menu-bar-only install means bringing the whole app
/// forward.
///
/// **It decides nothing.** `MenuBarState` resolves the status,
/// `MenuBarTranscript` decides which rows may be shown and how they are cut,
/// `EngineCycle` decides which engines a pick may land on, and
/// `EngineSelectionCommand` carries a pick out - the same call the Settings
/// picker and the ⌥M shortcut make. What lives here is the AppKit: building the
/// menu, keeping the icon in step, and reading the history page.
///
/// **It is rebuilt on open, not on every change.** `menuNeedsUpdate` is the one
/// place the menu is assembled, so nothing has to keep a dozen `NSMenuItem`s in
/// sync with published state, and nothing is recomputed while nobody is looking.
/// The icon is the exception and has to follow live, since it is on screen the
/// whole time.
@MainActor
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private let microphoneService = MicrophoneService.shared
    private let transcriptionService = TranscriptionService.shared
    private let recorder = AudioRecorder.shared
    private let queue = TranscriptionQueue.shared
    private let permissions: PermissionsManager

    /// The last page of history read for the menu. Refreshed when the menu is
    /// about to open, and when a recording finishes while it is not - reading
    /// SQLite on every dictation is cheaper than a stale menu, and it is one
    /// bounded query.
    private var recentTranscripts: [MenuBarTranscript] = []

    /// The engines a pick may safely land on, from `EngineCycle.available`.
    ///
    /// **Cached, and never computed while the menu is opening.** Deciding it
    /// needs `EngineAvailability.current()`, which reads the model caches and -
    /// on an install that has chosen the cloud - reaches the Keychain. Doing
    /// that inside `menuNeedsUpdate` puts a synchronous XPC round trip in front
    /// of every menu open, and on a build whose signature does not match the
    /// Keychain item it puts a **system dialog** there: measured on an ad-hoc
    /// build, the menu never opened and the app's whole accessibility tree went
    /// with it, because `menuNeedsUpdate` had not returned.
    ///
    /// So it is recomputed on the three events that can change it, all of which
    /// already re-resolve availability anyway.
    private var selectableEngines: [EngineKind] = []

    /// Opens the main window. Injected because it belongs to `AppDelegate`, which
    /// owns the window, and this owns the menu.
    private let showMainWindow: () -> Void

    init(permissions: PermissionsManager, showMainWindow: @escaping () -> Void) {
        self.permissions = permissions
        self.showMainWindow = showMainWindow
        super.init()
    }

    // MARK: - The status item

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        observe()
        refreshIcon()
        refreshSelectableEngines()
        Task { await refreshRecentTranscripts() }
    }

    /// What the snapshot is built from, read fresh each time.
    private var state: MenuBarState {
        MenuBarState.resolve(
            isRecording: recorder.isRecording || recorder.isConnecting,
            isProcessing: transcriptionService.isTranscribing || queue.isProcessing,
            isMissingRequiredPermission: permissions.isMissingRequiredPermission,
            canTranscribe: transcriptionService.selection.canTranscribe,
            shortcutsPaused: ShortcutPause.shared.isPaused,
            preparation: transcriptionService.modelPreparation)
    }

    /// Recomputes the engines a pick may land on.
    ///
    /// Never called from `menuNeedsUpdate` - see `selectableEngines`.
    ///
    /// `isCloudSelectable` is **false**, always, and that is a product decision
    /// rather than a shortcut around the Keychain. `EngineCatalog.pickerOrder`
    /// leaves the cloud engine out for a reason - one tap must not be all it
    /// takes to start sending dictation to a company - and this menu is the
    /// picker without opening Settings. A user already on the cloud engine still
    /// sees it named as their choice; going back to it is done where the consent
    /// sheet is.
    private func refreshSelectableEngines() {
        let preferences = AppPreferences.shared
        selectableEngines = EngineCycle.available(
            whisperModelPath: preferences.selectedWhisperModelPath,
            language: preferences.whisperLanguage,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion,
            availability: EngineAvailability.current(
                fluidAudioModelVersion: preferences.fluidAudioModelVersion),
            isCloudSelectable: false)
    }

    private func snapshot() -> MenuBarSnapshot {
        let preferences = AppPreferences.shared
        let selection = transcriptionService.selection

        let current = state
        return MenuBarSnapshot(
            state: current,
            desiredEngine: selection.desired,
            activeEngine: selection.active,
            selectableEngines: selectableEngines,
            // A dictation that has started belongs to the engine it started on -
            // the same rule `EngineCycle` applies to a press of ⌥M, which defers
            // rather than switching mid-session.
            canChangeEngine: current != .recording && current != .processing,
            trigger: DictationTrigger.current(preferences: preferences),
            shortcutsPaused: ShortcutPause.shared.isPaused,
            preparationFailure: transcriptionService.preparationFailure,
            recentTranscripts: recentTranscripts)
    }

    /// The icon follows live, unlike the menu: it is on screen all the time, and
    /// it is the whole point of having one.
    private func observe() {
        let iconRefresh: () -> Void = { [weak self] in self?.refreshIcon() }

        recorder.$isRecording.sink { _ in iconRefresh() }.store(in: &cancellables)
        recorder.$isConnecting.sink { _ in iconRefresh() }.store(in: &cancellables)
        transcriptionService.$isTranscribing.sink { _ in iconRefresh() }.store(in: &cancellables)
        transcriptionService.$selection.sink { _ in iconRefresh() }.store(in: &cancellables)
        transcriptionService.$modelPreparation.sink { _ in iconRefresh() }.store(in: &cancellables)
        queue.$isProcessing.sink { _ in iconRefresh() }.store(in: &cancellables)
        permissions.$hasCompletedInitialCheck.sink { _ in iconRefresh() }.store(in: &cancellables)
        permissions.$isMicrophonePermissionGranted.sink { _ in iconRefresh() }
            .store(in: &cancellables)
        permissions.$isAccessibilityPermissionGranted.sink { _ in iconRefresh() }
            .store(in: &cancellables)
        ShortcutPause.shared.$isPaused.sink { _ in iconRefresh() }.store(in: &cancellables)

        NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)
            .sink { [weak self] _ in Task { await self?.refreshRecentTranscripts() } }
            .store(in: &cancellables)

        // The three moments the safe engine list can change, all of which
        // already re-resolve availability elsewhere. Off the menu-open path on
        // purpose - see `selectableEngines`.
        transcriptionService.$selection
            .sink { [weak self] _ in self?.refreshSelectableEngines() }
            .store(in: &cancellables)
        for name in [
            Notification.Name.engineModelStateChanged, .selectedEngineChanged,
            .appPreferencesLanguageChanged,
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshSelectableEngines() }
                .store(in: &cancellables)
        }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let icon = state.icon

        if let image = NSImage(named: icon.assetName) {
            image.size = NSSize(width: MenuBarIcon.pointSize, height: MenuBarIcon.pointSize)
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: icon.systemSymbolFallback, accessibilityDescription: nil)
        }
        // The status item is the only part of this app a VoiceOver user can find
        // without a window, so it says what the app is doing rather than only
        // what it is called.
        button.image?.accessibilityDescription = "Kongweh: \(state.title)"
        button.toolTip = "Kongweh - \(state.title)"
    }

    private func refreshRecentTranscripts() async {
        // One page, newest first, filtered by the same rule the menu shows: a
        // handful of rows so the three that qualify are almost always in it.
        let page = (try? await RecordingStore.shared.fetchRecordings(limit: 20, offset: 0)) ?? []
        recentTranscripts = MenuBarTranscript.offered(from: page)
    }

    // MARK: - Building the menu

    private func build(_ menu: NSMenu, from snapshot: MenuBarSnapshot) {
        menu.removeAllItems()

        addStatus(to: menu, snapshot)
        menu.addItem(.separator())
        addDictationActions(to: menu, snapshot)
        menu.addItem(.separator())
        addEngine(to: menu, snapshot)
        addLanguage(to: menu)
        addMicrophone(to: menu)
        menu.addItem(.separator())
        addRecentTranscripts(to: menu, snapshot)
        menu.addItem(.separator())
        addWindows(to: menu)
    }

    private func addStatus(to menu: NSMenu, _ snapshot: MenuBarSnapshot) {
        let status = disabledItem(snapshot.state.title)
        status.image = NSImage(
            systemSymbolName: snapshot.state.isProblem
                ? "exclamationmark.triangle.fill" : snapshot.state.icon.systemSymbolFallback,
            accessibilityDescription: nil)
        menu.addItem(status)

        if case .preparingModel(let preparation) = snapshot.state,
            case .downloading(let fraction) = preparation.stage {
            menu.addItem(progressItem(fraction))
        }

        if let failure = snapshot.preparationFailure {
            menu.addItem(disabledItem(failure))
            let retry = NSMenuItem(
                title: "Retry Preparing Model", action: #selector(retryPreparation), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        if snapshot.shortcutsPaused {
            menu.addItem(disabledItem(MenuBarSnapshot.pausedExplanation))
        }

        if snapshot.state == .permissionNeeded || snapshot.state == .noEngine {
            // Two different fixes: a missing model is set right in Settings, and
            // a missing permission is granted from the window that explains it.
            let open = NSMenuItem(
                title: snapshot.state == .noEngine ? "Open Settings…" : "Open Kongweh…",
                action: snapshot.state == .noEngine
                    ? #selector(openModelSettings) : #selector(openApp),
                keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
    }

    private func addDictationActions(to menu: NSMenu, _ snapshot: MenuBarSnapshot) {
        let dictate = NSMenuItem(
            title: snapshot.dictationActionTitle, action: #selector(toggleDictation),
            keyEquivalent: "")
        dictate.target = self
        // The key that would do the same thing, shown as a label rather than as
        // a key equivalent: it is a global hotkey, not a menu shortcut, and
        // AppKit would try to claim it.
        if snapshot.trigger.isBound {
            dictate.badge = NSMenuItemBadge(string: snapshot.trigger.shortDescription)
        }
        dictate.isEnabled = !snapshot.state.isProblem || snapshot.state == .recording
        menu.addItem(dictate)

        let pause = NSMenuItem(
            title: snapshot.pauseActionTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
    }

    private func addEngine(to menu: NSMenu, _ snapshot: MenuBarSnapshot) {
        let item = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(
            disabledItem(
                "Chosen: \(EngineCatalog.entry(for: snapshot.desiredEngine).displayName)"))
        if let notice = snapshot.fallbackNotice {
            submenu.addItem(disabledItem(notice))
        }
        submenu.addItem(.separator())

        if snapshot.selectableEngines.isEmpty {
            submenu.addItem(disabledItem(EngineConfiguration.unavailableMessage))
        }
        for engine in snapshot.selectableEngines {
            let option = NSMenuItem(
                title: EngineCatalog.entry(for: engine).displayName,
                action: #selector(selectEngine(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = engine.rawValue
            option.state = engine == snapshot.desiredEngine ? .on : .off
            option.isEnabled = snapshot.canChangeEngine
            submenu.addItem(option)
        }
        if !snapshot.canChangeEngine {
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Finish the dictation first"))
        }
        if snapshot.desiredEngine.usesCloudProvider {
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Cloud is chosen in Settings → Cloud"))
        }

        item.submenu = submenu
        // The engine actually in use is on the parent item, so it is legible
        // without opening the submenu - that is the question this answers.
        item.badge = NSMenuItemBadge(
            string: EngineCatalog.entry(for: snapshot.activeEngine ?? snapshot.desiredEngine)
                .displayName)
        menu.addItem(item)
    }

    private func addLanguage(to menu: NSMenu) {
        let item = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let preferences = AppPreferences.shared
        let supported = LanguageUtil.supportedLanguages(
            engine: preferences.selectedEngine,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion)
        let current = preferences.whisperLanguage

        for code in supported {
            let option = NSMenuItem(
                title: LanguageUtil.languageNames[code] ?? code,
                action: #selector(selectLanguage(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = code
            option.state = code == current ? .on : .off
            submenu.addItem(option)
        }

        item.submenu = submenu
        item.badge = NSMenuItemBadge(string: LanguageUtil.languageNames[current] ?? current)
        menu.addItem(item)
    }

    private func addMicrophone(to menu: NSMenu) {
        let item = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let microphones = microphoneService.availableMicrophones
        let current = microphoneService.currentMicrophone

        if microphones.isEmpty {
            submenu.addItem(disabledItem("No microphones available"))
        } else {
            let builtIn = microphones.filter(\.isBuiltIn)
            let external = microphones.filter { !$0.isBuiltIn }
            for (index, group) in [builtIn, external].enumerated() where !group.isEmpty {
                if index > 0, !builtIn.isEmpty { submenu.addItem(.separator()) }
                for microphone in group {
                    let option = NSMenuItem(
                        title: microphone.displayName, action: #selector(selectMicrophone(_:)),
                        keyEquivalent: "")
                    option.target = self
                    option.representedObject = microphone
                    option.state = current?.id == microphone.id ? .on : .off
                    submenu.addItem(option)
                }
            }
        }

        item.submenu = submenu
        if let current { item.badge = NSMenuItemBadge(string: current.displayName) }
        menu.addItem(item)
    }

    /// The last three transcripts, as one line each.
    ///
    /// A menu can only be opened by somebody at an unlocked Mac, which is what
    /// makes showing text here acceptable at all - nothing on this path reaches a
    /// notification, a lock screen or anything that outlives the open menu, and
    /// `MenuBarTranscript` decides which rows qualify and cuts them to one line.
    private func addRecentTranscripts(to menu: NSMenu, _ snapshot: MenuBarSnapshot) {
        menu.addItem(disabledItem("Recent"))

        guard !snapshot.recentTranscripts.isEmpty else {
            menu.addItem(disabledItem("Nothing transcribed yet"))
            return
        }

        for transcript in snapshot.recentTranscripts {
            let item = NSMenuItem(title: transcript.preview, action: nil, keyEquivalent: "")
            // A submenu rather than a click that copies, and rather than the
            // alternate-item trick: two named actions are discoverable, and a
            // row that silently replaced the pasteboard the moment it was
            // clicked is not something to do to somebody by accident.
            let actions = NSMenu()

            let copy = NSMenuItem(
                title: "Copy", action: #selector(copyTranscript(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = transcript.full
            actions.addItem(copy)

            let open = NSMenuItem(
                title: "Open in History", action: #selector(openHistory), keyEquivalent: "")
            open.target = self
            actions.addItem(open)

            item.submenu = actions
            menu.addItem(item)
        }
    }

    private func addWindows(to menu: NSMenu) {
        for (title, selector) in [
            ("History…", #selector(openHistory)),
            ("Settings…", #selector(openSettings)),
            ("About Kongweh…", #selector(openAbout)),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Kongweh", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Items

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A determinate bar for the byte phases only. The Neural Engine compile
    /// publishes no fraction, and a bar left at its last value reads as a hang -
    /// the same division `ModelPreparationStage` makes everywhere else.
    private func progressItem(_ fraction: Double) -> NSMenuItem {
        let item = NSMenuItem()
        let indicator = NSProgressIndicator(
            frame: NSRect(x: 20, y: 2, width: 180, height: 12))
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = fraction
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 16))
        container.addSubview(indicator)
        item.view = container
        return item
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        ShortcutManager.shared.toggleDictationFromMenuBar()
    }

    @objc private func togglePause() {
        ShortcutPause.shared.toggle()
    }

    @objc private func retryPreparation() {
        transcriptionService.retryPreparingDesiredEngine()
    }

    /// The pick goes through the one place a user's engine choice is carried out,
    /// which is what keeps the language, the cloud bookkeeping and the reload
    /// together - see `EngineSelectionCommand`.
    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let engine = EngineKind(rawValue: raw)
        else { return }
        EngineSelectionCommand.select(engine)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        AppPreferences.shared.whisperLanguage = code
        NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
    }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openApp() {
        showMainWindow()
    }

    @objc private func openHistory() {
        // History *is* the main window; there is no second window to open.
        showMainWindow()
    }

    @objc private func openModelSettings() {
        open(.model)
    }

    @objc private func openSettings() {
        open(.setup)
    }

    @objc private func openAbout() {
        open(.about)
    }

    /// Opens the Settings sheet on a named tab.
    ///
    /// The tab is handed over through `SettingsPresentation` rather than through
    /// the notification, because the sheet's view does not exist yet when the
    /// notification is posted - it is built by the presentation the notification
    /// causes.
    private func open(_ tab: SettingsTab) {
        SettingsPresentation.pendingTab = tab
        showMainWindow()
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// The whole menu is assembled here, once, as it opens.
    ///
    /// Everything in it is a read of state that changes while the menu is shut,
    /// and rebuilding on open is both cheaper and less error-prone than keeping a
    /// dozen items in sync with published values nobody is looking at.
    func menuNeedsUpdate(_ menu: NSMenu) {
        build(menu, from: snapshot())
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshRecentTranscripts() }
    }
}
