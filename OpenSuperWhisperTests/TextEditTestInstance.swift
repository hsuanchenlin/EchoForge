import AppKit

/// Which TextEdit process the paste integration tests may drive and terminate.
///
/// `ClipboardUtilPasteIntegrationTests` needs a real TextEdit to type into through
/// Accessibility, and it kills that TextEdit when it is done. It used to find one by
/// bundle identifier, which made *every* running TextEdit a target: class setUp and class
/// tearDown force-terminated them all. `forceTerminate()` is a SIGKILL, so a run on a
/// developer's Mac took the document they had open with it - no save prompt, no autosave
/// on the way out, nothing to recover.
///
/// So ownership here is a **process identity**, never a bundle identifier. The tests own
/// exactly one process - the one their own launch created, with
/// `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` so that a TextEdit the
/// user already has open is not it - and nothing else is ever driven or terminated.
enum TextEditTestInstance {
    static let bundleIdentifier = "com.apple.TextEdit"

    /// The process identifiers of every TextEdit running right now.
    static func runningProcessIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    }

    /// A launch produced an instance the tests own only when it is not one that was
    /// already there.
    ///
    /// `createsNewApplicationInstance` normally guarantees a fresh process, but an app that
    /// refuses a second instance hands back the running one instead - and that one is the
    /// user's, so the tests must decline it rather than assume the launch was theirs.
    static func isOwned(launchedProcessID: pid_t, preexistingProcessIDs: Set<pid_t>) -> Bool {
        !preexistingProcessIDs.contains(launchedProcessID)
    }

    /// The processes cleanup may terminate: the owned one while it is still running, and
    /// nothing else. With no owned process there is nothing to clean up, however many
    /// TextEdits are on screen - they are all the user's.
    static func terminationTargets(ownedProcessID: pid_t?, runningProcessIDs: [pid_t]) -> [pid_t] {
        guard let ownedProcessID, runningProcessIDs.contains(ownedProcessID) else { return [] }
        return [ownedProcessID]
    }
}
