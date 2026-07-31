import AppKit
import XCTest
@testable import OpenSuperWhisper

final class DiskSpaceUtilTests: XCTestCase {

    func testHasEnoughFreeSpace_aboveThreshold_returnsTrue() {
        XCTAssertTrue(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 10_000_000_001))
    }

    func testHasEnoughFreeSpace_exactlyThreshold_returnsTrue() {
        XCTAssertTrue(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 10_000_000_000))
    }

    func testHasEnoughFreeSpace_belowThreshold_returnsFalse() {
        XCTAssertFalse(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 9_999_999_999))
        XCTAssertFalse(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 0))
    }

    func testDiskSpaceError_hasUserFacingMessage() {
        let message = DiskSpaceError().errorDescription
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("10 GB"))
    }
}

final class RecordingRetentionTests: XCTestCase {

    func testRetentionCutoffDate_subtractsDays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = try XCTUnwrap(RecordingStore.retentionCutoffDate(daysToKeep: 30, now: now))

        let expected = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(cutoff, expected)
        XCTAssertLessThan(cutoff, now)
    }

    func testRetentionCutoffDate_separatesOldAndFreshRecordings() throws {
        let now = Date()
        let cutoff = try XCTUnwrap(RecordingStore.retentionCutoffDate(daysToKeep: 7, now: now))

        let oldTimestamp = now.addingTimeInterval(-8 * 24 * 3600)
        let freshTimestamp = now.addingTimeInterval(-6 * 24 * 3600)

        XCTAssertTrue(oldTimestamp < cutoff)
        XCTAssertFalse(freshTimestamp < cutoff)
    }

    func testRetentionCutoffDate_nonPositiveDays_returnsNil() {
        XCTAssertNil(RecordingStore.retentionCutoffDate(daysToKeep: 0))
        XCTAssertNil(RecordingStore.retentionCutoffDate(daysToKeep: -5))
    }

    func testIsDeletableRecordingURL_insideRecordingsDirectory_returnsTrue() {
        let url = Recording.recordingsDirectory.appendingPathComponent("recording.wav")
        XCTAssertTrue(RecordingStore.isDeletableRecordingURL(url))
    }

    func testIsDeletableRecordingURL_outsideRecordingsDirectory_returnsFalse() {
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(URL(fileURLWithPath: "/tmp/recording.wav")))
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(Recording.recordingsDirectory))

        let escaping = Recording.recordingsDirectory.appendingPathComponent("../../Documents/important.wav")
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(escaping))
    }
}

final class LanguageSupportTests: XCTestCase {

    func testSupportedLanguages_whisper_returnsFullListWithAuto() {
        let languages = LanguageUtil.supportedLanguages(engine: .whisper, fluidAudioModelVersion: "v3")
        XCTAssertEqual(languages, LanguageUtil.availableLanguages)
        XCTAssertTrue(languages.contains("auto"))
        XCTAssertTrue(languages.contains("zh"))
    }

    func testSupportedLanguages_parakeetV2_isEnglishOnly() {
        let languages = LanguageUtil.supportedLanguages(engine: .fluidaudio, fluidAudioModelVersion: "v2")
        XCTAssertEqual(languages, ["en"])
    }

    func testSupportedLanguages_parakeetV3_excludesUnsupportedLanguages() {
        let languages = LanguageUtil.supportedLanguages(engine: .fluidaudio, fluidAudioModelVersion: "v3")

        for unsupported in ["auto", "zh", "ja", "ko", "ar", "tr", "he", "hi", "id", "ca"] {
            XCTAssertFalse(languages.contains(unsupported), "\(unsupported) must not be offered for Parakeet v3")
        }
        for supported in ["en", "de", "ru", "uk", "pl", "mt"] {
            XCTAssertTrue(languages.contains(supported), "\(supported) must be offered for Parakeet v3")
        }
        XCTAssertEqual(languages.count, 25)
    }

    /// F5. Paraformer-large is Mandarin-only and degrades silently rather than
    /// failing, so the lock is the only thing standing between an English
    /// recording and output full of raw `@@` BPE markers.
    func testSupportedLanguages_paraformer_isMandarinOnly() {
        for version in ["v2", "v3"] {
            XCTAssertEqual(
                LanguageUtil.supportedLanguages(engine: .paraformer, fluidAudioModelVersion: version),
                ["zh"],
                "Paraformer's language scope must not depend on the Parakeet model version"
            )
        }
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .paraformer), "zh")
    }

    /// Selecting Paraformer has to snap the language, and `Settings` has to see
    /// a Mandarin language so Asian autocorrect stays available for it.
    func testParaformerFallbackLanguage_isAnAsianLanguage() {
        XCTAssertTrue(Settings.asianLanguages.contains(LanguageUtil.fallbackLanguage(engine: .paraformer)))
    }

    /// F5. SenseVoice's scope is exactly the six languages its encoder has an
    /// embedding for. Anything wider is a language the app would ask for with an
    /// index FluidAudio neither validates nor rejects.
    func testSupportedLanguages_senseVoice_isTheSixEmbeddedLanguages() {
        for version in ["v2", "v3"] {
            XCTAssertEqual(
                LanguageUtil.supportedLanguages(engine: .sensevoice, fluidAudioModelVersion: version),
                ["auto", "zh", "yue", "en", "ja", "ko"],
                "SenseVoice's language scope must not depend on the Parakeet model version"
            )
        }
    }

    /// F5. The embed indices are FunASR's, not ours to renumber - a wrong one
    /// does not throw, it quietly mis-conditions the model.
    func testSenseVoiceLanguages_mapToTheVerifiedEmbedIndices() {
        XCTAssertEqual(SenseVoiceLanguage.allCases.map(\.embedIndex), [0, 3, 7, 4, 11, 12])
        XCTAssertEqual(SenseVoiceLanguage(languageCode: "zh"), .zh)
        XCTAssertEqual(
            SenseVoiceLanguage(languageCode: "de"), .auto,
            "a language with no embedding must fall back to auto-detect, never to an invented index"
        )
    }

    /// Selecting SenseVoice snaps the language to Mandarin, which also has to
    /// keep `Settings` on the CJK autocorrect path.
    func testSenseVoiceFallbackLanguage_isAnAsianLanguage() {
        XCTAssertTrue(Settings.asianLanguages.contains(LanguageUtil.fallbackLanguage(engine: .sensevoice)))
    }

    func testAllParakeetV3LanguagesHaveDisplayNames() {
        for code in LanguageUtil.parakeetV3Languages {
            XCTAssertNotNil(LanguageUtil.languageNames[code], "Missing display name for \(code)")
        }
    }

    /// The language picker shows all six when SenseVoice is selected - including
    /// Cantonese, which no other engine offers.
    func testAllSenseVoiceLanguagesHaveDisplayNames() {
        for code in LanguageUtil.senseVoiceLanguages {
            XCTAssertNotNil(LanguageUtil.languageNames[code], "Missing display name for \(code)")
        }
        XCTAssertEqual(LanguageUtil.languageNames["yue"], "Cantonese")
    }

    func testFallbackLanguage() {
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .fluidaudio), "en")
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: .whisper), "auto")
    }
}

final class CountLabelTests: XCTestCase {

    func testCountLabel_singularAndPlural() {
        XCTAssertEqual(countLabel(1, singular: "day", plural: "days"), "1 day")
        XCTAssertEqual(countLabel(7, singular: "day", plural: "days"), "7 days")
        XCTAssertEqual(countLabel(1, singular: "recording", plural: "recordings"), "1 recording")
        XCTAssertEqual(countLabel(0, singular: "recording", plural: "recordings"), "0 recordings")
    }
}

@MainActor
final class IndicatorPanelFullScreenTests: XCTestCase {

    func testIndicatorPanel_isVisibleOverFullScreenApps() throws {
        let manager = IndicatorWindowManager.shared
        manager.warmUp()

        let window = try XCTUnwrap(manager.window)

        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary),
                      "Panel must join full-screen spaces as an auxiliary window")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces),
                      "Panel must follow the user across all spaces")
        XCTAssertGreaterThanOrEqual(window.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }
}

final class ClipboardRestoreTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-clipboard-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func setString(_ string: String) -> Int {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    func testRestoreIfUnchanged_pasteboardUntouched_restoresOriginal() throws {
        _ = setString("original")
        let saved = try XCTUnwrap(ClipboardUtil.saveCurrentPasteboardContents(from: pasteboard))

        let changeCount = setString("transcription")

        let restored = ClipboardUtil.restoreIfUnchanged(saved, expectedChangeCount: changeCount, pasteboard: pasteboard)

        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreIfUnchanged_pasteboardChangedMeanwhile_keepsNewContents() throws {
        _ = setString("original")
        let saved = try XCTUnwrap(ClipboardUtil.saveCurrentPasteboardContents(from: pasteboard))

        let changeCount = setString("transcription")
        _ = setString("copied by user during the delay")

        let restored = ClipboardUtil.restoreIfUnchanged(saved, expectedChangeCount: changeCount, pasteboard: pasteboard)

        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied by user during the delay")
    }

    func testRestoreDelay_coversSlowPasteConsumers() {
        XCTAssertGreaterThanOrEqual(ClipboardUtil.clipboardRestoreDelay, 1.0,
                                    "Browsers and Electron apps can service Cmd+V hundreds of ms after posting")
    }
}

@MainActor
final class MainWindowResolutionTests: XCTestCase {

    func testTitledWindow_isMainAppWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        XCTAssertTrue(AppDelegate.isMainAppWindow(window))
    }

    func testBorderlessPanel_isNotMainAppWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        XCTAssertFalse(AppDelegate.isMainAppWindow(panel))
    }

    func testBorderlessWindow_isNotMainAppWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        XCTAssertFalse(AppDelegate.isMainAppWindow(window))
    }
}

final class StartHiddenPreferenceTests: XCTestCase {

    private let key = "startHiddenInMenuBar"
    private var originalValue: Any?

    override func setUp() {
        super.setUp()
        originalValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let originalValue {
            UserDefaults.standard.set(originalValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testStartHiddenInMenuBar_defaultsToFalse() {
        XCTAssertFalse(AppPreferences.shared.startHiddenInMenuBar)
    }

    func testStartHiddenInMenuBar_persistsChanges() {
        AppPreferences.shared.startHiddenInMenuBar = true
        XCTAssertTrue(AppPreferences.shared.startHiddenInMenuBar)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        AppPreferences.shared.startHiddenInMenuBar = false
        XCTAssertFalse(AppPreferences.shared.startHiddenInMenuBar)
    }
}
