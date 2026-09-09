import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// Draws the Setup Health rows and the microphone test card, and reads them
/// back.
///
/// The pane's whole job is to be legible at a glance on a Mac that is in some
/// state or other, and almost none of those states can be produced on a
/// developer's machine: no microphone grant, a half-installed model, an engine
/// still downloading. `SetupHealthRow` and `MicrophoneTestCard` take values so
/// they can be described here instead. Renders land in
/// `/tmp/EchoForgeSetupRenders/` for a human to open.
@MainActor
final class SetupHealthRenderTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/EchoForgeSetupRenders", isDirectory: true)

    /// The pane's content width on the shipped sheet, less its own padding.
    private static let paneWidth: CGFloat =
        SettingsSheetLayout.contentWidth(inSheetOfWidth: SettingsSheetLayout.preferredSize.width) - 64

    // MARK: - The three statuses

    func testAHealthyRowReadsAsSettledAndOffersTheTabAnyway() throws {
        try assert(
            row(
                SetupHealthCheck(
                    topic: .engine, status: .ok,
                    detail: "SenseVoice-Small is chosen and running.", note: nil,
                    destination: .model)),
            named: "setup-ok",
            showing: ["Transcription engine", "SenseVoice-Small", "Model"])
    }

    func testARowNeedingAttentionNamesBothEnginesAndTheTabThatFixesIt() throws {
        try assert(
            row(
                SetupHealthCheck(
                    topic: .engine, status: .attention,
                    detail: "Paraformer-large (zh) is chosen and still being prepared. "
                        + "SenseVoice-Small is standing in - it is what you were dictating with "
                        + "before.",
                    note: nil, destination: .model)),
            named: "setup-attention",
            showing: ["Paraformer", "standing in", "Model"])
    }

    func testABlockedRowSaysWhatCannotHappenAndWhereToGrantIt() throws {
        try assert(
            row(
                SetupHealthCheck(
                    topic: .permissions, status: .blocked,
                    detail: "Accessibility is not granted, so Kongweh cannot paste what you say.",
                    note: "Grant it in System Settings → Privacy & Security → Accessibility.",
                    destination: nil)),
            named: "setup-blocked",
            showing: ["Permissions", "Accessibility", "System Settings"])
    }

    /// The privacy row is the longest line on the pane and the one that must not
    /// truncate: it is the only place the whole position is stated at once.
    func testThePrivacyRowFitsItsWholeSentence() throws {
        try assert(
            row(
                SetupHealthCheck(
                    topic: .privacy, status: .attention,
                    detail: "Kongweh sends your recordings to the provider you configured "
                        + "(api.openai.com).",
                    note: "Everything else - rewriting, corrections, Ask, screen queries and "
                        + "voice edit - stays on this Mac.",
                    destination: .cloud)),
            named: "setup-privacy",
            showing: ["api.openai.com", "stays on this Mac", "Cloud"])
    }

    func testTheRowsAreLegibleInDarkModeToo() throws {
        try assert(
            row(
                SetupHealthCheck(
                    topic: .microphone, status: .blocked,
                    detail: "No microphone is available.",
                    note: "Connect one, or check it is not disabled in System Settings → Sound.",
                    destination: nil)),
            named: "setup-blocked-dark", scheme: .dark,
            showing: ["Microphone", "No microphone"])
    }

    /// Seven rows one after another, which is what the user actually sees.
    func testTheWholePaneReadsAsAList() throws {
        let checks = SetupHealth.checks(
            SetupHealthInputs(
                selection: EngineSelection(
                    desired: .sensevoice, active: .sensevoice, activeWhisperModelPath: nil,
                    interimReason: nil),
                preparation: nil, preparationFailure: nil,
                inventory: [
                    ModelInventoryEntry(
                        engine: .sensevoice, readiness: .ready, installedBytes: 268_000_000,
                        expectedMegabytes: 240,
                        cacheDirectories: [URL(fileURLWithPath: "/tmp/m")])
                ],
                dictationLanguage: "zh", chineseOutputScript: .traditional,
                fluidAudioModelVersion: "v3",
                microphoneCount: 2, currentMicrophoneName: "MacBook Pro Microphone",
                isMicrophoneGranted: true, isAccessibilityGranted: true,
                isScreenRecordingGranted: false,
                trigger: .keyboardShortcut("⌥`"), shortcutConflicts: [],
                cloudIsCompiledIn: true, cloudTranscriptionSelected: false,
                cloudTranslationEnabled: false, cloudHost: nil))

        let list = VStack(spacing: 8) {
            ForEach(checks) { check in
                SetupHealthRow(check: check, open: { _ in })
            }
        }

        try assert(
            list, named: "setup-pane",
            showing: ["Transcription engine", "Language", "Microphone", "Where your speech goes"])
    }

    // MARK: - The microphone test

    func testTheTestCardSaysWhatItWillDoBeforeItDoesIt() throws {
        try assert(
            MicrophoneTestCard(test: MicrophoneTestViewModel()),
            named: "setup-mic-idle",
            showing: ["Microphone test", "throws the audio away", "Test microphone"])
    }

    /// The verdict is the shipped one: a test that says "fine" and a dictation
    /// that says "Low signal" would be two opinions about the same reading.
    func testTheVerdictWordingCoversEveryOutcome() {
        XCTAssertTrue(
            MicrophoneTestCard.verdictText(for: .good).contains("transcribe well"))
        for signal in [MicrophoneSignal.noSignal, .low, .clipping] {
            let text = MicrophoneTestCard.verdictText(for: signal)
            XCTAssertTrue(text.contains(signal.shortLabel ?? "\u{0}"))
            XCTAssertTrue(text.contains(signal.advice ?? "\u{0}"))
        }
        XCTAssertEqual(
            MicrophoneTestCard.liveText(for: .measuring), "Listening. Say a sentence.")
        XCTAssertEqual(MicrophoneTestCard.liveText(for: .low), "Low signal")
    }

    // MARK: - Fixtures

    private func row(_ check: SetupHealthCheck) -> some View {
        SetupHealthRow(check: check, open: { _ in })
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
