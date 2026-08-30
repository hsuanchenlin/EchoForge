import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The history list's light-mode ground, as numbers a test can disagree with.
///
/// The defect: `windowBackground`, `cardBackground` and the hovered
/// `cardSurface` were all white, so a hovered history card washed out into the
/// window. `ThemePalette` is the one place those colours are chosen, so the
/// contrast is asserted here rather than by eyeballing a screenshot.
final class ThemePaletteTests: XCTestCase {

    /// The canvas has to be a grouped gray. `NSColor.windowBackgroundColor` is
    /// white on current macOS, which is exactly the token that produced the
    /// wash-out; the hardcoded canvas is the one that stays distinct from a
    /// white card.
    func testLightWindowCanvasIsAGroupedGrayNotWhite() {
        let window = resolve(ThemePalette.windowBackground(.light), scheme: .light)
        XCTAssertLessThan(
            luminance(window), 0.99,
            "light window background is white, so cards have no canvas")
        XCTAssertGreaterThan(
            luminance(window), 0.90,
            "light window background left the grouped-canvas range")
    }

    func testLightCardsStayCrispWhiteAtRestAndOnHover() {
        let rest = resolve(ThemePalette.cardBackground(.light), scheme: .light)
        let hover = resolve(ThemePalette.cardSurface(.light, hovered: true), scheme: .light)

        XCTAssertGreaterThan(luminance(rest), 0.995, "light cards are not white")
        XCTAssertGreaterThan(
            luminance(hover), 0.995,
            "hovered light cards washed out of white into off-white")
        XCTAssertEqual(rest.red, hover.red, accuracy: 0.002)
        XCTAssertEqual(rest.green, hover.green, accuracy: 0.002)
        XCTAssertEqual(rest.blue, hover.blue, accuracy: 0.002)
    }

    func testLightCardsSitAboveTheCanvas() {
        let window = luminance(resolve(ThemePalette.windowBackground(.light), scheme: .light))
        let card = luminance(resolve(ThemePalette.cardBackground(.light), scheme: .light))
        XCTAssertGreaterThan(
            card - window, 0.02,
            "light cards are not distinct from the window canvas")
    }

    /// Hover in light mode is elevation, not a fill change. The stroke firms
    /// up and the shadow deepens; the fill stays the card's own white.
    func testLightHoverRaisesTheStrokeAndTheShadow() {
        let restStroke = resolve(
            ThemePalette.cardStroke(.light, hovered: false, failed: false), scheme: .light)
        let hoverStroke = resolve(
            ThemePalette.cardStroke(.light, hovered: true, failed: false), scheme: .light)
        XCTAssertLessThan(
            luminance(hoverStroke), luminance(restStroke) - 0.05,
            "hovered light stroke is no firmer than the rest stroke")

        let restShadow = resolve(ThemePalette.cardShadow(.light, elevated: false), scheme: .light)
        let hoverShadow = resolve(ThemePalette.cardShadow(.light, elevated: true), scheme: .light)
        XCTAssertGreaterThan(
            hoverShadow.alpha, restShadow.alpha,
            "hovered light shadow is no deeper than the rest shadow")
    }

    func testLightChipsAndInsetsStayDistinctFromTheCard() {
        let card = luminance(resolve(ThemePalette.cardBackground(.light), scheme: .light))
        let chip = luminance(resolve(ThemePalette.chipSurface(.light), scheme: .light))
        let inset = luminance(resolve(ThemePalette.insetSurface(.light), scheme: .light))
        XCTAssertLessThan(chip, card - 0.02, "light chips vanished into the card")
        XCTAssertLessThan(inset, card - 0.01, "light insets vanished into the card")
    }

    /// Dark mode is not a filter over the light one. The window stays
    /// `underPageBackgroundColor`, cards stay `controlBackgroundColor`, and a
    /// hover still lifts a shade rather than flashing white.
    func testDarkPaletteKeepsItsOwnGround() {
        let window = resolve(ThemePalette.windowBackground(.dark), scheme: .dark)
        let card = resolve(ThemePalette.cardBackground(.dark), scheme: .dark)
        let hover = resolve(ThemePalette.cardSurface(.dark, hovered: true), scheme: .dark)

        XCTAssertLessThan(luminance(window), 0.35, "dark window left the dark range")
        XCTAssertLessThan(luminance(card), 0.35, "dark cards left the dark range")
        XCTAssertGreaterThan(
            luminance(hover), luminance(card),
            "dark hover no longer lifts a shade off the card")
        XCTAssertLessThan(
            luminance(hover), 0.45,
            "dark hover flashed toward white")

        let restShadow = resolve(ThemePalette.cardShadow(.dark, elevated: false), scheme: .dark)
        let hoverShadow = resolve(ThemePalette.cardShadow(.dark, elevated: true), scheme: .dark)
        XCTAssertGreaterThan(hoverShadow.alpha, restShadow.alpha)
    }

    // MARK: - Resolution

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private func resolve(_ color: Color, scheme: ColorScheme) -> RGBA {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var resolved = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            resolved = RGBA(
                red: rgb.redComponent,
                green: rgb.greenComponent,
                blue: rgb.blueComponent,
                alpha: rgb.alphaComponent)
        }
        return resolved
    }

    private func luminance(_ color: RGBA) -> CGFloat {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }
}
