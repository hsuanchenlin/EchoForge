import Combine
import Foundation

@testable import OpenSuperWhisper

/// The world one dictation runs in, faked.
///
/// Every port in `DictationSessionPorts.swift` has exactly one fake here, and
/// each one is a recorder of what it was asked to do plus a dial for what it
/// answers. Nothing touches a microphone, an engine, a database or the
/// pasteboard, which is the point: the orchestration in `DictationSession` used
/// to be reachable only through a real recording, and every rule it holds -
/// the busy rule, the fallback table, keep-versus-discard, what a cancel does -
/// could only be read out of the source.

// MARK: - The microphone

@MainActor
final class FakeDictationRecorder: DictationRecording, RecordingCaptureControlling {
    /// Real claims, so the session's "name the session you are stopping" rule
    /// is exercised rather than stubbed out. `RecordingSession` has no public
    /// initialiser precisely so nothing can fake one.
    private let claim = RecordingSessionClaim()

    var hasActiveInput = true
    /// nil refuses the claim, as a recorder whose microphone is already held does.
    var refusesToStart = false
    /// What `stopRecording` hands back. nil is a capture too short to keep.
    var stoppedURL: URL?
    var moveError: Error?

    private(set) var startedSessions: [RecordingSession] = []
    private(set) var startedCaptures: [RecordingCapture] = []
    private(set) var stoppedSessions: [RecordingSession] = []
    private(set) var cancelledSessions: [RecordingSession] = []
    private(set) var moves: [(from: URL, to: URL)] = []

    func startRecording() -> RecordingCapture? {
        guard !refusesToStart, let session = claim.claim() else { return nil }
        let capture = RecordingCapture(session: session, controller: self)
        startedSessions.append(session)
        startedCaptures.append(capture)
        return capture
    }

    func stopRecording(_ session: RecordingSession) async -> URL? {
        stoppedSessions.append(session)
        guard claim.release(session) else { return nil }
        return stoppedURL
    }

    func cancelRecording(_ session: RecordingSession) {
        cancelledSessions.append(session)
        _ = claim.release(session)
    }

    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {
        if let moveError { throw moveError }
        moves.append((from: tempURL, to: finalURL))
    }

    /// Reports a start that was accepted and then failed on the work queue.
    func failStart(reason: FailedRecordingStart.Reason) {
        guard let capture = startedCaptures.last else { return }
        _ = claim.release(capture.session)
        capture.completeStart(.failure(reason))
    }

    /// Paints this capture as connecting, the way a Bluetooth headset does.
    func sendConnecting(_ isConnecting: Bool = true) {
        startedCaptures.last?.noteConnecting(isConnecting)
    }

    /// Paints this capture as recording, and resolves its start as success.
    func sendRecording(_ isRecording: Bool = true) {
        startedCaptures.last?.noteRecording(isRecording)
    }
}

// MARK: - The engine

@MainActor
final class FakeDictationTranscriber: DictationTranscribing {
    var isTranscribing = false
    var wholeFileResult: Result<StyledTranscript, Error> = .success(.stub("whole file"))
    var finishedResult: Result<StyledTranscript, Error> = .success(.stub("live"))

    private(set) var wholeFileCalls: [URL] = []
    private(set) var finishedRaws: [String] = []
    private(set) var cancelCount = 0
    /// What each whole-file decode was asked to run with, in call order - what
    /// makes a delivery's own settings (routing, restyling) assertable without
    /// reaching into `DictationSession` for a private detail.
    private(set) var wholeFileSettings: [Settings] = []

    /// Held open until `release()` so a test can act while a decode is in flight.
    var gate: CheckedContinuation<Void, Never>?
    private var wantsGate = false

    func holdNextDecode() { wantsGate = true }

    func releaseDecode() {
        gate?.resume()
        gate = nil
    }

    private func waitIfGated() async {
        guard wantsGate else { return }
        wantsGate = false
        await withCheckedContinuation { self.gate = $0 }
    }

    /// Events this fake reports through `progress` before waiting on the gate,
    /// so a test can observe `.decoding(.rewriting)` while the decode is still
    /// in flight.
    var progressToEmit: [StageEvent] = []

    func transcribeAudio(
        url: URL,
        settings: Settings,
        progress: @escaping @MainActor (StageEvent) -> Void
    ) async throws -> StyledTranscript {
        wholeFileCalls.append(url)
        wholeFileSettings.append(settings)
        for event in progressToEmit { progress(event) }
        await waitIfGated()
        return try wholeFileResult.get()
    }

    func finishTranscribed(
        raw: String,
        settings: Settings,
        progress: @escaping @MainActor (StageEvent) -> Void
    ) async throws -> StyledTranscript {
        finishedRaws.append(raw)
        for event in progressToEmit { progress(event) }
        await waitIfGated()
        return try finishedResult.get()
    }

    func cancelTranscription() { cancelCount += 1 }
}

extension StyledTranscript {
    /// A finished transcript with nothing interesting about it but its text.
    static func stub(
        _ text: String, intent: SpokenIntentOutcome = .dictation,
        status: StyleRewriteStatus = .notRequested
    ) -> StyledTranscript {
        StyledTranscript(raw: text, transcript: text, final: text, status: status, intent: intent)
    }
}

// MARK: - The live decoder

@MainActor
final class FakeLiveDictation: LiveDictating {
    let settings: Settings
    var state: LiveDictationState
    var outcome: LiveDictationOutcome

    private(set) var startCount = 0
    private(set) var finishedSessions: [RecordingSession] = []
    private(set) var cancelledSessions: [RecordingSession] = []

    private let subject = CurrentValueSubject<PartialTranscript?, Never>(nil)
    var transcriptPublisher: AnyPublisher<PartialTranscript?, Never> {
        subject.eraseToAnyPublisher()
    }

    init(
        settings: Settings,
        state: LiveDictationState = .running,
        outcome: LiveDictationOutcome = .committed(raw: "live words")
    ) {
        self.settings = settings
        self.state = state
        self.outcome = outcome
    }

    func commit(_ transcript: PartialTranscript?) { subject.send(transcript) }

    func start() async { startCount += 1 }

    func finish(_ session: RecordingSession) async -> LiveDictationOutcome {
        finishedSessions.append(session)
        return outcome
    }

    func cancel(_ session: RecordingSession) { cancelledSessions.append(session) }
}

// MARK: - History

@MainActor
final class FakeDictationHistory: DictationHistory {
    private(set) var added: [Recording] = []
    private(set) var addedSync: [Recording] = []
    private(set) var kept: [(url: URL, duration: TimeInterval, reason: String, provenance: RecordingProvenance)] = []
    private(set) var provenanceUpdates: [(id: UUID, provenance: RecordingProvenance)] = []
    var addSyncError: Error?

    func addRecording(_ recording: Recording) { added.append(recording) }

    func addRecordingSync(_ recording: Recording) async throws {
        if let addSyncError { throw addSyncError }
        addedSync.append(recording)
    }

    @discardableResult
    func keepFailedDictation(
        temporaryURL: URL, duration: TimeInterval, reason: String,
        provenance: RecordingProvenance
    ) -> Recording? {
        kept.append((temporaryURL, duration, reason, provenance))
        return Recording.newRow(
            transcription: reason, duration: duration, status: .failed, progress: 0,
            provenance: provenance)
    }

    func updateProvenance(_ id: UUID, to provenance: RecordingProvenance) async {
        provenanceUpdates.append((id, provenance))
    }
}

@MainActor
final class FakeDictationQueue: DictationQueueing {
    var isProcessing = false
    private(set) var queued: [(url: URL, provenance: RecordingProvenance)] = []

    func addFileToQueue(url: URL, provenance: RecordingProvenance) async {
        queued.append((url, provenance))
    }
}

// MARK: - Where the words go

@MainActor
final class FakeDictationInsertion: DictationInserting {
    private(set) var inserted: [String] = []
    private(set) var pasted: [(text: String, capture: SelectedTextCapture)] = []
    /// False is a target app that went away between the capture and the paste.
    var pasteSucceeds = true

    func insert(_ text: String) { inserted.append(text) }

    func paste(_ text: String, replacing capture: SelectedTextCapture) async -> Bool {
        pasted.append((text, capture))
        return pasteSucceeds
    }
}

@MainActor
final class FakeDictationAsking: DictationAsking {
    private(set) var queries: [String] = []
    func present(query: String) { queries.append(query) }
}

final class FakeSelectionEditing: DictationSelectionEditing, @unchecked Sendable {
    var result: StyledTranscript = .stub("rewritten", status: .applied(styleID: "edit"))
    private(set) var instructions: [String] = []

    func rewrite(
        original: String, instruction: String, settings: Settings
    ) async -> StyledTranscript {
        instructions.append(instruction)
        return result
    }
}

struct FixedAudioDuration: DictationAudioMeasuring {
    var seconds: TimeInterval = 3
    func duration(of url: URL) async -> TimeInterval { seconds }
}

/// A session against the fakes above, for tests that need two of them.
@MainActor
func makeFakeDictationSession(
    recorder: FakeDictationRecorder,
    transcriber: FakeDictationTranscriber
) -> DictationSession {
    DictationSession(
        purpose: .dictation,
        dictationTarget: nil,
        recorder: recorder,
        transcriber: transcriber,
        history: FakeDictationHistory(),
        queue: FakeDictationQueue(),
        insertion: FakeDictationInsertion(),
        asking: FakeDictationAsking(),
        selectionEditor: FakeSelectionEditing(),
        measurement: FixedAudioDuration(seconds: 3),
        makeLiveSession: { _, _, _ in nil }
    )
}

/// Lets Combine hops posted to the main run loop land inside the test.
func pumpMainRunLoop() {
    for _ in 0 ..< 8 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

// MARK: - .toPanel delivery

@MainActor
final class FakeDictationPanelReceiver: DictationPanelReceiving {
    private(set) var produced: [String] = []
    private(set) var failures: [String] = []

    func voiceCaptureDidProduce(_ text: String) async { produced.append(text) }
    func voiceCaptureDidFail(_ message: String) { failures.append(message) }
}
