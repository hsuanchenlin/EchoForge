import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Renders the About pane's update card in the states a user only sees while
/// bytes are moving, and asserts both the pixels and the words.
///
/// These states cannot be screenshotted from outside: they exist mid-transfer,
/// and driving the real pane needs the Accessibility and Screen Recording
/// grants a checkout machine does not have. So the card is rendered in-process
/// instead - `UpdateCardView` draws from an explicit `UpdateState` into an
/// `NSHostingView` in an offscreen, never-shown window, and `cacheDisplay`
/// rasterises it with no permissions. Not `ImageRenderer`, although it also
/// works headless here: it draws the AppKit-backed `ProgressView`s as yellow
/// placeholder art, and evidence of a progress pane that misdraws the progress
/// bar is worse than none. Every render is written to
/// `/tmp/EchoForgeUpdateCardRenders/<name>.png` for a human to open.
///
/// Two layers of assertion, because each catches what the other cannot. The
/// wording is asserted through `UpdateCardView.statusText(for:)` - the same
/// composition the body draws - with the expected fragments taken from
/// `DownloadProgressText` rather than restated, so the rules are pinned
/// without a second copy of the copy: a downloading line always carries
/// bytes-of-total, no line is ever a bare percentage, and nothing numeric is
/// claimed before the first byte. The pixels are then read back with OCR, so a
/// state whose text never made it into the render fails here instead of
/// shipping a blank card that every string-level test still passes.
@MainActor
final class UpdateCardRenderTests: XCTestCase {

    /// Where the renders land. A fixed path rather than the per-run temporary
    /// directory so the doc comment above can say where to look and stay true.
    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeUpdateCardRenders", isDirectory: true)

    /// One canvas for every state so the gallery reads as one pane changing,
    /// tall enough that no state's card reaches the bottom edge.
    private static let cardSize = CGSize(width: 460, height: 220)

    /// The published v0.5.2 asset's real size, so the rendered byte counts are
    /// the magnitudes a user actually watches.
    private let release = PublishedRelease(
        version: AppVersion("0.6.0")!,
        tag: "v0.6.0",
        notes: "",
        downloadURL: URL(
            string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.6.0/EchoForge.dmg")!,
        sizeInBytes: 222_289_422
    )

    private var totalBytes: Int64 { Int64(release.sizeInBytes) }

    func testConnectingBeforeTheFirstByteClaimsNothingNumeric() throws {
        let state = UpdateState.connecting(
            release, DownloadProgress(receivedBytes: 0, totalBytes: totalBytes))

        let text = UpdateCardView.statusText(for: state)
        XCTAssertTrue(text.contains("Connecting"))
        XCTAssertNil(
            text.rangeOfCharacter(from: .decimalDigits),
            "before the first byte there is no honest number to show, got: \(text)")

        try assertRenders(state, named: "connecting", showing: ["Connecting", "Cancel"])
    }

    func testConnectingWithAPartialSaysWhatItResumesFrom() throws {
        let progress = DownloadProgress(receivedBytes: 115_000_000, totalBytes: totalBytes)
        let state = UpdateState.connecting(release, progress)

        let text = UpdateCardView.statusText(for: state)
        XCTAssertTrue(text.contains("Connecting"))
        XCTAssertTrue(text.contains("resuming"))
        XCTAssertTrue(
            text.contains(DownloadProgressText.bytes(progress)),
            "a resume must say how much is already down, got: \(text)")

        try assertRenders(
            state, named: "connecting-resuming",
            showing: ["Connecting", "resuming", DownloadProgressText.bytes(progress)])
    }

    func testEarlyDownloadLeadsWithBytesRateAndTimeRemaining() throws {
        let progress = DownloadProgress(
            receivedBytes: 11_300_000, totalBytes: totalBytes, bytesPerSecond: 9_400_000)
        let state = UpdateState.downloading(release, progress)

        let text = UpdateCardView.statusText(for: state)
        XCTAssertTrue(
            text.contains(DownloadProgressText.bytes(progress)),
            "bytes-of-total is what tells a slow download from a dead one, got: \(text)")
        XCTAssertTrue(text.contains(try XCTUnwrap(DownloadProgressText.rate(progress))))
        XCTAssertTrue(text.contains(try XCTUnwrap(DownloadProgressText.remaining(progress))))
        XCTAssertFalse(
            text.contains("%"),
            "a bare percentage is the 0% this pane exists to never show again, got: \(text)")

        try assertRenders(
            state, named: "downloading-early",
            showing: [
                DownloadProgressText.bytes(progress),
                try XCTUnwrap(DownloadProgressText.rate(progress)),
                try XCTUnwrap(DownloadProgressText.remaining(progress)),
            ])
    }

    func testNearlyFinishedDownloadStillLeadsWithBytes() throws {
        let progress = DownloadProgress(
            receivedBytes: 220_500_000, totalBytes: totalBytes, bytesPerSecond: 1_500_000)
        let state = UpdateState.downloading(release, progress)

        let text = UpdateCardView.statusText(for: state)
        XCTAssertTrue(text.contains(DownloadProgressText.bytes(progress)))
        XCTAssertFalse(text.contains("%"))
        // The last stretch says "a few seconds left" rather than counting down
        // to a zero it would then sit on while the file is closed.
        XCTAssertEqual(DownloadProgressText.remaining(progress), "a few seconds left")

        try assertRenders(
            state, named: "downloading-nearly-done",
            showing: [DownloadProgressText.bytes(progress), "a few seconds left"])
    }

    func testVerifyingNamesTheReleaseInsteadOfAStalledFullBar() throws {
        let state = UpdateState.verifying(release)

        let text = UpdateCardView.statusText(for: state)
        XCTAssertTrue(text.contains("Verifying"))
        XCTAssertTrue(text.contains(release.version.description))

        try assertRenders(state, named: "verifying", showing: ["Verifying", "0.6.0"])
    }

    func testFailureCarryingARetryableReleaseOffersRetryWithTheReason() throws {
        let reason = "The download stalled: no data arrived for 30 seconds."
        let state = UpdateState.failed(reason, retryable: release)

        XCTAssertEqual(UpdateCardView.statusText(for: state), reason)

        try assertRenders(state, named: "failed-retryable", showing: ["stalled", "Retry", "Dismiss"])
    }

    // MARK: - Rendering

    /// Rasterises the card in `state`, writes the PNG, and asserts what a
    /// human would otherwise eyeball: the canvas is the fixed size, it is not
    /// blank, and OCR finds every fragment of `showing` in the pixels.
    private func assertRenders(
        _ state: UpdateState, named name: String, showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // A white canvas with the light appearance forced, so the render does
        // not depend on the appearance the test host happened to inherit.
        let card = UpdateCardView(
            state: state,
            checkForUpdates: {}, download: { _ in }, cancelDownload: {},
            installAndRelaunch: { _, _ in }, dismiss: {}
        )
        .frame(width: Self.cardSize.width)
        .frame(height: Self.cardSize.height, alignment: .top)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: card)
        hosting.frame = CGRect(origin: .zero, size: Self.cardSize)

        // The window is never ordered front: `cacheDisplay` draws without it
        // ever appearing, so no test flashes a panel or steals focus.
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            "no bitmap to draw \(name) into", file: file, line: line)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, "no image behind \(name)", file: file, line: line)

        // The canvas is fixed in points; the pixel dimensions follow whatever
        // backing scale the machine's screen gives the offscreen window.
        let scale = window.backingScaleFactor
        XCTAssertGreaterThanOrEqual(scale, 1, "no backing scale for \(name)", file: file, line: line)
        XCTAssertEqual(
            image.width, Int(Self.cardSize.width * scale), "width of \(name)",
            file: file, line: line)
        XCTAssertEqual(
            image.height, Int(Self.cardSize.height * scale), "height of \(name)",
            file: file, line: line)

        let pixels = try XCTUnwrap(
            image.dataProvider?.data as Data?, "no pixel data behind \(name)",
            file: file, line: line)
        let first = pixels.first
        XCTAssertTrue(
            pixels.contains { $0 != first }, "the render of \(name) is a blank canvas",
            file: file, line: line)

        try write(image, named: name)

        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    private func write(_ image: CGImage, named name: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // The card's byte counts and version numbers are not prose; language
        // correction "fixes" them into words.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// OCR is trusted for glyphs, not for spacing: line breaks and the spaces
    /// around "of" and "/s" come back unevenly, so both sides are compared
    /// with whitespace removed and case folded.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
