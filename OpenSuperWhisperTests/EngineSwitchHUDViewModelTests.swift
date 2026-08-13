import XCTest

@testable import OpenSuperWhisper

/// The overlay's timing, which is the part of it that can be wrong.
///
/// The engine shortcut is pressed repeatedly by design - three presses to walk
/// three engines - so a hide belonging to a message that has already been replaced
/// is the normal case here rather than an edge one. That is the same mistake
/// `CapsuleHUDViewModelTests` pins for the dictation capsule, and it is pinned
/// separately because these are two overlays with two lifetimes.
@MainActor
final class EngineSwitchHUDViewModelTests: XCTestCase {

    /// Captures what was scheduled instead of waiting for it, so the suite does not
    /// spend two seconds per assertion.
    private final class Clock {
        private(set) var pending: [(TimeInterval, @MainActor () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            pending.append((delay, work))
        }

        @MainActor
        func fireAll() {
            let due = pending
            pending = []
            for (_, work) in due { work() }
        }
    }

    func testShowingAMessagePutsItUp() {
        let clock = Clock()
        let viewModel = EngineSwitchHUDViewModel(schedule: { clock.schedule($0, $1) })

        viewModel.show(EngineSwitchAnnouncement(text: "Engine: SenseVoice-Small", isCloud: false))

        XCTAssertEqual(viewModel.announcement?.text, "Engine: SenseVoice-Small")
        XCTAssertEqual(clock.pending.first?.0, EngineSwitchHUDViewModel.visibleDuration)
    }

    func testItHidesItselfWhenItsOwnTimerFires() {
        let clock = Clock()
        let viewModel = EngineSwitchHUDViewModel(schedule: { clock.schedule($0, $1) })
        var hides = 0
        viewModel.onHide = { hides += 1 }

        viewModel.show(EngineSwitchAnnouncement(text: "Engine: Whisper - base", isCloud: false))
        clock.fireAll()

        XCTAssertNil(viewModel.announcement)
        XCTAssertEqual(hides, 1)
    }

    /// The load-bearing one. A second press replaces the message, and the first
    /// press's hide - already scheduled, and due sooner - must not take the new one
    /// off the screen.
    func testASecondPressKeepsItsOwnMessageUp() {
        let clock = Clock()
        let viewModel = EngineSwitchHUDViewModel(schedule: { clock.schedule($0, $1) })

        viewModel.show(EngineSwitchAnnouncement(text: "Engine: Whisper - base", isCloud: false))
        let firstHide = clock.pending
        viewModel.show(EngineSwitchAnnouncement(text: "Engine: Parakeet", isCloud: false))
        for (_, work) in firstHide { work() }

        XCTAssertEqual(viewModel.announcement?.text, "Engine: Parakeet")

        clock.fireAll()
        XCTAssertNil(viewModel.announcement, "its own timer still ends it")
    }

    /// Nothing on screen means nothing to hide: a stray dismissal must not fade a
    /// panel that is already out, which is what makes the controller's
    /// `orderOut` safe to hang off `onHide`.
    func testDismissingNothingDoesNothing() {
        let clock = Clock()
        let viewModel = EngineSwitchHUDViewModel(schedule: { clock.schedule($0, $1) })
        var hides = 0
        viewModel.onHide = { hides += 1 }

        viewModel.dismiss()

        XCTAssertEqual(hides, 0)
    }

    // MARK: - Where the pill lands

    /// A 27" display with a 25 pt menu bar, in the coordinates AppKit reports.
    private static let display = (
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visible: CGRect(x: 0, y: 0, width: 2560, height: 1415)
    )

    private func pillTop(forOrigin origin: NSPoint, windowSize: CGSize) -> CGFloat {
        let pillTopInset = (windowSize.height - EngineSwitchHUDView.capsuleHeight) / 2
        return origin.y + windowSize.height - pillTopInset
    }

    func testThePillHangsBelowTheMenuBarAndIsCentred() {
        let size = EngineSwitchHUDView.windowSize
        let origin = EngineSwitchHUD.origin(
            visibleFrame: Self.display.visible,
            screenFrame: Self.display.frame,
            windowSize: size,
            topOffset: EngineSwitchHUD.topMargin
        )

        XCTAssertEqual(origin.x + size.width / 2, Self.display.visible.midX, accuracy: 0.001)
        XCTAssertEqual(
            pillTop(forOrigin: origin, windowSize: size),
            Self.display.visible.maxY - EngineSwitchHUD.topMargin,
            accuracy: 0.001,
            "the pill, not the panel around it, is what has to clear the menu bar"
        )
    }

    /// A press during a dictation is exactly when both overlays want the top of the
    /// screen, so with the capsule switched on this one sits clear of its slot.
    func testItSitsClearOfTheCapsuleWhenTheCapsuleIsSwitchedOn() {
        let withCapsule = EngineSwitchHUD.topOffset(capsuleHUDEnabled: true)
        let without = EngineSwitchHUD.topOffset(capsuleHUDEnabled: false)

        XCTAssertEqual(without, EngineSwitchHUD.topMargin)
        XCTAssertGreaterThanOrEqual(
            withCapsule,
            CapsuleHUDWindowController.topMargin + CapsuleHUDView.capsuleHeight,
            "it would otherwise be drawn over what the capsule is saying about the dictation"
        )
    }

    func testAScreenSmallerThanThePanelStillPutsItOnScreen() {
        let size = EngineSwitchHUDView.windowSize
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 60)
        let origin = EngineSwitchHUD.origin(
            visibleFrame: tiny, screenFrame: tiny, windowSize: size, topOffset: EngineSwitchHUD.topMargin
        )

        XCTAssertEqual(origin.x, tiny.minX, "clamped to the left edge rather than centred off it")
        XCTAssertGreaterThanOrEqual(origin.y, tiny.minY)
    }
}
