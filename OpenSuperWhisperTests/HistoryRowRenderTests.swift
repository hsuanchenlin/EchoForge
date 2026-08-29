import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the history card at both widths and reads the result back.
///
/// The same offscreen technique as `HistoryProvenanceRenderTests` - an
/// `NSHostingView` in a window that is never shown, rasterised with
/// `cacheDisplay`, which needs no permission and flashes nothing on screen.
/// Renders land in `/tmp/EchoForgeHistoryRenders/` for a human to open.
///
/// What this file is here to catch is what a metrics test cannot: a card that
/// lays itself out wider than the list offers, a state whose text has nowhere
/// to wrap, and a tier that is a different set of numbers but the same picture.
final class HistoryRowRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeHistoryRenders", isDirectory: true)

    /// What a row is offered in the narrowest window `ContentView` allows
    /// (`minWidth: 400`), less the list's own horizontal padding.
    private static let compactWidth: CGFloat = 400 - 32
    /// A window the user has dragged out to a comfortable reading width.
    private static let regularWidth: CGFloat = 820 - 32

    private static let transcript =
        "The quick brown fox jumps over the lazy dog, and then says something "
        + "rather longer so the card has to decide where to wrap it."

    // MARK: - Both tiers, every state

    @MainActor
    func testACompletedRowReadsAtBothWidths() throws {
        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "completed-\(tier.rawValue)",
                recording: recording(status: .completed),
                tier: tier,
                // The tail as well as the head: without it a transcript
                // truncated to one line at a wide width still passes, which is
                // exactly the bug this fixture was built from.
                showing: ["Dictation", "quick brown fox", "wrap it"]
            )
        }
    }

    @MainActor
    func testAFailedRowKeepsItsBadgeAndItsTranscriptAtBothWidths() throws {
        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "failed-\(tier.rawValue)",
                recording: recording(
                    status: .failed,
                    transcription: "No engine could transcribe this. Choose another engine and press regenerate."),
                tier: tier,
                showing: ["Transcription failed", "press regenerate"]
            )
        }
    }

    @MainActor
    func testARunningTranscriptionShowsItsProgressAtBothWidths() throws {
        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "transcribing-\(tier.rawValue)",
                recording: recording(
                    status: .transcribing, transcription: "", progress: 0.42,
                    sourceFileURL: "/tmp/some-long-interview-recording.m4a"),
                tier: tier,
                showing: ["Transcribing", "42%"]
            )
        }
    }

    @MainActor
    func testAQueuedRowSaysItIsQueuedAtBothWidths() throws {
        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "queued-\(tier.rawValue)",
                recording: recording(status: .pending, transcription: "", progress: 0),
                tier: tier,
                showing: ["In queue"]
            )
        }
    }

    @MainActor
    func testARowWithNoSpeechSaysSoAtBothWidths() throws {
        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "silent-\(tier.rawValue)",
                recording: recording(status: .completed, transcription: ""),
                tier: tier,
                showing: ["No speech detected"]
            )
        }
    }

    /// The longest label this row can carry, plus the sentence under it, plus
    /// the metadata chips. If anything is going to be pushed off the edge it is
    /// this row.
    @MainActor
    func testTheLongestCommandRowStillFitsAtBothWidths() throws {
        var recording = recording(
            status: .completed, transcription: "Open YouTube channel Vali101")
        recording.provenance = .youTubeCommandNotOpened(
            reason: .channelUnknown,
            message: "No allowlisted YouTube channel answers to “Vali101”. Add it in Settings → Dictionary & Snippets → YouTube Channels, or add that spelling as a spoken name on the channel you meant.")

        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "command-refused-\(tier.rawValue)",
                recording: recording,
                tier: tier,
                showing: ["YouTube command", "not opened", "Vali101", "spoken name"]
            )
        }
    }

    /// Dark mode is not a filter over the light one: the card fill, the border
    /// and the failure tint are each chosen per scheme.
    @MainActor
    func testTheCardDrawsInDarkModeToo() throws {
        try assertRow(
            named: "completed-dark",
            recording: recording(status: .completed),
            tier: .regular,
            scheme: .dark,
            showing: ["Dictation", "quick brown fox"]
        )
    }

    // MARK: - Fix with AI

    /// A corrected row says so, and keeps the way back to what it said before.
    @MainActor
    func testACorrectedRowShowsItsBadgeAndItsOriginalAtBothWidths() throws {
        var recording = recording(status: .completed, transcription: "我在開會，三點結束。")
        recording.rawTranscription = "我再開會，三點結束。"
        recording.aiCorrectedAt = Date(timeIntervalSince1970: 1_700_000_500)

        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "corrected-\(tier.rawValue)",
                recording: recording,
                tier: tier,
                // "Polished" rather than "AI Polished": Vision reads a capital
                // I as a lowercase L about half the time, so an assertion on
                // the two letters "AI" fails on a render that is perfectly
                // legible. The word beside them is what identifies the chip.
                showing: ["Polished", "Show original", "Compare"]
            )
        }
    }

    /// The press has to be visible on the card while the model works, or a slow
    /// correction and a button that did nothing look identical.
    @MainActor
    func testARowBeingFixedSaysSoAtBothWidths() async throws {
        let recording = recording(status: .completed)
        let release = expectation(description: "the model may answer")
        let corrections = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                await fulfillment(of: [release], timeout: 20)
                return StyledTranscript(
                    raw: request.original, transcript: request.text, final: request.text,
                    status: .notRequested)
            },
            committing: { _, _, _, _ in .applied }
        )
        XCTAssertTrue(corrections.correct(recording))

        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "fixing-\(tier.rawValue)",
                recording: recording,
                corrections: corrections,
                tier: tier,
                // "AI" is left out of the fragment for the reason above.
                showing: ["Fixing with"]
            )
        }

        release.fulfill()
        try await settle(corrections, recording.id)
    }

    /// A press that changed nothing explains itself on the card and nowhere
    /// else - never an alert, because the row still has every word it had.
    @MainActor
    func testAFixThatChangedNothingExplainsItselfOnTheCard() async throws {
        let recording = recording(status: .completed)
        let corrections = TranscriptCorrectionCoordinator(
            correcting: { request in
                StyledTranscript(
                    raw: request.original, transcript: request.text, final: request.text,
                    status: .unavailable(.appleIntelligenceOff))
            },
            committing: { _, _, _, _ in .applied }
        )
        corrections.correct(recording)
        try await settle(corrections, recording.id)

        for tier in HistoryWidthTier.allCases {
            try assertRow(
                named: "fix-refused-\(tier.rawValue)",
                recording: recording,
                corrections: corrections,
                tier: tier,
                showing: ["Apple Intelligence", "quick brown fox"]
            )
        }
    }

    /// The shimmer must not change how tall the row is.
    ///
    /// It is drawn over the words the card is still showing - a correction
    /// replaces nothing until it lands - so a card that grew while the model
    /// worked would push every row under it down the list and back again. That
    /// is exactly what `ShimmerOverlay` does when it is stacked beside the
    /// transcript rather than laid over it: it is a `GeometryReader`, so it
    /// takes every point it is offered, and the card grew by hundreds.
    ///
    /// The tolerance is the footer strip's progress ring, which is 15 pt where
    /// the timestamp beside it is 13 - the same two points a regeneration
    /// costs. Anything past that is the shimmer sizing the card again.
    ///
    /// Measured while the hosting view is allowed to size itself, which is the
    /// only measurement that says what a row asks a real list for.
    @MainActor
    func testFixingARowDoesNotChangeItsHeight() async throws {
        let recording = recording(status: .completed)
        let release = expectation(description: "the model may answer")
        let corrections = TranscriptCorrectionCoordinator(
            correcting: { [self] request in
                await fulfillment(of: [release], timeout: 20)
                return StyledTranscript(
                    raw: request.original, transcript: request.text, final: request.text,
                    status: .notRequested)
            },
            committing: { _, _, _, _ in .applied }
        )

        let idle = try height(
            of: row(recording), width: Self.regularWidth, metrics: .regular)
        XCTAssertTrue(corrections.correct(recording))
        let fixing = try height(
            of: row(recording, corrections: corrections),
            width: Self.regularWidth, metrics: .regular)

        XCTAssertEqual(
            fixing, idle, accuracy: 3,
            "the card changed height while it was being fixed")

        release.fulfill()
        try await settle(corrections, recording.id)
    }

    @MainActor
    private func settle(
        _ corrections: TranscriptCorrectionCoordinator, _ id: UUID,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0 ..< 400 {
            if !corrections.isCorrecting(id) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the correction never finished", file: file, line: line)
    }

    // MARK: - The tiers are actually different

    /// Two sets of numbers that produce the same picture would make the whole
    /// responsive layout a no-op that still passed every render assertion.
    @MainActor
    func testTheTwoTiersProduceDifferentLayouts() throws {
        let recording = recording(status: .completed)
        let width = Self.regularWidth

        let compact = try height(
            of: row(recording), width: width, metrics: .compact)
        let regular = try height(
            of: row(recording), width: width, metrics: .regular)

        XCTAssertNotEqual(
            compact, regular,
            "the compact and regular tiers lay the same row out identically")
        XCTAssertGreaterThan(
            compact, regular,
            "the compact tier stacks its metadata, so it must be the taller of the two")
    }

    /// The wiring, end to end: a list that measures itself must hand its rows
    /// the tier for the width it measured, not the environment default.
    @MainActor
    func testTheListHandsItsRowsTheTierForItsOwnWidth() throws {
        let recording = recording(status: .completed)

        let measuredWide = try height(
            of: row(recording).historyRowMetricsForContainerWidth(),
            width: Self.regularWidth, metrics: nil)
        let explicitRegular = try height(
            of: row(recording), width: Self.regularWidth, metrics: .regular)
        let explicitCompact = try height(
            of: row(recording), width: Self.regularWidth, metrics: .compact)

        XCTAssertEqual(
            measuredWide, explicitRegular, accuracy: 1,
            "a wide list did not put its rows in the regular tier")
        XCTAssertNotEqual(
            measuredWide, explicitCompact,
            "a wide list left its rows in the compact default")

        let measuredNarrow = try height(
            of: row(recording).historyRowMetricsForContainerWidth(),
            width: Self.compactWidth, metrics: nil)
        let narrowCompact = try height(
            of: row(recording), width: Self.compactWidth, metrics: .compact)
        XCTAssertEqual(
            measuredNarrow, narrowCompact, accuracy: 1,
            "a narrow list did not put its rows in the compact tier")
    }

    // MARK: - Fixtures

    private func recording(
        status: RecordingStatus,
        transcription: String = HistoryRowRenderTests.transcript,
        progress: Float = 1.0,
        sourceFileURL: String? = nil
    ) -> Recording {
        var recording = Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000.wav",
            transcription: transcription,
            duration: 12.5,
            status: status,
            progress: progress,
            sourceFileURL: sourceFileURL
        )
        recording.provenance = .dictation
        return recording
    }

    @MainActor
    private func row(
        _ recording: Recording,
        corrections: TranscriptCorrectionCoordinator? = nil
    ) -> AnyView {
        AnyView(
            RecordingRow(
                recording: recording, searchQuery: "", onDelete: {}, onRegenerate: {},
                corrections: corrections ?? TranscriptCorrectionCoordinator()))
    }

    // MARK: - Rendering

    @MainActor
    private func assertRow(
        named name: String,
        recording: Recording,
        corrections: TranscriptCorrectionCoordinator? = nil,
        tier: HistoryWidthTier,
        scheme: ColorScheme = .light,
        showing fragments: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let width = tier == .compact ? Self.compactWidth : Self.regularWidth
        let hosting = try hostingView(
            for: row(recording, corrections: corrections), width: width,
            metrics: HistoryRowMetrics.metrics(for: tier), scheme: scheme)

        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            "no bitmap to draw \(name) into", file: file, line: line)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, "no image behind \(name)", file: file, line: line)

        let pixels = try XCTUnwrap(
            image.dataProvider?.data as Data?, "no pixel data behind \(name)",
            file: file, line: line)
        let first = pixels.first
        XCTAssertTrue(
            pixels.contains { $0 != first }, "the render of \(name) is a blank canvas",
            file: file, line: line)

        try write(image, named: name)

        // Nothing may lay itself out wider than the list offers, or the right
        // end of the row is simply gone.
        XCTAssertLessThanOrEqual(
            hosting.subviews.first?.frame.width ?? 0, width,
            "the \(name) render is wider than the list offers", file: file, line: line)

        let observed = try recognizedText(in: image)
        for fragment in fragments {
            XCTAssertTrue(
                normalized(observed).contains(normalized(fragment)),
                "expected \"\(fragment)\" in the \(name) render; OCR read: \(observed)",
                file: file, line: line)
        }
    }

    /// Lays a view out at a fixed width and reports the height it asks for.
    ///
    /// `metrics` is nil for the one case that must resolve its own: a view that
    /// measures its container and publishes the tier itself.
    @MainActor
    private func height<Content: View>(
        of content: Content, width: CGFloat, metrics: HistoryRowMetrics?
    ) throws -> CGFloat {
        let hosting = try hostingView(
            for: content, width: width, metrics: metrics, sizesToFit: true)
        return hosting.fittingSize.height
    }

    @MainActor
    private func hostingView<Content: View>(
        for content: Content,
        width: CGFloat,
        metrics: HistoryRowMetrics?,
        scheme: ColorScheme = .light,
        sizesToFit: Bool = false
    ) throws -> NSHostingView<AnyView> {
        var root = AnyView(
            content
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
        if let metrics {
            root = AnyView(root.environment(\.historyRowMetrics, metrics))
        }

        let hosting = NSHostingView(rootView: root)
        // `fittingSize` is only the height the row asks for while the hosting
        // view is still allowed to size itself; zeroing `sizingOptions` makes
        // it report the frame it was handed, which is the same number for
        // every tier and would let a broken layout pass.
        if !sizesToFit { hosting.sizingOptions = [] }
        hosting.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: sizesToFit ? 900 : 420))

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // A container that measures itself publishes its width through a
        // preference, which SwiftUI delivers on a later turn of the run loop.
        // One layout pass is not enough to see the answer.
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            hosting.layoutSubtreeIfNeeded()
        }
        return hosting
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
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Case and spacing folded away: OCR is not required to agree with the app
    /// about either, and neither changes whether the words are on screen.
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
