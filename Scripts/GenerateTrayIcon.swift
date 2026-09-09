#!/usr/bin/env swift

// Kongweh's menu-bar icons, drawn as vectors so they stay crisp at every scale.
//
// This file is the artwork's source: the three PDFs it writes are committed, so
// the build never runs it. Edit here and re-run `Scripts/generate_tray_icon.sh`;
// `TrayIconArtworkTests` reads the *committed* PDFs rather than this source, so
// changing the drawing without regenerating fails a test instead of shipping the
// old icon.
//
// Usage: swift Scripts/GenerateTrayIcon.swift <output directory>
//
// ## The mark
//
// It is the same "Speech Ripple" as the app icon (`Scripts/GenerateAppIcon.swift`)
// and it is drawn to the same rules: symmetric, no microphone, one speaking form
// and its echo. Two mirrored pairs of open arcs around a soft upright aperture.
// The arcs are open at top and bottom rather than closed rings, because closed
// rings read as a target; the mirroring is what keeps a pair of arcs from reading
// as the system volume icon or as Wi-Fi.
//
// It replaces a leftover bear silhouette inherited from upstream, which matched
// neither the old EchoForge icon nor the current one.
//
// ## Why there are three
//
// The menu bar has to say what the app is doing without animating - a menu-bar
// icon that moves is a menu-bar icon that is noticed all day. So the state is
// carried by three unmistakable silhouettes rather than by motion or colour:
//
// - **idle**: the mark.
// - **recording**: the mark with a filled dot below it. The dot is the one
//   convention every user already knows.
// - **paused**: the mark with two upright bars in the same badge slot. A slash
//   was tried twice and measured at the size the icon is shown; see
//   `pauseBarWidth` for what went wrong with each.
//
// All three share the mark and differ only in the badge, which is what makes
// them read as one icon changing state rather than as three drawings.
//
// ## Template images
//
// All three are drawn in black with alpha and are loaded with `isTemplate = true`,
// so macOS tints them for the menu bar's appearance - light, dark, and the
// inverted state while the menu is open. Nothing here may rely on colour; the
// alpha channel is the whole drawing.
//
// ## Size
//
// The media box is 18x18 points, which is what `NSStatusItem` draws at. Every
// stroke is checked against that: at 1x, 18 points is 18 pixels, so nothing
// narrower than about 1.2 points survives. `innerRippleWidth` and
// `outerRippleWidth` are the numbers that decide it.

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Design space

/// The whole icon, in points. This is also the PDF's media box, so an `NSImage`
/// loaded from it has this as its natural size and needs no resizing.
let iconSize: CGFloat = 18

let center = CGPoint(x: iconSize / 2, y: iconSize / 2)

/// The utterance: a soft square rather than a circle or an upright pill - the
/// same shape and the same reason as the app icon. An upright capsule flanked by
/// arcs reads as a microphone, which this mark deliberately is not.
let coreSize: CGFloat = 4.6
let coreExponent: CGFloat = 3.6

struct Ripple {
    /// To the middle of the stroke.
    let radius: CGFloat
    let width: CGFloat
    /// Half the arc's span, in degrees, from the horizontal axis.
    let spread: CGFloat
}

let innerRippleWidth: CGFloat = 1.5
let outerRippleWidth: CGFloat = 1.2

let ripples = [
    Ripple(radius: 5.5, width: innerRippleWidth, spread: 52),
    Ripple(radius: 7.7, width: outerRippleWidth, spread: 42),
]

/// The recording dot.
///
/// Directly **below** the core, not in a corner: the ripples are open at the top
/// and the bottom - that openness is the mark - so the gap under the core is the
/// one place inside 18 points where a badge can sit without touching an arc. A
/// corner badge is what a first draft put here, and at 45 degrees it landed
/// straight through the lower end of the inner arc.
///
/// It also keeps the icon left-right symmetric, which the mark is.
let dotCenter = CGPoint(x: iconSize / 2, y: 2.6)
let dotRadius: CGFloat = 1.9

/// The paused badge: two upright bars, in the same slot as the recording dot.
///
/// A slash was the first two attempts and both were measured at the size the
/// icon is actually shown. Across the whole mark it filled the gaps between the
/// arcs and came out as a blob at 36 pixels; over the core alone, with the echo
/// dropped, the punch ate most of the core and the icon read as a pen. What
/// works at 18 points is a badge in the one gap the mark leaves - and using the
/// same slot for both states is what makes the three icons read as one family
/// with a changing badge rather than as three drawings.
let pauseBarWidth: CGFloat = 1.2
let pauseBarHeight: CGFloat = 3.8
let pauseBarGap: CGFloat = 1.1

// MARK: - Geometry

func squirclePath(in rect: CGRect, exponent: CGFloat, steps: Int = 240) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let middle = CGPoint(x: rect.midX, y: rect.midY)
    for step in 0...steps {
        let t = (CGFloat(step) / CGFloat(steps)) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = middle.x + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = middle.y + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// One arc as its own path. `addArc` draws a line from the current point to the
/// arc's start, so the two arcs of a ripple are built separately and appended -
/// adding them to one path joins them across the top and closes the ring, which
/// is the exact reading the open arcs exist to avoid.
func arcPath(radius: CGFloat, from start: CGFloat, to end: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    return path
}

func ripplePath(_ ripple: Ripple) -> CGPath {
    let path = CGMutablePath()
    let spread = ripple.spread * .pi / 180
    path.addPath(arcPath(radius: ripple.radius, from: -spread, to: spread))
    path.addPath(arcPath(radius: ripple.radius, from: .pi - spread, to: .pi + spread))
    return path
}

// MARK: - Drawing

enum TrayIconState: String, CaseIterable {
    case idle = "tray_icon"
    case recording = "tray_icon_recording"
    case paused = "tray_icon_paused"
}

func drawMark(in ctx: CGContext) {
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineCap(.round)

    for ripple in ripples {
        ctx.setLineWidth(ripple.width)
        ctx.addPath(ripplePath(ripple))
        ctx.strokePath()
    }

    let core = squirclePath(
        in: CGRect(
            x: center.x - coreSize / 2, y: center.y - coreSize / 2,
            width: coreSize, height: coreSize),
        exponent: coreExponent)
    ctx.addPath(core)
    ctx.fillPath()
}

// Nothing here erases. A PDF context has no way to: `.clear` is not a blend mode
// PDF can express, and CoreGraphics silently paints the shape opaque instead - a
// first draft punched a clearance ring around each badge and shipped a solid
// black block where the two pause bars should have been. So the badge sits in
// geometry that is already empty: the ripples are open at the top and the
// bottom, and the gap under the core is wide enough for either badge to stand
// clear of both the core and the arcs on its own. `TrayIconArtworkTests`
// measures that gap on the committed files.

/// The two bars of the pause badge, as rects.
func pauseBarRects() -> [CGRect] {
    let offset = pauseBarGap / 2 + pauseBarWidth / 2
    return [-offset, offset].map { dx in
        CGRect(
            x: dotCenter.x + dx - pauseBarWidth / 2,
            y: dotCenter.y - pauseBarHeight / 2,
            width: pauseBarWidth, height: pauseBarHeight)
    }
}

func draw(_ state: TrayIconState, in ctx: CGContext) {
    drawMark(in: ctx)

    switch state {
    case .idle:
        break

    case .recording:
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillEllipse(
            in: CGRect(
                x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2))

    case .paused:
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(pauseBarWidth)
        ctx.setLineCap(.round)
        for bar in pauseBarRects() {
            ctx.move(to: CGPoint(x: bar.midX, y: bar.minY + pauseBarWidth / 2))
            ctx.addLine(to: CGPoint(x: bar.midX, y: bar.maxY - pauseBarWidth / 2))
        }
        ctx.strokePath()
    }
}

// MARK: - Export

enum TrayIconError: Error, CustomStringConvertible {
    case contextFailed(String)
    case usage

    var description: String {
        switch self {
        case .contextFailed(let name): "Could not create a PDF context for \(name)"
        case .usage: "Usage: swift Scripts/GenerateTrayIcon.swift <output directory>"
        }
    }
}

func writePDF(_ state: TrayIconState, to directory: URL) throws {
    let url = directory.appendingPathComponent("\(state.rawValue).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
    guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw TrayIconError.contextFailed(state.rawValue)
    }
    ctx.beginPDFPage(nil)
    ctx.setShouldAntialias(true)
    draw(state, in: ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

do {
    guard CommandLine.arguments.count == 2 else { throw TrayIconError.usage }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for state in TrayIconState.allCases {
        try writePDF(state, to: directory)
        print("Wrote \(directory.appendingPathComponent("\(state.rawValue).pdf").path)")
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
