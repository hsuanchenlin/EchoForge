import Combine
import XCTest

@testable import OpenSuperWhisper

/// `LiveDictationSession` against a tap that is pushed synthetic frames, a
/// decoder that answers on cue and a VAD that reads silence off the samples -
/// no microphone, no model, no timer.
///
/// What is held here is the session's contract with `IndicatorViewModel`:
/// utterances are decoded in order and joined; every failure on the live path
/// is a `.fallback` with the capsule line already cleared - including a tap
/// that was not up yet, or stopped, when the key went up, a reload of the same
/// engine, and a tail the VAD heard words in that the policy would not decode;
/// `finish` decodes only the tail; cancelling discards everything; and
/// `finish` and `cancel` name the session they mean and are refused otherwise.
@MainActor
final class LiveDictationSessionTests: IsolatedPreferencesTestCase {

    private static let rate = LiveCutBudget.sampleRate

    /// A small budget so a test can speak its utterances in a few seconds of
    /// synthetic audio: 1 s of speech before a pause counts, a 0.4 s pause ends
    /// an utterance, 6 s is the cap.
    private static let budget = LiveCutBudget(
        minimumSpeechSeconds: 1.0, pauseSeconds: 0.4, maximumSeconds: 6.0,
        capSearchSeconds: 2.0, minimumTailSpeechSeconds: 0.5)

    private var claim: RecordingSessionClaim!
    private var session: RecordingSession!
    private var tap: FakeLiveAudioTap!
    private var decoder: FakeUtteranceDecoder!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            claim = RecordingSessionClaim()
            session = claim.claim()
            tap = FakeLiveAudioTap()
            decoder = FakeUtteranceDecoder()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-session-tests-\(UUID().uuidString)")
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func makeSession(engine: EngineKind = .whisper) -> LiveDictationSession {
        LiveDictationSession(
            recordingSession: session,
            engine: engine,
            budget: Self.budget,
            settings: Settings(),
            tap: tap,
            decoder: decoder,
            segmenter: RunSegmenter(),
            stopTail: 0,
            pollInterval: nil,
            utteranceDirectory: directory)
    }

    // MARK: - Audio

    private static func speech(seconds: Double) -> [Float] {
        Array(repeating: 0.5, count: Int(seconds * Double(rate)))
    }

    private static func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(rate)))
    }

    // MARK: - Ordering

    /// Two utterances separated by a pause are decoded in order, each as a file
    /// holding exactly the audio the policy cut, and joined into one transcript.
    func testUtterancesAreDecodedInOrderAndJoined() async throws {
        decoder.answers = ["We ship on Friday.", "Tag the release."]
        let live = makeSession()
        await live.start()
        XCTAssertEqual(live.state, .running)
        XCTAssertTrue(tap.isRunning)

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(decoder.decodes.count, 1)
        XCTAssertEqual(live.transcript?.text, "We ship on Friday.")
        XCTAssertEqual(live.transcript?.segmentCount, 1)

        tap.push(Self.speech(seconds: 1.2) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(decoder.decodes.count, 2)
        XCTAssertEqual(live.transcript?.text, "We ship on Friday. Tag the release.")
        XCTAssertEqual(live.transcript?.segment, "Tag the release.")

        // Each file held exactly the prefix the policy cut: the speech plus the
        // 0.1 s padded into the pause - and, for the second, the 0.5 s of that
        // first pause the cut left behind, which the policy commits ahead of a
        // pause rather than discarding first.
        XCTAssertEqual(
            decoder.decodes[0].sampleCount,
            Int(1.5 * Double(Self.rate)) + LiveCutBudget.cutPaddingSamples)
        XCTAssertEqual(
            decoder.decodes[1].sampleCount,
            Int(0.5 * Double(Self.rate)) + Int(1.2 * Double(Self.rate)) + LiveCutBudget.cutPaddingSamples)
        XCTAssertTrue(decoder.decodes.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) },
                      "an utterance file is removed once it has been decoded")

        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .committed(raw: "We ship on Friday. Tag the release."))
        XCTAssertEqual(live.state, .finished)
        XCTAssertFalse(tap.isRunning)
    }

    /// Nothing is decoded until a pause the policy accepts: unbroken speech is
    /// buffered, not cut, and the line stays empty.
    func testSpeechWithoutAPauseIsNotDecoded() async {
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 2.0))
        await live.poll()

        XCTAssertTrue(decoder.decodes.isEmpty)
        XCTAssertNil(live.transcript)
        XCTAssertEqual(live.state, .running)
    }

    /// A piece that decodes to nothing but punctuation is dropped by the
    /// joiner and never shown; the next real piece is the first on the line.
    func testAPunctuationOnlyUtteranceIsNotShown() async {
        decoder.answers = ["...", "Real words."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertNil(live.transcript)

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "Real words.")
        XCTAssertEqual(live.transcript?.segmentCount, 1)
    }

    // MARK: - Finish decodes the tail

    /// Only what was left after the last cut is decoded at the end, and the
    /// answer is everything joined.
    func testFinishDecodesOnlyTheTail() async {
        decoder.answers = ["First.", "Last."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(decoder.decodes.count, 1)

        tap.push(Self.speech(seconds: 0.8))
        let outcome = await live.finish(session)

        XCTAssertEqual(decoder.decodes.count, 2)
        // The uncommitted audio and nothing before it: what the first cut left
        // of its pause, then the tail speech.
        XCTAssertEqual(
            decoder.decodes[1].sampleCount,
            Int(0.5 * Double(Self.rate)) + Int(0.8 * Double(Self.rate)),
            "the tail is the uncommitted audio and nothing before it")
        XCTAssertEqual(outcome, .committed(raw: "First. Last."))
        XCTAssertEqual(live.transcript?.text, "First. Last.", "the line grows with the tail too")
    }

    /// A short last word after a pause - "…tag the release. Thanks." - holds
    /// less speech than the tail minimum, which the policy will not decode
    /// live and the whole-file decode keeps. So the session cannot stand for
    /// the recording: it used to answer `.committed("First.")` and the word
    /// was missing from the paste. The line is cleared before the fallback.
    func testAShortLastWordAfterACommittedUtteranceFallsBack() async {
        decoder.answers = ["First.", "Never decoded."]
        let live = makeSession()
        await live.start()
        var published: [PartialTranscript?] = []
        let subscription = live.$transcript.sink { published.append($0) }
        defer { subscription.cancel() }

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")
        tap.push(Self.speech(seconds: 0.2))

        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .fallback(.tailBelowMinimum))
        XCTAssertEqual(live.state, .failed(.tailBelowMinimum))
        XCTAssertEqual(decoder.decodes.count, 1, "the short tail is not decoded live")
        XCTAssertNil(live.transcript, "the line is cleared before the whole-file decode replaces it")
        XCTAssertEqual(published.last, .some(nil))
        XCTAssertFalse(tap.isRunning)
    }

    /// The same word as the whole dictation - "OK", "yes", released after a
    /// second: nothing committed, a tail under the minimum. It used to answer
    /// `.committed("")` and the recording was deleted as no speech.
    func testAShortDictationWithNothingCommittedFallsBack() async {
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 0.3))
        await live.poll()
        XCTAssertNil(live.transcript)

        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .fallback(.tailBelowMinimum))
        XCTAssertEqual(live.state, .failed(.tailBelowMinimum))
        XCTAssertTrue(decoder.decodes.isEmpty)
        XCTAssertFalse(tap.isRunning)
    }

    /// A recording the VAD found no speech in answers an empty transcript, the
    /// same answer a whole-file decode gives, rather than a fallback that would
    /// decode the silence again.
    func testSilenceAloneIsAnEmptyTranscript() async {
        let live = makeSession()
        await live.start()

        tap.push(Self.silence(seconds: 2.0))
        await live.poll()
        let outcome = await live.finish(session)

        XCTAssertTrue(decoder.decodes.isEmpty)
        XCTAssertEqual(outcome, .committed(raw: ""))
        XCTAssertEqual(live.state, .finished)
    }

    /// Silence after the last utterance - the user held the key a moment after
    /// the last word - is dropped, and what was committed is the transcript.
    func testSilenceAfterACommittedUtteranceIsDropped() async {
        decoder.answers = ["First."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        tap.push(Self.silence(seconds: 1.0))

        let outcome = await live.finish(session)
        XCTAssertEqual(decoder.decodes.count, 1)
        XCTAssertEqual(outcome, .committed(raw: "First."))
        XCTAssertEqual(live.transcript?.text, "First.")
    }

    /// The tap listens for the same tail the recorder keeps, so the end of a
    /// word released with the key reaches the live path too.
    func testFinishKeepsListeningForTheStopTail() async {
        decoder.answers = ["Done."]
        let live = LiveDictationSession(
            recordingSession: session, engine: .whisper, budget: Self.budget, settings: Settings(),
            tap: tap, decoder: decoder, segmenter: RunSegmenter(),
            stopTail: 0.05, pollInterval: nil, utteranceDirectory: directory)
        await live.start()
        tap.push(Self.speech(seconds: 0.6))

        let session = self.session!
        let finishing = Task { await live.finish(session) }
        // Arrives during the tail, before the tap is stopped.
        try? await Task.sleep(nanoseconds: 10_000_000)
        tap.push(Self.speech(seconds: 0.4))

        let outcome = await finishing.value
        XCTAssertEqual(outcome, .committed(raw: "Done."))
        XCTAssertEqual(decoder.decodes.first?.sampleCount, Int(1.0 * Double(Self.rate)))
    }

    // MARK: - Every failure is a fallback

    func testATapThatWillNotStartLeavesTheSessionUnavailable() async {
        tap.startError = LiveAudioTapError.noInputDevice
        let live = makeSession()
        await live.start()

        XCTAssertEqual(live.state, .unavailable(.tapUnavailable("No audio input to tap.")))
        XCTAssertFalse(tap.isRunning)

        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .fallback(.tapUnavailable("No audio input to tap.")))
        XCTAssertTrue(decoder.decodes.isEmpty)
    }

    /// The key going up while the tap is still opening - a short dictation on
    /// a slow input. The tap was not hearing the recording, so `finish` cannot
    /// stand for it: it used to drain an empty buffer and answer
    /// `.committed("")`, and the recorder's WAV was deleted as no speech.
    func testFinishWhileTheTapIsStillOpeningFallsBack() async {
        tap.holdStart()
        let live = makeSession()
        let starting = Task { await live.start() }
        await tap.waitUntilOpening()

        let outcome = await live.finish(session)
        guard case .fallback(.tapUnavailable) = outcome else {
            return XCTFail("expected a tap fallback, got \(outcome)")
        }
        guard case .failed(.tapUnavailable) = live.state else {
            return XCTFail("expected .failed(.tapUnavailable), got \(live.state)")
        }
        XCTAssertTrue(decoder.decodes.isEmpty)

        tap.releaseStart()
        await starting.value
        XCTAssertFalse(tap.isRunning, "a tap that opened after the finish is stopped as soon as it is up")
        guard case .failed(.tapUnavailable) = live.state else {
            return XCTFail("a late success does not revive the session, got \(live.state)")
        }
    }

    /// The same key-up, with the tap then failing to open: the refusal lands
    /// on a session that is no longer running and used to be dropped, leaving
    /// `finish`'s empty answer standing.
    func testATapThatFailsToOpenAfterTheKeyWentUpFallsBack() async {
        tap.holdStart()
        tap.startError = LiveAudioTapError.noInputDevice
        let live = makeSession()
        let starting = Task { await live.start() }
        await tap.waitUntilOpening()

        let outcome = await live.finish(session)
        guard case .fallback(.tapUnavailable) = outcome else {
            return XCTFail("expected a tap fallback, got \(outcome)")
        }

        tap.releaseStart()
        await starting.value
        XCTAssertFalse(tap.isRunning)
        guard case .failed(.tapUnavailable) = live.state else {
            return XCTFail("expected .failed(.tapUnavailable), got \(live.state)")
        }
        XCTAssertTrue(decoder.decodes.isEmpty)
    }

    /// The engine stopping itself mid-recording - an input device unplugged,
    /// its format changed - stops the frames while the recorder goes on
    /// writing the WAV. The next reading notices, clears the line and falls
    /// back, so the words after the stop come from the file rather than going
    /// missing from a `.committed` transcript.
    func testATapThatStopsDeliveringMidSessionFallsBack() async {
        decoder.answers = ["First."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")

        tap.stall()
        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        guard case .failed(.tapUnavailable) = live.state else {
            return XCTFail("expected .failed(.tapUnavailable), got \(live.state)")
        }
        XCTAssertNil(live.transcript)
        XCTAssertEqual(decoder.decodes.count, 1, "nothing more is decoded from a tap that stopped")
        let outcome = await live.finish(session)
        guard case .fallback(.tapUnavailable) = outcome else {
            return XCTFail("expected a tap fallback, got \(outcome)")
        }
    }

    /// The same stop landing between the last reading and the key going up,
    /// or during the stop tail, is caught by `finish` itself: the buffer ends
    /// where the engine stopped rather than where the key went up, so the tail
    /// is not decoded from it.
    func testATapThatStoppedBeforeTheKeyWentUpFallsBack() async {
        decoder.answers = ["First.", "Never decoded."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        tap.push(Self.speech(seconds: 0.8))
        tap.stall()

        let outcome = await live.finish(session)
        guard case .fallback(.tapUnavailable) = outcome else {
            return XCTFail("expected a tap fallback, got \(outcome)")
        }
        XCTAssertEqual(decoder.decodes.count, 1, "the tail is not decoded from a truncated buffer")
        XCTAssertNil(live.transcript)
        XCTAssertFalse(tap.isRunning)
    }

    /// An utterance that throws takes the line down first - a capsule following
    /// the session must show nothing the whole-file decode is about to replace -
    /// and `finish` answers with the fallback.
    func testADecodeThatThrowsClearsTheLineAndFallsBack() async {
        decoder.answers = ["We ship on Friday."]
        let live = makeSession()
        await live.start()
        var published: [PartialTranscript?] = []
        let subscription = live.$transcript.sink { published.append($0) }
        defer { subscription.cancel() }

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "We ship on Friday.")

        decoder.error = TranscriptionError.processingFailed
        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        XCTAssertNil(live.transcript, "the line is cleared before anything else")
        XCTAssertEqual(published.last, .some(nil))
        XCTAssertFalse(tap.isRunning, "the tap is stopped: nothing more is decoded live")
        guard case .failed(.decodeFailed) = live.state else {
            return XCTFail("expected .failed(.decodeFailed), got \(live.state)")
        }

        let outcome = await live.finish(session)
        guard case .fallback(.decodeFailed) = outcome else {
            return XCTFail("expected a decode fallback, got \(outcome)")
        }
    }

    /// A throw on the tail decode is the same fallback, even though everything
    /// before it decoded: a transcript with a hole in it is worse than a late one.
    func testATailThatThrowsFallsBack() async {
        decoder.answers = ["First."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        decoder.error = TranscriptionError.processingFailed
        tap.push(Self.speech(seconds: 0.8))

        let outcome = await live.finish(session)
        guard case .fallback(.decodeFailed) = outcome else {
            return XCTFail("expected a decode fallback, got \(outcome)")
        }
        XCTAssertNil(live.transcript)
    }

    /// The engine that would decode now is not the one the session started on:
    /// what was committed came from another model, so the file is decoded whole.
    func testAnEngineChangeMidSessionFallsBack() async {
        decoder.answers = ["First."]
        let live = makeSession(engine: .whisper)
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")

        decoder.activeEngine = .sensevoice
        tap.push(Self.speech(seconds: 0.5))
        await live.poll()

        XCTAssertEqual(live.state, .failed(.engineChanged))
        XCTAssertNil(live.transcript)
        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .fallback(.engineChanged))
        XCTAssertEqual(decoder.decodes.count, 1, "nothing is decoded on the new engine")
    }

    /// The same check, made again by `finish`: a model that finished preparing
    /// between the last poll and the key going up would otherwise have the tail
    /// decoded on the new engine and joined to the old engine's utterances,
    /// handed back as `.committed` without a word.
    func testAnEngineChangeBeforeTheTailFallsBack() async {
        decoder.answers = ["First.", "Never decoded."]
        let live = makeSession(engine: .whisper)
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")

        decoder.activeEngine = .sensevoice
        tap.push(Self.speech(seconds: 0.8))
        let outcome = await live.finish(session)

        XCTAssertEqual(outcome, .fallback(.engineChanged))
        XCTAssertEqual(live.state, .failed(.engineChanged))
        XCTAssertNil(live.transcript)
        XCTAssertEqual(decoder.decodes.count, 1, "the tail is not decoded on the new engine")
        XCTAssertFalse(tap.isRunning)
    }

    /// The same kind of engine loaded again - another Whisper model chosen in
    /// Settings, another FluidAudio version - is a change the kind cannot show.
    /// What was committed came from the old model, so the file is decoded whole.
    func testAReloadOfTheSameEngineMidSessionFallsBack() async {
        decoder.answers = ["First."]
        let live = makeSession(engine: .whisper)
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")

        decoder.engineLoadGeneration += 1
        XCTAssertEqual(decoder.activeEngine, .whisper, "the kind is unchanged")
        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        XCTAssertEqual(live.state, .failed(.engineChanged))
        XCTAssertNil(live.transcript)
        XCTAssertEqual(decoder.decodes.count, 1, "nothing is decoded on the new load")
        let outcome = await live.finish(session)
        XCTAssertEqual(outcome, .fallback(.engineChanged))
    }

    /// The same reload landing between the last poll and the key going up is
    /// caught before the tail, the way a change of kind is.
    func testAReloadOfTheSameEngineBeforeTheTailFallsBack() async {
        decoder.answers = ["First.", "Never decoded."]
        let live = makeSession(engine: .whisper)
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        XCTAssertEqual(live.transcript?.text, "First.")

        decoder.engineLoadGeneration += 1
        tap.push(Self.speech(seconds: 0.8))
        let outcome = await live.finish(session)

        XCTAssertEqual(outcome, .fallback(.engineChanged))
        XCTAssertEqual(live.state, .failed(.engineChanged))
        XCTAssertNil(live.transcript)
        XCTAssertEqual(decoder.decodes.count, 1, "the tail is not decoded on the new load")
    }

    /// The load the session compares against is the one current when it was
    /// made, not zero: a session made after a reload runs on that load.
    func testASessionMadeAfterAReloadRunsOnThatLoad() async {
        decoder.engineLoadGeneration = 3
        decoder.answers = ["First."]
        let live = makeSession(engine: .whisper)
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        XCTAssertEqual(live.state, .running)
        XCTAssertEqual(live.transcript?.text, "First.")
    }

    /// Unbroken speech past twice the cap has no pause to cut in; the WAV has
    /// all of it, so the session gives up rather than cutting inside a word.
    func testABufferPastTheCapFallsBack() async {
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 12.5))
        await live.poll()

        XCTAssertEqual(live.state, .failed(.bufferExceeded))
        XCTAssertTrue(decoder.decodes.isEmpty)
        XCTAssertFalse(tap.isRunning)
        let finished = await live.finish(session)
        XCTAssertEqual(finished, .fallback(.bufferExceeded))
    }

    // MARK: - Cancel discards

    func testCancelDiscardsEverything() async {
        decoder.answers = ["We ship on Friday."]
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()
        tap.push(Self.speech(seconds: 1.0))

        live.cancel(session)

        XCTAssertEqual(live.state, .cancelled)
        XCTAssertNil(live.transcript)
        XCTAssertFalse(tap.isRunning)
        let finished = await live.finish(session)
        XCTAssertEqual(finished, .fallback(.cancelled))
        XCTAssertEqual(decoder.decodes.count, 1, "the tail is not decoded after a cancel")
    }

    /// A decode already in flight when the session is cancelled finishes on the
    /// engine, and its words are dropped rather than published.
    func testAResultArrivingAfterCancelIsDropped() async {
        decoder.answers = ["Late words."]
        decoder.gate = true
        let live = makeSession()
        await live.start()

        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        let polling = Task { await live.poll() }
        await decoder.waitUntilDecoding()

        live.cancel(session)
        decoder.release()
        await polling.value

        XCTAssertNil(live.transcript)
        XCTAssertEqual(live.state, .cancelled)
    }

    /// The failed-start timing. `AudioRecorder` reports a start that failed on
    /// its work queue 20-35 ms after the press, while the tap is still opening
    /// off the main actor, so the view model's `endLiveSession` lands before
    /// `start` has returned. The tap that then comes up belongs to nobody and
    /// has to be stopped, not left listening on a microphone no one is
    /// recording from.
    func testACancelWhileTheTapIsOpeningStopsTheTapWhenItComesUp() async {
        tap.holdStart()
        let live = makeSession()
        let starting = Task { await live.start() }
        await tap.waitUntilOpening()

        live.cancel(session)
        XCTAssertEqual(live.state, .cancelled)

        tap.releaseStart()
        await starting.value

        XCTAssertFalse(tap.isRunning, "a tap that opened after the cancel is stopped as soon as it is up")
        XCTAssertEqual(live.state, .cancelled, "and a late success does not revive the session")
        let finished = await live.finish(session)
        XCTAssertEqual(finished, .fallback(.cancelled))
    }

    // MARK: - Session naming

    func testFinishIsRefusedForAnotherSession() async {
        decoder.answers = ["Mine."]
        let live = makeSession()
        await live.start()
        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        claim.release(session)
        let other = claim.claim()!
        let refused = await live.finish(other)
        XCTAssertEqual(refused, .fallback(.notThisSession))
        XCTAssertEqual(live.state, .running, "the session is untouched by a stop that was not its own")
        XCTAssertEqual(live.transcript?.text, "Mine.")
        XCTAssertTrue(tap.isRunning)

        let finished = await live.finish(session)
        XCTAssertEqual(finished, .committed(raw: "Mine."))
    }

    func testCancelIsRefusedForAnotherSession() async {
        decoder.answers = ["Mine."]
        let live = makeSession()
        await live.start()
        tap.push(Self.speech(seconds: 1.5) + Self.silence(seconds: 0.6))
        await live.poll()

        claim.release(session)
        let other = claim.claim()!
        live.cancel(other)

        XCTAssertEqual(live.state, .running)
        XCTAssertEqual(live.transcript?.text, "Mine.")
        XCTAssertTrue(tap.isRunning)
    }

    func testASessionCannotBeFinishedTwice() async {
        let live = makeSession()
        await live.start()
        _ = await live.finish(session)
        let finished = await live.finish(session)
        XCTAssertEqual(finished, .fallback(.notThisSession))
    }

    // MARK: - Eligibility

    /// Off by default: a fresh install decodes whole files exactly as before.
    func testLiveTranscriptionIsOffByDefault() {
        XCTAssertFalse(AppPreferences.shared.liveTranscriptionEnabled)
        XCTAssertNil(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: AppPreferences.shared.liveTranscriptionEnabled,
                engine: .whisper, showTimestamps: false))
    }

    func testOnlyTheDictationKeyOnALocalEngineGetsASession() {
        XCTAssertEqual(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: true, engine: .whisper, showTimestamps: false),
            .whisper)
        XCTAssertEqual(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: true, engine: .sensevoice, showTimestamps: false),
            .senseVoiceSmall)

        for purpose in [DictationPurpose.youTubeCommand, .selectionEdit] {
            XCTAssertNil(
                LiveDictationEligibility.budget(
                    purpose: purpose, isEnabled: true, engine: .whisper, showTimestamps: false),
                "\(purpose) is not dictation and is unchanged by this feature")
        }
        XCTAssertNil(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: true, engine: .cloud, showTimestamps: false),
            "the cloud engine stays at one request per dictation")
        XCTAssertNil(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: true, engine: nil, showTimestamps: false),
            "nothing can transcribe, so nothing can transcribe live")
        XCTAssertNil(
            LiveDictationEligibility.budget(
                purpose: .dictation, isEnabled: true, engine: .whisper, showTimestamps: true),
            "timestamps are offsets into the file whisper was handed, which an utterance is not")
    }

    /// The production factory reads the same switch and the engine that would
    /// actually decode: nil on a default install, nil when nothing can
    /// transcribe, and a session on the active engine once the switch is on.
    func testTheFactoryFollowsThePreferenceAndTheActiveEngine() {
        let service = TranscriptionService()
        let preferences = AppPreferences.shared
        preferences.selectedEngine = .sensevoice
        service.refreshSelection(
            availability: EngineAvailability(usableEngines: [.sensevoice], whisperModelPaths: []))
        XCTAssertEqual(service.activeEngine, .sensevoice)

        XCTAssertNil(
            LiveDictationSession.make(
                for: session, purpose: .dictation, settings: Settings(), service: service),
            "off by default")

        preferences.liveTranscriptionEnabled = true
        let live = LiveDictationSession.make(
            for: session, purpose: .dictation, settings: Settings(), service: service)
        XCTAssertEqual(live?.engine, .sensevoice)
        XCTAssertEqual(live?.recordingSession, session)

        service.refreshSelection(
            availability: EngineAvailability(usableEngines: [], whisperModelPaths: []))
        XCTAssertNil(service.activeEngine)
        XCTAssertNil(
            LiveDictationSession.make(
                for: session, purpose: .dictation, settings: Settings(), service: service),
            "nothing can transcribe, so nothing can transcribe live")
    }
}

// MARK: - Fakes

/// A tap the test pushes frames into. Records whether it is running so the
/// session's stops can be asserted, can be held half-open so a test can act
/// on the session while the tap is still starting, and can stall the way an
/// engine does when macOS stops it under the tap.
final class FakeLiveAudioTap: LiveAudioTapping {
    private let lock = NSLock()
    private var onFrames: (([Float]) -> Void)?
    var startError: Error?
    private(set) var stopCount = 0
    private var startHold: DispatchSemaphore?
    private var hasEnteredStart = false
    private var opening: CheckedContinuation<Void, Never>?
    private var isStalled = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onFrames != nil
    }

    var isDelivering: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onFrames != nil && !isStalled
    }

    /// The engine stopping itself under a running tap - an input device
    /// unplugged, its format changed: frames stop arriving and the tap reports
    /// it is no longer delivering, without anyone having called `stop`.
    func stall() {
        lock.lock()
        isStalled = true
        lock.unlock()
    }

    /// Makes the next `start` wait at `releaseStart()` - a tap still opening.
    func holdStart() {
        lock.lock()
        startHold = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// Resumes once a held `start` has been entered on its own thread.
    func waitUntilOpening() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEnteredStart {
                lock.unlock()
                continuation.resume()
                return
            }
            opening = continuation
            lock.unlock()
        }
    }

    func releaseStart() {
        lock.lock()
        let hold = startHold
        lock.unlock()
        hold?.signal()
    }

    func start(onFrames: @escaping ([Float]) -> Void) throws {
        lock.lock()
        hasEnteredStart = true
        let hold = startHold
        let opening = self.opening
        self.opening = nil
        lock.unlock()
        opening?.resume()
        hold?.wait()

        if let startError { throw startError }
        lock.lock()
        self.onFrames = onFrames
        lock.unlock()
    }

    func stop() {
        lock.lock()
        onFrames = nil
        isStalled = false
        stopCount += 1
        lock.unlock()
    }

    /// Delivers frames the way the audio thread would: only while running and
    /// not stalled.
    func push(_ samples: [Float]) {
        lock.lock()
        let handler = isStalled ? nil : onFrames
        lock.unlock()
        handler?(samples)
    }
}

/// A decoder that answers from a script, reads each file back so the test can
/// check what it was handed, and can be held mid-decode.
@MainActor
final class FakeUtteranceDecoder: LiveUtteranceDecoding {
    struct Decode {
        let url: URL
        let sampleCount: Int
    }

    var activeEngine: EngineKind? = .whisper
    var engineLoadGeneration = 0
    var answers: [String] = []
    var error: Error?
    private(set) var decodes: [Decode] = []

    /// When true, a decode waits at `release()`.
    var gate = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var decodingContinuation: CheckedContinuation<Void, Never>?
    private var isDecoding = false

    func decodeRaw(url: URL, settings: Settings) async throws -> String {
        let samples = try await PCMAudioLoader.loadSamples(from: url) ?? []
        decodes.append(Decode(url: url, sampleCount: samples.count))
        if gate {
            isDecoding = true
            decodingContinuation?.resume()
            decodingContinuation = nil
            await withCheckedContinuation { gateContinuation = $0 }
            isDecoding = false
        }
        if let error { throw error }
        return answers.isEmpty ? "" : answers.removeFirst()
    }

    func waitUntilDecoding() async {
        guard !isDecoding else { return }
        await withCheckedContinuation { decodingContinuation = $0 }
    }

    func release() {
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

/// A VAD for synthetic audio: every run of non-zero samples is speech, reported
/// in centiseconds of the buffer the way the real one reports.
final class RunSegmenter: LiveSpeechSegmenting {
    func segments(in samples: [Float]) throws -> [WhisperVadSegment] {
        var segments: [WhisperVadSegment] = []
        var start: Int?
        for (index, sample) in samples.enumerated() {
            if sample != 0 {
                if start == nil { start = index }
            } else if let began = start {
                segments.append(Self.segment(began, index))
                start = nil
            }
        }
        if let began = start {
            segments.append(Self.segment(began, samples.count))
        }
        return segments
    }

    private static func segment(_ start: Int, _ end: Int) -> WhisperVadSegment {
        let perCs = LiveCutBudget.sampleRate / 100
        return WhisperVadSegment(startCs: Int64(start / perCs), endCs: Int64((end + perCs - 1) / perCs))
    }
}
