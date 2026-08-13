import AppKit

/// Says the engine change out loud, for the users the pill cannot reach.
///
/// The overlay is a panel that never becomes key, ignores the mouse and belongs to
/// an app that is not frontmost - which is what makes it safe to show while someone
/// is typing somewhere else, and also what makes it invisible to VoiceOver: there
/// is no focus move for it to follow and nothing in the interaction to announce. An
/// announcement notification is the one channel that does not need focus, so the
/// shortcut posts one alongside the pill.
///
/// The payload is built by a pure function because that is the part with a
/// contract - the same sentence the pill shows, at a priority that interrupts,
/// since a two-second overlay that has already gone is not worth speaking after the
/// fact.
enum EngineSwitchAccessibility {

    /// What is handed to `NSAccessibility` for one announcement.
    ///
    /// `.high` deliberately: this is the result of a key the user just pressed, and
    /// a queued announcement arriving after the pill has faded describes a screen
    /// that no longer says anything.
    static func announcementUserInfo(
        for announcement: EngineSwitchAnnouncement
    ) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [
            .announcement: announcement.text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
    }

    /// Posts it against the application element, which is the element a HUD that
    /// owns no focus can speak through.
    @MainActor
    static func announce(_ announcement: EngineSwitchAnnouncement) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: announcementUserInfo(for: announcement)
        )
    }
}
