import Foundation

/// What the engine overlay is showing, and for how long.
///
/// Its own state machine, tiny as it is, for the same reason `CapsuleHUDViewModel`
/// is one: the part that goes wrong is the timing, and a timer belonging to a
/// message that has already been replaced is what takes the *new* message off the
/// screen. The engine shortcut is pressed repeatedly by design - three presses to
/// walk three engines - so that mistake would be the normal case rather than an
/// edge one.
///
/// Free of AppKit so the timings can be asserted without a window server or a real
/// wait; `EngineSwitchHUD` owns the panel and draws whatever comes out.
@MainActor
final class EngineSwitchHUDViewModel: ObservableObject {

    /// How long one message stays. Longer than the capsule's success badge
    /// (`CapsuleHUDViewModel.completeVisibleDuration`) because this is a sentence
    /// to read rather than a checkmark to notice, and shorter than its error badge
    /// because nothing here is a problem.
    static let visibleDuration: TimeInterval = 2.0

    /// `nil` when nothing is on screen.
    @Published private(set) var announcement: EngineSwitchAnnouncement?

    /// Called once whenever the overlay has finished with the screen.
    var onHide: (() -> Void)?

    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Which message a pending hide belongs to. Every `show` moves it on, so the
    /// hide scheduled by the previous press cannot close the current one - the
    /// same generation guard the capsule uses, and the same reason.
    private var generation = 0

    init(
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
            = EngineSwitchHUDViewModel.scheduleOnMainQueue
    ) {
        self.schedule = schedule
    }

    static func scheduleOnMainQueue(after delay: TimeInterval, work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Puts a message up, replacing whatever was there, and starts its own timer.
    func show(_ announcement: EngineSwitchAnnouncement) {
        generation += 1
        self.announcement = announcement

        let scheduled = generation
        schedule(Self.visibleDuration) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        guard announcement != nil else { return }
        generation += 1
        announcement = nil
        onHide?()
    }
}
