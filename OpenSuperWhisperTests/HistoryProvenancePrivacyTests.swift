import Foundation
import XCTest
@testable import OpenSuperWhisper

/// What history is allowed to write down.
///
/// The reason beside a failed command is stored on disk and read back weeks
/// later, so it is held to the same rule as everything else this app prints or
/// stores (`CloudRedaction`, `docs/cloud-api.md`): it may name what the user
/// said and what to do about it, and nothing else. A channel id, a feed URL, a
/// video URL or anything out of the Keychain in a history row would be a leak
/// with a very long half-life.
final class HistoryProvenancePrivacyTests: XCTestCase {

    private struct StubFetcher: YouTubeFeedFetching {
        let result: Result<Data, Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private final class MockBrowserOpener: BrowserOpening, @unchecked Sendable {
        let failure: BrowserOpenError?
        init(failure: BrowserOpenError? = nil) { self.failure = failure }
        func openInNewTab(_ url: URL) async throws {
            if let failure { throw failure }
        }
    }

    private let channelID = "UCaaaaaaaaaaaaaaaaaaaaaa"

    private var channel: YouTubeChannel {
        YouTubeChannel(displayName: "valley101", channelID: channelID)
    }

    private func feedData() -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>The newest one</title>
                <link rel="alternate" href="https://www.youtube.com/watch?v=bbbbbbbbbbb"/>
                <published>2026-08-01T10:00:00+00:00</published>
              </entry>
            </feed>
            """.utf8
        )
    }

    /// Every outcome the command has, checked against the three things that
    /// must never reach a stored row.
    func testNoStoredReasonCarriesAnIDAURLOrAScheme() async {
        var details: [String] = []

        for resolution: YouTubeChannelResolution in [
            .unknown(spoken: "Vali101"),
            .unknown(spoken: ""),
            .ambiguous(spoken: "valley", matches: ["valley101", "Valley 101"]),
            .disabled(spoken: "valley101"),
            .allowlisted(YouTubeChannel(displayName: "Broken", channelID: "@handle"),
                         matchedBy: .spokenName),
        ] {
            let service = YouTubeLatestVideoService(
                fetcher: StubFetcher(result: .success(feedData())), opener: MockBrowserOpener())
            details.append(
                RecordingProvenance.command(await service.run(resolution)).detail ?? "")
        }

        for error: YouTubeFeedError in [
            .unreachable, .httpStatus(404), .tooLarge, .malformed, .noEntries, .noUsableVideo,
        ] {
            let service = YouTubeLatestVideoService(
                fetcher: StubFetcher(result: .failure(error)), opener: MockBrowserOpener())
            details.append(
                RecordingProvenance.command(
                    await service.run(.allowlisted(channel, matchedBy: .spokenName))
                ).detail ?? "")
        }

        for failure: BrowserOpenError in [.chromeNotInstalled, .refusedURL] {
            let service = YouTubeLatestVideoService(
                fetcher: StubFetcher(result: .success(feedData())),
                opener: MockBrowserOpener(failure: failure))
            details.append(
                RecordingProvenance.command(
                    await service.run(.allowlisted(channel, matchedBy: .spokenName))
                ).detail ?? "")
        }

        // The one that opened. It names the channel as the user's own list names
        // it and the title the feed gave - never the id or the watch URL.
        let opening = YouTubeLatestVideoService(
            fetcher: StubFetcher(result: .success(feedData())), opener: MockBrowserOpener())
        details.append(
            RecordingProvenance.command(
                await opening.run(.allowlisted(channel, matchedBy: .spokenName))
            ).detail ?? "")

        details.append(contentsOf: [
            RecordingProvenance.queued(for: .youTubeCommand).detail ?? "",
            RecordingProvenance.notTranscribed(
                for: .youTubeCommand, reason: "No transcription engine is ready.").detail ?? "",
        ])

        XCTAssertGreaterThan(details.count, 12, "the scan covered almost nothing")
        for detail in details {
            XCTAssertFalse(detail.contains(channelID), "a channel ID reached history: \(detail)")
            XCTAssertFalse(detail.contains("://"), "a URL reached history: \(detail)")
            XCTAssertFalse(detail.contains("youtube.com"), "a host reached history: \(detail)")
            XCTAssertFalse(detail.contains("youtu.be"), "a host reached history: \(detail)")
            XCTAssertFalse(detail.contains("bbbbbbbbbbb"), "a video ID reached history: \(detail)")
        }
    }

    /// A stored row can only ever hold what `RecordingProvenance` produced, so
    /// the check above is only worth what this one is: nothing else writes those
    /// columns.
    /// Every directory a row could be written from: the app, the code it shares
    /// with the `echoforge` command-line tool, and the tool itself. The CLI
    /// reads history and must never write it, so it is scanned on the same
    /// terms as the app rather than left outside the rule.
    static let scannedSourceRoots = ["OpenSuperWhisper", "EchoForgeCore", "EchoForgeCLI"]

    func testOnlyTheProvenanceTypeWritesThoseColumns() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()

        // The row declares the columns and the schema creates them; nothing else
        // may name one. Both live in EchoForgeCore because the CLI reads the same
        // database, and a second declaration of a column is a second schema.
        let allowed: Set<String> = [
            "EchoForgeCore/History/Recording.swift",
            "EchoForgeCore/History/RecordingProvenance.swift",
            "EchoForgeCore/History/RecordingSchema.swift",
            "OpenSuperWhisper/Models/RecordingStore.swift",
        ]
        var scanned = 0
        for root in Self.scannedSourceRoots {
            let sources = repositoryRoot.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(atPath: sources.path)?
                .allObjects as? [String]
            else {
                throw XCTSkip("Sources are not beside the tests: \(sources.path)")
            }
            for file in files where file.hasSuffix(".swift") {
                let text = try String(
                    contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                scanned += 1
                guard !allowed.contains("\(root)/\(file)") else { continue }
                for column in ["provenanceKind", "provenanceReason", "provenanceDetail"]
                where text.contains(column) {
                    XCTFail(
                        "\(root)/\(file) writes \(column) directly. RecordingProvenance is the "
                            + "one thing that decides what goes in those columns, so a surface "
                            + "cannot put something in history that never went through it.")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources")
    }
}
