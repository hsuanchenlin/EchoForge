import AppKit
import SwiftUI

/// The Settings sheet's tabs, in the order the tab bar draws them.
///
/// The list lives here rather than inline in `SettingsView` for one reason: the
/// tab bar is a single row of titles sized by the sum of them, so the titles and
/// the sheet's width are a single decision and have to be checkable together.
/// `SettingsTabBarFitTests` reads this list, lays the bar out at
/// `SettingsSheetLayout.preferredSize.width`, and fails if the titles no longer
/// fit. Add a tab or lengthen a title without widening the sheet and that test
/// says so, instead of the app shipping "Mo...", "St...", "Cl...", "Ab...".
enum SettingsTab: Hashable, CaseIterable {
    case shortcuts
    case model
    case transcription
    case dictionary
    case style
    case advanced
    case cloud
    case about

    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .model: return "Model"
        case .transcription: return "Transcription"
        case .dictionary: return "Dictionary & Snippets"
        case .style: return "Style"
        case .advanced: return "Advanced"
        case .cloud: return "Cloud"
        case .about: return "About"
        }
    }

    /// The tabs this build actually shows. An offline-only build has no Cloud
    /// pane at all, so it has no Cloud tab either.
    ///
    /// The fit test deliberately measures `allCases` rather than this: the
    /// widest configuration is the one that has to fit, and a build that drops a
    /// tab cannot be the one that proves the shipped width is enough.
    static var visible: [SettingsTab] {
        CloudBuild.isCompiledIn ? allCases : allCases.filter { $0 != .cloud }
    }
}

/// How big the Settings sheet is, and why.
enum SettingsSheetLayout {
    /// The size the sheet asks for when the screen allows it.
    ///
    /// The width is set by the tab bar, not by any pane: `SettingsTabBar` is one
    /// row of titles, and eight of them plus their padding need about 640 pt.
    /// `.padding()` costs 32 pt of the sheet, so the sheet needs about 672 pt
    /// before the titles start truncating. 680 pt leaves a little slack.
    ///
    /// This started at 550 pt when the sheet had four tabs and was never
    /// revisited as tabs were added; by eight tabs it was 122 pt short and every
    /// title truncated.
    ///
    /// **What this width does not do.** It was once written down here as also
    /// fixing the tab bar's geometry - as making the keyboard focus ring and the
    /// selection agree again. It did neither. Measured at this very width,
    /// AppKit's segmented control still drew its focus ring about six points
    /// wider than the selected segment, and a displayed pane 900 pt wide still
    /// laid the bar out 657 pt wide instead of 648. Width buys untruncated
    /// titles and nothing else.
    ///
    /// The focus ring is fixed elsewhere and by other means: the bar is no
    /// longer AppKit's. `SettingsTabBar` draws the selection fill, the focus
    /// frame and the hit target from one frame per tab, which is also why no
    /// pane can move a segment any more - the bar is a sibling of the pane with
    /// a width of its own, not a control sized from the whole hosted tree.
    static let preferredSize = CGSize(width: 680, height: 500)

    /// The gap between the tab bar and the pane below it.
    ///
    /// Room for the focus frame is part of this number: it is drawn
    /// `SettingsTabBarMetrics.focusRingOutset` outside the selected tab, so a
    /// tighter gap than that would run the halo into the pane's edge.
    static let tabBarToPaneSpacing: CGFloat = 8

    /// The panel the panes are drawn on - the one the tab view used to draw, a
    /// shade off the sheet's own background in both appearances.
    static let paneCornerRadius: CGFloat = 8
    static let paneBackground = Color.primary.opacity(0.035)

    /// The preferred size, shrunk to whatever the screen can show.
    ///
    /// A small display can still force compression - there is no width that both
    /// fits a 900 pt-wide screen and holds eight untruncated titles - which is
    /// why the fit test measures `preferredSize` rather than this.
    static func size(fittingScreen visibleFrame: CGSize) -> CGSize {
        CGSize(
            width: min(preferredSize.width, visibleFrame.width - 40),
            height: min(preferredSize.height, visibleFrame.height - 60)
        )
    }

    /// The size the sheet uses on this Mac right now.
    static var current: CGSize {
        size(fittingScreen: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800))
    }

    /// The room a pane is laid out in on the shipped sheet: the sheet, less
    /// `.padding()` on both sides. The tab bar gets the same width.
    static func contentWidth(inSheetOfWidth width: CGFloat) -> CGFloat {
        width - 32
    }
}

extension View {

    /// Contains one Settings pane, so its content cannot lay itself out over the
    /// sheet's edge.
    ///
    /// A pane wider than the sheet used to do worse than overflow: macOS laid a
    /// SwiftUI `TabView`'s tab bar out from the whole hosted view tree, and the
    /// *displayed* pane was part of that tree, so a 900 pt pane took the bar from
    /// 648 pt to 657 pt and moved every segment as the user changed tabs. That
    /// path is gone with the tab view - `SettingsTabBar` is a sibling of the pane
    /// with a width of its own - and
    /// `SettingsTabBarGeometryTests.testAWidePaneDoesNotMoveASinglePixelOfTheBar`
    /// pins that, with or without this modifier.
    ///
    /// What is left is still worth having: a pane that reports a width larger
    /// than the sheet lays itself out past the sheet's edge, and this is what
    /// keeps it inside. The mechanism is that `Color.clear` accepts whatever
    /// width it is offered and reports nothing of its own, so the pane is laid
    /// out *inside* it as an overlay and never speaks for the sheet. Three other
    /// shapes were measured and rejected: `frame(maxWidth:)` and
    /// `frame(idealWidth:)` do not contain it at all, and `frame(width:)` does
    /// but forces every pane to a width the content area is narrower than, which
    /// clips real content.
    ///
    /// Deliberately **not** `clipped()`. The containment is the overlay, not the
    /// clip, and a clip at a pane's edge is exactly what would trim a keyboard
    /// focus ring drawn just outside a control - the accessibility behaviour this
    /// whole area exists to keep.
    ///
    /// That it does not move a pane's *contents* is a rendering question XCTest
    /// cannot answer without a screen - a hosted view's controls never get laid
    /// out - and was checked instead by rendering a pane of the shape every real
    /// one uses (`ScrollView` around a `VStack`) with and without this modifier:
    /// the two bitmaps came out byte-identical. Every pane being a `ScrollView`
    /// is why, since a scroll view takes whatever width it is offered and so is
    /// proposed exactly what it was proposed before.
    func settingsPane() -> some View {
        Color.clear.overlay { self }
    }
}
