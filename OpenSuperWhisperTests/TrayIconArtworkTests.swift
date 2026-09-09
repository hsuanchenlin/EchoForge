import AppKit
import XCTest

@testable import OpenSuperWhisper

/// The menu-bar icons, read out of the committed PDFs.
///
/// The **committed** files, deliberately, and for the same reason
/// `AppIconArtworkTests` reads the committed `.icns`: the build never runs
/// `Scripts/generate_tray_icon.sh`, so editing the artwork without regenerating
/// ships the old icon and nothing says so. This is what says so.
///
/// What it holds is the part that cannot be seen from the source: that three
/// files exist, that they are one family differing only in a badge, that the
/// badge stands clear of the mark, and that everything fits inside the 18 points
/// `NSStatusItem` draws. Each of those has already been got wrong once - a
/// clearance ring drawn with `.clear` into a PDF context, which cannot erase,
/// came out as a solid black block where two pause bars should have been.
final class TrayIconArtworkTests: XCTestCase {

    /// The three states, by asset name.
    private let names = [
        MenuBarIcon.idleAssetName, MenuBarIcon.recordingAssetName, MenuBarIcon.pausedAssetName,
    ]

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/\(name).pdf")
    }

    private func image(_ name: String) throws -> NSImage {
        try XCTUnwrap(NSImage(contentsOf: url(name)), "\(name).pdf is missing or unreadable")
    }

    /// The icon rasterised at `scale`, as coverage per pixel: 0 where nothing is
    /// drawn, 1 where it is solid. Row 0 is the **top** of the icon.
    ///
    /// Drawn into a bitmap of an exact pixel size rather than through
    /// `NSImage.lockFocus`, which rasterises at the *screen's* backing scale - so
    /// the grid's dimensions depended on which Mac the suite ran on and every
    /// index below meant something different on a Retina display.
    private func coverage(_ name: String, scale: Int) throws -> [[Double]] {
        let side = Int(MenuBarIcon.pointSize) * scale
        let pdf = try image(name)

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            "no bitmap to draw into")

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        pdf.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        return (0..<side).map { y in
            (0..<side).map { x in
                Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
    }

    private func totalInk(_ grid: [[Double]]) -> Double {
        grid.reduce(0) { $0 + $1.reduce(0, +) }
    }

    // MARK: - They exist, and they are the size the menu bar draws

    func testAllThreeIconsAreCommittedAtTheSizeTheStatusItemDraws() throws {
        for name in names {
            let image = try self.image(name)
            XCTAssertEqual(
                image.size.width, MenuBarIcon.pointSize, accuracy: 0.01,
                "\(name) is \(image.size.width) pt wide, not the \(MenuBarIcon.pointSize) pt "
                    + "NSStatusItem draws")
            XCTAssertEqual(image.size.height, MenuBarIcon.pointSize, accuracy: 0.01)
        }
    }

    /// Vector, not a bitmap: the menu bar is drawn at 1x and 2x and a rasterised
    /// asset is soft at one of them.
    func testTheIconsAreVectorArt() throws {
        for name in names {
            let data = try Data(contentsOf: url(name))
            XCTAssertTrue(
                data.starts(with: Array("%PDF".utf8)), "\(name) is not a PDF")
        }
    }

    // MARK: - The mark

    /// Symmetry is the mark's identity, and it is what keeps a pair of arcs from
    /// reading as the system volume icon or as Wi-Fi. The badge sits on the
    /// vertical axis, so all three stay symmetric.
    func testEveryIconIsLeftRightSymmetric() throws {
        for name in names {
            let grid = try coverage(name, scale: 8)
            let side = grid.count
            var worst = 0.0
            for y in 0..<side {
                for x in 0..<(side / 2) {
                    worst = max(worst, abs(grid[y][x] - grid[y][side - 1 - x]))
                }
            }
            XCTAssertLessThan(
                worst, 0.08, "\(name) is not symmetric about its vertical axis")
        }
    }

    /// Nothing is drawn against the edge, or the menu bar clips it.
    func testNothingTouchesTheEdgeOfTheIcon() throws {
        for name in names {
            let grid = try coverage(name, scale: 8)
            let side = grid.count
            for index in 0..<side {
                for value in [grid[0][index], grid[side - 1][index], grid[index][0], grid[index][side - 1]] {
                    XCTAssertLessThan(
                        value, 0.02, "\(name) draws against the edge of its own bounds")
                }
            }
        }
    }

    /// Enough ink to be seen, not so much that it is a blob. The paused icon was
    /// a blob twice before it became a badge.
    func testEachIconIsDrawnRatherThanBlankOrSolid() throws {
        for name in names {
            let grid = try coverage(name, scale: 8)
            let fraction = totalInk(grid) / Double(grid.count * grid.count)
            XCTAssertGreaterThan(fraction, 0.08, "\(name) is nearly blank")
            XCTAssertLessThan(fraction, 0.40, "\(name) is a blob at the size it is shown")
        }
    }

    // MARK: - One family, three badges

    /// The three differ, and differ **only** below the mark: they are one icon
    /// changing state, not three drawings.
    func testTheThreeStatesShareTheMarkAndDifferOnlyInTheBadge() throws {
        let idle = try coverage(MenuBarIcon.idleAssetName, scale: 8)
        let side = idle.count
        // The mark's own band: everything above the badge slot.
        let markRows = 0..<(side * 55 / 100)

        for name in [MenuBarIcon.recordingAssetName, MenuBarIcon.pausedAssetName] {
            let grid = try coverage(name, scale: 8)

            var worstInMark = 0.0
            for y in markRows {
                for x in 0..<side { worstInMark = max(worstInMark, abs(grid[y][x] - idle[y][x])) }
            }
            XCTAssertLessThan(
                worstInMark, 0.08, "\(name) redraws the mark instead of badging it")

            XCTAssertGreaterThan(
                totalInk(grid), totalInk(idle) * 1.05,
                "\(name) is indistinguishable from the idle icon")
        }

        let recording = try coverage(MenuBarIcon.recordingAssetName, scale: 8)
        let paused = try coverage(MenuBarIcon.pausedAssetName, scale: 8)
        var worst = 0.0
        for y in 0..<side {
            for x in 0..<side { worst = max(worst, abs(recording[y][x] - paused[y][x])) }
        }
        XCTAssertGreaterThan(
            worst, 0.5, "recording and paused have to be told apart at a glance")
    }

    /// The badge stands clear of the mark, on empty geometry rather than on a
    /// clearance that was erased - a PDF context cannot erase, and a draft that
    /// tried shipped a solid block.
    func testTheBadgeIsSeparatedFromTheMarkByAClearRow() throws {
        for name in [MenuBarIcon.recordingAssetName, MenuBarIcon.pausedAssetName] {
            let grid = try coverage(name, scale: 8)
            let side = grid.count
            // Rows are top-first, so the badge is at the bottom. Look for a row
            // in the lower third with no ink in the badge's column band.
            let band = (side * 35 / 100)..<(side * 65 / 100)
            let separated = ((side * 55 / 100)..<(side * 85 / 100)).contains { y in
                band.allSatisfy { x in grid[y][x] < 0.02 }
            }
            XCTAssertTrue(
                separated,
                "\(name)'s badge runs into the mark, so it reads as part of it")
        }
    }
}
