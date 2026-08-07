import CoreGraphics
import Foundation

/// Where a screenshot came from, in the only terms the app is allowed to keep.
///
/// The application's name and the window's title, because the panel says what it
/// is looking at and a user must be able to see that it is the right thing. No
/// address, no document path, and nothing at all is written to the database, the
/// pasteboard or the network - see `docs/screen-context.md`.
enum ScreenCaptureSource: Equatable, Sendable {
    case window(applicationName: String?, title: String?)
    case display

    /// The one line the Ask panel shows under the thumbnail.
    var label: String {
        switch self {
        case .window(let applicationName, let title):
            switch (applicationName, title?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case (let app?, let windowTitle?) where !windowTitle.isEmpty:
                return "\(app) - \(windowTitle)"
            case (let app?, _):
                return app
            case (nil, let windowTitle?) where !windowTitle.isEmpty:
                return windowTitle
            default:
                return "Window"
            }
        case .display:
            return "Screen"
        }
    }
}

/// One screenshot, taken for one question.
///
/// It lives exactly as long as the panel does. Nothing here is saved: a screen
/// query holds the image in memory while the model reads it, shows the user a
/// thumbnail of what it took, and forgets it when the conversation is closed.
///
/// `Equatable` by identity because a `CGImage` is not comparable and identity is
/// the only thing the state machine actually asks about - "is this the same
/// screenshot the question was asked with". `@unchecked Sendable` for the same
/// reason `CGImage` itself is safe to share: it is immutable once created.
struct ScreenObservation: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let image: CGImage
    let source: ScreenCaptureSource

    init(id: UUID = UUID(), image: CGImage, source: ScreenCaptureSource) {
        self.id = id
        self.image = image
        self.source = source
    }

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    static func == (lhs: ScreenObservation, rhs: ScreenObservation) -> Bool {
        lhs.id == rhs.id
    }
}

/// How large a screenshot may be by the time a model sees it.
///
/// A screen is far bigger than any model reads usefully: a 6K display is 24 MB
/// of pixels, and every stage after the capture - the OCR pass, the thumbnail,
/// the memory the panel holds while the conversation is open - pays for all of
/// them. The cap is applied twice on purpose. `ScreenCaptureService` sizes the
/// capture itself with `fittedSize`, so the large image is never allocated at
/// all; `downscaled` then holds the same line for an image that arrived from
/// anywhere else, and is a no-op for one that is already inside it.
enum ScreenshotDownscale {

    /// The longest edge a screenshot is given to the model with.
    ///
    /// 1560 px is the bound Anthropic's vision guidance names for images that
    /// should not be resampled again on the way in, and it is comfortably above
    /// what the on-device OCR pass needs to read UI text: a 1560-wide capture of
    /// a 3024-wide Retina window still has roughly 13 px of height per line of
    /// 12 pt text.
    static let maximumDimension: CGFloat = 1560

    /// The size `source` becomes, preserving aspect ratio and never enlarging.
    ///
    /// Never enlarging is the rule that matters: a small window blown up to the
    /// cap costs the model pixels it cannot learn anything from, and costs the
    /// OCR pass a blurrier image than the one it was given.
    static func fittedSize(for source: CGSize, maximumDimension: CGFloat = maximumDimension) -> CGSize {
        guard source.width > 0, source.height > 0, maximumDimension > 0 else { return .zero }
        let longestEdge = max(source.width, source.height)
        guard longestEdge > maximumDimension else {
            return CGSize(width: source.width.rounded(), height: source.height.rounded())
        }
        let scale = maximumDimension / longestEdge
        // At least one pixel in each direction: a 4000×1 strip would otherwise
        // round to a zero-height image, which no drawing context accepts.
        return CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }

    /// `image` at or inside the cap. Returns the original when it already is,
    /// and when it cannot be redrawn - a screenshot that is slightly too large
    /// is worth more than no screenshot at all.
    static func downscaled(_ image: CGImage, maximumDimension: CGFloat = maximumDimension) -> CGImage {
        let source = CGSize(width: image.width, height: image.height)
        let target = fittedSize(for: source, maximumDimension: maximumDimension)
        guard target != .zero, target != source else { return image }

        let width = Int(target.width)
        let height = Int(target.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
