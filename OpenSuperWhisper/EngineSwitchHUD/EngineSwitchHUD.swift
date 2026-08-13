import AppKit
import SwiftUI

/// A panel that can be seen but never focused, for the same load-bearing reason
/// `CapsuleHUDPanel` is one: the engine shortcut is pressed while the user is
/// typing in another app, and a HUD that took focus on its way up would move the
/// insertion point they are about to dictate into.
private final class EngineSwitchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes the frame it was given. AppKit otherwise pulls a window down until it
    /// fits the screen's visible frame, and this panel is deliberately taller than
    /// its pill - the extra is transparent margin for the shadow, and the top of it
    /// is meant to overlap the menu bar strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Shows which engine dictation is on, for two seconds, wherever the user is.
///
/// The engine shortcut is the one control in this app with no surface of its own:
/// it is pressed with no window open and nothing in front of the user, so the
/// overlay *is* the feedback. Everything about the panel - non-activating, mouse
/// events ignored, over every space - follows from it never being something to
/// interact with.
///
/// Not the dictation capsule, and deliberately not routed through it: the capsule
/// is one presentation of one dictation (`docs/capsule-hud.md`), it is off by
/// default, and a press that happens during a dictation would have to either
/// overwrite what that capsule is saying or wait for it. This is its own pill,
/// placed clear of the capsule's slot when the capsule is switched on.
///
/// **It is drawn on every attached display at once**, which is the one thing here
/// that is not obvious. It used to go to the screen holding the focused window, and
/// on a two-display Mac that is how the whole feature came to look missing: the
/// engine changed, the pill appeared on the display the user was not looking at,
/// and two seconds later there was nothing left to find. Choosing a screen at all
/// is a guess about where someone's eyes are - a guess this confirmation cannot
/// afford, because it is the only thing a press shows. On a single display it is
/// what it always was.
@MainActor
final class EngineSwitchHUD {
    static let shared = EngineSwitchHUD()

    /// The same fade the capsule uses - short enough to feel immediate, long
    /// enough not to read as a flash.
    static let fadeDuration: TimeInterval = 0.18

    /// The gap between the top of the usable screen and the top of the pill, when
    /// nothing else is up there. Measured from `visibleFrame`, which already
    /// excludes the menu bar on every display including the notched ones.
    static let topMargin: CGFloat = 12

    /// How far down the pill moves when the capsule HUD is switched on, so the two
    /// never sit on top of each other: a press during a dictation is exactly when
    /// both want the top of the screen. The capsule's own slot plus a gap.
    static let capsuleClearance: CGFloat = CapsuleHUDView.capsuleHeight + 8

    let viewModel: EngineSwitchHUDViewModel

    /// One panel per attached display, keyed by its display ID so a monitor being
    /// unplugged takes its panel with it rather than leaving one addressed to
    /// coordinates no display covers any more.
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    init() {
        // Built here rather than taken as a defaulted parameter: a default
        // argument is evaluated outside this type's actor, and this view model
        // belongs to the main actor like the panel it draws.
        let viewModel = EngineSwitchHUDViewModel()
        self.viewModel = viewModel
        viewModel.onHide = { [weak self] in self?.hidePanels() }
    }

    /// Puts an announcement on screen, replacing whatever was there.
    ///
    /// The pill and the spoken announcement go up together: a HUD that never takes
    /// focus is invisible to VoiceOver, and this shortcut has no other surface for
    /// it to read.
    func show(_ announcement: EngineSwitchAnnouncement) {
        viewModel.show(announcement)
        present()
        EngineSwitchAccessibility.announce(announcement)
    }

    // MARK: - The panels

    private func present() {
        let placements = Self.placements(
            for: ScreenGeometry.attached(),
            windowSize: EngineSwitchHUDView.windowSize,
            topOffset: Self.topOffset(capsuleHUDEnabled: CapsuleHUDWindowController.isEnabled)
        )

        discardPanels(notIn: Set(placements.map(\.displayID)))

        for placement in placements {
            let panel = ensurePanel(for: placement.displayID)
            panel.setFrameOrigin(placement.origin)

            guard !panel.isVisible || panel.alphaValue < 1 else { continue }
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hidePanels() {
        for panel in panels.values where panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // A further press may have put a new message up during the fade;
                // ordering the panel out then would take that one off the screen.
                guard let self, self.viewModel.announcement == nil else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// Takes down and forgets the panels belonging to displays that are no longer
    /// attached.
    private func discardPanels(notIn attached: Set<CGDirectDisplayID>) {
        for (displayID, panel) in panels where !attached.contains(displayID) {
            panel.orderOut(nil)
            panels[displayID] = nil
        }
    }

    private func ensurePanel(for displayID: CGDirectDisplayID) -> NSPanel {
        let panel = panels[displayID] ?? makePanel()
        panels[displayID] = panel

        if let hostingView = panel.contentView as? NSHostingView<EngineSwitchHUDView> {
            hostingView.rootView = EngineSwitchHUDView(viewModel: viewModel)
        } else {
            let hostingView = NSHostingView(rootView: EngineSwitchHUDView(viewModel: viewModel))
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            panel.contentView = hostingView
        }
        panel.setContentSize(EngineSwitchHUDView.windowSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func makePanel() -> NSPanel {
        let created = EngineSwitchPanel(
            contentRect: NSRect(origin: .zero, size: EngineSwitchHUDView.windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .floating
        // Over every desktop and alongside full-screen apps: the shortcut is
        // pressed from whatever the user is doing, not from this app.
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        created.backgroundColor = .clear
        created.isOpaque = false
        // The pill draws its own shadow, inside the window.
        created.hasShadow = false
        created.hidesOnDeactivate = false
        // Always: there is nothing here to click, and a HUD that swallowed
        // mouse events would take a strip of the screen away from the app
        // underneath it.
        created.ignoresMouseEvents = true
        return created
    }

    /// How far below the top of the usable screen the pill sits.
    ///
    /// A pure function of one preference rather than of whether a capsule happens
    /// to be visible: a press during a dictation and a press outside one must land
    /// the pill in the same place, or the overlay appears to jump around for
    /// reasons the user cannot see.
    static func topOffset(capsuleHUDEnabled: Bool) -> CGFloat {
        capsuleHUDEnabled ? topMargin + capsuleClearance : topMargin
    }

    /// Where the pill goes on one display.
    struct Placement: Equatable {
        let displayID: CGDirectDisplayID
        let origin: NSPoint
    }

    /// One placement per attached display, top-centre of each.
    ///
    /// A pure function of the geometry rather than of `NSScreen`, for the reason
    /// `origin` takes rectangles: the arithmetic is the part that goes wrong, and a
    /// checkout machine has one display while the setup this was written for has
    /// two. Empty in, empty out - a Mac with no display attached shows nothing,
    /// which is what the old single-panel guard did too.
    static func placements(
        for screens: [ScreenGeometry],
        windowSize: CGSize,
        topOffset: CGFloat
    ) -> [Placement] {
        screens.map { screen in
            Placement(
                displayID: screen.displayID,
                origin: origin(
                    visibleFrame: screen.visibleFrame,
                    screenFrame: screen.frame,
                    windowSize: windowSize,
                    topOffset: topOffset
                )
            )
        }
    }

    /// Top-centre of the screen's usable area, `topOffset` down, in the window
    /// coordinates AppKit wants.
    ///
    /// The same arithmetic - and the same reason for taking rectangles rather than
    /// an `NSScreen` - as `CapsuleHUDWindowController.origin`: it is the pill that
    /// has to land where it was asked to, not the taller window it is centred in,
    /// and that is the part that goes wrong.
    static func origin(
        visibleFrame visible: CGRect,
        screenFrame: CGRect,
        windowSize: CGSize,
        topOffset: CGFloat
    ) -> NSPoint {
        let pillTop = visible.maxY - topOffset
        let pillTopInset = (windowSize.height - EngineSwitchHUDView.capsuleHeight) / 2

        var x = visible.midX - windowSize.width / 2
        let y = max(screenFrame.minY, pillTop + pillTopInset - windowSize.height)

        x = max(visible.minX, min(x, visible.maxX - windowSize.width))
        return NSPoint(x: x, y: y)
    }
}
