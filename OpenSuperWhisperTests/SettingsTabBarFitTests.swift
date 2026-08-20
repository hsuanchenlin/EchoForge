import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The Settings tab bar has to fit the sheet it is drawn in, and has to hold
/// still while the user moves around it. Those are two separate problems with
/// two separate fixes, and this file measures both.
///
/// On macOS a SwiftUI `TabView` inside a sheet renders as one
/// `NSSegmentedControl` whose intrinsic width is the sum of its titles.
///
/// 1. **Too little room truncates every title.** The shipped 550 pt sheet gave
///    eight tabs 518 pt of a needed 640 and the app drew "Mo...", "St...",
///    "Cl...", "Ab...". `SettingsSheetLayout.preferredSize` is the fix, and the
///    first tests here are what watch it.
/// 2. **The displayed pane can resize the bar.** macOS lays the bar out from the
///    whole hosted view tree, and the pane on screen is part of that tree, so a
///    pane wider than the sheet makes the bar wider too and every segment rect
///    moves as the user changes tabs.
///
/// The second one used to be recorded here as a consequence of the first - as
/// something an uncompressed bar could not suffer from. That was wrong.
/// Measured at the shipped 680 pt width, a displayed pane 900 pt wide still
/// takes the bar from 648 pt to 657 pt, and the same pane on a tab that is not
/// showing changes nothing at all. Width buys untruncated titles and nothing
/// else; `settingsPane()` is what actually contains a pane, and
/// `testAWidePaneCannotResizeTheBar` is written so that it fails if that
/// modifier is removed.
///
/// What none of this establishes is that the keyboard focus ring and the
/// selection pill are drawn around the same rect. Constant segment geometry is a
/// precondition for that, not a proof of it; both are drawn by AppKit and the
/// only honest check is interactive, on a real Mac, with the bar focused. This
/// file deliberately claims the precondition and stops there.
///
/// Everything here is measured off a real `NSSegmentedControl` in a real view
/// tree, with no window and nothing on screen: an `NSHostingView` lays the bar
/// out on its own.
@MainActor
final class SettingsTabBarFitTests: XCTestCase {

    /// The bar is measured against **every** tab, not against
    /// `SettingsTab.visible`: an offline-only build drops the Cloud tab, and the
    /// narrower configuration cannot be what proves the shipped width is enough.
    private let tabs = SettingsTab.allCases

    /// Wider than the sheet by a margin no real pane would need, so that a bar
    /// which follows its pane cannot fail to show it.
    private let overWidePane: CGFloat = 900

    // MARK: - The headline

    func testTheTabTitlesFitTheShippedSheetWidth() throws {
        let bar = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)

        XCTAssertLessThanOrEqual(
            bar.intrinsicContentSize.width, bar.bounds.width,
            """
            The Settings tab titles no longer fit the sheet: the tab bar needs \
            \(bar.intrinsicContentSize.width) pt and has \(bar.bounds.width) pt. \
            They will truncate. Widen SettingsSheetLayout.preferredSize or \
            shorten a title in SettingsTab.
            """
        )
    }

    /// The slack, stated as a number so that shipping with two points to spare
    /// reads as the accident it would be.
    func testTheFitIsNotBalancedOnAKnifeEdge() throws {
        let bar = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)
        let slack = bar.bounds.width - bar.intrinsicContentSize.width

        XCTAssertGreaterThanOrEqual(
            slack, 4,
            "the tab bar fits by only \(slack) pt - the next tab or a slightly "
                + "longer title breaks it again")
    }

    /// The regression this replaces, kept as a live measurement rather than a
    /// comment: at the width the sheet used to ship, the same titles do not fit.
    /// If this ever stops failing to fit, the fit test above has stopped
    /// measuring anything.
    func testTheOldSheetWidthWouldStillNotFit() throws {
        let bar = try tabBar(inSheetOfWidth: 550)

        XCTAssertGreaterThan(
            bar.intrinsicContentSize.width, bar.bounds.width,
            "550 pt now fits eight tabs, so this test no longer proves the "
                + "fit test can fail")
    }

    // MARK: - What the user reads, and what VoiceOver reads

    func testEverySegmentCarriesItsFullTitle() throws {
        let bar = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)

        XCTAssertEqual(bar.segmentCount, tabs.count, "the tab bar lost or gained a tab")
        for (index, tab) in tabs.enumerated() {
            XCTAssertEqual(
                bar.label(forSegment: index), tab.title,
                "segment \(index) does not carry \(tab.title)")
        }
    }

    // MARK: - The bar must not follow the pane it is showing

    /// The headline of the second problem: with `settingsPane()` in place, no
    /// pane can move the bar, however wide it is and whichever tab it is on.
    ///
    /// Every combination is measured against the same baseline - the bar with no
    /// over-wide pane anywhere - so a failure names the case that moved it.
    func testAWidePaneCannotResizeTheBar() throws {
        let baseline = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width).bounds.width

        for paneWidth in [overWidePane, 2_000] as [CGFloat] {
            for paneIndex in [0, tabs.count - 1] {
                for selected in [0, tabs.count - 1] {
                    let bar = try tabBar(
                        inSheetOfWidth: SettingsSheetLayout.preferredSize.width,
                        paneContentWidth: paneWidth, paneOnTab: paneIndex, selecting: selected)

                    XCTAssertEqual(
                        bar.bounds.width, baseline, accuracy: 0.5,
                        """
                        A \(paneWidth) pt pane on tab \(paneIndex), with tab \
                        \(selected) showing, laid the tab bar out \
                        \(bar.bounds.width) pt wide instead of \(baseline). A bar \
                        whose width follows its pane has segment rects that move \
                        as the user changes tabs. settingsPane() is what prevents \
                        this.
                        """
                    )
                }
            }
        }
    }

    /// The control, and the reason the test above is worth anything: **without**
    /// `settingsPane()` the very same pane does move the bar, at the very same
    /// shipped width.
    ///
    /// This is what was measured wrong before. The sheet was widened to 680 pt
    /// and the pane feedback was written up as cured by it; it is not. If this
    /// test ever stops finding a difference - a macOS release that sizes the bar
    /// from the tab items alone, say - then the test above has stopped proving
    /// that the containment is load-bearing, and should be re-derived rather than
    /// trusted.
    func testWithoutContainmentTheShippedWidthDoesNotSaveTheBar() throws {
        let plain = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width, contained: false)
        let widePane = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width,
            paneContentWidth: overWidePane, contained: false)

        XCTAssertNotEqual(
            plain.bounds.width, widePane.bounds.width, accuracy: 0.5,
            """
            An uncontained \(overWidePane) pt pane no longer resizes the tab bar \
            at \(SettingsSheetLayout.preferredSize.width) pt, so \
            testAWidePaneCannotResizeTheBar is no longer measuring the \
            containment. Re-derive both before deleting either.
            """
        )
    }

    /// A pane only reaches the bar while it is the one on screen, which is what
    /// makes the symptom a moving one: the user changes tabs and the geometry
    /// changes under them. Pinned without the containment, because with it there
    /// is nothing to see.
    func testUncontainedItIsTheDisplayedPaneThatMovesTheBar() throws {
        let showingTheWidePane = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width,
            paneContentWidth: overWidePane, paneOnTab: 0, selecting: 0, contained: false)
        let showingAnotherPane = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width,
            paneContentWidth: overWidePane, paneOnTab: 0, selecting: tabs.count - 1,
            contained: false)

        XCTAssertNotEqual(
            showingTheWidePane.bounds.width, showingAnotherPane.bounds.width, accuracy: 0.5,
            "the same wide pane gave the same bar width whether or not it was the "
                + "pane on screen, so the feedback path being described has changed")
    }

    /// Containment must not cost anything on the shipped sheet: with no
    /// over-wide pane anywhere, the bar is laid out exactly as it was before the
    /// modifier existed, and the titles still fit.
    func testContainmentDoesNotChangeTheShippedLayout() throws {
        let contained = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)
        let uncontained = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width, contained: false)

        XCTAssertEqual(
            contained.bounds.width, uncontained.bounds.width, accuracy: 0.5,
            "settingsPane() changed the sheet's own layout, which it is not "
                + "supposed to do - it only keeps a pane from speaking for the bar")
        XCTAssertLessThanOrEqual(
            contained.intrinsicContentSize.width, contained.bounds.width,
            "the titles stopped fitting once the panes were contained")
    }

    // MARK: - Building the thing being measured

    /// `SettingsView`'s tab bar, in the geometry `SettingsView` gives it: the
    /// same tab items, the same `.settingsPane()`, the same `.padding()`, the
    /// same outer `.frame`.
    ///
    /// The panes are stand-ins rather than the real ones - constructing
    /// `SettingsView` would build a `SettingsViewModel`, a `PermissionsManager`
    /// and every pane's own state, none of which the tab bar's width depends on.
    /// `paneContentWidth` is how a pane's content is given a say, which is the
    /// one way a pane can reach the bar.
    ///
    /// - Parameters:
    ///   - paneContentWidth: the width of the one over-wide pane, or `nil` for a
    ///     sheet whose panes all sit inside it.
    ///   - paneOnTab: which tab that pane belongs to.
    ///   - selecting: which tab is showing, since only the displayed pane is part
    ///     of the layout the bar is sized from.
    ///   - contained: whether the panes carry `settingsPane()`, as `SettingsView`
    ///     applies it. `false` is for the control tests that show what it is for.
    private func tabBar(
        inSheetOfWidth width: CGFloat,
        paneContentWidth: CGFloat? = nil,
        paneOnTab: Int = 0,
        selecting: Int = 0,
        contained: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSSegmentedControl {
        let tabs = self.tabs
        let sheet = TabView(selection: .constant(tabs[selecting])) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                Pane(
                    width: index == paneOnTab ? paneContentWidth : nil,
                    contained: contained
                )
                .tabItem { tab.label }
                .tag(tab)
            }
        }
        .padding()
        .frame(width: width, height: SettingsSheetLayout.preferredSize.height)

        let hosting = NSHostingView(rootView: sheet)
        hosting.sizingOptions = []
        hosting.frame = CGRect(
            x: 0, y: 0, width: width, height: SettingsSheetLayout.preferredSize.height)
        hosting.layoutSubtreeIfNeeded()

        let bar = try XCTUnwrap(
            Self.firstSegmentedControl(in: hosting),
            "no NSSegmentedControl in the hosted tab view - macOS may have changed how a "
                + "SwiftUI TabView renders, and this test needs rewriting rather than deleting",
            file: file, line: line)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// One stand-in pane, optionally over-wide, optionally contained the way
    /// `SettingsView` contains the real ones.
    private struct Pane: View {
        let width: CGFloat?
        let contained: Bool

        var body: some View {
            let content = Color.clear.frame(width: width, height: width == nil ? nil : 1)
            if contained {
                content.settingsPane()
            } else {
                content
            }
        }
    }

    private static func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let bar = view as? NSSegmentedControl { return bar }
        for subview in view.subviews {
            if let bar = firstSegmentedControl(in: subview) { return bar }
        }
        return nil
    }
}
