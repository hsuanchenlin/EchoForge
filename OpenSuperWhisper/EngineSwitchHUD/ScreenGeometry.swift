import AppKit

/// One attached display, reduced to the three things a HUD placement needs.
///
/// It exists so "where does the pill go on each display" is a pure function that a
/// test can run against a two-display Mac it is not running on. `NSScreen` cannot
/// be constructed, and the arithmetic that puts a panel on the wrong display is
/// exactly the part worth asserting - see `EngineSwitchHUD.placements`.
struct ScreenGeometry: Equatable {

    /// The display this describes. Panels are keyed by it, so a monitor that is
    /// unplugged and plugged back in gets a panel placed on its current frame
    /// rather than one still addressed to where it used to be.
    let displayID: CGDirectDisplayID

    /// The whole display, including the strip the menu bar is drawn on.
    let frame: CGRect

    /// What is left after the menu bar and the Dock, which is what a pill measures
    /// its top margin from.
    let visibleFrame: CGRect

    /// Every display attached right now, in `NSScreen.screens` order.
    ///
    /// A screen with no display number is skipped rather than given a made-up one:
    /// that is the key panels are stored under, and two screens sharing a key would
    /// leave one of them without a pill.
    @MainActor
    static func attached() -> [ScreenGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return ScreenGeometry(
                displayID: displayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` AppKit files under `NSScreenNumber`, which is the
    /// only stable identity an `NSScreen` has - the objects themselves are replaced
    /// whenever the display configuration changes.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
