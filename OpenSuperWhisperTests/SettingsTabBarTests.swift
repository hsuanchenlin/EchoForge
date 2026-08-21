import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// What the owned tab bar promises apart from its rects: that a keyboard can
/// still drive it, and that replacing AppKit's control did not quietly drop the
/// affordances AppKit gave for free.
///
/// The rects themselves are measured in `SettingsTabBarGeometryTests`, and how
/// much of the sheet the titles need in `SettingsTabBarFitTests`.
@MainActor
final class SettingsTabBarTests: XCTestCase {

    private let tabs = SettingsTab.allCases

    // MARK: - Arrow keys

    /// The bar is one stop in the key-view loop and the arrows move the
    /// selection inside it, which is how the segmented control behaved.
    func testTheArrowKeysWalkTheWholeRow() throws {
        var tab = tabs[0]
        for expected in tabs.dropFirst() {
            let next = try XCTUnwrap(
                SettingsTabBarKeyboard.tab(in: tabs, after: tab, moving: .right),
                "the right arrow stopped before \(expected.title)")
            XCTAssertEqual(next, expected, "the right arrow did not reach \(expected.title)")
            tab = next
        }
        for expected in tabs.dropLast().reversed() {
            let previous = try XCTUnwrap(
                SettingsTabBarKeyboard.tab(in: tabs, after: tab, moving: .left),
                "the left arrow stopped before \(expected.title)")
            XCTAssertEqual(previous, expected, "the left arrow did not reach \(expected.title)")
            tab = previous
        }
    }

    /// They clamp rather than wrap: holding an arrow key down stops at the end
    /// of the row instead of cycling back through every pane.
    func testTheArrowKeysStopAtTheEndsOfTheRow() {
        XCTAssertNil(
            SettingsTabBarKeyboard.tab(in: tabs, after: tabs.first!, moving: .left),
            "the left arrow wrapped around from the first tab")
        XCTAssertNil(
            SettingsTabBarKeyboard.tab(in: tabs, after: tabs.last!, moving: .right),
            "the right arrow wrapped around from the last tab")
    }

    /// Up and down belong to whatever the pane below is doing - a list, a scroll
    /// view - so the bar leaves them alone.
    func testUpAndDownDoNotChangeTheTab() {
        for direction in [MoveCommandDirection.up, .down] {
            XCTAssertNil(
                SettingsTabBarKeyboard.tab(in: tabs, after: .transcription, moving: direction),
                "\(direction) moved the Settings tab")
        }
    }

    /// An offline-only build drops the Cloud tab, and the arrows have to walk
    /// the row that build actually shows rather than the full list.
    func testTheArrowKeysSkipATabThisBuildDoesNotShow() {
        let visible = tabs.filter { $0 != .cloud }

        XCTAssertEqual(
            SettingsTabBarKeyboard.tab(in: visible, after: .advanced, moving: .right), .about,
            "the right arrow landed on a tab this build does not draw")
        XCTAssertNil(
            SettingsTabBarKeyboard.tab(in: visible, after: .cloud, moving: .right),
            "a tab that is not in the row is not somewhere the arrows can move from")
    }

    // MARK: - The geometry contract, as numbers

    /// The two metrics that carry the fix, stated as a relationship rather than
    /// as two constants that happen to agree today.
    func testTheFocusFrameSurroundsTheSelectionRatherThanOverlappingIt() {
        let metrics = SettingsTabBarMetrics.standard

        XCTAssertEqual(
            metrics.focusRingWidth, metrics.focusRingOutset,
            "the focus frame's stroke and its outset have to match, or the halo "
                + "either overlaps the selection or leaves a gap inside itself")
        XCTAssertEqual(
            metrics.focusRingCornerRadius, metrics.cornerRadius + metrics.focusRingOutset,
            "the focus frame's corners have to grow with its outset, or the two "
                + "curves are parallel but not concentric")
        XCTAssertGreaterThan(metrics.focusRingOutset, 0, "a focus frame has to be visible")
    }

    /// The sheet has to leave the focus frame room. This is the number that
    /// would have been silently wrong if the gap under the bar were tightened.
    func testTheSheetLeavesRoomUnderTheBarForTheFocusFrame() {
        XCTAssertGreaterThanOrEqual(
            SettingsSheetLayout.tabBarToPaneSpacing,
            SettingsTabBarMetrics.standard.focusRingOutset,
            "the pane starts closer to the tab bar than the focus frame reaches, "
                + "so the halo runs into the pane's edge")
    }

    // MARK: - What VoiceOver and the pointer get

    /// Every tab carries its own, full title - the thing a screen reader reads
    /// and the thing the fit test measures - and nothing shortens it for the
    /// bar's benefit.
    func testEveryTabHasAFullTitleOfItsOwn() {
        XCTAssertEqual(SettingsTab.allCases.count, 8, "a tab was added or removed")
        for tab in tabs {
            XCTAssertFalse(tab.title.isEmpty, "a tab with no title cannot be read out")
            XCTAssertFalse(
                tab.title.hasSuffix("…") || tab.title.hasSuffix("..."),
                "\(tab.title) is already truncated in the model")
        }
        XCTAssertEqual(
            Set(tabs.map(\.title)).count, tabs.count, "two tabs share a title")
    }

    /// The affordances that came free with `NSSegmentedControl` and now have to
    /// be written down, checked at the source because there is no offscreen
    /// accessibility tree to read them out of: a hosted SwiftUI view builds its
    /// accessibility elements only for a real client.
    ///
    /// The pairing that matters most is the last one. `focusEffectDisabled()`
    /// switches off SwiftUI's own focus ring, and on its own that is exactly the
    /// "fix" this work is not allowed to be - a bar with no keyboard focus
    /// affordance at all. It is only acceptable because the bar draws its own,
    /// so the two have to appear together.
    func testTheBarKeepsTheAffordancesTheSegmentedControlHad() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenSuperWhisper/SettingsTabBar.swift"),
            encoding: .utf8)

        for required in [
            // The title a screen reader reads, per tab.
            ".accessibilityLabel(tab.title)",
            // Which one is showing, per tab.
            ".isSelected",
            // A tab is something you activate, and VoiceOver has to be able to.
            ".accessibilityAction",
            // One stop in the key-view loop, and the arrows inside it.
            ".focusable()",
            ".onMoveCommand",
            // The whole frame is the hit target, not the drawn curve.
            ".contentShape(Rectangle())",
        ] {
            XCTAssertTrue(
                source.contains(required),
                "SettingsTabBar no longer carries \(required), which is one of the "
                    + "things AppKit's segmented control gave the Settings sheet for free")
        }

        XCTAssertTrue(
            source.contains(".focusEffectDisabled()"),
            "the bar no longer switches off SwiftUI's own focus effect, so two "
                + "focus rings are drawn around the same tab")
        XCTAssertTrue(
            source.contains("strokeBorder(palette.focusRing"),
            "the bar disables the system focus effect without drawing its own "
                + "focus frame, which would leave the sheet with no keyboard focus "
                + "affordance at all")
    }
}
