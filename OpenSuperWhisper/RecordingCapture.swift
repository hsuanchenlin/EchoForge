import Combine
import Foundation

/// The recorder as one capture uses it: stop or cancel *this* session.
///
/// `AudioRecorder` is the production controller. Tests supply their own so the
/// handle can be exercised without CoreAudio.
protocol RecordingCaptureControlling: AnyObject {
    func stopRecording(_ session: RecordingSession) async -> URL?
    func cancelRecording(_ session: RecordingSession)
}

/// One recording, from the claim that took the microphone to the stop or cancel
/// that gives it back.
///
/// Returned by `AudioRecorder.startRecording`. The handle *is* the start's
/// result, the stop, the cancel and the connecting/recording signals - everything
/// that used to be a replaying `@Published` on a shared recorder. A surface that
/// holds a capture hears only that capture; there is no subscription to gate,
/// and no way to act on somebody else's failed start.
final class RecordingCapture: @unchecked Sendable {
    let session: RecordingSession

    private weak var controller: RecordingCaptureControlling?
    private let startWaiter = StartWaiter()
    private let connectingSubject = CurrentValueSubject<Bool, Never>(false)
    private let recordingSubject = CurrentValueSubject<Bool, Never>(false)
    private let levelLock = NSLock()
    private var levelContinuation: AsyncStream<MicrophoneLevel>.Continuation?

    init(session: RecordingSession, controller: RecordingCaptureControlling) {
        self.session = session
        self.controller = controller
    }

    deinit {
        startWaiter.completeIfPending(.success(()))
        levelContinuation?.finish()
    }

    /// Completes when the microphone has opened, or with the reason it never did.
    ///
    /// Idempotent: every waiter, including one that arrives after the start has
    /// already resolved, sees the same result. Connecting is not success - a
    /// Bluetooth headset can still fail to open after connecting has been
    /// published - so this waits for recording to begin, or for the start to
    /// fail.
    func started() async -> Result<Void, FailedRecordingStart.Reason> {
        await startWaiter.value()
    }

    func stop() async -> URL? {
        startWaiter.completeIfPending(.success(()))
        guard let controller else { return nil }
        return await controller.stopRecording(session)
    }

    func cancel() {
        startWaiter.completeIfPending(.success(()))
        controller?.cancelRecording(session)
    }

    /// The recorder is reaching a device that takes a moment to open. Per-capture,
    /// so a dictation that was refused cannot be painted as connecting by
    /// somebody else's headset.
    var isConnectingPublisher: AnyPublisher<Bool, Never> {
        connectingSubject.eraseToAnyPublisher()
    }

    /// The recorder is capturing. Per-capture for the same reason.
    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        recordingSubject.eraseToAnyPublisher()
    }

    /// Microphone levels while this capture is in flight.
    var levels: AsyncStream<MicrophoneLevel> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.levelLock.lock()
            self.levelContinuation = continuation
            self.levelLock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.levelLock.lock()
                self.levelContinuation = nil
                self.levelLock.unlock()
            }
        }
    }

    // MARK: - The recorder's reports

    /// The start has resolved. Safe to call more than once: the first answer
    /// sticks, so a stop racing a late failure cannot flip a success into a
    /// failure after the caller has already moved on.
    func completeStart(_ result: Result<Void, FailedRecordingStart.Reason>) {
        startWaiter.complete(result)
    }

    func noteConnecting(_ isConnecting: Bool) {
        connectingSubject.send(isConnecting)
    }

    func noteRecording(_ isRecording: Bool) {
        recordingSubject.send(isRecording)
        if isRecording {
            startWaiter.complete(.success(()))
        }
    }

    func pushLevel(_ level: MicrophoneLevel) {
        levelLock.lock()
        let continuation = levelContinuation
        levelLock.unlock()
        continuation?.yield(level)
    }
}

/// One-shot start result, waitable from any queue.
private final class StartWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, FailedRecordingStart.Reason>?
    private var waiters: [CheckedContinuation<Result<Void, FailedRecordingStart.Reason>, Never>] = []

    func complete(_ result: Result<Void, FailedRecordingStart.Reason>) {
        let toResume: [CheckedContinuation<Result<Void, FailedRecordingStart.Reason>, Never>]
        lock.lock()
        if self.result != nil {
            lock.unlock()
            return
        }
        self.result = result
        toResume = waiters
        waiters = []
        lock.unlock()
        for waiter in toResume {
            waiter.resume(returning: result)
        }
    }

    func completeIfPending(_ result: Result<Void, FailedRecordingStart.Reason>) {
        complete(result)
    }

    func value() async -> Result<Void, FailedRecordingStart.Reason> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
