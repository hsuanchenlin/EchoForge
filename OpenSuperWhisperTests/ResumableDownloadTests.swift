import XCTest

@testable import OpenSuperWhisper

/// A checksum fetcher that answers from memory. Internal rather than private so
/// `UpdateInstallerTests` can use the same one.
final class StubChecksumFetcher: ChecksumFetching, @unchecked Sendable {
    /// What every release published before v0.5.2 looks like: no sidecar asset,
    /// so nothing is ever fetched. Any call to it is a test failing loudly
    /// rather than quietly passing verification.
    static let unavailable = StubChecksumFetcher(document: nil)

    let document: String?
    private let lock = NSLock()
    private var _requests: [URL] = []

    init(document: String?) {
        self.document = document
    }

    var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func fetchChecksumDocument(from url: URL) async throws -> String {
        lock.lock()
        _requests.append(url)
        lock.unlock()
        guard let document else {
            throw UpdateInstallError.checksumUnavailable("no sidecar was published")
        }
        return document
    }
}

/// What a range request's answer means for the bytes already on disk.
///
/// These are the rules that decide whether a resumed download appends or starts
/// again, and getting one wrong produces a file of exactly the right length made
/// of the wrong bytes - which is why they are a pure function with a table
/// against it rather than something only a network can exercise.
final class ResumeDecisionTests: XCTestCase {

    func testAPlainOkStartsOverEvenWhenSomethingIsOnDisk() {
        // 200 means the body is the whole file: either no range was asked for,
        // or `If-Range` failed because the asset changed. Appending it to what
        // is on disk is the corruption this case exists to prevent.
        XCTAssertEqual(
            ResumeDecision.decide(
                statusCode: 200, contentLength: 1000, contentRange: nil,
                existingBytes: 400, declaredBytes: 1000
            ),
            .restart(totalBytes: 1000)
        )
    }

    func testAPartialContentAtTheEndOfTheFileIsAppended() {
        XCTAssertEqual(
            ResumeDecision.decide(
                statusCode: 206, contentLength: 600, contentRange: "bytes 400-999/1000",
                existingBytes: 400, declaredBytes: 1000
            ),
            .append(existingBytes: 400, totalBytes: 1000)
        )
    }

    func testAPartialContentStartingSomewhereElseStartsOver() {
        // Resuming from anywhere but the end of the file would leave a hole.
        XCTAssertEqual(
            ResumeDecision.decide(
                statusCode: 206, contentLength: 600, contentRange: "bytes 300-999/1000",
                existingBytes: 400, declaredBytes: 1000
            ),
            .restart(totalBytes: 1000)
        )
    }

    func testPartialContentForSomethingNeverAskedForIsRefused() {
        guard case .fail = ResumeDecision.decide(
            statusCode: 206, contentLength: 600, contentRange: "bytes 400-999/1000",
            existingBytes: 0, declaredBytes: 1000
        ) else {
            return XCTFail("206 with no range requested is not something to interpret")
        }
    }

    func testAnUnreadableRangeIsRefusedRatherThanGuessed() {
        guard case .fail = ResumeDecision.decide(
            statusCode: 206, contentLength: 600, contentRange: "chunks 400 to 999",
            existingBytes: 400, declaredBytes: 1000
        ) else {
            return XCTFail("an unparseable Content-Range must not be interpreted")
        }
    }

    func testAFullPartialIsAlreadyComplete() {
        XCTAssertEqual(
            ResumeDecision.decide(
                statusCode: 416, contentLength: 0, contentRange: "bytes */1000",
                existingBytes: 1000, declaredBytes: 1000
            ),
            .alreadyComplete(totalBytes: 1000)
        )
    }

    func testAPartialLongerThanTheAssetStartsOver() {
        XCTAssertEqual(
            ResumeDecision.decide(
                statusCode: 416, contentLength: 0, contentRange: "bytes */1000",
                existingBytes: 1200, declaredBytes: 1000
            ),
            .restart(totalBytes: 1000)
        )
    }

    func testAnythingElseFails() {
        guard case .fail(let reason) = ResumeDecision.decide(
            statusCode: 503, contentLength: 0, contentRange: nil,
            existingBytes: 0, declaredBytes: 1000
        ) else {
            return XCTFail("a 503 is not a download")
        }
        XCTAssertTrue(reason.contains("503"), reason)
    }

    func testContentRangeParsing() {
        XCTAssertEqual(ContentRange("bytes 0-99/100"), ContentRange(start: 0, end: 99, total: 100))
        XCTAssertEqual(ContentRange("bytes 5-9/*")?.total, nil)
        XCTAssertNil(ContentRange("items 0-99/100"))
        XCTAssertNil(ContentRange(nil))
    }

    /// The request is the other half: without `If-Range` a server whose copy
    /// changed would hand back bytes from the new asset to be appended to the
    /// old one's prefix.
    func testAResumeAsksForARangeConditionedOnTheRecordedValidator() {
        let metadata = PartialDownloadMetadata(
            sourceURL: "https://example.invalid/EchoForge.dmg",
            totalBytes: 1000,
            entityTag: "\"abc\"",
            lastModified: "Mon, 10 Aug 2026 00:00:00 GMT"
        )
        let request = ResumableDownload.makeRequest(
            url: URL(string: "https://example.invalid/EchoForge.dmg")!,
            existingBytes: 400,
            validator: metadata
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=400-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"abc\"")
    }

    func testAFirstAttemptAsksForNoRangeAtAll() {
        let request = ResumableDownload.makeRequest(
            url: URL(string: "https://example.invalid/EchoForge.dmg")!,
            existingBytes: 0,
            validator: nil
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Range"))
    }

    func testLastModifiedStandsInForAServerWithNoEntityTag() {
        let metadata = PartialDownloadMetadata(
            sourceURL: "https://example.invalid/EchoForge.dmg",
            totalBytes: 1000,
            entityTag: nil,
            lastModified: "Mon, 10 Aug 2026 00:00:00 GMT"
        )
        let request = ResumableDownload.makeRequest(
            url: URL(string: "https://example.invalid/EchoForge.dmg")!,
            existingBytes: 400,
            validator: metadata
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "Mon, 10 Aug 2026 00:00:00 GMT")
    }
}

/// Where partials live, and what may be resumed from.
final class PartialDownloadStoreTests: XCTestCase {

    private var root: URL!
    private var store: PartialDownloadStore!
    private let version = AppVersion("0.5.3")!
    private let source = URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/v0.5.3/EchoForge.dmg")!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PartialDownloadStore(root: root)
        try? store.prepareDirectory(for: version)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func writePartial(_ bytes: Int, source: URL) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: store.partialFile(for: version))
        store.write(
            PartialDownloadMetadata(
                sourceURL: source.absoluteString, totalBytes: 1000, entityTag: "\"v1\"", lastModified: nil
            ),
            for: version
        )
    }

    func testResumesFromWhatIsOnDiskForTheSameAsset() throws {
        try writePartial(400, source: source)
        XCTAssertEqual(store.resumableBytes(for: version, sourceURL: source), 400)
    }

    /// The file is named after the asset, not the URL, so a partial left by a
    /// different source has to be refused by the metadata rather than the name.
    func testDoesNotResumeAPartialFromADifferentURL() throws {
        try writePartial(400, source: URL(string: "https://example.invalid/EchoForge.dmg")!)
        XCTAssertEqual(store.resumableBytes(for: version, sourceURL: source), 0)
    }

    func testDoesNotResumeWithoutMetadata() throws {
        try Data(repeating: 0xAB, count: 400).write(to: store.partialFile(for: version))
        XCTAssertEqual(store.resumableBytes(for: version, sourceURL: source), 0)
    }

    /// A half-download of a release nobody will install is hundreds of megabytes
    /// of nothing.
    func testDiscardsPartialsForOtherVersions() throws {
        let old = AppVersion("0.5.2")!
        try store.prepareDirectory(for: old)
        try Data(repeating: 0x1, count: 10).write(to: store.partialFile(for: old))
        try writePartial(400, source: source)

        store.discardPartialsOtherThan(version)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partialFile(for: old).path))
        XCTAssertEqual(store.resumableBytes(for: version, sourceURL: source), 400)
    }

    func testDiscardingRemovesBothTheBytesAndTheValidator() throws {
        try writePartial(400, source: source)
        store.discardPartial(for: version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partialFile(for: version).path))
        XCTAssertNil(store.metadata(for: version))
    }
}

/// Hashing a file, and reading the digest a release publishes.
final class FileDigestTests: XCTestCase {

    func testHashesAFileInBlocks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        // Deliberately larger than one block, so the streaming path is the one
        // under test rather than a single read.
        try Data(repeating: 0x61, count: FileDigest.blockSize + 1234).write(to: file)

        let digest = try FileDigest.sha256(of: file)

        let expected = try shasum(file)
        XCTAssertEqual(digest, expected, "must agree with shasum, which is what produced the published sidecar")
    }

    /// The digest the release publishes, computed the way the release script
    /// computes it - so this asserts against the real tool rather than against
    /// another copy of the same Swift.
    private func shasum(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }

    func testReadsTheDigestForTheNamedFile() {
        let document = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  EchoForge.dmg\n"
        XCTAssertEqual(
            FileDigest.parseChecksumDocument(document, expectedFileName: "EchoForge.dmg"),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )
    }

    func testReadsBinaryModeOutput() {
        let document = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef *EchoForge.dmg"
        XCTAssertNotNil(FileDigest.parseChecksumDocument(document, expectedFileName: "EchoForge.dmg"))
    }

    /// A sidecar naming some other file is not this file's checksum, and
    /// accepting it would be verification that proves nothing.
    func testRefusesADigestForAnotherFile() {
        let document = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SomethingElse.dmg"
        XCTAssertNil(FileDigest.parseChecksumDocument(document, expectedFileName: "EchoForge.dmg"))
    }

    func testRefusesAnythingThatIsNotASha256() {
        XCTAssertNil(FileDigest.parseChecksumDocument("not a checksum", expectedFileName: "EchoForge.dmg"))
        XCTAssertNil(FileDigest.parseChecksumDocument("abc123  EchoForge.dmg", expectedFileName: "EchoForge.dmg"))
        XCTAssertNil(FileDigest.parseChecksumDocument("", expectedFileName: "EchoForge.dmg"))
    }
}

/// What the pane says about a transfer.
///
/// The rules here are the ones that make a slow download distinguishable from a
/// dead one, which is the whole reason the percentage stopped being the only
/// thing shown.
final class DownloadProgressTests: XCTestCase {

    func testFractionIsClampedToTheAssetsOwnEnd() {
        XCTAssertEqual(DownloadProgress(receivedBytes: 50, totalBytes: 100).fraction, 0.5)
        XCTAssertEqual(DownloadProgress(receivedBytes: 150, totalBytes: 100).fraction, 1)
        XCTAssertEqual(DownloadProgress(receivedBytes: 10, totalBytes: 0).fraction, 0)
    }

    func testBytesAreShownAgainstTheTotal() {
        let text = DownloadProgressText.bytes(DownloadProgress(receivedBytes: 12_400_000, totalBytes: 222_289_422))
        XCTAssertTrue(text.contains(" of "), text)
        XCTAssertTrue(text.contains("MB"), text)
    }

    /// "0 KB/s" on a live transfer is the same lie the bare percentage told.
    func testNoRateIsShownRatherThanAZeroOne() {
        XCTAssertNil(DownloadProgressText.rate(DownloadProgress(receivedBytes: 1, totalBytes: 100)))
        XCTAssertNil(DownloadProgressText.rate(
            DownloadProgress(receivedBytes: 1, totalBytes: 100, bytesPerSecond: 0)
        ))
        XCTAssertNotNil(DownloadProgressText.rate(
            DownloadProgress(receivedBytes: 1, totalBytes: 100, bytesPerSecond: 1_200_000)
        ))
    }

    func testTimeRemainingIsRoundedToSomethingAPersonWouldSay() {
        func remaining(_ received: Int64, _ total: Int64, _ rate: Double) -> String? {
            DownloadProgressText.remaining(
                DownloadProgress(receivedBytes: received, totalBytes: total, bytesPerSecond: rate)
            )
        }
        XCTAssertEqual(remaining(0, 5_000_000, 1_000_000), "a few seconds left")
        XCTAssertEqual(remaining(0, 30_000_000, 1_000_000), "about 30 seconds left")
        XCTAssertEqual(remaining(0, 120_000_000, 1_000_000), "about 2 minutes left")
        XCTAssertEqual(remaining(0, 60_000_000, 1_000_000), "about a minute left")
    }

    /// Nothing counts down to zero and then sits there while the file is closed
    /// and hashed.
    func testNothingIsSaidWhenThereIsNothingLeftToFetch() {
        XCTAssertNil(DownloadProgressText.remaining(
            DownloadProgress(receivedBytes: 100, totalBytes: 100, bytesPerSecond: 1_000_000)
        ))
    }

    func testTheSummaryLeavesOutWhatItHasNothingToSayAbout() {
        let bare = DownloadProgressText.summary(DownloadProgress(receivedBytes: 5, totalBytes: 100))
        XCTAssertFalse(bare.contains("("), bare)

        let full = DownloadProgressText.summary(
            DownloadProgress(receivedBytes: 5_000_000, totalBytes: 100_000_000, bytesPerSecond: 1_000_000)
        )
        XCTAssertTrue(full.contains("/s"), full)
        XCTAssertTrue(full.contains("left"), full)
    }

    func testTheRateFollowsTheLinkRatherThanTheWholeTransfer() {
        var estimator = TransferRateEstimator()
        // A slow start...
        estimator.record(totalBytes: 0, at: 0)
        estimator.record(totalBytes: 100_000, at: 1)
        let slow = estimator.rate
        XCTAssertEqual(try XCTUnwrap(slow), 100_000, accuracy: 1)

        // ...followed by a fast stretch has to move the number, or the estimate
        // describes a link speed that stopped being true.
        for second in 2...12 {
            estimator.record(totalBytes: Int64(100_000 + (second - 1) * 2_000_000), at: Double(second))
        }
        XCTAssertGreaterThan(try XCTUnwrap(estimator.rate), 1_000_000)
    }

    func testSamplesTooCloseTogetherAreAccumulatedRatherThanMeasured() {
        var estimator = TransferRateEstimator()
        estimator.record(totalBytes: 0, at: 0)
        // A handful of bytes over a millisecond is not a measurement.
        XCTAssertNil(estimator.record(totalBytes: 16_384, at: 0.001))
    }

    /// A resumed transfer's counter starts where the partial ended, so a
    /// decreasing count is a new baseline and never a negative rate.
    func testADecreasingByteCountDoesNotProduceANegativeRate() {
        var estimator = TransferRateEstimator()
        estimator.record(totalBytes: 5_000_000, at: 0)
        estimator.record(totalBytes: 1_000_000, at: 1)
        XCTAssertNil(estimator.rate)
        estimator.record(totalBytes: 2_000_000, at: 2)
        XCTAssertGreaterThan(try XCTUnwrap(estimator.rate), 0)
    }
}
