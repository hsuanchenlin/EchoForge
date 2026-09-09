import XCTest

@testable import OpenSuperWhisper

/// A row's Cancel button must stop only the transfer that row is showing.
///
/// Two rows can be preparing at once - the desired engine's background
/// preparation plus a Settings-driven download of a different engine - and
/// before the targeting was decided per engine, a Cancel on either row stopped
/// both: `ModelInventoryView.cancel` called `settings.cancelDownload()`
/// unconditionally, killing a download the user never pointed at (and a
/// cancelled pack does not fall back, so that engine was left incomplete).
final class ModelInventoryCancelTests: XCTestCase {

    func testRowOwningTheServicePreparationCancelsOnlyIt() {
        let targets = ModelInventoryCancel.targets(
            for: .sensevoice,
            servicePreparation: .sensevoice,
            settingsDownload: .paraformer)

        XCTAssertTrue(targets.servicePreparation)
        XCTAssertFalse(targets.settingsDownload)
    }

    func testRowOwningTheSettingsDownloadCancelsOnlyIt() {
        let targets = ModelInventoryCancel.targets(
            for: .paraformer,
            servicePreparation: .sensevoice,
            settingsDownload: .paraformer)

        XCTAssertFalse(targets.servicePreparation)
        XCTAssertTrue(targets.settingsDownload)
    }

    func testRowOwningNeitherTransferCancelsNothing() {
        let targets = ModelInventoryCancel.targets(
            for: .whisper,
            servicePreparation: .sensevoice,
            settingsDownload: .paraformer)

        XCTAssertFalse(targets.servicePreparation)
        XCTAssertFalse(targets.settingsDownload)
    }

    func testIdleSurfacesCancelNothing() {
        let targets = ModelInventoryCancel.targets(
            for: .sensevoice,
            servicePreparation: nil,
            settingsDownload: nil)

        XCTAssertFalse(targets.servicePreparation)
        XCTAssertFalse(targets.settingsDownload)
    }
}
