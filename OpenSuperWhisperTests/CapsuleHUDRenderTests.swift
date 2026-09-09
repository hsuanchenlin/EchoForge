import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the capsule and reads it back.
///
/// The capsule is the hardest surface in the app to look at: it exists for a few
/// seconds, on top of whatever the user was typing in, on a build with a
/// microphone grant. The microphone diagnostics make that worse, because the
/// states worth checking are the ones that need a broken microphone to produce.
/// So they are rendered offscreen instead - an `NSHostingView` in a window that
/// is never shown, rasterised with `cacheDisplay`, needing no permission and
/// flashing nothing on screen. Renders land in `/tmp/EchoForgeCapsuleRenders/`
/// for a human to open.
@MainActor
final class CapsuleHUDRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeCapsuleRenders", isDirectory: true)

    /// The render's clock starts *now* rather than at a fixed epoch, and that is
    /// not laziness: the duration counter is a `TimelineView` reading the real
    /// wall clock against the view model's start date, so a 1970 fixture draws
    /// "496645:21:20" and makes every render unreadable - and wider than the pill
    /// it is measuring.
    private var clock = Date()

    override func setUp() {
        super.setUp()
        clock = Date()
    }

    // MARK: - The ordinary pill

    /// A dictation that is going fine says nothing about the microphone: the
    /// meter, the counter and the chip, exactly as before.
    func testAHealthyRecordingIsStillTheOneRowPill() throws {
        let viewModel = recording(peakDecibels: -11, seconds: 3)

        let image = try render(viewModel, named: "capsule-recording")
        let text = normalized(try recognizedText(in: image))
        XCTAssertFalse(text.contains(normalized("No signal")))
        XCTAssertFalse(text.contains(normalized("Low signal")))
        XCTAssertFalse(text.contains(normalized("Clipping")))
        XCTAssertEqual(viewModel.signal, .good)
    }

    // MARK: - The three diagnostics

    /// The line names the state **and** the input it came from: "no signal" is
    /// not actionable until the user knows which microphone the app is on, and
    /// they are dictating into another app and cannot go and look.
    func testASilentMicrophoneIsNamedOnThePill() throws {
        let viewModel = recording(
            peakDecibels: -160, seconds: 3, microphoneName: "MacBook Pro Microphone")
        XCTAssertEqual(viewModel.signal, .noSignal)

        try assert(
            viewModel, named: "capsule-no-signal",
            showing: ["No signal", "MacBook Pro Microphone"])
    }

    func testAQuietMicrophoneSaysSoAndNamesItself() throws {
        let viewModel = recording(peakDecibels: -36, seconds: 3, microphoneName: "Amiron wireless")
        XCTAssertEqual(viewModel.signal, .low)

        try assert(
            viewModel, named: "capsule-low-signal", showing: ["Low signal", "Amiron wireless"])
    }

    func testAClippingMicrophoneSaysSoAndNamesItself() throws {
        let viewModel = recording(peakDecibels: 0, seconds: 3, microphoneName: "Scarlett Solo USB")
        XCTAssertEqual(viewModel.signal, .clipping)

        try assert(
            viewModel, named: "capsule-clipping", showing: ["Clipping", "Scarlett Solo USB"])
    }

    func testTheDiagnosticIsLegibleInDarkModeToo() throws {
        let viewModel = recording(
            peakDecibels: -160, seconds: 3, microphoneName: "MacBook Pro Microphone")

        try assert(
            viewModel, named: "capsule-no-signal-dark", scheme: .dark,
            showing: ["No signal", "MacBook Pro Microphone"])
    }

    /// An audio interface can name itself in sixty characters. The line
    /// truncates rather than widening the pill past the panel that contains it -
    /// anything outside the *window* bounds is cut off, so a pill that overflowed
    /// would be one with its own rounded edge sliced away.
    ///
    /// Checked in pixels rather than in frames: the pill is laid out inside a
    /// hosting view pinned to the panel size, so its own frame is not something
    /// the view hierarchy reports back. What can be read is whether anything was
    /// drawn against the panel's edges, and that is exactly the failure.
    func testALongDeviceNameDoesNotPushThePillOutOfItsPanel() throws {
        let viewModel = recording(
            peakDecibels: -160, seconds: 3,
            microphoneName: "Universal Audio Apollo Twin X QUAD Heritage Edition Input 1")

        let rep = try bitmap(of: try host(viewModel, scheme: .light))
        try write(try XCTUnwrap(rep.cgImage), named: "capsule-long-device-name")

        let ground = try XCTUnwrap(rep.colorAt(x: 1, y: 1), "no pixel at the corner")
        for x in [0, 1, rep.pixelsWide - 2, rep.pixelsWide - 1] {
            for y in stride(from: 2, to: rep.pixelsHigh - 2, by: 4) {
                let pixel = try XCTUnwrap(rep.colorAt(x: x, y: y))
                XCTAssertEqual(
                    pixel.redComponent, ground.redComponent, accuracy: 0.02,
                    "the pill is drawn against the panel edge at (\(x), \(y))")
            }
        }
    }

    // MARK: - Fixtures

    /// A view model mid-capture, having heard `seconds` of audio peaking at
    /// `peakDecibels`.
    private func recording(
        peakDecibels: Float, seconds: TimeInterval, microphoneName: String? = nil
    ) -> CapsuleHUDViewModel {
        let viewModel = CapsuleHUDViewModel(
            now: { [unowned self] in self.clock }, schedule: { _, _ in })
        viewModel.beginSession(mode: .dictate, microphoneName: microphoneName)
        viewModel.beginRecording()

        var elapsed: TimeInterval = 0
        var phase = 0
        while elapsed < seconds {
            // A shaped envelope rather than a flat line, so the render shows the
            // meter the way a real voice draws it.
            let shape = Float(abs(sin(Double(phase) / 3.0)))
            viewModel.pushLevel(
                MicrophoneLevel(
                    averageDecibels: peakDecibels - 8 - (1 - shape) * 12,
                    peakDecibels: peakDecibels - (1 - shape) * 6))
            phase += 1
            elapsed += AudioRecorder.levelSampleInterval
            clock = clock.addingTimeInterval(AudioRecorder.levelSampleInterval)
        }
        viewModel.refreshSignal()
        return viewModel
    }

    // MARK: - Rendering

    private func assert(
        _ viewModel: CapsuleHUDViewModel,
        named name: String,
        scheme: ColorScheme = .light,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let image = try render(viewModel, named: name, scheme: scheme)
        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    @discardableResult
    private func render(
        _ viewModel: CapsuleHUDViewModel, named name: String, scheme: ColorScheme = .light
    ) throws -> CGImage {
        let hosting = try host(viewModel, scheme: scheme)
        let image = try self.image(of: hosting)
        try write(image, named: name)

        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?, "no pixel data")
        let first = pixels.first
        XCTAssertTrue(pixels.contains { $0 != first }, "the render is a blank canvas")
        return image
    }

    /// Lays the capsule out in a window that is never shown, over a flat ground
    /// so the pill's material has something to sit on.
    private func host(
        _ viewModel: CapsuleHUDViewModel, scheme: ColorScheme
    ) throws -> NSHostingView<AnyView> {
        let root = AnyView(
            CapsuleHUDView(viewModel: viewModel)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.86))
                .environment(\.colorScheme, scheme))

        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: CapsuleHUDView.windowSize)

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func bitmap(of hosting: NSHostingView<AnyView>) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "no bitmap to draw into")
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private func image(of hosting: NSHostingView<AnyView>) throws -> CGImage {
        try XCTUnwrap(try bitmap(of: hosting).cgImage, "no image behind the render")
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
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
