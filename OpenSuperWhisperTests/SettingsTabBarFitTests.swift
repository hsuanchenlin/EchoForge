import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The Settings tab bar has to fit the sheet it is drawn in.
///
/// On macOS a SwiftUI `TabView` inside a sheet renders as one
/// `NSSegmentedControl` whose intrinsic width is the sum of its titles. Give it
/// less room than that and AppKit compresses it, which costs two things at once:
///
/// 1. **Every title truncates.** The shipped 550 pt sheet gave eight tabs 518 pt
///    of a needed 640 and the app drew "Mo...", "St...", "Cl...", "Ab...".
/// 2. **Segment rects stop being constant.** A compressed bar's width follows
///    the *displayed* pane's content, so segment geometry changes as the user
///    moves between tabs. That is what let the keyboard focus ring be drawn
///    around a 75.5 pt rect while the selection pill was drawn around the 64 pt
///    rect it actually belongs to - the two were derived from different layouts
///    of the same control.
///
/// Both are one number, and this is the test that watches it. It would have
/// failed the day the sheet reached six tabs.
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

    // MARK: - The headline

    func testTheTabTitlesFitTheShippedSheetWidth() throws {
        let bar = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)

        XCTAssertLessThanOrEqual(
            bar.intrinsicContentSize.width, bar.bounds.width,
            """
            The Settings tab titles no longer fit the sheet: the tab bar needs \
            \(bar.intrinsicContentSize.width) pt and has \(bar.bounds.width) pt. \
            They will truncate, and the keyboard focus ring will stop matching \
            the selected tab. Widen SettingsSheetLayout.preferredSize or shorten \
            a title in SettingsTab.
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

    // MARK: - Why the focus ring and the selection agreed again

    /// The bar's geometry must not depend on which pane is showing.
    ///
    /// Measured on the shipped 550 pt sheet: a 570 pt-wide element in the
    /// *displayed* pane laid the tab bar out 608 pt wide instead of 518, and
    /// segment 0 went from 64.0 pt to 75.5 pt. Moving between panes therefore
    /// moved every segment, and a focus ring drawn from one layout landed on a
    /// pill drawn from another. At an uncompressed width the bar sits at the
    /// sheet's width whatever the pane does, so the segments hold still.
    func testTheBarIsNotResizedByThePaneItIsShowing() throws {
        let plain = try tabBar(inSheetOfWidth: SettingsSheetLayout.preferredSize.width)
        let withWidePane = try tabBar(
            inSheetOfWidth: SettingsSheetLayout.preferredSize.width, paneContentWidth: 570)

        XCTAssertEqual(
            plain.bounds.width, withWidePane.bounds.width, accuracy: 0.5,
            """
            The tab bar is \(withWidePane.bounds.width) pt wide with a wide pane \
            showing and \(plain.bounds.width) pt without one. A bar whose width \
            follows its pane has segment rects that move as the user changes \
            tabs, which is how the focus ring and the selection come apart.
            """
        )
        XCTAssertLessThanOrEqual(
            withWidePane.intrinsicContentSize.width, withWidePane.bounds.width,
            "the titles stopped fitting once a pane had real content in it")
    }

    // MARK: - Building the thing being measured

    /// `SettingsView`'s tab bar, in the geometry `SettingsView` gives it: the
    /// same tab items, the same `.padding()`, the same outer `.frame`.
    ///
    /// The panes are stand-ins rather than the real ones - constructing
    /// `SettingsView` would build a `SettingsViewModel`, a `PermissionsManager`
    /// and every pane's own state, none of which the tab bar's width depends on.
    /// `paneContentWidth` is how a pane's content is given a say, which is the
    /// one way a pane can reach the bar.
    private func tabBar(
        inSheetOfWidth width: CGFloat,
        paneContentWidth: CGFloat? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSSegmentedControl {
        let sheet = TabView {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                Color.clear
                    .frame(
                        width: index == 0 ? paneContentWidth : nil,
                        height: paneContentWidth == nil ? nil : 1)
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

    private static func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let bar = view as? NSSegmentedControl { return bar }
        for subview in view.subviews {
            if let bar = firstSegmentedControl(in: subview) { return bar }
        }
        return nil
    }
}
