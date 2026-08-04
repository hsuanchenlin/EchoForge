import XCTest
@testable import OpenSuperWhisper

/// Pins how the Style pane's three preferences reach the pipeline.
///
/// The rule worth a test is the independence: rewriting is a peer of the
/// deterministic terms stage, not its parent, so switching one off must leave
/// the other exactly as it was. A user who turns rewriting off is not asking
/// for their dictionary to stop working.
final class StyleRewritePreferencesTests: IsolatedPreferencesTestCase {

    func testRewritingIsOffOnAFreshInstall() {
        XCTAssertFalse(AppPreferences.shared.styleRewriteEnabled)
        XCTAssertNil(storedPreference("styleRewriteEnabled"))
    }

    func testAFreshInstallSelectsTheDefaultStyleAndNoCustomPrompt() {
        XCTAssertEqual(AppPreferences.shared.styleRewriteStyleID, StyleRewriteCatalog.defaultStyleID)
        XCTAssertEqual(AppPreferences.shared.styleRewriteCustomPrompt, "")
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
            settings.styleRewrite.instruction, StyleRewriteCatalog.style(id: "bullets")?.instruction
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

        XCTAssertEqual(Settings().styleRewrite.instruction, "Rewrite this as a haiku.")
    }
}
