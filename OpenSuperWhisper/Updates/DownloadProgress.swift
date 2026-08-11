import Foundation

/// How far a transfer has got, in the terms a user can check against reality.
///
/// A bare percentage is what made a working download indistinguishable from a
/// dead one: the About pane rendered `0%` for everything from "the request has
/// not been answered" to "1.1 MB of a 212 MB asset has arrived", and a user
/// watching it had no way to tell which. The percentage is derived here rather
/// than passed around, and it travels with the byte counts it came from, so
/// nothing downstream can show a fraction without being able to show the bytes
/// behind it.
struct DownloadProgress: Equatable, Sendable {
    /// Bytes on disk, counting anything a resumed transfer started from.
    let receivedBytes: Int64

    /// What the whole asset is, from `Content-Length` plus whatever was already
    /// on disk, falling back to the release metadata's declared size.
    let totalBytes: Int64

    /// A smoothed recent rate, or `nil` before there is enough of a sample to
    /// say anything honest. Never shown as zero: "0 KB/s" on a live transfer is
    /// the same lie the bare percentage told.
    let bytesPerSecond: Double?

    init(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double? = nil) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// Clamped to `0...1`: a server that under-reports `Content-Length` must not
    /// produce a progress bar past its own end.
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    var remainingBytes: Int64 { max(totalBytes - receivedBytes, 0) }

    /// Seconds left at the current rate, or `nil` when there is no rate to
    /// project or nothing left to fetch. Deliberately not smoothed a second
    /// time - `TransferRateEstimator` has already done that, and an estimate
    /// that lags reality twice is worse than one that moves.
    var estimatedSecondsRemaining: TimeInterval? {
        guard let bytesPerSecond, bytesPerSecond > 0, remainingBytes > 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}

/// Turns byte counts arriving at whatever rate the network delivers them into a
/// rate a human can read.
///
/// Exponentially weighted rather than "total bytes over total time": the useful
/// question during a download is how fast it is going *now*, and an average
/// since the first byte answers a slow start long after it stopped being true.
/// The instantaneous rate is far too jittery to render - `URLSession` delivers
/// callbacks thousands of times a second - so it is smoothed.
///
/// Pure and clock-injected, so the arithmetic can be asserted without a network
/// and without waiting.
struct TransferRateEstimator {
    /// How much of each new sample is taken. Low enough that a momentary stall
    /// or burst does not swing the displayed number, high enough that a genuine
    /// change in link speed shows up within a few seconds.
    static let smoothingFactor = 0.25

    /// Samples closer together than this are accumulated rather than measured:
    /// dividing a handful of bytes by a millisecond produces a number with no
    /// information in it.
    static let minimumSampleInterval: TimeInterval = 0.25

    private var lastSampleTime: TimeInterval?
    private var lastSampleBytes: Int64 = 0
    private var smoothedRate: Double?

    init() {}

    /// Records that `totalBytes` have now arrived at `time` seconds on some
    /// monotonic clock, and returns the smoothed rate if there is one.
    @discardableResult
    mutating func record(totalBytes: Int64, at time: TimeInterval) -> Double? {
        guard let previousTime = lastSampleTime else {
            lastSampleTime = time
            lastSampleBytes = totalBytes
            return smoothedRate
        }

        let elapsed = time - previousTime
        guard elapsed >= Self.minimumSampleInterval else { return smoothedRate }

        // A resumed transfer restarts its byte count from where the partial file
        // ended, so a *decrease* is a new measurement baseline, not a negative
        // rate.
        let delta = totalBytes - lastSampleBytes
        lastSampleTime = time
        lastSampleBytes = totalBytes
        guard delta >= 0 else {
            smoothedRate = nil
            return nil
        }

        let sample = Double(delta) / elapsed
        smoothedRate = smoothedRate.map { $0 + Self.smoothingFactor * (sample - $0) } ?? sample
        return smoothedRate
    }

    var rate: Double? { smoothedRate }
}

/// The words the About pane puts on a transfer.
///
/// Formatting lives here rather than in the view because it is the part with
/// rules worth asserting: bytes are shown against the total so a stalled number
/// is visible, a rate is omitted entirely rather than shown as zero, and a
/// remaining time is rounded to something a person would say out loud instead of
/// counting down in seconds.
enum DownloadProgressText {
    static func bytes(_ progress: DownloadProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: progress.receivedBytes)
        let total = formatter.string(fromByteCount: progress.totalBytes)
        return "\(received) of \(total)"
    }

    static func rate(_ progress: DownloadProgress) -> String? {
        guard let bytesPerSecond = progress.bytesPerSecond, bytesPerSecond >= 1 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    /// `nil` when there is no rate to project from. Never "0 seconds left": the
    /// last moments of a transfer say nothing rather than counting to zero and
    /// then sitting there while the file is closed and verified.
    static func remaining(_ progress: DownloadProgress) -> String? {
        guard let seconds = progress.estimatedSecondsRemaining, seconds >= 1 else { return nil }
        switch seconds {
        case ..<10: return "a few seconds left"
        // Above about three quarters of a minute a person says "a minute", not
        // "50 seconds", and the estimate is not accurate enough to justify the
        // second.
        case ..<45: return "about \(Int(seconds.rounded())) seconds left"
        default:
            let minutes = Int((seconds / 60).rounded())
            return minutes == 1 ? "about a minute left" : "about \(minutes) minutes left"
        }
    }

    /// The whole line, with the parts that have nothing to say left out.
    static func summary(_ progress: DownloadProgress) -> String {
        let detail = [rate(progress), remaining(progress)].compactMap { $0 }
        guard !detail.isEmpty else { return bytes(progress) }
        return "\(bytes(progress)) (\(detail.joined(separator: ", ")))"
    }
}
