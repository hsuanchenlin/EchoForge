import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The defect this file exists for: the Settings tab bar drew its keyboard focus
/// ring around a different rect than its selection.
///
/// AppKit's segmented control did that and could not be talked out of it - the
/// ring came out about six points wider than the selected segment, at two
/// different sheet widths, on every tab, and both rects were produced inside
/// macOS. `SettingsTabBar` replaces it with one frame per tab, so the fill and
/// the focus frame are the background and the overlay of a single view.
///
/// That claim is worth exactly as much as a measurement of it, so this file
/// measures it: the bar is rendered offscreen and the two rects are read back
/// out of the pixels. Rendering is what makes it possible at all - a focus ring
/// drawn by AppKit only exists in a key window on a real screen, which is
/// precisely why nobody could pin the old one; this ring is an ordinary overlay
/// in the view tree, so `cacheDisplay` sees it with no window on screen, no
/// permissions, and nothing flashing on a developer's display.
///
/// The bar is drawn in flat, unmistakable colours (`Self.flat`) rather than the
/// shipped palette. The geometry is what is under test; using primary colours
/// keeps the measurement from depending on which accent colour the machine
/// running the tests happens to be set to.
///
/// Every render is written to `/tmp/EchoForgeSettingsTabBarRenders/` for a human
/// to open, the same way `EngineSwitchHUDRenderTests` leaves its pills there.
@MainActor
final class SettingsTabBarGeometryTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeSettingsTabBarRenders", isDirectory: true)

    private let metrics = SettingsTabBarMetrics.standard
    private let tabs = SettingsTab.allCases

    /// Half a point either way. The rects are read off a bitmap, so a boundary
    /// can land on either side of a pixel; anything larger than this is a real
    /// disagreement rather than rounding.
    private let tolerance: CGFloat = 0.75

    // MARK: - The headline

    /// The focus frame is the selected tab's frame grown by the same amount on
    /// all four sides - on **every** tab, including the two at the ends of the
    /// row, where the old control was furthest out.
    func testTheFocusFrameIsConcentricWithTheSelectionOnEveryTab() throws {
        for tab in tabs {
            let render = try render(selecting: tab, focused: true, named: "focus-\(tab.title)")
            let fill = try XCTUnwrap(
                render.box(of: .fill), "no selection fill drawn for \(tab.title)")
            let ring = try XCTUnwrap(
                render.box(of: .focusRing), "no focus frame drawn for \(tab.title)")

            let outsets = [
                ("left", fill.minX - ring.minX),
                ("right", ring.maxX - fill.maxX),
                ("top", fill.minY - ring.minY),
                ("bottom", ring.maxY - fill.maxY),
            ]
            for (side, outset) in outsets {
                XCTAssertEqual(
                    outset, metrics.focusRingOutset, accuracy: tolerance,
                    """
                    On the \(tab.title) tab the focus frame stands \(outset) pt \
                    outside the selection on the \(side), not \
                    \(metrics.focusRingOutset) pt. Selection \(fill), focus frame \
                    \(ring). This is the defect the owned tab bar exists to fix - \
                    see SettingsTabBar.
                    """)
            }
        }
    }

    /// The other half of "concentric": the halo has to be the same thickness all
    /// the way round, and has to sit **outside** the fill rather than over it.
    /// Measured as the run of ring pixels immediately beside the fill, on all
    /// four sides of one tab.
    func testTheFocusFrameIsOneEvenHaloOutsideTheSelection() throws {
        let render = try render(selecting: .transcription, focused: true, named: "halo")
        let fill = try XCTUnwrap(render.box(of: .fill))

        let midY = fill.midY
        let midX = fill.midX
        let runs = [
            ("left", render.run(of: .focusRing, from: CGPoint(x: fill.minX - 0.5, y: midY), towards: .minusX)),
            ("right", render.run(of: .focusRing, from: CGPoint(x: fill.maxX + 0.5, y: midY), towards: .plusX)),
            ("top", render.run(of: .focusRing, from: CGPoint(x: midX, y: fill.minY - 0.5), towards: .minusY)),
            ("bottom", render.run(of: .focusRing, from: CGPoint(x: midX, y: fill.maxY + 0.5), towards: .plusY)),
        ]

        for (side, thickness) in runs {
            XCTAssertEqual(
                thickness, metrics.focusRingWidth, accuracy: tolerance,
                "the focus frame is \(thickness) pt thick on the \(side), not "
                    + "\(metrics.focusRingWidth) pt - the halo is uneven, or it is "
                    + "overlapping the selection instead of surrounding it")
        }
    }

    /// The selection follows the selected tab, left to right, and every tab is a
    /// different rect. Cheap, and it is what makes the concentricity test above
    /// mean something: a bar that drew the same rect whatever was selected would
    /// pass that one.
    func testTheSelectionSitsOnTheSelectedTab() throws {
        var previous: CGRect?
        for tab in tabs {
            let render = try render(selecting: tab, focused: false, named: "selection-\(tab.title)")
            let fill = try XCTUnwrap(
                render.box(of: .fill), "no selection fill drawn for \(tab.title)")

            XCTAssertEqual(
                fill.height, metrics.height, accuracy: tolerance,
                "the selection on \(tab.title) is \(fill.height) pt tall, not the "
                    + "bar's \(metrics.height) pt")
            if let previous {
                XCTAssertGreaterThan(
                    fill.minX, previous.minX,
                    "the selection did not move right when the tab after "
                        + "\(previous) was selected")
            }
            previous = fill
        }
    }

    // MARK: - Focus is drawn, and only when there is focus

    func testThereIsNoFocusFrameWithoutKeyboardFocus() throws {
        let render = try render(selecting: .transcription, focused: false, named: "unfocused")

        XCTAssertNotNil(render.box(of: .fill), "the unfocused bar lost its selection too")
        XCTAssertNil(
            render.box(of: .focusRing),
            "a focus frame is drawn around a bar that does not have keyboard focus")
    }

    /// A background window shows no focus ring and an unemphasised selection,
    /// the way every other macOS control behaves.
    func testABackgroundWindowShowsNoFocusFrame() throws {
        let render = try render(
            selecting: .transcription, focused: true, active: .inactive, named: "inactive")

        XCTAssertNil(
            render.box(of: .focusRing),
            "the tab bar keeps drawing a keyboard focus frame in a window that is "
                + "not key")
    }

    // MARK: - In the sheet the bar actually ships in

    /// The focus frame reaches outside the bar, so the sheet has to leave it
    /// room: rendered inside the real sheet geometry, the first and last tabs'
    /// frames are still whole and still concentric.
    ///
    /// This is the case a clip would break - `settingsPane()` is deliberately not
    /// `clipped()` for the same reason - and the case that a bar laid out hard
    /// against the sheet's padding would cut in half.
    func testTheFocusFrameIsNotClippedByTheSheet() throws {
        for tab in [tabs.first!, tabs.last!] {
            let render = try renderSheet(selecting: tab, named: "sheet-\(tab.title)")
            let fill = try XCTUnwrap(render.box(of: .fill), "no selection in the sheet render")
            let ring = try XCTUnwrap(render.box(of: .focusRing), "no focus frame in the sheet render")

            XCTAssertEqual(
                fill.minX - ring.minX, metrics.focusRingOutset, accuracy: tolerance,
                "in the sheet, the \(tab.title) tab's focus frame is cut off on the left")
            XCTAssertEqual(
                ring.maxX - fill.maxX, metrics.focusRingOutset, accuracy: tolerance,
                "in the sheet, the \(tab.title) tab's focus frame is cut off on the right")
            XCTAssertEqual(
                ring.height, metrics.height + 2 * metrics.focusRingOutset, accuracy: tolerance,
                "in the sheet, the \(tab.title) tab's focus frame is \(ring.height) pt "
                    + "tall - something above or below the bar is trimming it")
        }
    }

    /// Nothing the pane does moves the bar.
    ///
    /// The control this replaces was not like that: macOS sized a `TabView`'s
    /// tab bar from the whole hosted view tree, the displayed pane included, so
    /// at this very sheet width a 900 pt pane took the bar from 648 pt to 657 pt
    /// and every segment rect moved as the user changed tabs. `SettingsTabBar`
    /// is a sibling of the pane with a width of its own, so it cannot.
    ///
    /// Asserted as pixels rather than as a width, because that is the whole
    /// claim: not one dot of the bar changes.
    func testAWidePaneDoesNotMoveASinglePixelOfTheBar() throws {
        let baseline = try renderSheet(selecting: .transcription, named: "pane-baseline")

        for paneWidth in [900, 2_000] as [CGFloat] {
            for contained in [true, false] {
                let render = try renderSheet(
                    selecting: .transcription, paneContentWidth: paneWidth, contained: contained,
                    named: "pane-\(Int(paneWidth))-\(contained ? "contained" : "loose")")

                XCTAssertEqual(
                    render.pixels, baseline.pixels,
                    """
                    A \(paneWidth) pt pane\
                    \(contained ? "" : ", uncontained,") changed what the tab \
                    bar draws. A bar whose geometry follows its pane has tab \
                    rects that move as the user changes tabs, which is exactly \
                    what the owned bar exists to make impossible.
                    """)
            }
        }
    }

    // MARK: - Rendering

    private enum Ink {
        case fill
        case focusRing

        /// The flat colours below are far enough apart that a channel test is
        /// enough, and antialiased edge pixels are excluded rather than
        /// half-counted.
        func matches(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
            switch self {
            case .fill: return red > 180 && green < 80 && blue < 80
            case .focusRing: return green > 180 && red < 80 && blue < 80
            }
        }
    }

    /// The shipped palette with the three colours this file measures replaced by
    /// flat primaries. Every measurement below is of a rect, never of a colour,
    /// so the substitution costs the tests nothing and buys them independence
    /// from the machine's accent colour.
    private static let flat = SettingsTabBarPalette(
        track: .white,
        divider: .black,
        selectionFill: Color(red: 1, green: 0, blue: 0),
        unemphasizedSelectionFill: Color(red: 1, green: 0, blue: 0),
        selectedTitle: .white,
        title: .black,
        hover: .white,
        focusRing: Color(red: 0, green: 1, blue: 0)
    )

    private func render(
        selecting tab: SettingsTab, focused: Bool, active: ControlActiveState = .key,
        named name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Render {
        let bar = SettingsTabBarRow(
            tabs: tabs,
            selection: tab,
            focusedTab: focused ? tab : nil,
            metrics: metrics,
            palette: Self.flat,
            select: { _ in }
        )
        // Room around the bar so the focus frame is inside the bitmap rather
        // than against its edge, where it could not be told from a clipped one.
        .padding(2 * metrics.focusRingOutset)
        .background(Color.white)
        .environment(\.controlActiveState, active)

        return try Render(of: bar, named: name, file: file, line: line)
    }

    /// The bar in the geometry `SettingsView` gives it: the same spacing, the
    /// same `.padding()`, the same sheet width, with a stand-in for the pane.
    private func renderSheet(
        selecting tab: SettingsTab, paneContentWidth: CGFloat? = nil, contained: Bool = true,
        named name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Render {
        let sheet = VStack(spacing: SettingsSheetLayout.tabBarToPaneSpacing) {
            SettingsTabBarRow(
                tabs: tabs, selection: tab, focusedTab: tab, metrics: metrics,
                palette: Self.flat, select: { _ in })
            Pane(width: paneContentWidth, contained: contained)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(
            width: SettingsSheetLayout.preferredSize.width,
            // Only the top of the sheet is under test, and a shorter render is a
            // faster one.
            height: 120)
        .background(Color.white)
        .environment(\.controlActiveState, .key)

        return try Render(of: sheet, named: name, file: file, line: line)
    }

    /// A stand-in pane, optionally wider than the sheet, optionally contained
    /// the way `SettingsView` contains the real ones. Drawn in nothing the
    /// measurements above look for, so it cannot be mistaken for the bar.
    private struct Pane: View {
        let width: CGFloat?
        let contained: Bool

        var body: some View {
            let content = Color.white.frame(width: width, height: width == nil ? nil : 1)
            if contained {
                content.settingsPane()
            } else {
                content
            }
        }
    }

    /// One offscreen render, and the measurements that can be taken off it.
    ///
    /// All rects come back in **points**, with y increasing downwards, so they
    /// can be compared against the metrics directly.
    private struct Render {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        init(of view: some View, named name: String, file: StaticString, line: UInt) throws {
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            // Read the fitting size first: switching sizing options off is what
            // stops the view from resizing itself, and it also zeroes it.
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)

            // Never ordered front. `cacheDisplay` draws without the window
            // appearing, so no test flashes anything or takes focus.
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: .borderless, backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(
                hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
                "no bitmap to draw \(name) into", file: file, line: line)
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = try XCTUnwrap(rep.cgImage, "no image behind \(name)", file: file, line: line)

            let pixelWidth = image.width
            let pixelHeight = image.height
            var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
            buffer.withUnsafeMutableBytes { raw in
                guard
                    let context = CGContext(
                        data: raw.baseAddress, width: pixelWidth, height: pixelHeight,
                        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                // The hosted view draws its own background, but the bitmap it is
                // cached into keeps an alpha channel; flattening onto white is
                // what makes a channel test mean what it says.
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            }
            width = pixelWidth
            height = pixelHeight
            scale = window.backingScaleFactor
            pixels = buffer

            try Render.write(image, named: name)
        }

        subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }

        /// The bounding box of everything drawn in one ink, in points.
        func box(of ink: Ink) -> CGRect? {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where ink.matches(self[x, y].0, self[x, y].1, self[x, y].2) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(
                x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }

        enum Direction {
            case minusX, plusX, minusY, plusY
        }

        /// How far one ink runs from a point, in points: the thickness of a
        /// stroke, measured where it is expected to be.
        func run(of ink: Ink, from start: CGPoint, towards direction: Direction) -> CGFloat {
            var x = Int((start.x * scale).rounded(.down))
            var y = Int((start.y * scale).rounded(.down))
            var counted = 0
            while x >= 0, x < width, y >= 0, y < height {
                let pixel = self[x, y]
                guard ink.matches(pixel.0, pixel.1, pixel.2) else { break }
                counted += 1
                switch direction {
                case .minusX: x -= 1
                case .plusX: x += 1
                case .minusY: y -= 1
                case .plusY: y += 1
                }
            }
            return CGFloat(counted) / scale
        }

        private static func write(_ image: CGImage, named name: String) throws {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try FileManager.default.createDirectory(
                at: SettingsTabBarGeometryTests.outputDirectory, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "-")
            try png.write(
                to: SettingsTabBarGeometryTests.outputDirectory
                    .appendingPathComponent("\(safe).png"))
        }
    }
}
