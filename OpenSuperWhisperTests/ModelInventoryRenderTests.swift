import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the model inventory rows and reads them back.
///
/// The rows are the only surface in the app that shows a *half*-installed model,
/// a model that is the last one that can transcribe, and a model being fetched -
/// and none of those can be produced on a developer's machine without breaking
/// something first. `ModelInventoryRow` takes values rather than a view model
/// exactly so they can be described here instead. Renders land in
/// `/tmp/EchoForgeModelRenders/` for a human to open.
@MainActor
final class ModelInventoryRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeModelRenders", isDirectory: true)

    /// The Settings pane's content width, less the card padding the rows sit in.
    private static let paneWidth: CGFloat =
        SettingsSheetLayout.contentWidth(inSheetOfWidth: SettingsSheetLayout.preferredSize.width) - 48

    /// The row leads with the **outcome**, and keeps the model name beside it -
    /// one because the picker above asks users to choose an implementation
    /// before anything says what it is for, the other because retaining the
    /// model name is a licence obligation.
    func testAReadyModelNamesWhatItIsForAndWhatItIsCalled() throws {
        try assert(
            row(engine: .sensevoice, readiness: .ready, bytes: 268_000_000, expected: 240),
            named: "model-ready",
            showing: [
                EngineCatalog.entry(for: .sensevoice).outcome,
                EngineCatalog.entry(for: .sensevoice).displayName,
                "Ready",
                "240 MB",
            ])
    }

    /// The state a "downloaded" badge could never show. It has to name itself,
    /// or the only visible symptom is a model that downloads itself again.
    func testAHalfInstalledModelSaysSoAndOffersToRetry() throws {
        try assert(
            row(engine: .paraformer, readiness: .incomplete, bytes: 120_000_000, expected: 653),
            named: "model-incomplete",
            showing: ["Incomplete", "Retry", "Remove"])
    }

    func testAModelThatIsNotInstalledOffersOnlyToDownloadIt() throws {
        let image = try render(
            row(engine: .paraformer, readiness: .notInstalled, bytes: 0, expected: 653),
            named: "model-not-installed")
        let text = normalized(try recognizedText(in: image))

        XCTAssertTrue(text.contains(normalized("Not installed")))
        XCTAssertTrue(text.contains(normalized("Download")))
        XCTAssertFalse(
            text.contains(normalized("Remove")), "there is nothing on the disk to remove")
    }

    /// Whisper and Parakeet pick between several models, so the row must not
    /// offer to download one on the user's behalf.
    func testAMultiModelEngineIsSentToItsOwnList() throws {
        try assert(
            row(engine: .whisper, readiness: .notInstalled, bytes: 0, expected: nil),
            named: "model-multi",
            showing: ["Choose a model"])
    }

    func testTheEngineInUseAndTheRecommendedOneAreBothMarked() throws {
        try assert(
            row(
                engine: .sensevoice, readiness: .ready, bytes: 268_000_000, expected: 240,
                isRecommended: true, isActive: true),
            named: "model-recommended-active",
            showing: ["Recommended", "In use"])
    }

    func testADownloadInFlightShowsItsPercentage() throws {
        try assert(
            row(
                engine: .sensevoice, readiness: .preparing(.downloading(fraction: 0.42)),
                bytes: 90_000_000, expected: 240),
            named: "model-downloading",
            showing: ["Downloading 42", "Cancel"])
    }

    /// The compile publishes no fraction, so the row says what it is doing
    /// rather than showing a bar that has stopped moving.
    func testACompileSaysPreparingRatherThanShowingAStalledBar() throws {
        try assert(
            row(engine: .sensevoice, readiness: .preparing(.preparing), bytes: 268_000_000,
                expected: 240),
            named: "model-preparing",
            showing: ["Preparing"])
    }

    func testTheCloudEngineIsListedAsKeepingNothingHere() throws {
        try assert(
            row(engine: .cloud, readiness: .noWeightsToInstall, bytes: 0, expected: nil),
            named: "model-cloud",
            showing: ["No local weights"])
    }

    func testTheRowsAreLegibleInDarkModeToo() throws {
        try assert(
            row(
                engine: .sensevoice, readiness: .ready, bytes: 268_000_000, expected: 240,
                isRecommended: true),
            named: "model-ready-dark",
            scheme: .dark,
            showing: ["Ready", "Recommended"])
    }

    /// A row is read to somebody who cannot see it as one thing, not as eight
    /// labels and five buttons.
    func testARowSaysWhatItIsAndWhereItStandsToAReaderWhoCannotSeeIt() {
        let entry = ModelInventoryEntry(
            engine: .sensevoice, readiness: .ready, installedBytes: 268_000_000,
            expectedMegabytes: 240, cacheDirectories: [URL(fileURLWithPath: "/tmp/x")])

        XCTAssertTrue(entry.sizeSummary.contains("240 MB"))
        XCTAssertEqual(entry.outcome, EngineCatalog.entry(for: .sensevoice).outcome)
        XCTAssertEqual(entry.displayName, EngineCatalog.entry(for: .sensevoice).displayName)
    }

    // MARK: - Fixtures

    private func row(
        engine: EngineKind,
        readiness: ModelReadiness,
        bytes: Int64,
        expected: Int?,
        isRecommended: Bool = false,
        isActive: Bool = false,
        isSelected: Bool = false
    ) -> ModelInventoryRow {
        ModelInventoryRow(
            entry: ModelInventoryEntry(
                engine: engine,
                readiness: readiness,
                installedBytes: bytes,
                expectedMegabytes: expected,
                cacheDirectories: engine == .cloud ? [] : [URL(fileURLWithPath: "/tmp/models")]),
            isRecommended: isRecommended,
            isActive: isActive,
            isSelected: isSelected,
            recommendationReason: EngineRecommendation.reason(
                for: EngineRecommendation.Machine(
                    dictationLanguage: "zh", systemLanguage: "en",
                    physicalMemoryBytes: 32 << 30, mixesEnglishAndChinese: false,
                    fluidAudioModelVersion: "v3")),
            download: {}, cancel: {}, choose: {}, reveal: {}, remove: {})
    }

    // MARK: - Rendering

    private func assert<Content: View>(
        _ content: Content,
        named name: String,
        scheme: ColorScheme = .light,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let image = try render(content, named: name, scheme: scheme)
        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    @discardableResult
    private func render<Content: View>(
        _ content: Content, named name: String, scheme: ColorScheme = .light
    ) throws -> CGImage {
        let root = AnyView(
            content
                .frame(width: Self.paneWidth)
                .padding(16)
                .background(ThemePalette.windowBackground(scheme))
                .environment(\.colorScheme, scheme))

        let hosting = NSHostingView(rootView: root)
        let height = hosting.fittingSize.height
        hosting.frame = CGRect(
            origin: .zero, size: CGSize(width: Self.paneWidth + 32, height: max(height, 80)))

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
            hosting.subviews.first?.frame.width ?? 0, Self.paneWidth + 32,
            "the row is wider than the pane it has to fit in")
        return image
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
