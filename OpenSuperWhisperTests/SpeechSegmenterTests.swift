import XCTest

@testable import OpenSuperWhisper

/// One `SpeechSegmenter` is one `whisper_vad_context`, which is stateful and
/// not reentrant - and `LiveDictationSession` shares a single instance across
/// sessions, each reading it on a detached task. A cancel-and-retry can put a
/// new session's first VAD pass on the context while the old session's last
/// one is still running, so the instance itself has to keep its calls apart.
final class SpeechSegmenterTests: XCTestCase {

    private static let audioURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("jfk.wav")

    /// Eight passes on one instance at once come back as the one pass alone
    /// does - which they cannot unless the instance runs them one at a time.
    func testConcurrentCallsOnOneInstanceAnswerAsASequentialCallDoes() async throws {
        try XCTSkipIf(SpeechSegmenter.vadModelPath == nil, "Silero VAD model not bundled")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.audioURL.path),
            "jfk sample not present in repo root")
        let loaded = try await PCMAudioLoader.loadSamples(from: Self.audioURL)
        let samples = try XCTUnwrap(loaded)

        let segmenter = SpeechSegmenter()
        let expected = Self.ranges(try segmenter.segments(in: samples))
        XCTAssertFalse(expected.isEmpty, "the clip is speech")

        let results = await withTaskGroup(of: [ClosedRange<Int64>]?.self) { group in
            for _ in 0..<8 {
                group.addTask(priority: .userInitiated) {
                    (try? segmenter.segments(in: samples)).map(Self.ranges)
                }
            }
            var collected: [[ClosedRange<Int64>]?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        for result in results {
            XCTAssertEqual(result, expected, "a pass that shared the context with another gave a different answer")
        }
    }

    private static func ranges(_ segments: [WhisperVadSegment]) -> [ClosedRange<Int64>] {
        segments.map { $0.startCs...$0.endCs }
    }
}
