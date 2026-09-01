import XCTest
@testable import OpenSuperWhisper

/// Pins how the Style pane's three preferences reach the pipeline.
///
/// The rule worth a test is the independence: rewriting is a peer of the
/// deterministic terms stage, not its parent, so switching one off must leave
/// the other exactly as it was. A user who turns rewriting off is not asking
/// for their dictionary to stop working.
final class StyleRewritePreferencesTests: IsolatedPreferencesTestCase {

    /// A fresh install polishes. The stored value is still absent, which is the
    /// other half of the claim: this is a default rather than a write, so an
    /// install that turned rewriting off is not being turned back on.
    func testRewritingIsOnOnAFreshInstall() {
        XCTAssertTrue(AppPreferences.shared.styleRewriteEnabled)
        XCTAssertNil(storedPreference("styleRewriteEnabled"))
    }

    /// The default is the style that changes the user's words least. Anything
    /// louder is a choice for the user to make, not one to arrive switched on.
    func testAFreshInstallSelectsTheDefaultStyleAndNoCustomPrompt() {
        XCTAssertEqual(AppPreferences.shared.styleRewriteStyleID, StyleRewriteCatalog.defaultStyleID)
        XCTAssertEqual(StyleRewriteCatalog.defaultStyleID, "polish")
        XCTAssertEqual(AppPreferences.shared.styleRewriteCustomPrompt, "")
        XCTAssertTrue(Settings().styleRewrite.isRunnable)
    }

    /// Off is a real answer and survives a relaunch: the default only fills in
    /// for a key nobody has written.
    func testAStoredOffSurvivesTheOnByDefault() {
        AppPreferences.shared.styleRewriteEnabled = false

        XCTAssertEqual(storedPreference("styleRewriteEnabled") as? Bool, false)
        XCTAssertFalse(AppPreferences.shared.styleRewriteEnabled)
        XCTAssertFalse(Settings().styleRewrite.isEnabled)
    }

    /// On by default must not also mean on by default over the network. There
    /// is no cloud path out of rewriting to reach - `CloudPrivacyTests` pins
    /// that for every feature - and the default that is now on is the one that
    /// makes it worth restating here: a fresh install polishes, and it does so
    /// entirely on the Mac.
    func testRewritingOnByDefaultStaysOnDevice() {
        XCTAssertTrue(AppPreferences.shared.styleRewriteEnabled)
        XCTAssertNil(OnDeviceModelFeature.rewriting.cloudFeature)
        XCTAssertEqual(
            StyleRewriterFactory.availability(for: .rewriting), StyleRewriterFactory.availability()
        )
    }

    func testSettingsCarriesTheStoredConfigurationIntoThePipeline() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "bullets"
        preferences.styleRewriteCustomPrompt = "Rewrite this as a haiku."

        let settings = Settings()

        XCTAssertTrue(settings.styleRewrite.isEnabled)
        XCTAssertEqual(settings.styleRewrite.style.id, "bullets")
        XCTAssertEqual(settings.styleRewrite.customPrompt, "Rewrite this as a haiku.")
        // The preset is selected, so its instruction is the one that is sent -
        // the custom prompt is kept but unused.
        XCTAssertEqual(
            settings.styleRewrite.instruction(for: .other),
            StyleRewriteCatalog.style(id: "bullets")?.instructions.english
        )
    }

    func testAStoredStyleFromANewerBuildFallsBackRatherThanDisablingRewriting() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "a-style-this-build-has-never-heard-of"

        let settings = Settings()

        XCTAssertEqual(settings.styleRewrite.style.id, StyleRewriteCatalog.defaultStyleID)
        XCTAssertTrue(settings.styleRewrite.isRunnable)
    }

    func testTurningRewritingOffLeavesTheDictionaryStageOn() {
        let preferences = AppPreferences.shared
        preferences.safeCorrectionEnabled = true
        preferences.styleRewriteEnabled = true

        preferences.styleRewriteEnabled = false

        XCTAssertTrue(Settings().safeCorrectionEnabled)
    }

    func testTurningTheDictionaryStageOffLeavesRewritingOn() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.safeCorrectionEnabled = false

        XCTAssertTrue(Settings().styleRewrite.isEnabled)
    }

    /// Switching to another style and back must not cost the user what they
    /// wrote.
    func testTheCustomPromptSurvivesSelectingAnotherStyle() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteCustomPrompt = "Rewrite this as a haiku."
        preferences.styleRewriteStyleID = "formal"
        preferences.styleRewriteStyleID = StyleRewriteStyle.customID

        XCTAssertEqual(
            Settings().styleRewrite.instruction(for: .other), "Rewrite this as a haiku."
        )
    }
}
