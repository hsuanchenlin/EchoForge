import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))

    /// Opens the Ask panel and starts listening for a spoken question, or ends
    /// the question already being spoken.
    ///
    /// Its own shortcut rather than a mode of the recording one: the panel is
    /// something the user goes to and reads, and folding it into the dictation
    /// hotkey would make every dictation ambiguous. ⌥A by default, and
    /// configurable like the others - it is a plain global hotkey, so whatever
    /// the key would otherwise type is consumed while it is bound.
    ///
    /// A press records, the way the dictation key and ⌥Y do. It is not a
    /// show/hide toggle: a key that closed an open panel could not also be one
    /// that always starts listening, and the panel is closed with Esc or the
    /// Close button. Discarding a recording gives the microphone back and puts
    /// the card back to the answer before it; it closes nothing.
    static let askPanel = Self("askPanel", default: .init(.a, modifiers: .option))

    /// Asks a question about what is on screen: takes a screenshot of the window
    /// the user is in and starts recording the question at the same moment.
    ///
    /// ⌥S by default, beside ⌥A because it is the same panel reached with one
    /// more thing attached. Its own shortcut rather than a modifier on ⌥A: the
    /// screenshot has to be taken *before* this app comes forward, which is a
    /// decision that cannot be made after a panel is already open.
    /// See `docs/screen-context.md`.
    static let askAboutScreen = Self("askAboutScreen", default: .init(.s, modifiers: .option))

    /// Moves dictation to the next engine that is ready, wrapping around.
    ///
    /// ⌥M by default - free alongside ⌥`, ⌥A and ⌥S, and M for model, which is
    /// what a user calls this. Its own shortcut for the same reason the two above
    /// have theirs: it is a decision made *while* working in another app, which is
    /// exactly when opening Settings to change engine costs more than the switch is
    /// worth. See `EngineSwitcher` and `docs/engine-shortcut.md`.
    static let cycleEngine = Self("cycleEngine", default: .init(.m, modifiers: .option))

    /// Records a **YouTube command** and nothing else: hold it, name a channel
    /// from the allowlist, let go, and that channel's newest video opens in
    /// Chrome.
    ///
    /// Its own key rather than a phrase the dictation shortcut listens for, and
    /// that is the security boundary rather than an ergonomic preference. A
    /// dictation is words on their way into somebody's document; this is an
    /// instruction that opens a browser. Sharing one key meant every dictation
    /// had to be read for a command first, and a mis-read one would have opened
    /// a video instead of typing what was said. With two keys the app never has
    /// to guess: what this key captures can only ever open an allowlisted
    /// channel, and what the dictation key captures can only ever be typed.
    /// ⌥Y by default, free alongside ⌥`, ⌥A, ⌥S and ⌥M.
    /// See `DictationPurpose` and `docs/youtube-latest-video.md`.
    static let youTubeCommand = Self("youTubeCommand", default: .init(.y, modifiers: .option))

    /// Records a **voice edit** and nothing else: highlight text in any app,
    /// press it, speak an instruction, and the selection is replaced with the
    /// rewritten text. If nothing is highlighted, the clipboard is edited
    /// instead.
    ///
    /// Its own key rather than a mode of the dictation shortcut, for the same
    /// reason ⌥Y is: a dictation is words on their way into somebody's
    /// document; this is an instruction applied to words that are already
    /// there. Sharing one key would make every dictation ambiguous. ⌥E by
    /// default, free alongside ⌥`, ⌥A, ⌥S, ⌥M and ⌥Y.
    /// See `DictationPurpose.selectionEdit` and `docs/selection-edit.md`.
    static let editSelection = Self("editSelection", default: .init(.e, modifiers: .option))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    /// Which key started the session `activeVm` belongs to, so a second press
    /// stops the session it actually started and a double-press has to be two
    /// presses of the same key.
    private var activePurpose: DictationPurpose = .dictation
    private var pendingPressPurpose: DictationPurpose = .dictation
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false
    private var lastPressDownTime: CFAbsoluteTime = 0
    private var pressConsumed = false

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown(purpose: .dictation)
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        // The YouTube command key, driven by the same press/hold machinery as
        // dictation so it behaves the way the user's hands already expect - and
        // carrying `.youTubeCommand` all the way to `Settings`, which is what
        // makes the two captures different things rather than one thing with a
        // flag. Independent of the three exclusive trigger modes below, like ⌥A
        // and ⌥S: it is reached the same way whether dictation is on a key, a
        // modifier or a mouse button.
        KeyboardShortcuts.onKeyDown(for: .youTubeCommand) { [weak self] in
            self?.handleKeyDown(purpose: .youTubeCommand)
        }

        KeyboardShortcuts.onKeyUp(for: .youTubeCommand) { [weak self] in
            self?.handleKeyUp()
        }

        // Same press/hold machinery as dictation and the YouTube command, and
        // carrying `.selectionEdit` all the way to `Settings`. Independent of
        // the three exclusive trigger modes below, like ⌥A, ⌥S and ⌥Y: it is
        // reached the same way whether dictation is on a key, a modifier or a
        // mouse button.
        KeyboardShortcuts.onKeyDown(for: .editSelection) { [weak self] in
            self?.handleKeyDown(purpose: .selectionEdit)
        }

        KeyboardShortcuts.onKeyUp(for: .editSelection) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.activeVm != nil, IndicatorWindowManager.shared.requestCancel() {
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)

        // Deliberately independent of the recording trigger's three exclusive
        // modes below: the Ask panel is reached the same way whether dictation
        // is on a key combination, a modifier or a mouse button.
        //
        // On key-up rather than key-down, like ⌥S and ⌥M: a Carbon hotkey held
        // down repeats, and a repeat here would start and end a question over
        // and over. The capture still begins on the press the user makes.
        KeyboardShortcuts.onKeyUp(for: .askPanel) {
            Task { @MainActor in
                AskPanelWindowController.shared.toggleVoiceQuestion()
            }
        }

        // Independent of the recording trigger for the same reason ⌥A is, and
        // independent of ⌥A itself: pressing this while the panel happens to be
        // open starts a screen query rather than closing it.
        KeyboardShortcuts.onKeyUp(for: .askAboutScreen) {
            Task { @MainActor in
                AskPanelWindowController.shared.toggleScreenQuery()
            }
        }

        // Independent of the recording trigger, like the two above, and safe to
        // press during a dictation: a press while one is in flight is held and
        // applied when it ends, rather than changing the engine underneath the
        // words already spoken (`EngineSwitcher`).
        //
        // On key-up rather than key-down, so holding the key down walks one engine
        // instead of every engine in the cycle.
        KeyboardShortcuts.onKeyUp(for: .cycleEngine) {
            Task { @MainActor in
                EngineSwitcher.shared.advance()
            }
        }
    }
    
    private func setupRecordingTrigger() {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none {
            useMouseButtonHotkey = true
            useModifierOnlyHotkey = false
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown(purpose: .dictation)
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: mouseButton)
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown(purpose: .dictation)
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            lastPressDownTime = 0
            pressConsumed = false
            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName) (double-press: \(AppPreferences.shared.doublePressToTrigger))")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    /// - Parameter purpose: what a session this press *starts* is for. A press
    ///   that stops a session in flight stops whatever is running, whichever key
    ///   it came from: there is one recording at a time, and the alternative -
    ///   refusing the other key - would leave a session nothing could stop.
    private func handleKeyDown(purpose: DictationPurpose) {
        holdWorkItem?.cancel()
        holdMode = false

        // Require a double-tap only when starting a new recording. Once recording is
        // active, a single press stops it so the user isn't forced to double-tap again.
        if AppPreferences.shared.doublePressToTrigger && activeVm == nil {
            let now = CFAbsoluteTimeGetCurrent()
            let threshold = NSEvent.doubleClickInterval
            // Two presses of *different* keys are not a double-press: ⌥` then
            // ⌥Y is somebody changing their mind, and treating it as a trigger
            // would start the wrong kind of session.
            if lastPressDownTime > 0, now - lastPressDownTime <= threshold,
               pendingPressPurpose == purpose {
                lastPressDownTime = 0
            } else {
                lastPressDownTime = now
                pendingPressPurpose = purpose
                pressConsumed = false
                return
            }
        }
        pressConsumed = true

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        let isStartingRecording = activeVm == nil

        Task { @MainActor in
            if self.activeVm == nil {
                // A voice edit has to know what it is rewriting before the
                // overlay is drawn, so the HUD can say "Editing Selection..."
                // rather than "Recording...". AX is capped at 0.25 s per call;
                // the ⌘C fallback waits up to 200 ms. Capture first so a
                // press with nothing to edit never takes the microphone.
                let capture: SelectedTextCapture?
                if purpose == .selectionEdit {
                    capture = SelectedTextExtractor.capture()
                } else {
                    capture = nil
                }

                // Start recording immediately: resolving the caret position talks to
                // the focused app via AX IPC and can hang for seconds if that app
                // is busy - the first words must not be lost because of it.
                let vm = IndicatorWindowManager.shared.prepare(
                    purpose: purpose, selectionEdit: capture)
                if purpose == .selectionEdit, capture == nil {
                    vm.showNothingToEdit()
                    let cursorPosition = FocusUtils.getCurrentCursorPosition()
                    let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
                    let indicatorPoint = anchorPoint ?? cursorPosition
                    IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: indicatorPoint)
                    return
                }
                vm.startRecording()
                self.activeVm = vm
                self.activePurpose = purpose
                
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
                let indicatorPoint = anchorPoint ?? cursorPosition
                
                IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: indicatorPoint)
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }

        // Arm hold mode only when this press starts a recording. Arming it on the
        // stopping press would trigger a second stop on key-up.
        if holdToRecordEnabled && isStartingRecording {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }

    /// Resolves the input anchor without letting a slow focused app delay the
    /// indicator: whichever finishes first wins - the AX resolution or the
    /// deadline. On timeout the caller falls back to the mouse position; the
    /// late AX result is simply discarded.
    private static func resolveAnchorPoint(timeoutNanoseconds: UInt64) async -> NSPoint? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSPoint?, Never>) in
            let gate = AnchorGate(continuation)
            Task.detached {
                let point = FocusUtils.getInputAnchorPoint()
                await gate.resume(point)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resume(nil)
            }
        }
    }

    private actor AnchorGate {
        private var continuation: CheckedContinuation<NSPoint?, Never>?

        init(_ continuation: CheckedContinuation<NSPoint?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: NSPoint?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil

        guard pressConsumed else { return }
        pressConsumed = false

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord

        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode && self.activeVm != nil {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
            self.holdMode = false
        }
    }
}
