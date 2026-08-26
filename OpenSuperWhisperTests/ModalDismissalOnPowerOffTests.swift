import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The half of the restart fix that has to actually move pixels: when the
/// power-off broadcast arrives, a presented sheet comes off the window.
///
/// This is a behavioural test against a real `NSWindow` and a real
/// `attachedSheet`, because the two obvious ways to write the fix both *look*
/// right and were both measured not to work - see `PowerOffPresentationGuard`.
/// The window is never ordered front and is parked off screen, so nothing here
/// appears on a developer's display or takes their focus.
@MainActor
final class ModalDismissalOnPowerOffTests: XCTestCase {

    // MARK: - The fix

    func testTheSheetComesDownWhenTheAppIsAskedToDismissModalPresentations() throws {
        let center = NotificationCenter()
        let host = try presentedSheet(dismissingOn: center)
        defer { host.close() }

        XCTAssertNotNil(host.window.attachedSheet, "the fixture never presented a sheet")
        XCTAssertTrue(host.state.isPresented)

        center.post(name: .dismissModalPresentations, object: nil)
        // Measured at 270 ms - AppKit's sheet-dismissal animation, which
        // `Transaction.disablesAnimations` does not shorten. Three seconds is
        // slack, not a rate the fix has to hit.
        waitForSheetToClear(on: host.window, within: 3)

        XCTAssertNil(
            host.window.attachedSheet,
            "the sheet is still attached, so AppKit would still refuse the system's quit event")
        XCTAssertFalse(
            host.state.isPresented,
            "the sheet left the screen without SwiftUI being told, so SwiftUI can put it back")
    }

    /// The mirror image, and the reason `dismissesOnPowerOff` writes a SwiftUI
    /// binding instead of calling AppKit.
    ///
    /// `NSWindow.endSheet` is the obvious simplification of this whole fix, and
    /// it does not dismiss anything: SwiftUI, not AppKit, owns whether this
    /// sheet is presented, and `endSheet` leaves that state untouched. On a live
    /// app that showed up as `attachedSheet` still being non-nil more than a
    /// second later - SwiftUI simply puts the sheet back. The state is the part
    /// that is deterministic to assert, and it is also the part that matters:
    /// while SwiftUI still believes it is presenting, the app has dismissed
    /// nothing and the system's quit event is still refused.
    ///
    /// Anyone who "simplifies" the guard into that AppKit call fails this test
    /// rather than shipping a restart that still gets cancelled.
    func testEndSheetDoesNotChangeTheStateSwiftUIPresentsFrom() throws {
        let center = NotificationCenter()
        let host = try presentedSheet(dismissingOn: center)
        defer { host.close() }
        let sheet = try XCTUnwrap(host.window.attachedSheet)

        host.window.endSheet(sheet)
        settle(for: 0.5)

        XCTAssertTrue(
            host.state.isPresented,
            "endSheet now writes back through the SwiftUI binding. Re-measure the guard "
                + "before relying on it: the binding-based dismissal is still correct, but "
                + "this test's claim about AppKit has expired.")
    }

    // MARK: - Nothing new escapes the guard

    /// Every `.sheet` and `.confirmationDialog` in the app blocks the system's
    /// quit event for as long as it is up, so every one of them needs the
    /// modifier. A new presentation site added without it is exactly how this
    /// bug comes back.
    ///
    /// `.alert` is deliberately **not** covered: measured, an `.alert` does not
    /// block termination while a `.confirmationDialog` does, even though AppKit
    /// builds both out of `_NSAlertPanel`. That exemption is a measurement, not
    /// an oversight.
    ///
    /// `NSOpenPanel.runModal()` in `AppStyleMappingSettingsView` is app-modal
    /// rather than a sheet and is out of this guard's reach: `runModal` runs its
    /// own event loop, so a notification cannot take it down. It is transient
    /// and the user is standing at the machine when it is up, so it is left
    /// alone knowingly.
    func testEverySheetAndConfirmationDialogDismissesOnPowerOff() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        guard let files = FileManager.default.enumerator(atPath: sources.path)?
            .allObjects as? [String]
        else {
            throw XCTSkip("Sources are not beside the tests: \(sources.path)")
        }

        var presentationSites = 0
        var scanned = 0
        for file in files where file.hasSuffix(".swift") {
            let text = try String(
                contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            scanned += 1

            let sites = text.components(separatedBy: ".sheet(").count - 1
                + text.components(separatedBy: ".confirmationDialog(").count - 1
            guard sites > 0 else { continue }
            presentationSites += sites

            let guarded = text.components(separatedBy: "dismissesOnPowerOff(").count - 1
            XCTAssertGreaterThanOrEqual(
                guarded, sites,
                "\(file) presents \(sites) sheet(s)/confirmation dialog(s) but only \(guarded) "
                    + "of them are marked .dismissesOnPowerOff. An unguarded one cancels the "
                    + "user's restart and names Kongweh in a system dialog.")
        }

        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources, so it proved almost nothing")
        XCTAssertGreaterThanOrEqual(
            presentationSites, 5,
            "the scan found fewer presentation sites than the app is known to have, so its "
                + "pattern has stopped matching")
    }

    // MARK: - The fixture

    /// The presentation state, held outside the view so the test can read what
    /// SwiftUI believes rather than only what AppKit shows.
    private final class PresentationState: ObservableObject {
        @Published var isPresented = true
    }

    /// A window whose SwiftUI content presents a sheet and dismisses it on the
    /// broadcast - the shape of every real call site, with none of their state.
    private struct SheetHost: View {
        @ObservedObject var state: PresentationState

        var body: some View {
            Color.clear
                .frame(width: 320, height: 200)
                .sheet(isPresented: $state.isPresented) {
                    Text("A sheet that would refuse the system's quit event")
                        .padding()
                        .frame(width: 280, height: 120)
                }
                .dismissesOnPowerOff($state.isPresented)
        }
    }

    private struct PresentedSheet {
        let window: NSWindow
        let state: PresentationState
        func close() { window.close() }
    }

    private func presentedSheet(
        dismissingOn center: NotificationCenter,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> PresentedSheet {
        let state = PresentationState()
        let controller = NSHostingController(
            rootView: SheetHost(state: state).environment(\.modalDismissalCenter, center))
        // Far off any real display, and only ever `orderFrontRegardless` - a
        // sheet needs its parent window to exist and be visible, and no test may
        // put one where a developer can see it or lose focus to it.
        let window = NSWindow(
            contentRect: CGRect(x: -20000, y: -20000, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(3)
        while window.attachedSheet == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return PresentedSheet(window: window, state: state)
    }

    private func waitForSheetToClear(on window: NSWindow, within seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while window.attachedSheet != nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Let SwiftUI and AppKit finish whatever they were going to do, so an
    /// assertion about what did *not* happen is made after the chance to happen.
    private func settle(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
