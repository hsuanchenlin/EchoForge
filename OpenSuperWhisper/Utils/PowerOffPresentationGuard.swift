import AppKit
import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// Every modal presentation this app owns must go away, now.
    ///
    /// Posted only by `PowerOffPresentationGuard`, and listened for only by
    /// `dismissesOnPowerOff`. It exists so that "macOS is shutting down" is
    /// decided in one place and acted on in one way, rather than every
    /// presentation site growing its own reading of a workspace notification.
    static let dismissModalPresentations = Notification.Name("DismissModalPresentations")
}

/// The single owner of "macOS is about to restart, so get every sheet off the
/// screen before the quit event arrives".
///
/// ## Why this exists at all
///
/// A visible window-modal sheet makes AppKit refuse the quit Apple Event that
/// loginwindow sends, reply `userCanceledErr`, and hand the user
/// *"'Kongweh' interrupted restart. To continue restarting, quit 'Kongweh'."*
/// Kongweh is a menu-bar app that stays up all day and its Settings surface is
/// a sheet, so this was a routine way to lose a restart.
///
/// Two dead ends are worth stating, because both look like the obvious fix and
/// both were measured not to work:
///
/// - **`applicationShouldTerminate` cannot help.** AppKit's modal-sheet check
///   runs *before* the delegate is consulted; on a blocked quit the delegate is
///   never called at all. The system log says `App termination blocked by modal
///   sheet` and no `Asking app delegate whether applicationShouldTerminate:`
///   line is ever emitted.
/// - **`NSWindow.endSheet` cannot help either.** SwiftUI owns the presentation;
///   the AppKit-level dismissal is ignored and `attachedSheet` is still non-nil
///   more than a second later. Only setting the SwiftUI binding back to
///   `false`/`nil` actually takes the sheet down.
///
/// So the only place to intervene is *before* the quit event, and the only
/// signal available then is `NSWorkspace.willPowerOffNotification`, which AppKit
/// derives from loginwindow's logout broadcast.
///
/// ## The honest limit
///
/// Taking a sheet down costs about 270 ms - AppKit's sheet-dismissal animation,
/// which `Transaction.disablesAnimations` does not shorten. loginwindow quits
/// apps one at a time, so in practice there are seconds between the broadcast
/// and this app's quit event and the guard wins comfortably. It can lose only if
/// Kongweh happens to be first in the quit list, and even then the sheet is
/// gone by the time the user presses **Try Again**. This turns "always blocks"
/// into "at worst one extra click, once"; it is a race that is heavily won, not
/// a proof.
///
/// ## Where the seam is
///
/// Both notification centres are injected so the whole path is testable with no
/// shutdown involved: a test posts `willPowerOff` into its own workspace centre
/// and watches its own app centre. `PowerOffPresentationGuardTests` drives it.
final class PowerOffPresentationGuard {
    /// The instance the app runs. Started once, from
    /// `applicationDidFinishLaunching`.
    static let shared = PowerOffPresentationGuard()

    private let workspaceCenter: NotificationCenter
    private let appCenter: NotificationCenter
    private let powerOffNotification: Notification.Name
    private var observer: NSObjectProtocol?

    /// - Parameters:
    ///   - workspaceCenter: where the power-off signal is read. The real one is
    ///     `NSWorkspace.shared.notificationCenter`; `NotificationCenter.default`
    ///     does *not* carry it.
    ///   - appCenter: where `.dismissModalPresentations` is broadcast. Must be
    ///     the same centre `dismissesOnPowerOff` reads - see
    ///     `EnvironmentValues.modalDismissalCenter`.
    ///   - powerOffNotification: injectable only so a test can post a name of
    ///     its own into a centre it owns; production always uses
    ///     `NSWorkspace.willPowerOffNotification`.
    init(
        observing workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        broadcastingOn appCenter: NotificationCenter = .default,
        powerOffNotification: Notification.Name = NSWorkspace.willPowerOffNotification
    ) {
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        self.powerOffNotification = powerOffNotification
    }

    deinit {
        if let observer { workspaceCenter.removeObserver(observer) }
    }

    /// Begin watching for the power-off broadcast. Calling this twice is a no-op
    /// rather than a second observer, so a double `start()` cannot double-post.
    func start() {
        guard observer == nil else { return }
        // `.main` because the only listeners are SwiftUI views: `onReceive`
        // delivers on whichever thread posted, and a state write from a
        // background thread is not something to leave to the poster.
        observer = workspaceCenter.addObserver(
            forName: powerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismissModalPresentations()
        }
    }

    /// Stop watching. Only tests need this; the app's guard lives as long as the
    /// app does.
    func stop() {
        guard let observer else { return }
        workspaceCenter.removeObserver(observer)
        self.observer = nil
    }

    private func dismissModalPresentations() {
        appCenter.post(name: .dismissModalPresentations, object: nil)
    }
}

// MARK: - The listening half

private struct ModalDismissalCenterKey: EnvironmentKey {
    static let defaultValue: NotificationCenter = .default
}

extension EnvironmentValues {
    /// The centre `dismissesOnPowerOff` listens on.
    ///
    /// It is an environment value purely so a test can hand a hosted view its
    /// own centre; nothing in the app ever sets it.
    var modalDismissalCenter: NotificationCenter {
        get { self[ModalDismissalCenterKey.self] }
        set { self[ModalDismissalCenterKey.self] = newValue }
    }
}

private struct DismissesOnPowerOff: ViewModifier {
    @Environment(\.modalDismissalCenter) private var center
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(center.publisher(for: .dismissModalPresentations)) { _ in
            dismiss()
        }
    }
}

extension View {
    /// Take this presentation down when macOS is about to restart, shut down or
    /// log out.
    ///
    /// Belongs on **every** `.sheet` and `.confirmationDialog` in the app: each
    /// one of them refuses the system's quit event for as long as it is on
    /// screen. `.alert` is deliberately exempt - measured, an `.alert` does not
    /// block termination while a `.confirmationDialog` does, even though AppKit
    /// builds both out of `_NSAlertPanel`. `PowerOffPresentationGuard` has the
    /// full account.
    func dismissesOnPowerOff(_ isPresented: Binding<Bool>) -> some View {
        modifier(DismissesOnPowerOff {
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        })
    }

    /// The `item:` form of the same thing.
    func dismissesOnPowerOff<Item>(_ item: Binding<Item?>) -> some View {
        modifier(DismissesOnPowerOff {
            if item.wrappedValue != nil { item.wrappedValue = nil }
        })
    }
}
