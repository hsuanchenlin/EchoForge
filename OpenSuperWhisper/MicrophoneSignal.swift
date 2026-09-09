import Foundation

/// One reading of the microphone, in the units the hardware reports it in.
///
/// Two numbers rather than one, because the two questions the level answers are
/// different measurements. "Is anything arriving, and is it loud enough" is a
/// question about mean power, which is what the meter has always drawn. "Is the
/// signal being clipped" is a question about the loudest *sample* in the buffer,
/// and mean power cannot answer it: a voice peaking at 0 dBFS between syllables
/// averages out at around -18 dBFS, which reads as a healthy recording right up
/// until the transcript comes back full of crushed consonants.
///
/// dBFS rather than the 0…1 the meter draws, so the thresholds in
/// `MicrophoneSignalMonitor` are stated in the unit they were measured in.
/// `AudioRecorder.normalizedLevel(decibels:)` is the one place that converts,
/// and the two `normalized…` properties below are the only callers a view needs.
struct MicrophoneLevel: Equatable {

    /// Mean power over the last buffer, in dBFS.
    let averageDecibels: Float

    /// The loudest sample in the last buffer, in dBFS.
    let peakDecibels: Float

    /// What the meter reads when nothing is being captured. `AVAudioRecorder`
    /// reports -160 dBFS for true digital silence.
    static let silent = MicrophoneLevel(averageDecibels: -160, peakDecibels: -160)

    /// The mean, on the 0…1 scale the waveform draws.
    var normalizedAverage: Float { AudioRecorder.normalizedLevel(decibels: averageDecibels) }

    /// The peak, on the same scale.
    var normalizedPeak: Float { AudioRecorder.normalizedLevel(decibels: peakDecibels) }

    /// A reading described by where it would sit on the meter.
    ///
    /// The inverse of `AudioRecorder.normalizedLevel(decibels:)`, for the callers
    /// that think in bar heights rather than in decibels: previews, and the tests
    /// that assert what the meter draws. `peak` defaults to `average`, which is
    /// the conservative reading - it can only ever make a sample look quieter
    /// than it was, never louder.
    static func normalized(average: Float, peak: Float? = nil) -> MicrophoneLevel {
        MicrophoneLevel(
            averageDecibels: decibels(forNormalized: average),
            peakDecibels: decibels(forNormalized: peak ?? average)
        )
    }

    static func decibels(forNormalized value: Float) -> Float {
        let floorDecibels = AudioRecorder.levelSilenceDecibels
        let clamped = min(1, max(0, value))
        return floorDecibels + clamped * -floorDecibels
    }
}

/// What the app is willing to say about the microphone during one capture.
///
/// Deliberately four states and not a number. A meter that only draws amplitude
/// confirms that *something* arrived; it cannot tell a user that the wrong input
/// is selected, that a Bluetooth headset came up on its call profile, or that
/// they are too far from the machine - and those are the three ways a dictation
/// silently comes back wrong. Each case here is one of those, phrased so it can
/// be shown without interrupting the recording it is about.
///
/// Nothing here is alarming and nothing here stops a capture: the user may be
/// deliberately whispering, and a recording that is refused because the app
/// disagreed about the volume is worse than a quiet transcript.
enum MicrophoneSignal: Hashable {

    /// Too early to say. The first samples of a capture are not evidence of
    /// anything - a Bluetooth microphone takes a moment to reach its working
    /// gain, and a user who has not started speaking yet is not a fault.
    case measuring

    /// Nothing above the noise floor has arrived since the capture started.
    /// The usual causes are the wrong input device and a muted one.
    case noSignal

    /// Something arrived, but never loud enough to transcribe well.
    case low

    /// A normal, usable signal.
    case good

    /// Samples are reaching the top of the scale, so the waveform is being
    /// squared off before any engine sees it.
    case clipping

    /// Whether this is worth telling the user about. `measuring` and `good` are
    /// the ordinary course of a dictation and say nothing.
    var isDiagnostic: Bool {
        switch self {
        case .measuring, .good: return false
        case .noSignal, .low, .clipping: return true
        }
    }

    /// The two words the capsule has room for beside the meter.
    var shortLabel: String? {
        switch self {
        case .measuring, .good: return nil
        case .noSignal: return "No signal"
        case .low: return "Low signal"
        case .clipping: return "Clipping"
        }
    }

    /// The SF Symbol beside the label. Each names the state rather than being a
    /// generic warning, so the shape distinguishes the three the way the words do.
    var symbolName: String? {
        switch self {
        case .measuring, .good: return nil
        case .noSignal: return "mic.slash"
        case .low: return "speaker.wave.1"
        case .clipping: return "waveform.badge.exclamationmark"
        }
    }

    /// The sentence a pane with room for one says, naming the thing to change.
    ///
    /// It never claims to know which of the causes it is: the app can see the
    /// samples and not the room, so it says what it measured and what to check.
    var advice: String? {
        switch self {
        case .measuring, .good: return nil
        case .noSignal:
            return "Nothing is reaching Kongweh from this microphone. Check that the right input "
                + "is selected and that it is not muted."
        case .low:
            return "The signal is very quiet, which usually means the wrong input or too much "
                + "distance from it. Speech this quiet transcribes badly."
        case .clipping:
            return "The signal is hitting the top of the scale and being squared off. Move back "
                + "from the microphone, or turn its input volume down in System Settings."
        }
    }

    /// What VoiceOver is told, when it is told anything.
    ///
    /// The full sentence rather than the pill's two words: an announcement is
    /// heard once, with no pane around it to explain what "Low" was about.
    var announcement: String? {
        guard let shortLabel, let advice else { return nil }
        return "\(shortLabel). \(advice)"
    }
}

/// Turns a stream of level readings into one of those five states.
///
/// A pure value type, fed samples with the time they were taken, so every
/// threshold and every grace period can be asserted without a microphone, a
/// window server or a real 1.5-second wait - the same reason
/// `CapsuleHUDViewModel` takes its clock as an argument.
///
/// Three rules decide what it will and will not claim.
///
/// **It measures the whole capture, not the last moment.** `loudestPeak` only
/// ever grows, so somebody who says a sentence and then pauses is not told their
/// microphone went silent. "No signal" therefore means what it says: nothing
/// above the noise floor has arrived *at any point* since the capture started.
///
/// **It waits before it speaks.** Nothing but clipping can be reported inside
/// `graceInterval`, because the opening moments of a capture are the moments a
/// Bluetooth input is still coming up to gain and the user has not started
/// talking. Reporting "No signal" there would fire on almost every dictation.
///
/// **Clipping wins.** It is the one state that is already damaging the
/// recording rather than merely describing it, and it is the one a user can act
/// on mid-sentence, so a single clipped buffer raises it and it stays up for
/// `clippingHoldInterval` afterwards - long enough to be read, short enough not
/// to outlive the syllable that caused it.
struct MicrophoneSignalMonitor: Equatable {

    /// At or below this, in dBFS, a peak counts as the noise floor rather than
    /// as sound. A built-in microphone in a quiet room sits around -50 dBFS on
    /// mean power and rather higher on peaks, so this is set above that.
    static let silenceDecibels: Float = -42

    /// At or below this, in dBFS, the loudest thing heard so far is too quiet
    /// to transcribe well. Speech at a normal distance peaks around -12 dBFS.
    static let lowSignalDecibels: Float = -28

    /// At or above this, in dBFS, samples are being squared off.
    static let clippingDecibels: Float = -1

    /// How long a capture has to run before anything but clipping is claimed.
    static let graceInterval: TimeInterval = 1.5

    /// How long a clipping report stays up after the last clipped buffer.
    static let clippingHoldInterval: TimeInterval = 1.2

    /// When the capture started, or `nil` before the first sample.
    private(set) var startedAt: Date?

    /// The loudest peak seen since `startedAt`. Monotonic on purpose.
    private(set) var loudestPeak: Float = -.infinity

    /// When the last clipped buffer arrived.
    private(set) var lastClippedAt: Date?

    init() {}

    /// Forgets everything, for the start of a new capture.
    mutating func reset() {
        startedAt = nil
        loudestPeak = -.infinity
        lastClippedAt = nil
    }

    /// Records one reading.
    mutating func record(_ level: MicrophoneLevel, at date: Date) {
        if startedAt == nil { startedAt = date }
        loudestPeak = max(loudestPeak, level.peakDecibels)
        if level.peakDecibels >= Self.clippingDecibels {
            lastClippedAt = date
        }
    }

    /// What the app is willing to say at `date`.
    func signal(at date: Date) -> MicrophoneSignal {
        if let lastClippedAt, date.timeIntervalSince(lastClippedAt) < Self.clippingHoldInterval {
            return .clipping
        }
        guard let startedAt, date.timeIntervalSince(startedAt) >= Self.graceInterval else {
            return .measuring
        }
        if loudestPeak <= Self.silenceDecibels { return .noSignal }
        if loudestPeak <= Self.lowSignalDecibels { return .low }
        return .good
    }
}
