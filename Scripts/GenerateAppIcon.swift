#!/usr/bin/env swift

// Kongweh's app icon, drawn as vectors so it can be regenerated at any size.
//
// This file is the icon's source artwork: there is no .sketch/.svg to keep in
// sync, and every size in AppIcon.icns is rendered from these paths rather than
// resampled from one bitmap, so the small menu-bar and Finder sizes stay crisp.
//
// Run it through `Scripts/generate_app_icon.sh`, which renders the iconset and
// packs it with `iconutil`.
//
// Usage: swift Scripts/GenerateAppIcon.swift <output.iconset directory>
//
// The mark is "Speech Ripple", and it is named for what the product is called:
// kóng-uē (講話), Taiwanese for "to talk". A soft upright aperture at the centre
// is the utterance; two mirrored pairs of open arcs are it carrying outward and
// decaying. That is the whole mark - one speaking form, its echo, nothing else.
//
// Three things about it are deliberate and worth keeping.
//
// It is symmetric. A core with arcs on one side only is the system volume icon,
// and arcs fanning from a corner are Wi-Fi; mirroring them is what keeps this
// from being read as either. It is also why the arcs are open at the top and
// bottom rather than closed rings, which would read as a target.
//
// There is no microphone, and there is nothing left of the forge: this icon
// replaced a bronze-and-ember direction that was dropped with the EchoForge
// name, so an orange spark or a warm plate creeping back in would be a
// regression, not a refresh. The palette is ink, white and cyan.
//
// It is deliberately bold - at 16 pt the whole icon is 16 px, so every element
// is at least ~1.5 px wide there. 1024 / 16 = 64, so nothing may be narrower
// than 96 in this design space and still resolve in the menu bar or Finder's
// list view. `coreSize`, `innerRippleWidth` and `outerRippleWidth` are the
// numbers that decide it; check any change against a real 16 px render, and
// expect the outer ripple to merge into the inner one there. That merge is the
// echo decaying and is the intended reading, not a defect.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design space

/// Every coordinate below is in a 1024x1024 design space; each exported size
/// scales the whole drawing, so nothing is ever resampled.
let designSize: CGFloat = 1024

enum Palette {
    // Plate: deep ink, lit from the top-left corner and falling to near-black at
    // the bottom-right, so the tile has depth without a second light source.
    static let plateTop = CGColor(red: 0.173, green: 0.212, blue: 0.376, alpha: 1) // #2C3660
    static let plateMid = CGColor(red: 0.078, green: 0.102, blue: 0.220, alpha: 1) // #141A38
    static let plateBottom = CGColor(red: 0.027, green: 0.035, blue: 0.071, alpha: 1) // #070912
    static let plateSheen = CGColor(red: 0.812, green: 0.878, blue: 1.0, alpha: 0.10) // #CFE0FF @ 10%
    static let plateSheenFade = CGColor(red: 0.812, green: 0.878, blue: 1.0, alpha: 0)

    // The utterance: near-white, cooling very slightly downward so it reads as a
    // lit form rather than a flat cut-out.
    static let coreTop = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1) // #FFFFFF
    static let coreBottom = CGColor(red: 0.847, green: 0.965, blue: 1.0, alpha: 1) // #D8F6FF

    // The echo, cooling as it expands. Both ripples read this gradient radially
    // from the centre, so the left and right sides are the same brightness at
    // the same distance - a left-to-right gradient would light one side only.
    static let rippleNear = CGColor(red: 0.561, green: 0.949, blue: 1.0, alpha: 1) // #8FF2FF
    static let rippleFar = CGColor(red: 0.118, green: 0.608, blue: 0.769, alpha: 1) // #1E9BC4
    static let coreGlow = CGColor(red: 0.400, green: 0.900, blue: 1.0, alpha: 0.42)

    /// The rim runs the other way to the plate, and it has to: the plate's
    /// bottom-right is `plateBottom`, which is 1.1:1 against a dark Dock - an
    /// edge nobody can see. A flat 18% rim only reaches about 1.4:1, so the rim
    /// is a gradient, faint where the plate lights itself and strong where it
    /// does not, which puts the weak corner at 3.3:1 and clears the 3:1 that
    /// non-text contrast asks for. Cool rather than white, to match the ink.
    static let rimBright = CGColor(red: 0.863, green: 0.910, blue: 1.0, alpha: 0.14) // #DCE8FF @ 14%
    static let rimDark = CGColor(red: 0.863, green: 0.910, blue: 1.0, alpha: 0.44) // #DCE8FF @ 44%
}

/// The rounded square, as a superellipse rather than a circular-corner rounded
/// rect: it is what macOS app icons actually use, and the difference is visible
/// at 512 pt and above.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    for step in 0...steps {
        let t = (CGFloat(step) / CGFloat(steps)) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = center.x + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = center.y + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func gradient(_ colors: [CGColor], at locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: locations
    )!
}

// MARK: - The mark

let markCenter = CGPoint(x: 512, y: 512)

/// The utterance: a soft square rather than a circle or an upright pill. The
/// shape is doing two jobs. It rhymes with the plate, which is a superellipse
/// of the same family, so the tile reads as one drawing; and it is the one form
/// here that cannot be mistaken for a microphone, which an upright capsule
/// flanked by arcs very much can - that reading is what this replaced.
let coreSize: CGFloat = 180
let coreExponent: CGFloat = 3.6

/// The echo. Two pairs, each open at the top and bottom, each mirrored across
/// the centre. `radius` is to the middle of the stroke.
struct Ripple {
    let radius: CGFloat
    let width: CGFloat
    /// Half the arc's span, in degrees, measured from the horizontal axis.
    let spread: CGFloat
    let opacity: CGFloat
}

let innerRippleWidth: CGFloat = 92
let outerRippleWidth: CGFloat = 72

let ripples = [
    Ripple(radius: 196, width: innerRippleWidth, spread: 52, opacity: 1),
    Ripple(radius: 300, width: outerRippleWidth, spread: 42, opacity: 0.55),
]

/// The outermost the mark ever reaches, which is what has to stay inside the
/// plate. The arcs sit at the plate's full-width middle rather than near a
/// corner, so this is the only clearance that matters.
let markOuterRadius: CGFloat = 300 + 72 / 2

/// One arc, as a path of its own. `CGMutablePath.addArc` draws a line from the
/// current point to the arc's start, so the two arcs of a ripple have to be
/// built separately and appended - adding them to one path joins them across
/// the top and closes the ring, which is the exact reading the open arcs exist
/// to avoid.
func arcPath(radius: CGFloat, from start: CGFloat, to end: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: markCenter, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    return path
}

func ripplePath(_ ripple: Ripple) -> CGPath {
    let path = CGMutablePath()
    let spread = ripple.spread * .pi / 180
    // Right, then left. Both are open at the top and bottom.
    path.addPath(arcPath(radius: ripple.radius, from: -spread, to: spread))
    path.addPath(arcPath(radius: ripple.radius, from: .pi - spread, to: .pi + spread))
    return path
}

/// Turn a stroke into a fill region. CoreGraphics can only fill a gradient
/// through a clip, and `replacePathWithStrokedPath` is the one way to get the
/// outline of a stroke as a path, so a gradient-filled arc goes through this
/// rather than through a hand-built outline that would have to be re-derived
/// every time a width or a radius changes.
func strokedOutline(of path: CGPath, width: CGFloat, in ctx: CGContext) -> CGPath {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.beginPath()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.replacePathWithStrokedPath()
    let outline = ctx.path?.copy() ?? CGMutablePath()
    ctx.beginPath()
    return outline
}

func fillLinear(
    _ outline: CGPath, in ctx: CGContext,
    with gradient: CGGradient, from start: CGPoint, to end: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient, start: start, end: end,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func fillRadial(
    _ outline: CGPath, in ctx: CGContext,
    with gradient: CGGradient, from innerRadius: CGFloat, to outerRadius: CGFloat,
    opacity: CGFloat
) {
    ctx.saveGState()
    ctx.setAlpha(opacity)
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient,
        startCenter: markCenter, startRadius: innerRadius,
        endCenter: markCenter, endRadius: outerRadius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

// MARK: - The icon

func drawIcon(in ctx: CGContext, pixelSize: CGFloat) {
    let scale = pixelSize / designSize
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // Plate. The inset matches macOS's icon grid, which leaves the outer ~9%
    // empty so the icon lines up with Apple's own in the Dock and Finder.
    let plate = CGRect(x: 92, y: 92, width: 840, height: 840)
    let plateShape = squirclePath(in: plate)

    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([Palette.plateTop, Palette.plateMid, Palette.plateBottom], at: [0, 0.46, 1]),
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // A sheen down from the top edge, so the ink reads as a polished plate
    // rather than as flat paint.
    ctx.drawLinearGradient(
        gradient([Palette.plateSheen, Palette.plateSheenFade], at: [0, 1]),
        start: CGPoint(x: 512, y: plate.maxY),
        end: CGPoint(x: 512, y: 544),
        options: []
    )
    ctx.restoreGState()

    // Rim light, so the plate has an edge against a dark desktop. It is stroked
    // at twice its visible width and clipped to the plate, because a centred
    // stroke puts half its width *outside* the superellipse - which would paint
    // the tile 846 units wide on a grid that allows 840, and leave the icon
    // fractionally larger than every Apple icon beside it in the Dock.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    fillLinear(
        strokedOutline(of: plateShape, width: 12, in: ctx), in: ctx,
        with: gradient([Palette.rimBright, Palette.rimDark], at: [0, 1]),
        from: CGPoint(x: plate.minX, y: plate.maxY), to: CGPoint(x: plate.maxX, y: plate.minY)
    )
    ctx.restoreGState()

    // Everything from here on is clipped to the plate, so glows stay inside the
    // rounded square instead of hazing over the transparent corners.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()

    // The light the utterance casts, under everything, so the mark sits in the
    // plate rather than on top of it.
    ctx.drawRadialGradient(
        gradient([Palette.coreGlow, CGColor(red: 0.400, green: 0.900, blue: 1.0, alpha: 0)], at: [0, 1]),
        startCenter: markCenter, startRadius: 0,
        endCenter: markCenter, endRadius: 300,
        options: []
    )

    // The echo, farthest first, so a nearer ripple always wins the overlap.
    let echo = gradient([Palette.rippleNear, Palette.rippleFar], at: [0, 1])
    for ripple in ripples.reversed() {
        fillRadial(
            strokedOutline(of: ripplePath(ripple), width: ripple.width, in: ctx), in: ctx,
            with: echo, from: 150, to: markOuterRadius, opacity: ripple.opacity
        )
    }

    // The utterance itself, last and brightest.
    let core = squirclePath(
        in: CGRect(
            x: markCenter.x - coreSize / 2, y: markCenter.y - coreSize / 2,
            width: coreSize, height: coreSize
        ),
        exponent: coreExponent
    )
    fillLinear(
        core, in: ctx,
        with: gradient([Palette.coreTop, Palette.coreBottom], at: [0, 1]),
        from: CGPoint(x: 0, y: markCenter.y + coreSize / 2),
        to: CGPoint(x: 0, y: markCenter.y - coreSize / 2)
    )

    ctx.restoreGState() // plate clip
}

// MARK: - Export

func renderPNG(pixelSize: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.contextFailed(pixelSize)
    }
    drawIcon(in: ctx, pixelSize: CGFloat(pixelSize))
    guard let image = ctx.makeImage() else { throw IconError.imageFailed(pixelSize) }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw IconError.writeFailed(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.writeFailed(url) }
}

enum IconError: Error, CustomStringConvertible {
    case contextFailed(Int)
    case imageFailed(Int)
    case writeFailed(URL)
    case usage

    var description: String {
        switch self {
        case .contextFailed(let size): "Could not create a \(size)px bitmap context"
        case .imageFailed(let size): "Could not snapshot the \(size)px bitmap"
        case .writeFailed(let url): "Could not write \(url.path)"
        case .usage: "Usage: swift Scripts/GenerateAppIcon.swift <output.iconset directory>"
        }
    }
}

/// The ten files `iconutil` expects, which between them cover every size macOS
/// asks for from the menu bar to the Dock at 2x.
let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    guard CommandLine.arguments.count == 2 else { throw IconError.usage }
    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for entry in iconsetEntries {
        try renderPNG(pixelSize: entry.pixels, to: outputDirectory.appendingPathComponent(entry.name))
    }
    print("Rendered \(iconsetEntries.count) icon sizes into \(outputDirectory.path)")
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
