import CoreGraphics
import ImageIO
import XCTest

/// The app icon, checked as pixels rather than as source.
///
/// `Scripts/GenerateAppIcon.swift` is the artwork, but it is a standalone script
/// that never links into the app, so nothing here can call it. What ships is
/// `OpenSuperWhisper/AppIcon.icns`, committed and loaded through
/// `CFBundleIconFile`, and that is what these read: the same bytes macOS draws
/// in the Dock, the menu bar and Finder.
///
/// Reading the artifact rather than the script is also the only way to catch the
/// failure that actually happens here, which is the committed `.icns` drifting
/// from the script because somebody edited the artwork and did not re-run
/// `Scripts/generate_app_icon.sh`. A test over the source would have passed
/// through that.
///
/// The sizes reviewed are 1024, 64, 32 and 16: the Dock at 2x, the Finder icon
/// view, the Finder list view and the menu bar. 16 is the one that constrains
/// the design - the whole icon is 16 px there - so every property below is
/// asserted at every one of them unless the property is inherently a large-size
/// one, which is called out where it happens.
final class AppIconArtworkTests: XCTestCase {
    private static let reviewedWidths = [1024, 64, 32, 16]

    // MARK: - The artifact

    func testTheShippedIcnsDecodesAtEverySizeItClaims() throws {
        let icon = try iconImages()
        // Ten entries pack down to seven distinct widths, because `iconutil`
        // stores 32pt@1x and 16pt@2x (and two more such pairs) as separate
        // entries of the same size.
        XCTAssertEqual(icon.keys.sorted(), [16, 32, 64, 128, 256, 512, 1024])
        for (width, image) in icon {
            XCTAssertEqual(image.width, image.height, "the \(width)px image is not square")
        }
    }

    // MARK: - Grid and safe area

    /// macOS composites the icon straight onto the Dock and Finder, so anything
    /// in the corners is drawn outside the squircle and reads as a square halo
    /// around the tile.
    func testCornersAreTransparentSoTheSquircleReads() throws {
        try forEachReviewedSize { width, raster in
            for (x, y) in [(0, 0), (raster.width - 1, 0), (0, raster.width - 1), (raster.width - 1, raster.width - 1)] {
                XCTAssertEqual(
                    raster[x, y].alpha, 0,
                    "the \(width)px image paints its (\(x), \(y)) corner, which falls outside the squircle"
                )
            }
        }
    }

    /// The plate is inset 92 of 1024 - about 9% - because that is the grid
    /// Apple's own icons sit on, and an icon drawn to the full canvas looks
    /// oversized beside them in the Dock. Nothing may be painted in that margin.
    func testNothingIsPaintedOutsideTheIconGrid() throws {
        let raster = try raster(width: 1024)
        // One pixel of tolerance for the antialiased edge of the plate itself.
        let inset = 92.0 - 1
        for y in 0 ..< raster.width {
            for x in 0 ..< raster.width {
                guard raster[x, y].alpha > 0 else { continue }
                let outside = Double(x) < inset || Double(y) < inset
                    || Double(x) > 1023 - inset || Double(y) > 1023 - inset
                XCTAssertFalse(outside, "(\(x), \(y)) is painted inside the icon grid's empty margin")
                if outside { return }
            }
        }
    }

    /// The mark has to clear the plate's edge, not merely fall inside the
    /// canvas: a ripple that runs into the rim reads as clipped. The arcs sit on
    /// the plate's full-width middle, so their horizontal reach is the only
    /// clearance that matters.
    func testTheMarkKeepsItsMarginFromThePlateEdge() throws {
        let raster = try raster(width: 1024)
        var minX = raster.width, maxX = -1, minY = raster.width, maxY = -1
        for y in 0 ..< raster.width {
            for x in 0 ..< raster.width where raster[x, y].isMark {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, 0, "no mark was found at all")
        // The plate spans 92...932. 24px of clearance at 1024 is under half a
        // pixel at 16, so this is a large-size composition rule, not a
        // legibility one.
        for (edge, value) in [("left", minX), ("top", minY)] {
            XCTAssertGreaterThan(value, 92 + 24, "the mark crowds the plate's \(edge) edge")
        }
        for (edge, value) in [("right", maxX), ("bottom", maxY)] {
            XCTAssertLessThan(value, 932 - 24, "the mark crowds the plate's \(edge) edge")
        }
    }

    // MARK: - Palette

    /// The palette is ink, white and cyan. This is the assertion that the forge
    /// is gone: the direction this icon replaced was bronze and ember, and the
    /// single property that separates the two is that nothing here is warm. Any
    /// opaque pixel with more red than blue is a spark, a bronze plate or an
    /// ember haze coming back.
    func testNothingInThePaletteIsWarm() throws {
        try forEachReviewedSize { width, raster in
            for y in 0 ..< raster.width {
                for x in 0 ..< raster.width {
                    let pixel = raster[x, y]
                    guard pixel.alpha > 200 else { continue }
                    if pixel.red > pixel.blue {
                        XCTFail(
                            "the \(width)px image has a warm pixel at (\(x), \(y)): "
                                + "rgb(\(pixel.red), \(pixel.green), \(pixel.blue)). "
                                + "The palette is ink, white and cyan - no spark, no bronze."
                        )
                        return
                    }
                }
            }
        }
    }

    func testThePlateIsInkAndTheMarkIsWhiteAndCyan() throws {
        let raster = try raster(width: 1024)
        let opaque = raster.opaquePixels

        let brightest = try XCTUnwrap(opaque.max { $0.luminance < $1.luminance })
        XCTAssertGreaterThan(brightest.red, 230, "the utterance should be near-white")
        XCTAssertGreaterThan(brightest.green, 230)
        XCTAssertGreaterThan(brightest.blue, 230)

        let darkest = try XCTUnwrap(opaque.min { $0.luminance < $1.luminance })
        XCTAssertGreaterThan(darkest.blue, darkest.red, "the plate should be ink, not neutral black")

        // The echo, sampled on the inner ripple, level with the centre.
        let ripple = raster[512 - 196, 512]
        XCTAssertGreaterThan(ripple.blue, ripple.red + 60, "the echo should be cyan")
        XCTAssertGreaterThan(ripple.green, ripple.red + 40)
    }

    // MARK: - Contrast

    /// Non-text contrast wants 3:1. The mark clears that many times over at
    /// every size, which is what carries the icon in the menu bar, where the
    /// plate's own edge is far too fine to help.
    func testTheMarkClearsNonTextContrastAtEverySize() throws {
        try forEachReviewedSize { width, raster in
            let opaque = raster.opaquePixels
            guard let brightest = opaque.max(by: { $0.luminance < $1.luminance }),
                  let darkest = opaque.min(by: { $0.luminance < $1.luminance })
            else { return XCTFail("the \(width)px image has no opaque pixels") }
            XCTAssertGreaterThan(
                contrast(brightest, darkest), 10,
                "the \(width)px image only reaches \(contrast(brightest, darkest)):1 mark-to-plate"
            )
        }
    }

    /// The plate's bottom-right corner is near-black, and so is a dark Dock, so
    /// without help the tile has no visible edge there at all - it measures
    /// about 1.1:1. The rim is a gradient for exactly this reason.
    ///
    /// This is a large-size property and deliberately only asserted at 1024: the
    /// rim is 6 units of 1024, which is under a tenth of a pixel at 16, so no
    /// rim treatment can survive to the menu bar. What carries the small sizes
    /// is the mark's own contrast, asserted above.
    func testThePlateHasAVisibleEdgeOnADarkDock() throws {
        let raster = try raster(width: 1024)
        let dock = Pixel(red: 26, green: 26, blue: 28, alpha: 255) // #1A1A1C

        var brightestRim = dock
        let band = Double(raster.width) * 0.055
        let centre = Double(raster.width) / 2
        for y in raster.width / 2 ..< raster.width {
            for x in raster.width / 2 ..< raster.width {
                let pixel = raster[x, y]
                guard pixel.alpha > 200 else { continue }
                let dx = Double(x) - centre, dy = Double(y) - centre
                guard (dx * dx + dy * dy).squareRoot() > centre - band else { continue }
                if pixel.luminance > brightestRim.luminance { brightestRim = pixel }
            }
        }
        XCTAssertGreaterThan(
            contrast(brightestRim, dock), 3,
            "the plate's bottom-right edge is invisible against a dark Dock"
        )
    }

    // MARK: - The mark

    /// The utterance is the centre of the composition, and it is the element
    /// that has to survive to 16 px - four pixels of near-white there.
    func testTheUtteranceIsCentredAndPresentAtEverySize() throws {
        try forEachReviewedSize { width, raster in
            var sumX = 0.0, sumY = 0.0, count = 0.0
            for y in 0 ..< raster.width {
                for x in 0 ..< raster.width where raster[x, y].isUtterance {
                    sumX += Double(x); sumY += Double(y); count += 1
                }
            }
            XCTAssertGreaterThan(count, 0, "the \(width)px image has no utterance left")
            guard count > 0 else { return }

            // Pixel centres sit on half-integers, so a perfectly centred mark
            // lands on (width - 1) / 2 rather than width / 2.
            let centre = Double(raster.width - 1) / 2
            let tolerance = max(1.0, Double(raster.width) / 256)
            XCTAssertEqual(sumX / count, centre, accuracy: tolerance, "\(width)px: utterance is off-centre horizontally")
            XCTAssertEqual(sumY / count, centre, accuracy: tolerance, "\(width)px: utterance is off-centre vertically")
        }
    }

    /// The echo is mirrored, and that is load-bearing rather than decorative: a
    /// core with arcs on one side only is the system volume icon.
    ///
    /// The two sides are not pixel-identical and are not asserted to be. The
    /// plate is lit diagonally from the top-left, so the left ripples composite
    /// over a lighter plate than the right ones and more of them pass a fixed
    /// colour threshold. What is asserted is that both sides carry a real share
    /// of the echo, which is what fails if a ripple is ever dropped or the
    /// mirroring is lost.
    func testTheEchoAppearsOnBothSidesAtEverySize() throws {
        try forEachReviewedSize { width, raster in
            var utteranceMinX = raster.width, utteranceMaxX = -1
            for y in 0 ..< raster.width {
                for x in 0 ..< raster.width where raster[x, y].isUtterance {
                    utteranceMinX = min(utteranceMinX, x)
                    utteranceMaxX = max(utteranceMaxX, x)
                }
            }
            guard utteranceMaxX >= 0 else { return XCTFail("\(width)px: no utterance to measure the echo against") }

            var left = 0, right = 0
            for y in 0 ..< raster.width {
                for x in 0 ..< raster.width where raster[x, y].isMark {
                    if x < utteranceMinX { left += 1 }
                    if x > utteranceMaxX { right += 1 }
                }
            }
            XCTAssertGreaterThan(left, 0, "\(width)px: the echo is missing to the left of the utterance")
            XCTAssertGreaterThan(right, 0, "\(width)px: the echo is missing to the right of the utterance")

            let balance = Double(min(left, right)) / Double(max(left, right))
            XCTAssertGreaterThan(
                balance, 0.5,
                "\(width)px: the echo is lopsided (\(left) left, \(right) right) - it should read as mirrored"
            )
        }
    }

    // MARK: - Reading the icon

    private struct Pixel {
        let red: Int, green: Int, blue: Int, alpha: Int

        /// The near-white centre of the mark.
        var isUtterance: Bool { alpha > 200 && min(red, min(green, blue)) > 215 }
        /// The mark as a whole: the utterance plus the cyan echo, and not the
        /// ink plate or the soft glow it sits in.
        var isMark: Bool { alpha > 128 && blue > 150 && blue > red + 40 }

        var luminance: Double {
            func channel(_ value: Int) -> Double {
                let scaled = Double(value) / 255
                return scaled <= 0.03928 ? scaled / 12.92 : pow((scaled + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }
    }

    private func contrast(_ a: Pixel, _ b: Pixel) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// One decoded size, indexed from the top-left in pixels.
    private struct Raster {
        let width: Int
        private let pixels: [Pixel]

        init(_ image: CGImage) {
            width = image.width
            var bytes = [UInt8](repeating: 0, count: width * width * 4)
            let side = width
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress,
                    width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            pixels = stride(from: 0, to: bytes.count, by: 4).map {
                Pixel(
                    red: Int(bytes[$0]), green: Int(bytes[$0 + 1]),
                    blue: Int(bytes[$0 + 2]), alpha: Int(bytes[$0 + 3])
                )
            }
        }

        subscript(x: Int, y: Int) -> Pixel { pixels[y * width + x] }
        var opaquePixels: [Pixel] { pixels.filter { $0.alpha > 200 } }
    }

    /// Every image inside the shipped `.icns`, keyed by width.
    private func iconImages() throws -> [Int: CGImage] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            "AppIcon.icns is not in the built app bundle"
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil), "AppIcon.icns could not be opened"
        )
        var images: [Int: CGImage] = [:]
        for index in 0 ..< CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            // The .icns carries two entries at several sizes (1x of one point
            // size and 2x of another); they are the same drawing, so the first
            // one at each width is enough.
            if images[image.width] == nil { images[image.width] = image }
        }
        return images
    }

    private func raster(width: Int) throws -> Raster {
        let image = try XCTUnwrap(iconImages()[width], "AppIcon.icns has no \(width)px image")
        return Raster(image)
    }

    private func forEachReviewedSize(_ body: (Int, Raster) throws -> Void) throws {
        for width in Self.reviewedWidths {
            try body(width, try raster(width: width))
        }
    }
}
