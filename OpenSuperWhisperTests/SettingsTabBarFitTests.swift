import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The Settings tab bar has to fit the sheet it is drawn in.
///
/// It is one row of titles, so what it needs is the sum of them, and the sheet's
/// width and the tab titles are therefore a single decision. The shipped 550 pt
/// sheet gave eight tabs 518 pt of a needed 640 and the app drew "Mo...",
/// "St...", "Cl...", "Ab..."; `SettingsSheetLayout.preferredSize` is the fix and
/// this file is what watches it. Add a tab or lengthen a title without widening
/// the sheet and this says so, at test time.
///
/// Two things this file used to claim and no longer does. It measured an
/// `NSSegmentedControl`, because a SwiftUI `TabView` in a sheet rendered the tabs
/// as one; the bar is now EchoForge's own view (`SettingsTabBar`). And it
/// recorded the width as also settling the keyboard focus ring, which was never
/// true - measured at 680 pt, AppKit still drew that ring about six points wider
/// than the selected segment. The ring is fixed by owning the bar, and
/// `SettingsTabBarGeometryTests` measures it.
///
/// Everything here is measured off a real view tree with no window and nothing
/// on screen: an `NSHostingView` lays the bar out on its own.
@MainActor
final class SettingsTabBarFitTests: XCTestCase {

    /// The bar is measured against **every** tab, not against
    /// `SettingsTab.visible`: an offline-only build drops the Cloud tab, and the
    /// narrower configuration cannot be what proves the shipped width is enough.
    private let tabs = SettingsTab.allCases

    // MARK: - The headline

    func testTheTabTitlesFitTheShippedSheetWidth() {
        let needed = widthNeededByTheBar()
        let available = SettingsSheetLayout.contentWidth(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width)

        XCTAssertLessThanOrEqual(
            needed, available,
            """
            The Settings tab titles no longer fit the sheet: the tab bar needs \
            \(needed) pt and has \(available) pt. They will truncate. Widen \
            SettingsSheetLayout.preferredSize or shorten a title in SettingsTab.
            """
        )
    }

    /// The slack, stated as a number so that shipping with two points to spare
    /// reads as the accident it would be.
    func testTheFitIsNotBalancedOnAKnifeEdge() {
        let slack =
            SettingsSheetLayout.contentWidth(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)
            - widthNeededByTheBar()

        XCTAssertGreaterThanOrEqual(
            slack, 4,
            "the tab bar fits by only \(slack) pt - the next tab or a slightly "
                + "longer title breaks it again")
    }

    /// The regression this replaces, kept as a live measurement rather than a
    /// comment: at the width the sheet used to ship, the same titles do not fit.
    /// If this ever stops failing to fit, the fit test above has stopped
    /// measuring anything.
    func testTheOldSheetWidthWouldStillNotFit() {
        XCTAssertGreaterThan(
            widthNeededByTheBar(), SettingsSheetLayout.contentWidth(inSheetOfWidth: 550),
            "550 pt now fits eight tabs, so this test no longer proves the fit "
                + "test can fail")
    }

    /// The bar is as tall as it says it is, which is what the sheet's remaining
    /// room is calculated from.
    func testTheBarIsTheHeightItsMetricsClaim() {
        let hosting = NSHostingView(rootView: bar())

        XCTAssertEqual(
            hosting.fittingSize.height, SettingsTabBarMetrics.standard.height, accuracy: 0.5,
            "the tab bar is \(hosting.fittingSize.height) pt tall, not the "
                + "\(SettingsTabBarMetrics.standard.height) pt its metrics claim")
    }

    /// Dropping the Cloud tab, as an offline-only build does, cannot make the
    /// bar need more room. Cheap, and it pins that the bar is drawn from the list
    /// it is handed rather than from `allCases`.
    func testAnOfflineOnlyBuildNeedsNoMoreRoom() {
        let offline = NSHostingView(rootView: bar(tabs: tabs.filter { $0 != .cloud }))

        XCTAssertLessThan(
            offline.fittingSize.width, widthNeededByTheBar(),
            "a build with one tab fewer wants at least as much room as the full "
                + "one, so the bar is not being drawn from the list it is given")
    }

    // MARK: - Building the thing being measured

    private func bar(tabs: [SettingsTab]? = nil) -> SettingsTabBarRow {
        SettingsTabBarRow(
            tabs: tabs ?? self.tabs,
            selection: (tabs ?? self.tabs)[0],
            focusedTab: nil,
            select: { _ in }
        )
    }

    /// What the bar asks for when nothing is squeezing it: the sum of the
    /// titles, their padding and the hairlines between them.
    private func widthNeededByTheBar() -> CGFloat {
        NSHostingView(rootView: bar()).fittingSize.width
    }
}
