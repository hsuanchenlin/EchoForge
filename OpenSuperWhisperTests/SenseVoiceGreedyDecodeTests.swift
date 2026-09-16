import CoreML
import XCTest
@testable import OpenSuperWhisper

/// The greedy CTC decode the app now owns for SenseVoice, pinned as a pure
/// function over synthetic logits - no weights involved.
///
/// Timing cannot be deterministic in CI, so what is asserted here is the
/// causal contract instead: the decode reads raw tensor storage (fp16 as well
/// as fp32) rather than boxed subscripts, and its collapse/strip semantics are
/// exactly the pinned FluidAudio manager's. The byte-for-byte comparison
/// against `SenseVoiceManager` on real encoder output lives in
/// `SenseVoiceEngineIntegrationTests`.
final class SenseVoiceGreedyDecodeTests: XCTestCase {

    /// Builds [1, frames, vocab] logits whose per-frame argmax is `argmaxIds`,
    /// in the given storage type. Values are written through the boxed
    /// subscript - the slow path - which is fine for a handful of elements and
    /// proves the decode does not depend on it.
    private func logits(argmaxIds: [Int], vocab: Int, dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, argmaxIds.count as NSNumber, vocab as NSNumber], dataType: dataType)
        for (t, id) in argmaxIds.enumerated() {
            array[[0, t as NSNumber, id as NSNumber]] = NSNumber(value: 1.0)
        }
        return array
    }

    private let vocabulary: [Int: String] = [
        0: "<unk>",
        1: "你",
        2: "▁好",
        3: "<|zh|>",
        4: "<|withitn|>",
    ]

    func testArgmaxReadsTheWinningTokenPerFrame() throws {
        for dataType in [MLMultiArrayDataType.float32, .float16] {
            let logits = try logits(argmaxIds: [1, 2], vocab: 5, dataType: dataType)
            XCTAssertEqual(
                SenseVoiceGreedyDecode.argmaxPerFrame(logits: logits, frames: 2), [1, 2],
                "data type \(dataType.rawValue)")
        }
    }

    func testFloat16AndFloat32StorageDecodeIdentically() throws {
        let ids = [3, 1, 1, 0, 2, 2, 0, 1]
        let fp32 = try logits(argmaxIds: ids, vocab: 5, dataType: .float32)
        let fp16 = try logits(argmaxIds: ids, vocab: 5, dataType: .float16)
        XCTAssertEqual(
            SenseVoiceGreedyDecode.argmaxPerFrame(logits: fp16, frames: ids.count),
            SenseVoiceGreedyDecode.argmaxPerFrame(logits: fp32, frames: ids.count))
    }

    /// The pinned manager's collapse: `prev` updates on *every* frame, so a
    /// blank between repeats re-arms them - `1,1,blank,1` keeps both 1s.
    func testBlankIsDroppedAndRepeatsCollapseWithBlankReArming() throws {
        let logits = try logits(argmaxIds: [1, 1, 0, 1], vocab: 5, dataType: .float16)
        let text = SenseVoiceGreedyDecode.transcript(
            logits: logits, validFrames: 4, vocabulary: vocabulary)
        XCTAssertEqual(text, "你你")
    }

    /// Frames past `validFrames` are bucket padding and must not be decoded.
    func testFramesPastValidFramesAreIgnored() throws {
        let logits = try logits(argmaxIds: [1, 2, 2, 1], vocab: 5, dataType: .float16)
        let text = SenseVoiceGreedyDecode.transcript(
            logits: logits, validFrames: 3, vocabulary: vocabulary)
        XCTAssertEqual(text, "你 好", "the fourth frame's 你 is padding")
    }

    /// The model's `<|lang|><|emo|><|event|><|itn|>` prefix tags never reach the
    /// user, and the SentencePiece word boundary becomes a space.
    func testMetaTagsAreStrippedAndWordBoundariesBecomeSpaces() throws {
        let logits = try logits(argmaxIds: [3, 4, 1, 2], vocab: 5, dataType: .float16)
        let text = SenseVoiceGreedyDecode.transcript(
            logits: logits, validFrames: 4, vocabulary: vocabulary)
        XCTAssertEqual(text, "你 好")
    }

    func testAllBlankFramesDecodeToEmpty() throws {
        let logits = try logits(argmaxIds: [0, 0, 0], vocab: 5, dataType: .float16)
        XCTAssertEqual(
            SenseVoiceGreedyDecode.transcript(logits: logits, validFrames: 3, vocabulary: vocabulary),
            "")
    }
}
