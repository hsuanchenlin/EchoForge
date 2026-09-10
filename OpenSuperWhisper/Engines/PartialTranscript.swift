import Foundation

/// Text an engine has **committed** part-way through a decode.
///
/// The word that matters is committed. This is not a partial hypothesis that may
/// be revised: whisper.cpp emits a segment when it has finished deciding what
/// that segment says, and every later segment is appended after it. So the text
/// here only ever grows, never rewrites itself, and a surface showing it is
/// showing words the engine has already settled on rather than a guess that will
/// flicker.
///
/// That distinction is why this type exists at all rather than a bare `String`.
/// A cross-engine *streaming* contract - unstable hypotheses, revisions,
/// ordering - is a much larger promise and a later one; this is the honest,
/// smaller half of it, available from the one engine in this app that segments
/// as it goes.
struct PartialTranscript: Equatable, Sendable {
    /// Everything committed so far, joined in order.
    let text: String
    /// The segment that has just landed.
    let segment: String
    /// How many segments the engine has committed, including this one.
    let segmentCount: Int

    /// Whether there is anything worth showing. A decode that has produced only
    /// whitespace has produced nothing.
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// An engine that can say what it has decoded before it has finished.
///
/// A **separate** protocol rather than a member of `TranscriptionEngine`,
/// deliberately. Three of this app's four local engines return one final string
/// and have nothing to report along the way, and giving them a property they
/// could never fill would turn "this engine has partial output" into a runtime
/// question - always nil, occasionally not - instead of a fact a caller can
/// check once. `TranscriptionService` asks with a conditional cast, and a
/// surface that gets nothing back shows progress alone, exactly as it did before
/// this existed.
protocol PartialTranscriptEmitting: AnyObject {
    /// Called on the engine's own decoding thread, once per committed segment.
    ///
    /// The caller is responsible for getting the value onto whichever actor it
    /// needs - the same contract `TranscriptionEngine.onProgressUpdate` has, for
    /// the same reason: whisper.cpp's callbacks fire from its worker thread and
    /// hopping inside the engine would put a main-queue dispatch in the middle
    /// of a decode.
    var onPartialTranscript: ((PartialTranscript) -> Void)? { get set }
}

/// Accumulates the segments one decode commits.
///
/// Pure, and its own type so the joining rule is testable without a model: an
/// engine hands it whatever it just read out of its decoder, and it answers with
/// the whole transcript so far. Segments arrive already carrying their own
/// leading space in whisper's output, so they are joined with nothing between
/// them and trimmed only at the ends.
struct PartialTranscriptAccumulator {
    private var segments: [String] = []

    init() {}

    /// Records one committed segment and answers what to publish, or nil when
    /// the segment adds nothing a user could see.
    mutating func append(_ segment: String) -> PartialTranscript? {
        segments.append(segment)
        let text = segments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = PartialTranscript(
            text: text, segment: segment, segmentCount: segments.count)
        return partial.hasText ? partial : nil
    }

    var segmentCount: Int { segments.count }
}
