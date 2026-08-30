import Foundation

/// One claim on the microphone, handed to whichever caller took it.
///
/// Identity is the whole point. Five keys reach one `AudioRecorder` - the two
/// dictation keys, ⌥A, ⌥S and ⌥E - and a caller that believes it is recording can be
/// wrong: its claim may have been given back on the recorder's work queue (no
/// microphone, an `AVAudioRecorder` that threw) and taken by somebody else
/// since. So stopping and cancelling **name the session they mean**, and one
/// that is no longer in flight is refused rather than obeyed. Without that, the
/// Ask panel's stop returned a dictation's audio and pasted a spoken question
/// into the user's document, and the main window's record button ended a
/// capture it never started.
struct RecordingSession: Equatable {
    fileprivate let id: UInt64
}

/// Who holds the microphone, as a value that can be reasoned about without one.
///
/// Deliberately its own type rather than three fields inside `AudioRecorder`.
/// This is the entire ownership rule the app's five recording entry points rest
/// on, and the recorder around it is a singleton wired to real hardware - so
/// inside it, the seizures this exists to prevent could only ever be asserted by
/// reading the source. Out here they are ordinary assertions;
/// `RecordingSessionClaimTests` is that suite.
///
/// It is a **lock** rather than the recorder's serial work queue because a
/// caller asking whether the microphone is free must not be made to wait behind
/// the 20-35 ms of CoreAudio round-trips a start already running on that queue
/// is paying. That synchrony is load-bearing: `AudioRecorder.isRecording` is
/// published a main-queue hop *after* those round-trips, so a press landing in
/// that window read an idle recorder and started a second recording on it.
final class RecordingSessionClaim {
    private let lock = NSLock()
    private var inFlight: RecordingSession?
    private var lastID: UInt64 = 0

    /// Whether anything holds the microphone right now.
    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight != nil
    }

    /// Takes the microphone for one session, or refuses because something is
    /// already holding it.
    func claim() -> RecordingSession? {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil else { return nil }
        lastID += 1
        let claimed = RecordingSession(id: lastID)
        inFlight = claimed
        return claimed
    }

    /// Gives the microphone back, but only from the session that holds it.
    ///
    /// The compare and the clear are one operation, which is what makes this
    /// safe to decide "carrying out this stop is mine to do" with: of two
    /// callers naming the same session, exactly one is told yes.
    ///
    /// - Returns: whether `session` was the session in flight. False means the
    ///   caller owns nothing and must not touch the recorder.
    @discardableResult
    func release(_ session: RecordingSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == session else { return false }
        inFlight = nil
        return true
    }
}
