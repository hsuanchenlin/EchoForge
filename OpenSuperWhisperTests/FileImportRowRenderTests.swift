import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// The row that makes file transcription findable, drawn and read back.
///
/// It sits inside `ContentView`, behind a microphone and an Accessibility grant,
/// so the only other way to look at it is to launch a fully permitted build - and
/// the state that matters most, a queue with files in it, needs audio files
/// dropped on that build first. Renders land in `/tmp/EchoForgeFileRenders/`.
@MainActor
final class FileImportRowRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeFileRenders", isDirectory: true)

    /// The narrowest window `ContentView` allows, less the list's own padding -
    /// this row shares that width with a button, so it is where it is tightest.
    private static let compactWidth: CGFloat = 400 - 32
    private static let regularWidth: CGFloat = 450 - 32

    /// The whole point: it says what it does **before** anything is dragged.
    func testItInvitesFilesBeforeADragHasStarted() throws {
        for (name, width) in [("compact", Self.compactWidth), ("regular", Self.regularWidth)] {
            try assert(
                row(queued: 0), named: "file-import-\(name)", width: width,
                showing: ["Drop audio files", "Open Files"])
        }
    }

    /// A queue is counted, because "transcribing…" over four files reads as one
    /// file taking a very long time.
    func testAQueueIsCountedAndOffersTheWayToLookAtIt() throws {
        try assert(
            row(queued: 3), named: "file-import-queued", width: Self.regularWidth,
            showing: ["3 files in the queue", "Show", "Open Files"])
    }

    /// The lens is a toggle, and the way back is offered from the same row that
    /// sent the user there.
    func testTheLensOffersTheWayBackOnceItIsApplied() throws {
        try assert(
            row(queued: 2, showingFiles: true), named: "file-import-lens-on",
            width: Self.regularWidth, showing: ["Show all"])
    }

    func testItIsLegibleInDarkModeToo() throws {
        try assert(
            row(queued: 0), named: "file-import-dark", width: Self.regularWidth, scheme: .dark,
            showing: ["Drop audio files", "Open Files"])
    }

    // MARK: - The wording, as a decision

    func testTheQueueSummaryCountsRatherThanPluralisingWrongly() {
        XCTAssertEqual(FileImportRow.queueSummary(count: 1), "1 file in the queue")
        XCTAssertEqual(FileImportRow.queueSummary(count: 4), "4 files in the queue")
    }

    /// A reader who cannot see the well is told both ways in - the drop and the
    /// button - because the drop is the one they cannot discover by tabbing.
    func testTheRowNamesBothWaysInForAReaderWhoCannotSeeIt() {
        XCTAssertTrue(FileImportRow.accessibilityHint.contains("Drop"))
        XCTAssertTrue(FileImportRow.accessibilityHint.contains("Open Files"))
        XCTAssertFalse(FileImportRow.prompt.isEmpty)
    }

    // MARK: - Fixtures

    private func row(queued: Int, showingFiles: Bool = false) -> FileImportRow {
        FileImportRow(
            queuedFileCount: queued, isShowingFiles: showingFiles, showFiles: {}, open: { _ in })
    }

    // MARK: - Rendering

    private func assert<Content: View>(
        _ content: Content,
        named name: String,
        width: CGFloat,
        scheme: ColorScheme = .light,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = AnyView(
            content
                .frame(width: width)
                .padding(16)
                .background(ThemePalette.windowBackground(scheme))
                .environment(\.colorScheme, scheme))

        let hosting = NSHostingView(rootView: root)
        let height = hosting.fittingSize.height
        hosting.frame = CGRect(
            origin: .zero, size: CGSize(width: width + 32, height: max(height, 60)))

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "no bitmap to draw into")
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, "no image behind the render")

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))

        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, width + 32,
            "the row lays itself out wider than the window it lives in")

        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
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
