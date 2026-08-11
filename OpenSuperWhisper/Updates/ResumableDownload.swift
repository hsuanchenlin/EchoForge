import CryptoKit
import Foundation

/// What is known about a partly-downloaded asset, kept beside the bytes.
///
/// Written to disk rather than held in memory because the point of the partial
/// file is to outlive the attempt that produced it - a failed download, a
/// dismissed pane, a quit app - and a resumed transfer that cannot prove the
/// bytes it is appending to came from the same asset is worse than one that
/// starts again.
struct PartialDownloadMetadata: Codable, Equatable {
    /// The asset URL the partial was fetched from, before any redirect. A
    /// different one means a different download, whatever the file is called.
    let sourceURL: String

    /// What the server said the whole asset was, when it said anything.
    let totalBytes: Int64

    /// The validator a resume is conditioned on. `If-Range` with this is what
    /// makes appending safe: a server whose copy has changed answers 200 with
    /// the whole file instead of 206 with a piece of a different one.
    let entityTag: String?

    /// Fallback validator for a server that offers no `ETag`.
    let lastModified: String?
}

/// Where partial downloads live between attempts, and the rules about what may
/// be resumed.
///
/// One directory per release version, under Caches rather than Application
/// Support: these are re-fetchable bytes, and a user clearing caches to reclaim
/// disk is doing exactly the right thing with them. Deliberately *not* the
/// system temporary directory, which macOS empties out from under a partial that
/// is meant to survive a quit.
struct PartialDownloadStore {
    /// Partials for versions other than the one being fetched are removed
    /// whenever a new download starts: a superseded release's half-download is
    /// hundreds of megabytes that nothing will ever ask for again.
    let root: URL
    let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            let identifier = Bundle.main.bundleIdentifier ?? "com.hsuanchenlin.EchoForge"
            self.root = caches.appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("Updates", isDirectory: true)
        }
    }

    func directory(for version: AppVersion) -> URL {
        root.appendingPathComponent(version.description, isDirectory: true)
    }

    func partialFile(for version: AppVersion) -> URL {
        directory(for: version).appendingPathComponent("\(UpdateManifest.assetName).partial")
    }

    func metadataFile(for version: AppVersion) -> URL {
        directory(for: version).appendingPathComponent("\(UpdateManifest.assetName).partial.json")
    }

    func prepareDirectory(for version: AppVersion) throws {
        try fileManager.createDirectory(at: directory(for: version), withIntermediateDirectories: true)
    }

    func metadata(for version: AppVersion) -> PartialDownloadMetadata? {
        guard let data = try? Data(contentsOf: metadataFile(for: version)) else { return nil }
        return try? JSONDecoder().decode(PartialDownloadMetadata.self, from: data)
    }

    func write(_ metadata: PartialDownloadMetadata, for version: AppVersion) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataFile(for: version), options: .atomic)
    }

    /// Bytes already on disk for this version, or 0 when there is nothing usable
    /// to resume from.
    func resumableBytes(for version: AppVersion, sourceURL: URL) -> Int64 {
        guard let metadata = metadata(for: version), metadata.sourceURL == sourceURL.absoluteString else {
            return 0
        }
        let attributes = try? fileManager.attributesOfItem(atPath: partialFile(for: version).path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    func discardPartial(for version: AppVersion) {
        try? fileManager.removeItem(at: partialFile(for: version))
        try? fileManager.removeItem(at: metadataFile(for: version))
    }

    /// Removes every partial that is not for `version`. Called when a download
    /// starts, which is the one moment the app knows which one is still wanted.
    func discardPartialsOtherThan(_ version: AppVersion) {
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where entry.lastPathComponent != version.description {
            try? fileManager.removeItem(at: entry)
        }
    }
}

/// What a server's answer to a range request means for the bytes already on
/// disk.
///
/// A separate value with a pure function behind it because this is the part that
/// corrupts a download when it is wrong - appending a 200's whole-file body onto
/// an existing partial produces a file of the right length made of the wrong
/// bytes, which then fails a checksum with no clue as to why - and it is the
/// part a test can exercise without a socket.
enum ResumeDecision: Equatable {
    /// Append the body to the partial, which already holds `existingBytes`.
    case append(existingBytes: Int64, totalBytes: Int64)

    /// Ignore what is on disk and write the body from the start.
    case restart(totalBytes: Int64)

    /// The server says the range is unsatisfiable and the partial is already the
    /// whole asset.
    case alreadyComplete(totalBytes: Int64)

    case fail(String)

    /// `existingBytes` is what was on disk when the request was made, and 0 when
    /// no range was asked for.
    static func decide(
        statusCode: Int,
        contentLength: Int64,
        contentRange: String?,
        existingBytes: Int64,
        declaredBytes: Int64
    ) -> ResumeDecision {
        switch statusCode {
        case 200:
            // Either nothing was asked for, or the server ignored the range - or
            // `If-Range` failed because the asset changed. All three mean the
            // body is the whole file, so anything already on disk is stale.
            let total = contentLength > 0 ? contentLength : declaredBytes
            return .restart(totalBytes: total)

        case 206:
            guard existingBytes > 0 else {
                return .fail("The server sent part of a file that was requested whole.")
            }
            guard let parsed = ContentRange(contentRange) else {
                return .fail("The server sent an unreadable range.")
            }
            guard parsed.start == existingBytes else {
                // A server that resumes from somewhere other than where the file
                // ends would leave a hole. Nothing recoverable to do but start
                // again.
                return .restart(totalBytes: parsed.total ?? declaredBytes)
            }
            let total = parsed.total ?? (existingBytes + contentLength)
            return .append(existingBytes: existingBytes, totalBytes: total)

        case 416:
            // The partial is at or past the end of the resource. If it is
            // exactly the declared size it is simply finished; otherwise it is
            // longer than the asset and cannot be part of it.
            guard existingBytes == declaredBytes, declaredBytes > 0 else {
                return .restart(totalBytes: declaredBytes)
            }
            return .alreadyComplete(totalBytes: declaredBytes)

        default:
            return .fail("The server returned an unexpected response (\(statusCode)).")
        }
    }
}

/// `bytes start-end/total`, as `Content-Range` states it.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    /// `nil` for the `*` a server may send when it does not know.
    let total: Int64?

    init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    init?(_ header: String?) {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        self.start = start
        self.end = end
        self.total = Int64(parts[1])
    }
}

/// The SHA-256 of a file, computed a block at a time.
///
/// Streamed rather than `Data(contentsOf:)`: the asset is hundreds of megabytes
/// and reading it into memory to hash it is a spike a user notices, on a machine
/// that is about to mount a disk image anyway.
enum FileDigest {
    static let blockSize = 1024 * 1024

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let block = try handle.read(upToCount: blockSize) ?? Data()
            if block.isEmpty { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a `shasum -a 256` line - `<64 hex>  <filename>` - and returns the
    /// digest. Strict about the shape: this decides whether an update is
    /// installed, so a document that is nearly right is refused rather than
    /// half-read.
    static func parseChecksumDocument(_ text: String, expectedFileName: String) -> String? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let digest = String(fields[0]).lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { continue }
            // `shasum` writes " *name" in binary mode and "  name" in text mode.
            let name = String(fields[1]).drop(while: { $0 == "*" })
            guard name == expectedFileName else { continue }
            return digest
        }
        return nil
    }
}

/// One transfer that can pick up where the last one stopped.
///
/// This replaces the download-task-plus-`didWriteData` shape the updater used
/// before, and keeps the platform lesson that shape was written around: progress
/// callbacks are delivered to a **session's own delegate** and never to one
/// passed per task, so the transfer owns its session. A data task rather than a
/// download task because a download task hands over a finished file it chose the
/// location of, which cannot be appended to - and appending is the entire point
/// here. The body is written straight to the partial file as it arrives, so
/// memory is a chunk at a time rather than an asset at a time.
///
/// What makes appending safe is `If-Range`: the request carries the validator
/// recorded when the partial was written, and a server whose copy has changed
/// answers 200 with the whole asset instead of 206 with a piece of a different
/// one. `ResumeDecision` is where that answer is read.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// What the caller gets back when the bytes are down.
    struct Outcome {
        let file: URL
        let totalBytes: Int64
    }

    private let destination: URL
    private let declaredBytes: Int64
    private let existingBytes: Int64
    private let activity: DownloadActivityClock?
    private let report: @Sendable (DownloadProgress) -> Void
    private let onValidator: @Sendable (PartialDownloadMetadata) -> Void
    private let sourceURL: URL

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var handle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var failure: Error?
    private var hasFinished = false
    private var rate = TransferRateEstimator()
    private let started = DispatchTime.now()

    init(
        sourceURL: URL,
        destination: URL,
        declaredBytes: Int64,
        existingBytes: Int64,
        activity: DownloadActivityClock? = nil,
        onValidator: @escaping @Sendable (PartialDownloadMetadata) -> Void = { _ in },
        report: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.declaredBytes = declaredBytes
        self.existingBytes = existingBytes
        self.activity = activity
        self.onValidator = onValidator
        self.report = report
    }

    /// The request a resume is made with. Static so a test can assert the
    /// headers without running a transfer.
    static func makeRequest(url: URL, existingBytes: Int64, validator: PartialDownloadMetadata?) -> URLRequest {
        var request = URLRequest(url: url)
        guard existingBytes > 0 else { return request }
        request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        // Without this a server whose asset changed would happily send bytes
        // from the *new* file to be appended to the old one's prefix.
        if let tag = validator?.entityTag {
            request.setValue(tag, forHTTPHeaderField: "If-Range")
        } else if let modified = validator?.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    func run(session: URLSession, request: URLRequest) async throws -> Outcome {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(throwing: UpdateInstallError.downloadFailed("The server returned no response."))
            return completionHandler(.cancel)
        }

        let decision = ResumeDecision.decide(
            statusCode: http.statusCode,
            contentLength: http.expectedContentLength > 0 ? http.expectedContentLength : 0,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            existingBytes: existingBytes,
            declaredBytes: declaredBytes
        )

        // Recorded before any bytes are written, so a later attempt resumes
        // against the same copy of the asset this one is appending to.
        onValidator(PartialDownloadMetadata(
            sourceURL: sourceURL.absoluteString,
            totalBytes: decisionTotal(decision),
            entityTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        ))

        switch decision {
        case .append(let existing, let total):
            do {
                try openHandle(truncating: false)
                try handle?.seekToEnd()
                lock.lock(); receivedBytes = existing; totalBytes = total; lock.unlock()
            } catch {
                finish(throwing: error)
                return completionHandler(.cancel)
            }

        case .restart(let total):
            do {
                try openHandle(truncating: true)
                lock.lock(); receivedBytes = 0; totalBytes = total; lock.unlock()
            } catch {
                finish(throwing: error)
                return completionHandler(.cancel)
            }

        case .alreadyComplete(let total):
            lock.lock(); receivedBytes = total; totalBytes = total; lock.unlock()
            report(DownloadProgress(receivedBytes: total, totalBytes: total))
            finish(returning: Outcome(file: destination, totalBytes: total))
            return completionHandler(.cancel)

        case .fail(let reason):
            finish(throwing: UpdateInstallError.downloadFailed(reason))
            return completionHandler(.cancel)
        }

        activity?.recordActivity()
        reportProgress()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        activity?.recordActivity()
        lock.lock()
        guard let handle, failure == nil else { return lock.unlock() }
        do {
            try handle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
        } catch {
            failure = UpdateInstallError.downloadFailed("It could not be written to disk. \(error.localizedDescription)")
            dataTask.cancel()
        }
        lock.unlock()
        reportProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let writeFailure = failure
        let received = receivedBytes
        let total = totalBytes
        try? handle?.close()
        handle = nil
        lock.unlock()

        if let writeFailure { return finish(throwing: writeFailure) }
        if let error { return finish(throwing: error) }
        finish(returning: Outcome(file: destination, totalBytes: total > 0 ? total : received))
    }

    /// Same rule as everywhere else the updater follows a redirect: the host
    /// allow-list is enforced where the bytes actually come from, not only on
    /// the URL the metadata named.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard UpdateManifest.isAllowedRedirectHost(request.url) else { return completionHandler(nil) }
        // `URLSession` drops the original headers on a cross-host redirect, and
        // GitHub always redirects to its object store - so a resume that does
        // not re-apply them downloads the whole asset and appends it.
        var followed = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            followed.setValue(range, forHTTPHeaderField: "Range")
        }
        if let ifRange = task.originalRequest?.value(forHTTPHeaderField: "If-Range") {
            followed.setValue(ifRange, forHTTPHeaderField: "If-Range")
        }
        completionHandler(followed)
    }

    // MARK: - Private

    private func decisionTotal(_ decision: ResumeDecision) -> Int64 {
        switch decision {
        case .append(_, let total), .restart(let total), .alreadyComplete(let total): return total
        case .fail: return declaredBytes
        }
    }

    private func openHandle(truncating: Bool) throws {
        let fileManager = FileManager.default
        if truncating || !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: destination)
        if truncating { try handle?.truncate(atOffset: 0) }
    }

    private func reportProgress() {
        lock.lock()
        let received = receivedBytes
        let total = totalBytes
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000_000
        let bytesPerSecond = rate.record(totalBytes: received, at: elapsed)
        lock.unlock()
        report(DownloadProgress(receivedBytes: received, totalBytes: total, bytesPerSecond: bytesPerSecond))
    }

    private func finish(returning outcome: Outcome) {
        guard let pending = takeContinuation() else { return }
        pending.resume(returning: outcome)
    }

    private func finish(throwing error: Error) {
        guard let pending = takeContinuation() else { return }
        pending.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Outcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished, let pending = continuation else { return nil }
        hasFinished = true
        continuation = nil
        return pending
    }
}
