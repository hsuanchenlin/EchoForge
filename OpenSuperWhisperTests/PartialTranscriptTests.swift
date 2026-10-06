import Combine
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

    /// One engine that reports a segment on cue - either when a test fires the
    /// callback itself, or from inside a real decode when `emitting` names the
    /// segment. Nothing else about a decode is needed: the published preview is
    /// written where the callback lands.
    private final class SegmentingEngine: TranscriptionEngine, PartialTranscriptEmitting,
        @unchecked Sendable
    {
        var isModelLoaded = true
        var engineName: String { "segmenting" }
        var onProgressUpdate: ((Float) -> Void)?
        var onPartialTranscript: ((PartialTranscript) -> Void)?

        private let emitting: String?

        init(emitting: String? = nil) { self.emitting = emitting }

        func initialize() async throws {}

        func transcribeAudio(url: URL, settings: Settings) async throws -> String {
            guard let emitting else { return "" }
            onPartialTranscript?(
                PartialTranscript(text: emitting, segment: emitting, segmentCount: 1))
            return emitting
        }

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
    ///
    /// Kanji-only on purpose: `isHanDominant` refuses on the first kana scalar
    /// whatever the language, so a fixture with kana in it would pass with the
    /// language gate deleted. `東京都庁見学` is Han-dominant, which leaves `ja`
    /// as the only thing keeping 学 from becoming 學.
    func testAJapaneseSegmentIsNeverConverted() async {
        XCTAssertTrue(ChineseScriptVariant.isHanDominant("東京都庁見学"))

        let shown = await published("東京都庁見学", language: "ja", script: .traditional)

        XCTAssertEqual(shown?.text, "東京都庁見学")
    }

    /// This path has no detection to read - whisper detects inside
    /// `whisper_full` and the segments arrive while it is still running - so on
    /// `auto` the language has not said Chinese and the segments show as the
    /// engine wrote them. Converting on the text alone is what let a kanji-only
    /// first segment carry a Japanese decode into Traditional; a live session,
    /// which pins a language of its own, is the path that can do better.
    func testAnAutoDecodeIsPublishedAsTheEngineWroteIt() async {
        let shown = await published("这个项目的进度很好", language: "auto", script: .traditional)

        XCTAssertEqual(shown?.text, "这个项目的进度很好")
    }

    // MARK: - The decode that draws its own line

    /// A live session's utterance decode publishes no segments here at all.
    ///
    /// The capsule is already in `.polishing(.transcribing)` while `finish`
    /// decodes the tail - the one state `showPartialTranscript` accepts this
    /// global publisher in - so segments published from a live decode would go
    /// up in the engine's own script, under the `auto` the decode still runs in,
    /// and be replaced a moment later by the committed line in the user's
    /// script. That is a rewrite of words already read.
    func testARawDecodePublishesNoSegments() async throws {
        let engine = SegmentingEngine(emitting: "我们开会")
        let service = TranscriptionService()
        service.engineOverride = engine
        let shown = Shown()
        let watching = service.$partialTranscript.compactMap { $0 }.sink { shown.append($0) }
        defer { watching.cancel() }

        _ = try await service.decodeRaw(url: Self.audioURL, settings: Self.chineseSettings())
        await Self.settle(until: { !shown.texts.isEmpty })

        XCTAssertEqual(shown.texts, [], "a live session's own decode put words on the capsule")
        XCTAssertNil(
            engine.onPartialTranscript,
            "and its callback must not be left on the engine for a later frame to fire")
    }

    /// And the whole-file decode still does, which is what makes the case above
    /// a decision rather than a dead callback: the same engine, the same
    /// segment, through `transcribeAudio`.
    func testAWholeFileDecodeStillPublishesItsSegments() async throws {
        let engine = SegmentingEngine(emitting: "我们开会")
        let service = TranscriptionService()
        service.engineOverride = engine
        let shown = Shown()
        let watching = service.$partialTranscript.compactMap { $0 }.sink { shown.append($0) }
        defer { watching.cancel() }

        _ = try await service.transcribeAudio(
            url: Self.audioURL, settings: Self.chineseSettings())
        await Self.settle(until: { !shown.texts.isEmpty })

        XCTAssertEqual(
            shown.texts, ["我們開會"],
            "the whole-file decode's own segments are still shown, in the chosen script")
    }

    /// What reached the publisher, collected off the main actor's turns.
    private final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ partial: PartialTranscript) {
            lock.lock(); defer { lock.unlock() }
            values.append(partial.text)
        }

        var texts: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    /// Waits for the main-actor hop each publish makes, up to a budget, so the
    /// positive case cannot pass on timing and the negative case cannot fail on
    /// it.
    private static func settle(until satisfied: () -> Bool) async {
        for _ in 0..<50 where !satisfied() {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Chinese dictation with Traditional output and every optional stage off,
    /// so the only thing that can change the published text is the script.
    private static func chineseSettings() -> Settings {
        var settings = Settings()
        settings.selectedLanguage = "zh"
        settings.chineseOutputScript = .traditional
        settings.useAsianAutocorrect = false
        settings.safeCorrectionEnabled = false
        settings.styleRewrite = .disabled
        return settings
    }

    private static var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("test_audio.m4a")
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
