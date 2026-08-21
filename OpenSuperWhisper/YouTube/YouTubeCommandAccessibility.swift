import AppKit

/// Says what a spoken YouTube command did, for the users the overlay cannot
/// reach.
///
/// The dictation overlays are panels that never become key and belong to an app
/// that is not frontmost - which is what makes them safe to show while someone is
/// typing somewhere else, and also what makes them invisible to VoiceOver. An
/// announcement notification is the one channel that needs no focus, so the
/// command posts one alongside whatever the overlay says. It is the same shape
/// and the same reasoning as `EngineSwitchAccessibility`.
///
/// It is also the surface that carries the *whole* sentence. The card has room
/// for four or five words, so a refusal names the fix in full only here and in
/// the log - which is why the message is built by `YouTubeLatestVideoReport` and
/// not by a view.
enum YouTubeCommandAccessibility {

    static func announcementUserInfo(
        for report: YouTubeLatestVideoReport
    ) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [
            .announcement: report.spokenSummary,
            // The result of something the user just said out loud, and the
            // overlay that shows it lasts two seconds: an announcement queued
            // behind another one would describe a screen that has moved on.
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
    }

    @MainActor
    static func announce(_ report: YouTubeLatestVideoReport) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: announcementUserInfo(for: report)
        )
    }
}
