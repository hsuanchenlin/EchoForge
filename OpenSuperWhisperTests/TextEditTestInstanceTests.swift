import AppKit
import XCTest

/// The paste integration tests kill a TextEdit when they are done, and the rule they have to
/// keep is that it is *theirs*. They used to match on the bundle identifier, so class setUp
/// and class tearDown force-terminated every running TextEdit and took the user's open
/// document with them.
///
/// These run without TextEdit, without Accessibility and without a window server, because
/// the part worth pinning is the decision, not the launch.
final class TextEditTestInstanceTests: XCTestCase {

    // MARK: - Nothing the tests did not launch is ever terminated

    func testNothingIsTerminatedWhenNoInstanceWasLaunched() {
        XCTAssertEqual(
            TextEditTestInstance.terminationTargets(ownedProcessID: nil, runningProcessIDs: [4242, 4243]),
            [],
            "TextEdits are running but this class launched none of them, so all of them are the user's"
        )
    }

    func testOnlyTheLaunchedInstanceIsTerminated() {
        XCTAssertEqual(
            TextEditTestInstance.terminationTargets(
                ownedProcessID: 4243,
                runningProcessIDs: [4242, 4243, 4244]
            ),
            [4243],
            "the user's other TextEdits must survive a run that launched one of its own"
        )
    }

    func testAnAlreadyExitedInstanceIsNotTerminated() {
        XCTAssertEqual(
            TextEditTestInstance.terminationTargets(ownedProcessID: 4243, runningProcessIDs: [4242]),
            [],
            "the owned process is gone, and its identifier must not fall through onto another one"
        )
    }

    // MARK: - What counts as launched

    func testAFreshProcessIsOwned() {
        XCTAssertTrue(
            TextEditTestInstance.isOwned(launchedProcessID: 4244, preexistingProcessIDs: [4242, 4243])
        )
    }

    func testALaunchThatHandedBackARunningProcessIsNotOwned() {
        XCTAssertFalse(
            TextEditTestInstance.isOwned(launchedProcessID: 4242, preexistingProcessIDs: [4242, 4243]),
            "an app that refuses a second instance returns the running one, which belongs to the user"
        )
    }

    func testEveryProcessIsOwnedWhenNoneWereRunning() {
        XCTAssertTrue(TextEditTestInstance.isOwned(launchedProcessID: 4242, preexistingProcessIDs: []))
    }

    // MARK: - Against the real process table

    /// `runningProcessIDs` is what the ownership decision is fed, so it has to report the
    /// live process table rather than a stale snapshot. Nothing is launched or terminated
    /// here - a run with TextEdit open and a run without it both have to pass.
    ///
    /// The table itself is shared and mutable: a sibling test host's paste tests launch and
    /// kill their own TextEdit mid-run, and `NSWorkspace.shared.runningApplications` only
    /// catches up when the main run loop spins. So the two reads are compared, and a
    /// mismatch is re-read after a run-loop turn rather than trusted - a stale
    /// `runningProcessIDs` disagrees on every read, churn only on the one it straddled.
    func testRunningProcessIDsMatchTheProcessTable() {
        var reported = Set(TextEditTestInstance.runningProcessIDs())
        var expected = workspaceTextEditProcessIDs()
        let deadline = Date().addingTimeInterval(2)
        while reported != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            reported = Set(TextEditTestInstance.runningProcessIDs())
            expected = workspaceTextEditProcessIDs()
        }
        XCTAssertEqual(reported, expected)
    }

    private func workspaceTextEditProcessIDs() -> Set<pid_t> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == TextEditTestInstance.bundleIdentifier }
                .map(\.processIdentifier)
        )
    }

    // MARK: - The invariant that cannot be expressed as a type

    /// The integration tests may terminate a process only through `terminationTargets`.
    ///
    /// A source scan rather than a behavioural test, because the failure guarded against is
    /// a future edit adding one convenient `for app in runningApplications ... forceTerminate()`
    /// back - and running that edit to catch it is what destroys the document. Skipped rather
    /// than failed when the sources are not beside the tests.
    func testPasteIntegrationTestsTerminateOnlyThroughTheOwnershipHelper() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisperTests.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Sources are not beside the tests: \(source.path)")
        }
        let text = try String(contentsOf: source, encoding: .utf8)

        let terminations = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .filter { $0.contains("forceTerminate") || $0.contains(".terminate()") }
        XCTAssertEqual(
            terminations.count,
            1,
            "expected exactly one termination call, inside terminateOwnedTextEdit; found: \(terminations)"
        )
        XCTAssertTrue(
            text.contains("TextEditTestInstance.terminationTargets"),
            "the one termination call must take its targets from the ownership helper"
        )
        XCTAssertTrue(
            text.contains("configuration.createsNewApplicationInstance = true"),
            "the tests must launch their own TextEdit process rather than adopt a running one"
        )
    }
}
