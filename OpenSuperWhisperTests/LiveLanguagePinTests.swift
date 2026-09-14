import XCTest

@testable import OpenSuperWhisper

/// The rules `LiveLanguagePin` holds a session's decode language to, stated
/// against decodes a test writes: the first confident detection pins, nothing
/// else does, an explicit language is never touched, and the pin reaches a
/// copy of the settings and never the original.
final class LiveLanguagePinTests: IsolatedPreferencesTestCase {

    private func settings(language: String) -> Settings {
        var settings = Settings()
        settings.selectedLanguage = language
        return settings
    }

    private func decode(_ language: DecodedLanguage?, text: String = "words") -> RawDecode {
        RawDecode(text: text, language: language)
    }

    // MARK: - Starting state

    func testAutoStartsDetectingAndUnpinned() {
        let pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertTrue(pin.isAutomatic)
        XCTAssertTrue(pin.isDetecting)
        XCTAssertFalse(pin.isPinned)
        XCTAssertNil(pin.pinnedLanguage)
        XCTAssertEqual(pin.decodeLanguage, "auto")
    }

    func testAnExplicitLanguageIsNeverDetecting() {
        let pin = LiveLanguagePin(selectedLanguage: "de")
        XCTAssertFalse(pin.isAutomatic)
        XCTAssertFalse(pin.isDetecting)
        XCTAssertFalse(pin.isPinned)
        XCTAssertEqual(pin.decodeLanguage, "de")
    }

    // MARK: - Pinning

    func testTheFirstConfidentDetectionPins() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertTrue(pin.observe(decode(.detected("zh", probability: 0.99))))
        XCTAssertTrue(pin.isPinned)
        XCTAssertFalse(pin.isDetecting)
        XCTAssertEqual(pin.pinnedLanguage, "zh")
        XCTAssertEqual(pin.decodeLanguage, "zh")
    }

    func testTheMinimumConfidenceIsInclusive() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertTrue(pin.observe(decode(.detected("en", probability: LiveLanguagePin.minimumConfidence))))
        XCTAssertEqual(pin.pinnedLanguage, "en")
    }

    func testTheMinimumConfidenceIsAMajority() {
        // The detector's answer is a softmax over every language, so this is
        // "more mass than every other language together" - the bar below
        // which a first utterance is a guess, not a language.
        XCTAssertEqual(LiveLanguagePin.minimumConfidence, 0.5)
    }

    func testAPinIsKeptOverLaterDetections() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertTrue(pin.observe(decode(.detected("zh", probability: 0.9))))
        XCTAssertFalse(pin.observe(decode(.detected("en", probability: 1.0))))
        XCTAssertEqual(pin.pinnedLanguage, "zh", "the first confident utterance decides the session")
    }

    // MARK: - Refusals

    func testALowConfidenceDetectionDoesNotPin() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertFalse(pin.observe(decode(.detected("zh", probability: LiveLanguagePin.minimumConfidence - 0.001))))
        XCTAssertNil(pin.pinnedLanguage)
        XCTAssertTrue(pin.isDetecting, "the next utterance is detected again")
    }

    func testAGivenLanguageDoesNotPin() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertFalse(pin.observe(decode(.given("zh"))))
        XCTAssertNil(pin.pinnedLanguage)
    }

    func testNoLanguageDoesNotPin() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertFalse(pin.observe(decode(nil)))
        XCTAssertNil(pin.pinnedLanguage)
    }

    func testAnInvalidCodeDoesNotPin() {
        for code in ["", "auto", " zh", "zh\n"] {
            var pin = LiveLanguagePin(selectedLanguage: "auto")
            XCTAssertFalse(pin.observe(decode(.detected(code, probability: 1))), "\(code.debugDescription)")
            XCTAssertNil(pin.pinnedLanguage, "\(code.debugDescription)")
        }
    }

    func testAProbabilityOutsideTheUnitIntervalDoesNotPin() {
        for probability in [Float(-0.1), 1.01, .nan, .infinity] {
            var pin = LiveLanguagePin(selectedLanguage: "auto")
            XCTAssertFalse(pin.observe(decode(.detected("zh", probability: probability))), "\(probability)")
            XCTAssertNil(pin.pinnedLanguage, "\(probability)")
        }
    }

    func testADetectionOverNoWordsDoesNotPin() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertFalse(pin.observe(decode(.detected("zh", probability: 1), text: "")))
        XCTAssertFalse(pin.observe(decode(.detected("zh", probability: 1), text: " \n")))
        XCTAssertNil(pin.pinnedLanguage)
    }

    func testAnExplicitLanguageIsNeverPinnedOver() {
        var pin = LiveLanguagePin(selectedLanguage: "en")
        XCTAssertFalse(pin.observe(decode(.detected("zh", probability: 1))))
        XCTAssertNil(pin.pinnedLanguage)
        XCTAssertEqual(pin.decodeLanguage, "en")
    }

    // MARK: - Settings

    func testThePinReachesACopyOfTheSettingsAndNotTheOriginal() {
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        let original = settings(language: "auto")

        XCTAssertEqual(pin.applied(to: original).selectedLanguage, "auto", "unpinned, the settings are returned as they are")

        XCTAssertTrue(pin.observe(decode(.detected("zh", probability: 1))))
        let decodeSettings = pin.applied(to: original)
        XCTAssertEqual(decodeSettings.selectedLanguage, "zh")
        XCTAssertEqual(original.selectedLanguage, "auto")
        XCTAssertEqual(decodeSettings.initialPrompt, original.initialPrompt, "nothing but the language changes")
        XCTAssertEqual(decodeSettings.personalTerms, original.personalTerms)
    }

    func testThePinNeverWritesThePreference() {
        AppPreferences.shared.whisperLanguage = "auto"
        var pin = LiveLanguagePin(selectedLanguage: "auto")
        XCTAssertTrue(pin.observe(decode(.detected("zh", probability: 1))))
        _ = pin.applied(to: settings(language: "auto"))
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, "auto")
    }
}
