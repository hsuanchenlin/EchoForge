import AppKit
import SwiftUI

/// The Settings sheet's tab bar, drawn by this app instead of by AppKit.
///
/// **Why this exists.** A SwiftUI `TabView` in a sheet renders its tabs as one
/// `NSSegmentedControl`, and on macOS 26 that control draws its selection and
/// its keyboard focus ring from two different pieces of geometry. Measured on
/// the shipped sheet, the selection pill sat exactly on the selected segment's
/// rect and the focus ring around it was about six points wider on the right -
/// a visible strip of bar background inside the ring, on every tab, at two
/// different sheet widths. Widening the sheet did not fix it (0.8.2 shipped an
/// uncompressed bar and the ring was still wrong); nothing above the control
/// could, because both rects are produced inside AppKit.
///
/// **What replaces it.** One frame per tab, and everything the user can see or
/// hit derived from that same frame:
///
/// - the tab's own bounds are the frame;
/// - the selection fill is that frame's rounded rect;
/// - the keyboard focus frame is that frame outset by
///   `SettingsTabBarMetrics.focusRingOutset` on all four sides;
/// - the hit target is that frame, exactly (`contentShape(Rectangle())`).
///
/// They cannot disagree, because there is nothing for them to disagree about:
/// SwiftUI lays the tab out once and the fill, the ring and the hit shape are
/// the background, the overlay and the content shape of that one view.
/// `SettingsTabBarGeometryTests` reads the concentricity back out of rendered
/// pixels rather than trusting that sentence.
///
/// **What is deliberately kept.** The bar is one stop in the key-view loop, the
/// way the segmented control was: left and right arrows move the selection
/// (`SettingsTabBarKeyboard`), and the focus frame is drawn around the selected
/// tab. Each tab is its own accessibility element carrying its full title and,
/// when it is the one showing, the selected trait. `focusEffectDisabled()`
/// turns off SwiftUI's *own* focus effect - the ring below replaces it, and is
/// the whole point; nothing here removes the affordance.
struct SettingsTabBar: View {

    @Binding var selection: SettingsTab

    /// The tabs to draw. Defaults to the ones this build ships, which is what
    /// `SettingsView` wants; the tests pass their own list.
    var tabs: [SettingsTab] = SettingsTab.visible

    var metrics: SettingsTabBarMetrics = .standard
    var palette: SettingsTabBarPalette = .standard

    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsTabBarRow(
            tabs: tabs,
            selection: selection,
            // The focus frame belongs to the selected tab, because that is what
            // an arrow key would move: the bar takes focus as a whole, the way
            // the segmented control it replaces did.
            focusedTab: isFocused ? selection : nil,
            metrics: metrics,
            palette: palette,
            select: { tab in
                // A click is how the segmented control became first responder,
                // so a following arrow key moved the tab rather than whatever
                // in the pane last held focus. Match that.
                selection = tab
                isFocused = true
            }
        )
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            if let next = SettingsTabBarKeyboard.tab(in: tabs, after: selection, moving: direction) {
                selection = next
            }
        }
        .accessibilityLabel("Settings tabs")
    }
}

// MARK: - The bar as it is drawn

/// The tab bar with no state of its own: what it shows is entirely its
/// arguments.
///
/// `SettingsTabBar` owns the focus state and hands the result down as
/// `focusedTab`. Keeping the drawing free of `@FocusState` is what lets a test
/// render the focused bar offscreen - a focus ring that only exists in a key
/// window is exactly what could not be measured about AppKit's.
struct SettingsTabBarRow: View {

    let tabs: [SettingsTab]
    let selection: SettingsTab

    /// The tab to draw the keyboard focus frame around, or `nil` when the bar
    /// does not have keyboard focus.
    let focusedTab: SettingsTab?

    var metrics: SettingsTabBarMetrics = .standard
    var palette: SettingsTabBarPalette = .standard
    let select: (SettingsTab) -> Void

    /// A background window's selection is grey and shows no focus ring, the way
    /// every other macOS control behaves.
    @Environment(\.controlActiveState) private var activeState

    @State private var hovered: SettingsTab?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                if index > 0 {
                    divider(between: tabs[index - 1], and: tab)
                }
                item(tab)
            }
        }
        .frame(height: metrics.height)
        .background(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(palette.track)
        )
        .accessibilityElement(children: .contain)
    }

    /// One tab. Every rect the user can see or click comes from this view's own
    /// frame - see the type's documentation.
    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Text(tab.title)
            .font(metrics.titleFont)
            .foregroundStyle(titleColor(selected: isSelected))
            .lineLimit(1)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.height)
            .background { fill(for: tab, isSelected: isSelected) }
            .overlay { focusRing(around: tab) }
            // The whole frame, not the rounded rect: a segment's corners are
            // clickable on the control this replaces, and a hit target that
            // stops at the fill's curve is a target that misses.
            .contentShape(Rectangle())
            .onTapGesture { select(tab) }
            .onHover { inside in
                if inside {
                    hovered = tab
                } else if hovered == tab {
                    hovered = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(tab) }
            // The focus frame reaches outside the tab it belongs to, so the
            // selected tab is drawn last and nothing paints over its ring.
            .zIndex(isSelected ? 1 : 0)
    }

    @ViewBuilder private func fill(for tab: SettingsTab, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        if isSelected {
            shape.fill(isEmphasized ? palette.selectionFill : palette.unemphasizedSelectionFill)
        } else if hovered == tab {
            shape.fill(palette.hover)
        }
    }

    /// The keyboard focus frame: the tab's frame, grown by the same amount on
    /// every side, with a corner radius grown to match so the two curves stay
    /// concentric rather than merely parallel.
    @ViewBuilder private func focusRing(around tab: SettingsTab) -> some View {
        if tab == focusedTab, isEmphasized {
            RoundedRectangle(cornerRadius: metrics.focusRingCornerRadius, style: .continuous)
                .strokeBorder(palette.focusRing, lineWidth: metrics.focusRingWidth)
                .padding(-metrics.focusRingOutset)
        }
    }

    /// The hairline between two tabs, which macOS hides next to the selected
    /// one. Drawing it as a fixed-width element rather than as an overlay is
    /// what keeps every tab's frame the same whichever tab is selected.
    private func divider(between left: SettingsTab, and right: SettingsTab) -> some View {
        let touchesHighlight = [left, right].contains { $0 == selection || $0 == hovered }
        return Rectangle()
            .fill(touchesHighlight ? Color.clear : palette.divider)
            .frame(width: metrics.dividerWidth, height: metrics.dividerHeight)
    }

    private func titleColor(selected: Bool) -> Color {
        selected && isEmphasized ? palette.selectedTitle : palette.title
    }

    private var isEmphasized: Bool { activeState == .key }
}

// MARK: - Geometry

/// Every measurement the tab bar draws with.
///
/// The two that carry the fix are `focusRingOutset` and `focusRingWidth`: the
/// focus frame is the selected tab's frame grown by the outset, and the stroke
/// is drawn inwards from there, so the halo sits entirely outside the fill and
/// is the same thickness on all four sides.
struct SettingsTabBarMetrics: Equatable {

    /// The bar's height, which is also every tab's height. 24 pt is what the
    /// segmented control this replaces was laid out at, so the sheet below the
    /// bar keeps the room it had.
    var height: CGFloat = 24

    var cornerRadius: CGFloat = 6

    /// Room either side of a title. 10 pt is what macOS gives a segment of this
    /// control at this text size, so the eight titles need about as much of the
    /// sheet as they did before.
    var horizontalPadding: CGFloat = 10

    var titleSize: CGFloat = 13

    var dividerWidth: CGFloat = 1
    var dividerHeight: CGFloat = 14

    /// How far outside the selected tab's frame the focus frame is drawn.
    var focusRingOutset: CGFloat = 3

    /// The focus frame's stroke. Equal to the outset, so the halo's inner edge
    /// lands on the tab's frame: the ring surrounds the fill instead of
    /// overlapping it.
    var focusRingWidth: CGFloat = 3

    static let standard = SettingsTabBarMetrics()

    var focusRingCornerRadius: CGFloat { cornerRadius + focusRingOutset }

    var titleFont: Font { .system(size: titleSize) }
}

/// Every colour the tab bar draws with.
///
/// Gathered into a value for two reasons: so the appearance is stated in one
/// place rather than scattered through the view, and so a test can render the
/// bar in flat, unmistakable colours and measure the geometry without depending
/// on which accent colour the machine running it happens to use.
struct SettingsTabBarPalette {

    var track: Color
    var divider: Color

    /// The selected tab in a key window, and in any other window.
    var selectionFill: Color
    var unemphasizedSelectionFill: Color

    var selectedTitle: Color
    var title: Color
    var hover: Color
    var focusRing: Color

    /// The shipped colours, matched against a render of the segmented control
    /// this replaces: a track a shade darker than the sheet, a hairline between
    /// tabs, and the accent colour under the selected title. The opacities are
    /// what put the track and the divider on the greys that control drew
    /// (rgb 235 and rgb 212 on a white sheet), in both appearances.
    static let standard = SettingsTabBarPalette(
        track: Color.primary.opacity(0.09),
        divider: Color(nsColor: .separatorColor),
        selectionFill: .accentColor,
        unemphasizedSelectionFill: Color.primary.opacity(0.14),
        selectedTitle: Color(nsColor: .alternateSelectedControlTextColor),
        title: Color(nsColor: .labelColor),
        hover: Color.primary.opacity(0.06),
        focusRing: Color(nsColor: .keyboardFocusIndicatorColor)
    )
}

// MARK: - Keyboard

/// Which tab an arrow key lands on, as a pure function so it can be tested
/// without a key window.
///
/// The bar is a single focus stop and the arrows move the selection inside it,
/// which is how the segmented control this replaces behaved. They **clamp**:
/// the first tab's left arrow and the last tab's right arrow do nothing, so a
/// user holding an arrow key down stops at the end of the row instead of
/// cycling past it.
enum SettingsTabBarKeyboard {

    static func tab(
        in tabs: [SettingsTab], after current: SettingsTab, moving direction: MoveCommandDirection
    ) -> SettingsTab? {
        guard let index = tabs.firstIndex(of: current) else { return nil }
        switch direction {
        case .left:
            return index > 0 ? tabs[index - 1] : nil
        case .right:
            return index + 1 < tabs.count ? tabs[index + 1] : nil
        default:
            // Up and down belong to whatever the pane below is doing.
            return nil
        }
    }
}
