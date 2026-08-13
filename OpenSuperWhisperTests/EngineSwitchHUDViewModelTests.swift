import AppKit
import XCTest

@testable import OpenSuperWhisper

/// The overlay's timing, placement and spoken form - everything about it that can
/// be wrong without a window server being involved.
///
/// The engine shortcut is pressed repeatedly by design - three presses to walk
/// three engines - so a hide belonging to a message that has already been replaced
/// is the normal case here rather than an edge one. That is the same mistake
/// `CapsuleHUDViewModelTests` pins for the dictation capsule, and it is pinned
/// separately because these are two overlays with two lifetimes.
///
/// The placement cases carry the other half: which display the pill lands on is
/// what once made this whole feature look absent, and it is asserted against a
/// two-display arrangement no checkout machine has.
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

    // MARK: - Which displays it lands on

    /// The two-display arrangement the shortcut was reported broken on: a built-in
    /// screen and a monitor to the right of it, sitting lower.
    private static let twoDisplays = [
        ScreenGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950)
        ),
        ScreenGeometry(
            displayID: 2,
            frame: CGRect(x: 1512, y: 182, width: 1280, height: 800),
            visibleFrame: CGRect(x: 1512, y: 182, width: 1280, height: 800)
        ),
    ]

    /// The bug the mirroring exists for: the pill used to go to the screen holding
    /// the focused window, so on this Mac the engine changed and the confirmation
    /// appeared on a display the user was not looking at - and two seconds later
    /// there was nothing left to find.
    func testEveryAttachedDisplayGetsThePill() {
        let placements = EngineSwitchHUD.placements(
            for: Self.twoDisplays,
            windowSize: EngineSwitchHUDView.windowSize,
            topOffset: EngineSwitchHUD.topMargin
        )

        XCTAssertEqual(placements.map(\.displayID), [1, 2])
    }

    func testEachDisplaySPillIsCentredOnThatDisplay() {
        let size = EngineSwitchHUDView.windowSize
        let placements = EngineSwitchHUD.placements(
            for: Self.twoDisplays, windowSize: size, topOffset: EngineSwitchHUD.topMargin
        )

        for (placement, screen) in zip(placements, Self.twoDisplays) {
            XCTAssertEqual(
                placement.origin.x + size.width / 2, screen.visibleFrame.midX, accuracy: 0.001,
                "the pill on display \(placement.displayID) is centred on some other display"
            )
            XCTAssertEqual(
                pillTop(forOrigin: placement.origin, windowSize: size),
                screen.visibleFrame.maxY - EngineSwitchHUD.topMargin,
                accuracy: 0.001,
                "the pill on display \(placement.displayID) hangs from the wrong screen's top edge"
            )
        }
    }

    /// A Mac with its lid shut and no monitor attached: nothing to draw on, and
    /// nothing drawn. The same answer the single-panel version gave.
    func testNoDisplaysMeansNoPill() {
        XCTAssertEqual(
            EngineSwitchHUD.placements(
                for: [], windowSize: EngineSwitchHUDView.windowSize, topOffset: EngineSwitchHUD.topMargin
            ),
            []
        )
    }

    // MARK: - What VoiceOver is told

    /// The pill is a panel that never takes focus, which is what makes it safe to
    /// show mid-typing and also what makes it silent. The announcement is the only
    /// channel this shortcut has to a VoiceOver user.
    func testTheAnnouncementCarriesTheSameSentenceThePillShows() throws {
        let announcement = EngineSwitchMessage.announcement(
            for: .switched(.sensevoice), whisperModelPath: nil, cloudModel: ""
        )

        let userInfo = EngineSwitchAccessibility.announcementUserInfo(for: announcement)

        XCTAssertEqual(userInfo[.announcement] as? String, announcement.text)
        XCTAssertTrue(
            try XCTUnwrap(userInfo[.announcement] as? String)
                .contains(EngineCatalog.entry(for: .sensevoice).displayName),
            "the spoken confirmation has to name the engine, which is the whole content of it"
        )
    }

    /// Spoken now or not at all: the pill it accompanies is gone in two seconds, so
    /// a queued announcement would describe a screen that has already moved on.
    func testTheAnnouncementInterruptsRatherThanQueues() {
        let userInfo = EngineSwitchAccessibility.announcementUserInfo(
            for: EngineSwitchAnnouncement(text: "Engine: Parakeet", isCloud: false)
        )

        XCTAssertEqual(
            userInfo[.priority] as? Int, NSAccessibilityPriorityLevel.high.rawValue
        )
    }

    /// A deferred press must not be announced as a switch that has happened - the
    /// one rule the overlay's wording carries, and now the spoken form carries it
    /// too because they are the same string.
    func testADeferredPressIsSpokenAsDeferred() throws {
        let userInfo = EngineSwitchAccessibility.announcementUserInfo(
            for: EngineSwitchMessage.announcement(
                for: .deferred(.paraformer), whisperModelPath: nil, cloudModel: ""
            )
        )

        let spoken = try XCTUnwrap(userInfo[.announcement] as? String)
        XCTAssertTrue(spoken.contains("after this dictation"), "spoken as done, not as pending: \(spoken)")
    }
}
