import XCTest
@testable import OpenSuperWhisper

/// Regression coverage for the chunking layer.
///
/// The constraints and fixtures here are the ones verified against FluidAudio
/// 0.15.4 on the real compiled CoreML models, and the identifiers (C1-C5,
/// F1-F3, F6) are the ones the runtime report uses:
///
/// - **C1** 30.000 s / 480,000 sample ceiling - above it CoreML *throws*.
/// - **C2** 0.200 s / 3,200 sample floor - below it CoreML throws too, and this
///   is the one a naive chunker hits, on the short remainder at the end.
/// - **C3** Paraformer clamps to 128 output tokens *silently*; a 28.1 s clip
///   came back at 127 characters with 35.8 % CER, 0.53 % once chunked.
/// - **C4** Boundaries belong in VAD silence; every blind cut cost ~+0.5 pp CER.
/// - **C5** No engine has a no-speech gate; silence transcribes as hallucinated
///   text, so silence must produce no chunks at all.
///
/// None of this needs model weights.
final class AudioChunkerTests: XCTestCase {

    private let sampleRate = 16_000

    // MARK: - Fixtures

    private func samples(seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * Double(sampleRate)))
    }

    private func segment(_ start: Double, _ end: Double) -> WhisperVadSegment {
        WhisperVadSegment(startCs: Int64(start * 100), endCs: Int64(end * 100))
    }

    /// One uninterrupted stretch of speech covering the whole recording - the
    /// worst case for a chunker, because the VAD offers no seam to cut at.
    private func continuousSpeech(seconds: Double) -> ([Float], [WhisperVadSegment]) {
        (samples(seconds: seconds), [segment(0, seconds)])
    }

    private func assertWithinRange(
        _ chunks: [AudioChunk],
        _ budget: AudioChunkBudget,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (index, chunk) in chunks.enumerated() {
            XCTAssertGreaterThanOrEqual(
                chunk.samples.count, budget.minimumSamples,
                "\(context): chunk \(index) is \(chunk.samples.count) samples, under the floor",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                chunk.samples.count, budget.maximumSamples,
                "\(context): chunk \(index) is \(chunk.samples.count) samples, over the ceiling",
                file: file, line: line
            )
        }
    }

    /// Every sample the VAD called speech, and which chunk (if any) covers it.
    private func uncoveredSpeechSamples(
        segments: [WhisperVadSegment],
        chunks: [AudioChunk],
        sampleCount: Int
    ) -> Int {
        var covered = [Bool](repeating: false, count: sampleCount)
        for chunk in chunks {
            for index in chunk.range where index < sampleCount {
                covered[index] = true
            }
        }
        var uncovered = 0
        for segment in segments {
            let start = min(max(0, Int(segment.startCs) * sampleRate / 100), sampleCount)
            let end = min(max(0, Int(segment.endCs) * sampleRate / 100), sampleCount)
            for index in start..<max(start, end) where !covered[index] {
                uncovered += 1
            }
        }
        return uncovered
    }

    // MARK: - F1: the accepted-range boundary

    func testF1_everyChunkStaysInsideTheAcceptedRange() {
        let durations = [0.1, 0.19, 1.0, 13.9, 29.9, 30.0, 30.1, 45.0, 90.0, 175.0]
        let budgets: [(String, AudioChunkBudget)] = [
            ("paraformer", .paraformerZh),
            ("sensevoice", .senseVoiceSmall)
        ]

        for (name, budget) in budgets {
            for duration in durations {
                let (audio, segments) = continuousSpeech(seconds: duration)
                let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

                XCTAssertFalse(chunks.isEmpty, "\(name) \(duration)s produced no chunks for speech")
                assertWithinRange(chunks, budget, "\(name) \(duration)s")
            }
        }
    }

    /// The 40 s fixture that is 0.9 s of speech, 36 s of digital silence and
    /// 1.4 s of speech. A fixed-window chunker turns the silence into chunks of
    /// its own, which both engines answer with hallucinated text.
    func testF1_speechSeparatedByLongSilenceProducesOnlySpeechChunks() {
        let audio = samples(seconds: 40.64)
        let segments = [segment(0, 0.9), segment(39.2, 40.6)]

        for budget in [AudioChunkBudget.paraformerZh, .senseVoiceSmall] {
            let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

            XCTAssertEqual(chunks.count, 2, "the 36 s of silence must not become a chunk")
            assertWithinRange(chunks, budget, "silence-separated")
            XCTAssertEqual(
                uncoveredSpeechSamples(segments: segments, chunks: chunks, sampleCount: audio.count), 0
            )
        }
    }

    /// The floor is reached by growing into the surrounding audio, not by
    /// padding: real context beats zeros, and the chunk still must not overlap
    /// its neighbour.
    func testF1_subFloorSegmentGrowsIntoSurroundingAudioRatherThanPadding() {
        let audio = samples(seconds: 10)
        let segments = [segment(5.0, 5.1)] // 0.1 s, under the 0.2 s floor
        let budget = AudioChunkBudget.paraformerZh

        let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

        XCTAssertEqual(chunks.count, 1)
        assertWithinRange(chunks, budget, "sub-floor segment")
        XCTAssertEqual(
            chunks[0].range.count, chunks[0].samples.count,
            "there was 10 s of audio to grow into, so nothing should have been zero-padded"
        )
    }

    /// Only when the whole recording is shorter than the floor is there nothing
    /// to grow into.
    func testF1_recordingShorterThanTheFloorIsPaddedNotRejected() {
        let audio = samples(seconds: 0.1)
        let segments = [segment(0, 0.1)]
        let budget = AudioChunkBudget.paraformerZh

        let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, budget.minimumSamples)
        XCTAssertEqual(chunks[0].range.count, 1600, "the padding must not be claimed as source audio")
    }

    // MARK: - F2: Paraformer's silent token clamp

    /// 28.14 s of dense Mandarin is inside the 30 s ceiling and still overruns
    /// the 128-token decoder. The chunker has to cut it anyway.
    func testF2_denseSpeechInsideTheCeilingIsStillChunkedForTheTokenBudget() {
        let (audio, segments) = continuousSpeech(seconds: 28.14)
        let budget = AudioChunkBudget.paraformerZh

        let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

        XCTAssertGreaterThan(
            chunks.count, 1,
            "a 28.1 s clip fed in one shot returns 127 characters of a 200-character script"
        )
        assertWithinRange(chunks, budget, "28.14 s dense speech")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                chunk.samples.count, budget.preferredSamples,
                "chunks must stay inside the token-derived budget, not just the 30 s ceiling"
            )
        }
    }

    func testF2_theTokenBudgetIsWhatBindsForParaformer() {
        let budget = AudioChunkBudget.paraformerZh

        XCTAssertLessThan(
            budget.preferredSamples, budget.maximumSamples,
            "128 tokens bind well before 30 s; a duration-only budget would silently truncate"
        )
        XCTAssertEqual(budget.seconds(samples: budget.preferredSamples), 14.2, accuracy: 0.3)
    }

    // MARK: - F3: long audio is split, never truncated

    func testF3_longAudioCoversEverySpeechSample() {
        let durations = [30.1, 44.78, 87.6, 175.0]
        let budgets: [(String, AudioChunkBudget)] = [
            ("paraformer", .paraformerZh),
            ("sensevoice", .senseVoiceSmall)
        ]

        for (name, budget) in budgets {
            for duration in durations {
                let (audio, segments) = continuousSpeech(seconds: duration)
                let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

                XCTAssertEqual(
                    uncoveredSpeechSamples(segments: segments, chunks: chunks, sampleCount: audio.count), 0,
                    "\(name) \(duration)s lost speech - long audio was truncated, not chunked"
                )
                XCTAssertEqual(
                    chunks.last?.range.upperBound, audio.count,
                    "\(name) \(duration)s dropped the tail, which is where the closing sentence is"
                )
                assertWithinRange(chunks, budget, "\(name) \(duration)s")
            }
        }
    }

    /// The concrete failure this replaces: 44.78 s cut into fixed 14 s windows
    /// left a 2,276-sample (0.142 s) remainder, and CoreML threw on it.
    func testF3_noShortRemainderAtTheEndOfLongAudio() throws {
        let (audio, segments) = continuousSpeech(seconds: 44.78)
        let budget = AudioChunkBudget.paraformerZh

        let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

        assertWithinRange(chunks, budget, "44.78 s")
        let last = try XCTUnwrap(chunks.last)
        XCTAssertGreaterThan(
            last.samples.count, 3_200,
            "the remainder chunk is the one a fixed-window chunker gets wrong"
        )
    }

    func testF3_chunkCountGrowsWithDurationRatherThanSaturating() {
        let budget = AudioChunkBudget.senseVoiceSmall

        let short = AudioChunker.chunks(
            from: continuousSpeech(seconds: 45).0, segments: continuousSpeech(seconds: 45).1, budget: budget
        )
        let long = AudioChunker.chunks(
            from: continuousSpeech(seconds: 175).0, segments: continuousSpeech(seconds: 175).1, budget: budget
        )

        XCTAssertGreaterThan(long.count, short.count)
        XCTAssertGreaterThanOrEqual(
            Double(long.count), 175.0 / budget.seconds(samples: budget.preferredSamples),
            "chunk count must track the audio, or something is being dropped"
        )
    }

    // MARK: - F6: the silence gate

    func testF6_noSpeechSegmentsProduceNoChunks() {
        let audio = samples(seconds: 5)

        for budget in [AudioChunkBudget.paraformerZh, .senseVoiceSmall] {
            XCTAssertTrue(
                AudioChunker.chunks(from: audio, segments: [], budget: budget).isEmpty,
                "silence must return empty, not a padded chunk: neither engine has a no-speech gate"
            )
        }
    }

    func testF6_emptyAndDegenerateSegmentsProduceNoChunks() {
        let audio = samples(seconds: 5)
        // Zero-length and inverted segments must be dropped, not turned into
        // under-length chunks.
        let degenerate = [segment(1.0, 1.0), segment(3.0, 2.0)]

        XCTAssertTrue(
            AudioChunker.chunks(from: audio, segments: degenerate, budget: .paraformerZh).isEmpty
        )
    }

    // MARK: - C4: boundaries in silence

    func testC4_boundariesFallBetweenSegmentsWhenTheVadOffersOne() {
        // Three 6 s phrases separated by 2 s pauses, against a budget that fits
        // two phrases but not three.
        let audio = samples(seconds: 26)
        let segments = [segment(0, 6), segment(8, 14), segment(16, 22)]
        let budget = AudioChunkBudget(
            minimumSeconds: 0.2, maximumSeconds: 30, preferredSeconds: 15
        )

        let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].range, 0..<(14 * sampleRate), "first cut belongs in the 14-16 s pause")
        XCTAssertEqual(chunks[1].range, (16 * sampleRate)..<(22 * sampleRate))
    }

    func testC4_chunksNeverOverlap() {
        let audio = samples(seconds: 60)
        let segments = (0..<10).map { segment(Double($0) * 6, Double($0) * 6 + 5) }

        for budget in [AudioChunkBudget.paraformerZh, .senseVoiceSmall] {
            let chunks = AudioChunker.chunks(from: audio, segments: segments, budget: budget)
            for pair in zip(chunks, chunks.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    pair.0.range.upperBound, pair.1.range.lowerBound,
                    "overlapping chunks transcribe the same words twice"
                )
            }
        }
    }
}

/// The budget is the seam that keeps the chunker engine-neutral: no engine's
/// limits may be baked into it.
final class AudioChunkBudgetTests: XCTestCase {

    func testArbitraryLimitsAreHonouredVerbatim() {
        let budget = AudioChunkBudget(
            sampleRate: 8_000, minimumSeconds: 0.5, maximumSeconds: 40, preferredSeconds: 12
        )

        XCTAssertEqual(budget.minimumSamples, 4_000)
        XCTAssertEqual(budget.maximumSamples, 320_000)
        XCTAssertEqual(budget.preferredSamples, 96_000)
    }

    func testPreferredLengthIsClampedIntoTheAcceptedRange() {
        let tooLong = AudioChunkBudget(minimumSeconds: 0.2, maximumSeconds: 30, preferredSeconds: 120)
        XCTAssertEqual(tooLong.preferredSamples, tooLong.maximumSamples)

        let tooShort = AudioChunkBudget(minimumSeconds: 0.2, maximumSeconds: 30, preferredSeconds: 0.05)
        XCTAssertEqual(tooShort.preferredSamples, tooShort.minimumSamples)
    }

    func testTokenBudgetLowersThePreferredLength() {
        let durationOnly = AudioChunkBudget(
            minimumSeconds: 0.2, maximumSeconds: 30, preferredSeconds: 30
        )
        let tokenBudgeted = AudioChunkBudget(
            minimumSeconds: 0.2, maximumSeconds: 30, preferredSeconds: 30,
            tokenBudget: 128, tokensPerSecond: 9
        )

        XCTAssertEqual(durationOnly.preferredSamples, 480_000)
        XCTAssertLessThan(tokenBudgeted.preferredSamples, durationOnly.preferredSamples)
        XCTAssertEqual(tokenBudgeted.seconds(samples: tokenBudgeted.preferredSamples), 14.22, accuracy: 0.01)
    }

    /// C1/C2 verbatim: the range the FluidAudio preprocessor accepts.
    func testFluidAudioPresetsPinTheVerifiedRange() {
        for budget in [AudioChunkBudget.paraformerZh, .senseVoiceSmall] {
            XCTAssertEqual(budget.minimumSamples, 3_200)
            XCTAssertEqual(budget.maximumSamples, 480_000)
            XCTAssertLessThan(
                budget.preferredSamples, budget.maximumSamples,
                "chunks must stay strictly below the ceiling that throws"
            )
        }
    }

    /// SenseVoice has no silent token clamp, so it gets longer chunks - fewer
    /// seams, and every blind cut costs accuracy.
    func testSenseVoiceGetsLongerChunksThanParaformer() {
        XCTAssertGreaterThan(
            AudioChunkBudget.senseVoiceSmall.preferredSamples,
            AudioChunkBudget.paraformerZh.preferredSamples
        )
        XCTAssertEqual(
            AudioChunkBudget.senseVoiceSmall.seconds(samples: AudioChunkBudget.senseVoiceSmall.preferredSamples),
            28.0, accuracy: 0.01
        )
    }

    func testSampleIndexConvertsVadCentiseconds() {
        let budget = AudioChunkBudget.paraformerZh
        XCTAssertEqual(budget.sampleIndex(centiseconds: 0), 0)
        XCTAssertEqual(budget.sampleIndex(centiseconds: 100), 16_000)
        XCTAssertEqual(budget.sampleIndex(centiseconds: 3_000), 480_000)
    }
}

/// The facade engines are meant to call. It exists so the mandatory silence gate
/// cannot be skipped by accident.
final class AudioChunkSourceTests: XCTestCase {

    // F6, through the real bundled Silero VAD rather than hand-written segments.
    func testSilenceProducesNoChunks() throws {
        try XCTSkipIf(SpeechSegmenter.vadModelPath == nil, "Silero VAD model not bundled")

        let source = AudioChunkSource()
        let silence = [Float](repeating: 0, count: 16_000 * 5)

        XCTAssertTrue(try source.chunks(for: silence, budget: .paraformerZh).isEmpty)
        XCTAssertTrue(try source.chunks(for: silence, budget: .senseVoiceSmall).isEmpty)
    }

    func testSpeechProducesChunksInsideTheAcceptedRange() async throws {
        let audioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("jfk.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: audioURL.path), "jfk sample not present in repo root"
        )

        let source = AudioChunkSource()
        let chunks = try await source.chunks(for: audioURL, budget: .paraformerZh)

        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertGreaterThanOrEqual(chunk.samples.count, AudioChunkBudget.paraformerZh.minimumSamples)
            XCTAssertLessThanOrEqual(chunk.samples.count, AudioChunkBudget.paraformerZh.maximumSamples)
        }
    }
}
