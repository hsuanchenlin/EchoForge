#!/usr/bin/env swift

// EchoForge's app icon, drawn as vectors so it can be regenerated at any size.
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
// The mark: a dark indigo rounded square, a bright cyan soundwave rising left to
// right, and a small orange forge spark the wave flows into. It is deliberately
// bold - at 16 pt the whole icon is 16 px, so every element is at least ~1.5 px
// wide there.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design space

/// Every coordinate below is in a 1024x1024 design space; each exported size
/// scales the whole drawing, so nothing is ever resampled.
let designSize: CGFloat = 1024

enum Palette {
    static let plateTop = CGColor(red: 0.196, green: 0.180, blue: 0.494, alpha: 1) // #322E7E
    static let plateBottom = CGColor(red: 0.055, green: 0.051, blue: 0.204, alpha: 1) // #0E0D34
    static let waveTop = CGColor(red: 0.404, green: 0.910, blue: 0.976, alpha: 1) // #67E8F9
    static let waveBottom = CGColor(red: 0.024, green: 0.663, blue: 0.831, alpha: 1) // #06A9D4
    static let waveGlow = CGColor(red: 0.133, green: 0.827, blue: 0.933, alpha: 0.55)
    static let sparkCore = CGColor(red: 1.0, green: 0.937, blue: 0.792, alpha: 1) // #FFEFCA
    static let sparkMid = CGColor(red: 1.0, green: 0.686, blue: 0.180, alpha: 1) // #FFAF2E
    static let sparkEdge = CGColor(red: 0.996, green: 0.365, blue: 0.055, alpha: 1) // #FE5D0E
    static let sparkGlow = CGColor(red: 1.0, green: 0.478, blue: 0.086, alpha: 0.55)
    static let rim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
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

func linearGradient(from top: CGColor, to bottom: CGColor) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
}

/// A four-pointed sparkle: straight-ish points pulled in by quadratic curves, so
/// it still reads as a spark at 32 px where a many-pointed star turns to mush.
func sparkPath(center: CGPoint, radius: CGFloat, waist: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = [
        CGPoint(x: center.x, y: center.y + radius),
        CGPoint(x: center.x + radius, y: center.y),
        CGPoint(x: center.x, y: center.y - radius),
        CGPoint(x: center.x - radius, y: center.y),
    ]
    path.move(to: points[0])
    path.addQuadCurve(to: points[1], control: CGPoint(x: center.x + waist, y: center.y + waist))
    path.addQuadCurve(to: points[2], control: CGPoint(x: center.x + waist, y: center.y - waist))
    path.addQuadCurve(to: points[3], control: CGPoint(x: center.x - waist, y: center.y - waist))
    path.addQuadCurve(to: points[0], control: CGPoint(x: center.x - waist, y: center.y + waist))
    path.closeSubpath()
    return path
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
        linearGradient(from: Palette.plateTop, to: Palette.plateBottom),
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    ctx.restoreGState()

    // Rim light, so the plate has an edge against a dark desktop.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.setStrokeColor(Palette.rim)
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // Everything from here on is clipped to the plate, so glows stay inside the
    // rounded square instead of hazing over the transparent corners.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()

    // Soundwave: four bars rising toward the spark.
    let barWidth: CGFloat = 86
    let barGap: CGFloat = 56
    let barHeights: [CGFloat] = [210, 330, 470, 610]
    let centerY: CGFloat = 512
    var barX: CGFloat = 152

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 44, color: Palette.waveGlow)
    let waveShape = CGMutablePath()
    for height in barHeights {
        let rect = CGRect(x: barX, y: centerY - height / 2, width: barWidth, height: height)
        waveShape.addRoundedRect(in: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        barX += barWidth + barGap
    }
    // Fill once through a clip so the gradient runs across the whole wave rather
    // than restarting inside every bar, and one shadow is cast for the group.
    ctx.addPath(waveShape)
    ctx.setFillColor(Palette.waveBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(waveShape)
    ctx.clip()
    ctx.drawLinearGradient(
        linearGradient(from: Palette.waveTop, to: Palette.waveBottom),
        start: CGPoint(x: 0, y: centerY + 305),
        end: CGPoint(x: 0, y: centerY - 305),
        options: []
    )
    ctx.restoreGState()

    // Forge spark the wave flows into.
    let sparkCenter = CGPoint(x: 782, y: 600)

    ctx.saveGState()
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.sparkGlow, CGColor(red: 1, green: 0.478, blue: 0.086, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: sparkCenter, startRadius: 20,
        endCenter: sparkCenter, endRadius: 190,
        options: []
    )
    ctx.restoreGState()

    ctx.saveGState()
    let spark = sparkPath(center: sparkCenter, radius: 132, waist: 30)
    ctx.addPath(spark)
    ctx.clip()
    ctx.drawRadialGradient(
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [Palette.sparkCore, Palette.sparkMid, Palette.sparkEdge] as CFArray,
            locations: [0, 0.42, 1]
        )!,
        startCenter: CGPoint(x: sparkCenter.x - 18, y: sparkCenter.y + 18), startRadius: 4,
        endCenter: sparkCenter, endRadius: 140,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

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
