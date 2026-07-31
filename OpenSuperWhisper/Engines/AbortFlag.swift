import Foundation

/// Thread-safe "stop now" flag shared by the engines that poll for cancellation.
///
/// Every engine sees cancellation from two threads: `cancelTranscription()`
/// arrives on the main actor while the transcription runs off it. Whisper hands
/// the flag's address to a C abort callback, so an engine owns its flag for its
/// whole lifetime rather than per transcription - the pointer must never dangle.
final class AbortFlag {
    private let lock = NSLock()
    private var _isSet = false

    var isSet: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSet
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isSet = newValue
        }
    }
}
