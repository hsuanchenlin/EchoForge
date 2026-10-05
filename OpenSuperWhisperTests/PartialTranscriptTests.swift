import XCTest

@testable import OpenSuperWhisper

/// The accumulator, and the rule that makes partial output honest.
final class PartialTranscriptAccumulatorTests: XCTestCase {

    func testSegmentsAreJoinedInOrder() {
        var accumulator = PartialTranscriptAccumulator()
        _ = accumulator.append(" We ship")
        let second = accumulator.append(" on Friday.")

        XCTAssertEqual(second?.text, "We ship on Friday.")
        XCTAssertEqual(second?.segment, " on Friday.")
        XCTAssertEqual(second?.segmentCount, 2)
    }

    /// The text only ever grows: whisper commits a segment and never revises it,
    /// which is the whole reason this app is willing to show partial output at
    /// all.
    func testTheTextOnlyEverGrows() {
        var accumulator = PartialTranscriptAccumulator()
        var lengths: [Int] = []
        for segment in [" one", " two", " three", " four"] {
            if let partial = accumulator.append(segment) { lengths.append(partial.text.count) }
        }
        XCTAssertEqual(lengths, lengths.sorted())
    }

    /// A decode that has produced only whitespace has produced nothing, and a
    /// surface asked to show nothing would grow a blank line.
    func testASilentSegmentReportsNothing() {
        var accumulator = PartialTranscriptAccumulator()
        XCTAssertNil(accumulator.append("   "))
        XCTAssertNil(accumulator.append("\n"))
        XCTAssertNotNil(accumulator.append(" words"))
    }

    func testTheCountIncludesSegmentsThatSaidNothing() {
        var accumulator = PartialTranscriptAccumulator()
        _ = accumulator.append(" ")
        _ = accumulator.append("hello")
        XCTAssertEqual(accumulator.segmentCount, 2)
    }
}

/// Which engines can report partial output, and what the ones that cannot do.
@MainActor
final class PartialTranscriptEngineTests: XCTestCase {

    /// Whisper is the one engine in this app that segments as it decodes. The
    /// other three return one final string, and a protocol they could never
    /// fill would turn "does this engine have partial output" into a runtime
    /// question instead of a fact.
    func testOnlyWhisperEmitsPartialOutput() {
        XCTAssertTrue(WhisperEngine() is PartialTranscriptEmitting)

        let others: [TranscriptionEngine] = [
            SenseVoiceEngine(), ParaformerEngine(),
        ]
        for engine in others {
            XCTAssertFalse(
                engine is PartialTranscriptEmitting,
                "\(engine.engineName) claims partial output it cannot produce")
        }
    }

    /// The published value is cleared rather than left to replay. `@Published`
    /// hands a fresh subscriber the last value it saw, which for this one is the
    /// previous dictation's words on this dictation's overlay.
    func testCancellingClearsWhatWasDecodedSoFar() {
        let service = TranscriptionService.shared
        service.cancelTranscription()
        XCTAssertNil(service.partialTranscript)
    }
}

/// The script the service publishes a preview in.
///
/// The whole-file whisper decode is the second surface that shows words before
/// `TextPostProcessor.process` has run - the first is a live session - and the
/// two have to agree, because the same dictation can produce both: a live
/// session that falls back hands the recording to this path and the capsule
/// goes on showing its segments.
@MainActor
final class ServicePartialTranscriptScriptTests: IsolatedPreferencesTestCase {

    /// One engine that reports a segment on cue. Nothing else about a decode
    /// is needed: the published preview is written where the callback lands.
    private final class SegmentingEngine: TranscriptionEngine, PartialTranscriptEmitting {
        var isModelLoaded = true
        var engineName: String { "segmenting" }
        var onProgressUpdate: ((Float) -> Void)?
        var onPartialTranscript: ((PartialTranscript) -> Void)?

        func initialize() async throws {}
        func transcribeAudio(url: URL, settings: Settings) async throws -> String { "" }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { [] }
    }

    private func published(
        _ raw: String, language: String, script: ChineseScriptVariant
    ) async -> PartialTranscript? {
        AppPreferences.shared.chineseOutputScript = script
        AppPreferences.shared.whisperLanguage = language
        let service = TranscriptionService()
        let engine = SegmentingEngine()
        service.observePartialTranscripts(of: engine, generation: 0, settings: Settings())

        engine.onPartialTranscript?(
            PartialTranscript(text: raw, segment: raw, segmentCount: 1))
        // The callback fires on the engine's own thread and hops to the main
        // actor, which is the hop this yield waits out.
        await Task.yield()
        return service.partialTranscript
    }

    /// The bug, on the whole-file path: whisper mixes the two scripts inside
    /// one sentence, and the capsule showed that mixture for the length of the
    /// decode before the paste arrived in one script.
    func testASimplifiedSegmentIsPublishedInTheChosenScript() async {
        let shown = await published("这个项目的进度很好", language: "zh", script: .traditional)

        XCTAssertEqual(shown?.text, "這個項目的進度很好")
        XCTAssertEqual(shown?.segment, "這個項目的進度很好")
    }

    func testSimplifiedIsHonouredOnThisPathToo() async {
        let shown = await published("這個項目", language: "zh", script: .simplified)

        XCTAssertEqual(shown?.text, "这个项目")
    }

    func testAnEnglishSegmentIsPublishedExactlyAsDecoded() async {
        let shown = await published(
            "We ship the release on Friday.", language: "en", script: .traditional)

        XCTAssertEqual(shown?.text, "We ship the release on Friday.")
    }

    /// The dictation language is read from the settings the transcription ran
    /// under, so a Japanese decode is no more converted here than anywhere
    /// else.
    func testAJapaneseSegmentIsNeverConverted() async {
        let shown = await published("学校に行きます", language: "ja", script: .traditional)

        XCTAssertEqual(shown?.text, "学校に行きます")
    }
}

/// The capsule's half: when it will show decoded words and when it refuses to.
@MainActor
final class CapsulePartialTranscriptTests: XCTestCase {

    private func decodingCapsule() -> CapsuleHUDViewModel {
        let viewModel = CapsuleHUDViewModel(now: { Date() }, schedule: { _, _ in })
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()
        viewModel.beginPolishing(.transcribing)
        return viewModel
    }

    func testDecodedWordsAppearWhileTheEngineIsRunning() {
        let viewModel = decodingCapsule()
        viewModel.showPartialTranscript("We ship on Friday")
        XCTAssertEqual(viewModel.partialText, "We ship on Friday")
    }

    /// The source is a global publisher, so the same rule `setMode` follows
    /// applies: a queue transcription (file drop, open-with, history regenerate)
    /// must not write its words onto a capsule that is still recording.
    func testAQueueTranscriptionCannotWriteOntoARecordingCapsule() {
        let viewModel = CapsuleHUDViewModel(now: { Date() }, schedule: { _, _ in })
        viewModel.beginSession(mode: .dictate)
        viewModel.beginRecording()

        viewModel.showPartialTranscript("somebody else's file")

        XCTAssertNil(viewModel.partialText)
    }

    func testAnEmptyPartialLeavesThePillAsItWas() {
        let viewModel = decodingCapsule()
        viewModel.showPartialTranscript("   ")
        XCTAssertNil(viewModel.partialText)
    }

    /// Once the model has the text, the pill says what it is doing with it
    /// rather than keeping a line of transcript beside a different promise.
    func testTheDecodedLineGoesWhenRewritingStarts() {
        let viewModel = decodingCapsule()
        viewModel.showPartialTranscript("We ship on Friday")
        viewModel.beginPolishing(.rewriting)
        XCTAssertNil(viewModel.partialText)
    }

    func testANewSessionDoesNotInheritTheLastOnesWords() {
        let viewModel = decodingCapsule()
        viewModel.showPartialTranscript("We ship on Friday")
        viewModel.beginSession(mode: .dictate)
        XCTAssertNil(viewModel.partialText)
    }
}
