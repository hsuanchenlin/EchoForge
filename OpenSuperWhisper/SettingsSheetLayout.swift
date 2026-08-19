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
    /// Compression is not merely ugly. A compressed bar's segment widths become
    /// a function of the whole layout - the *displayed* pane's content width
    /// feeds back into the bar - so segment rects move as the user changes tabs,
    /// which is what let the keyboard focus ring be drawn around a different
    /// rect than the selection. At the uncompressed width the bar sits at its
    /// intrinsic size and every segment rect is constant.
    ///
    /// This started at 550 pt when the sheet had four tabs and was never
    /// revisited as tabs were added; by eight tabs it was 122 pt short and every
    /// title truncated.
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
