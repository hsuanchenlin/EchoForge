//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// The process entry point.
///
/// It sits in front of `OpenSuperWhisperApp` rather than on it so that
/// `LaunchDiagnostics` gets to run before *anything* the app does - before
/// SwiftUI builds the `App` value, whose stored properties reach
/// `AppPreferences.shared` and `MicrophoneService.shared` on the way past. A
/// release verifier has to be able to start the build it is about to publish
/// without that build migrating the operator's preferences or installing a
/// starter model into their model cache. See `LaunchDiagnostics`.
@main
enum AppEntryPoint {
    static func main() {
        if LaunchDiagnostics.isRequested {
            LaunchDiagnostics.runAndExit()
        }
        OpenSuperWhisperApp.main()
    }
}

struct OpenSuperWhisperApp: App {
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isRunningTests {
                    EmptyView()
                } else if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450)
            .frame(minHeight: 400, maxHeight: 900)
            .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        guard !Self.isRunningTests else { return }
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        WhisperModelManager.shared.ensureDefaultModelPresent()
        // Loading the rewriting model is the slow part of the first rewrite,
        // and the first rewrite is the one the user is standing in front of
        // waiting to paste. Rewriting is on by default, so this now runs on a
        // fresh install too - and must not pull a model onto a Mac whose owner
        // never asked for one. It does not: `prewarmIfAvailable` is gated on
        // `StyleRewriteAvailability.canRun`, which is false until Apple
        // Intelligence is switched on and its model already downloaded, so
        // there is nothing here to fetch.
        if AppPreferences.shared.styleRewriteEnabled {
            StyleRewriterFactory.prewarmIfAvailable()
        }
    }
}

extension OpenSuperWhisperApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var mainWindow: NSWindow?
    private var recordingRetentionTimer: Timer?
    private var hideMainWindowAtLaunch = false

    /// The status item and everything in it. Its own type because the menu is no
    /// longer four items: it is the app's whole state seen from outside the
    /// window, and it has a state machine (`MenuBarState`) worth testing.
    private var menuBar: MenuBarController?

    /// The permission state the menu bar reflects. Owned here rather than by the
    /// controller because it is the app's, not the menu's - and because a second
    /// `PermissionsManager` would be a second poller.
    private var permissionsManager: PermissionsManager { .shared }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OpenSuperWhisperApp.isRunningTests else { return }

        // Order matters, and both of these run before anything constructs an
        // engine - `warmUp()` below does.
        //
        // The starter weights go into the model cache first, so everything that
        // follows sees a Mac that can already transcribe rather than one that
        // has to download before it can. In a build packaged without them this
        // is a no-op and the app behaves exactly as it did before.
        print("Starter model: \(StarterModel.installIfNeeded())")

        // Then an install left with no usable engine is repaired against what is
        // actually downloaded, rather than failing at the user's first dictation.
        EngineConfiguration.recoverIfNeeded()

        // Once per install, and never again once the user has a list of their
        // own: the samples are how the Snippets pane explains itself, not a
        // floor the app keeps restoring. See `VoiceSnippetStore`.
        VoiceSnippetStore.shared.installSamplesIfNeeded()

        let menuBar = MenuBarController(
            permissions: permissionsManager,
            showMainWindow: { [weak self] in self?.showMainWindow() })
        menuBar.install()
        self.menuBar = menuBar

        // A sheet on screen makes AppKit refuse the system's quit event, which
        // cancels the user's restart and names this app in a dialog. The guard
        // takes them down when the shutdown broadcast arrives, which is before
        // that event. See `PowerOffPresentationGuard`.
        PowerOffPresentationGuard.shared.start()

        // The WindowGroup window usually does not exist yet at this point:
        // SwiftUI creates it after applicationDidFinishLaunching, so it is
        // adopted lazily from windowDidBecomeKey instead.
        if let window = Self.resolveMainWindow() {
            adoptMainWindow(window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // SwiftUI owns the WindowGroup window and can replace its delegate,
        // so windowWillClose on AppDelegate is not guaranteed to fire. The
        // notification is delivered regardless of who the delegate is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let prefs = AppPreferences.shared
        if prefs.startHiddenInMenuBar && prefs.hasCompletedOnboarding {
            hideMainWindowAtLaunch = true
            mainWindow?.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        OpenSuperWhisperApp.startTranscriptionQueue()
        
        IndicatorWindowManager.shared.warmUp()
        
        startRecordingRetentionSchedule()

        Task { @MainActor in
            await RecordingStore.shared.backfillMissingDurations()
        }
    }

    /// The update session is the one thing in this app with work that can still
    /// be moving bytes when the user quits, so it is told to stand down here -
    /// see `UpdateViewModel.prepareForTermination` for what it does and, more
    /// importantly, what it leaves alone.
    ///
    /// `sharedIfCreated` rather than `shared`: asking must not be what brings an
    /// updater into existence on the way out of a session that never opened
    /// About.
    func applicationWillTerminate(_ notification: Notification) {
        UpdateViewModel.sharedIfCreated?.prepareForTermination()
    }

    private func startRecordingRetentionSchedule() {
        cleanupOutdatedRecordings()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.cleanupOutdatedRecordings()
        }
        timer.tolerance = 60 * 60
        recordingRetentionTimer = timer
    }

    private func cleanupOutdatedRecordings() {
        let prefs = AppPreferences.shared
        guard prefs.autoDeleteRecordingsEnabled else { return }
        let days = prefs.autoDeleteRecordingsAfterDays
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    /// The WindowGroup window must be told apart from the other windows the
    /// app creates: the status item's NSStatusBarWindow, the borderless
    /// indicator NSPanel and SwiftUI sheet host windows.
    static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled)
    }

    private static func resolveMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first(where: isMainAppWindow)
    }

    /// SwiftUI creates the WindowGroup window after applicationDidFinishLaunching
    /// and can recreate it later, so the reference is (re)captured whenever a
    /// main-type window becomes key.
    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainAppWindow(window),
              window !== mainWindow
        else { return }
        adoptMainWindow(window)
    }

    private func adoptMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        window.minSize = NSSize(width: 450, height: 400)
        window.maxSize = NSSize(width: 450, height: 900)

        if hideMainWindowAtLaunch {
            hideMainWindowAtLaunch = false
            window.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func anyWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, Self.isMainAppWindow(closing) else { return }
        // Deferred so the check runs after the window has actually closed.
        DispatchQueue.main.async {
            let anyMainWindowVisible = NSApplication.shared.windows.contains {
                $0 !== closing && Self.isMainAppWindow($0) && $0.isVisible
            }
            if !anyMainWindowVisible {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        if mainWindow == nil {
            mainWindow = Self.resolveMainWindow()
        }

        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(width: 450, height: frameSize.height)
    }
}
