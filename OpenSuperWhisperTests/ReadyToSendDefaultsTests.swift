import XCTest
@testable import OpenSuperWhisper

/// The two defaults a fresh install now arrives with: the transcript is
/// polished, and the dictation it came from was shown in the capsule.
///
/// They are pinned together because they were changed together and for one
/// reason - dictation should be good and visible without the user first finding
/// two switches - and because the same rule carries both: a *default* fills in
/// for a key nobody has written, and never overwrites one somebody has.
@MainActor
final class ReadyToSendDefaultsTests: IsolatedPreferencesTestCase {

    // MARK: - Polish

    func testAFreshInstallPolishesWithTheStyleThatChangesTheLeast() {
        let settings = Settings()

        XCTAssertTrue(settings.styleRewrite.isEnabled)
        XCTAssertEqual(settings.styleRewrite.style.id, StyleRewriteCatalog.defaultStyleID)
        XCTAssertEqual(StyleRewriteCatalog.defaultStyleID, "polish")
        XCTAssertTrue(settings.styleRewrite.isRunnable)
    }

    /// The deterministic stage is a peer, not a child: it was on before this
    /// change and is on after it, and neither switch reaches the other.
    func testTheDeterministicStageIsStillOnAndStillIndependent() {
        XCTAssertTrue(Settings().safeCorrectionEnabled)

        AppPreferences.shared.styleRewriteEnabled = false

        XCTAssertTrue(Settings().safeCorrectionEnabled)
    }

    // MARK: - The capsule

    func testAFreshInstallShowsTheCapsule() {
        XCTAssertTrue(AppPreferences.shared.capsuleHUDEnabled)
        XCTAssertTrue(CapsuleHUDWindowController.isEnabled)
    }

    /// Still one overlay and not two. The capsule being the default changes
    /// which one a session gets, never how many.
    func testTheCapsuleReplacesTheCardRatherThanJoiningIt() {
        XCTAssertTrue(CapsuleHUDWindowController.isEnabled)

        AppPreferences.shared.capsuleHUDEnabled = false

        XCTAssertFalse(CapsuleHUDWindowController.isEnabled)
    }

    /// The engine-switch HUD moves down to clear the capsule, and now does so
    /// on a fresh install rather than only where the capsule was switched on.
    func testTheEngineSwitchHUDClearsTheCapsuleOnAFreshInstall() {
        XCTAssertGreaterThan(
            EngineSwitchHUD.topOffset(capsuleHUDEnabled: true),
            EngineSwitchHUD.topOffset(capsuleHUDEnabled: false)
        )
        XCTAssertEqual(
            EngineSwitchHUD.topOffset(capsuleHUDEnabled: CapsuleHUDWindowController.isEnabled),
            EngineSwitchHUD.topOffset(capsuleHUDEnabled: true)
        )
    }

    // MARK: - Neither default overwrites a stored answer

    /// The whole safety of turning two things on: an install that already
    /// answered keeps its answer, and neither default writes anything.
    func testAStoredAnswerWinsOverBothDefaults() {
        XCTAssertNil(storedPreference("styleRewriteEnabled"))
        XCTAssertNil(storedPreference("capsuleHUDEnabled"))

        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = false
        preferences.capsuleHUDEnabled = false

        XCTAssertEqual(storedPreference("styleRewriteEnabled") as? Bool, false)
        XCTAssertEqual(storedPreference("capsuleHUDEnabled") as? Bool, false)
        XCTAssertFalse(preferences.styleRewriteEnabled)
        XCTAssertFalse(preferences.capsuleHUDEnabled)
        XCTAssertFalse(Settings().styleRewrite.isEnabled)
        XCTAssertFalse(CapsuleHUDWindowController.isEnabled)
    }

    /// The settings the two changed defaults are neighbours of are unchanged.
    /// Each of these puts a second reading on a dictation or sends something
    /// somewhere, which is a different question from "polish it" and "show it".
    func testTheDefaultsAroundThemDidNotMove() {
        let preferences = AppPreferences.shared

        XCTAssertFalse(preferences.spokenIntentsEnabled)
        XCTAssertFalse(preferences.appAwareStyleEnabled)
        XCTAssertFalse(preferences.youTubeChannelModelMatchEnabled)
    }
}
