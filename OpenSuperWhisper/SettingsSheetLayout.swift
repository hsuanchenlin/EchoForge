import AppKit
import SwiftUI

/// The Settings sheet's tabs, in the order the tab bar draws them.
///
/// The list lives here rather than inline in `SettingsView` for one reason: the
/// tab bar is an `NSSegmentedControl` sized by the *sum of its titles*, so the
/// titles and the sheet's width are a single decision and have to be checkable
/// together. `SettingsTabBarFitTests` reads this list, lays the bar out at
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

    var systemImage: String {
        switch self {
        case .shortcuts: return "command"
        case .model: return "cpu"
        case .transcription: return "text.bubble"
        case .dictionary: return "character.book.closed"
        case .style: return "wand.and.stars"
        case .advanced: return "gear"
        case .cloud: return "cloud"
        case .about: return "info.circle"
        }
    }

    var label: Label<Text, Image> {
        Label(title, systemImage: systemImage)
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
    /// The width is set by the tab bar, not by any pane. macOS lays the eight
    /// tab titles out in a single `NSSegmentedControl` whose intrinsic width is
    /// roughly 640 pt; `.padding()` costs 32 pt of the sheet, so the sheet needs
    /// about 672 pt before the bar stops being compressed. 680 pt leaves a
    /// little slack.
    ///
    /// This started at 550 pt when the sheet had four tabs and was never
    /// revisited as tabs were added; by eight tabs it was 122 pt short and every
    /// title truncated.
    ///
    /// **What this width does not do.** It was once written down here as also
    /// fixing the tab bar's geometry, on the reasoning that an uncompressed bar
    /// sits at its intrinsic size and so cannot be moved by the pane below it.
    /// That is wrong, and measuring it says so: at this very width, a displayed
    /// pane 900 pt wide lays the bar out 657 pt wide instead of 648, and the
    /// same pane on a tab that is *not* showing changes nothing. The width is
    /// what stops the titles truncating, and nothing more. What holds the bar
    /// still is `settingsPane()`, which is applied to every pane and keeps a
    /// pane's own width from reaching the bar at all.
    ///
    /// Whether the keyboard focus ring and the selection pill then agree is a
    /// separate question this cannot answer: both are drawn by AppKit, and the
    /// only honest check is an interactive one on a real Mac, tabbing to the bar
    /// and looking at it. Constant segment geometry is a precondition for them
    /// agreeing, not a proof that they do.
    static let preferredSize = CGSize(width: 680, height: 500)

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
}

extension View {

    /// Contains one Settings pane, so its content cannot resize the tab bar.
    ///
    /// macOS lays a SwiftUI `TabView`'s tab bar out from the whole hosted view
    /// tree, and the *displayed* pane is part of that tree: a pane wider than the
    /// sheet makes the bar wider too, which moves every segment. Measured on the
    /// shipped 680 pt sheet, a 900 pt pane takes the bar from 648 pt to 657 pt,
    /// and moving to any other tab takes it back - so segment rects shift as the
    /// user changes tabs. `SettingsSheetLayout.preferredSize` does not prevent
    /// that; only this does.
    ///
    /// The mechanism is that `Color.clear` accepts whatever width it is offered
    /// and reports nothing of its own, so the pane is laid out *inside* it as an
    /// overlay and never gets to speak for the sheet. Three other shapes were
    /// measured and rejected: `frame(maxWidth:)` and `frame(idealWidth:)` do not
    /// contain it at all, and `frame(width:)` does but forces every pane to a
    /// width the tab view's content area is narrower than, which clips real
    /// content.
    ///
    /// Deliberately **not** `clipped()`. The containment is the overlay, not the
    /// clip, and a clip at a pane's edge is exactly what would trim a keyboard
    /// focus ring drawn just outside a control - the accessibility behaviour this
    /// whole area exists to keep.
    ///
    /// `SettingsTabBarFitTests` pins the half that can be measured headlessly:
    /// that this contains the bar, and that it does not change the sheet's own
    /// layout. That it does not move a pane's *contents* is a rendering question
    /// XCTest cannot answer without a screen - a hosted view's controls never get
    /// laid out - and was checked instead by rendering a pane of the shape every
    /// real one uses (`ScrollView` around a `VStack`) with and without this
    /// modifier: the two bitmaps came out byte-identical. Every pane being a
    /// `ScrollView` is why, since a scroll view takes whatever width it is
    /// offered and so is proposed exactly what the tab view proposed before.
    func settingsPane() -> some View {
        Color.clear.overlay { self }
    }
}
