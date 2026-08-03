import XCTest
import FluidAudio

@testable import OpenSuperWhisper

/// What the app is allowed to show while a model is being prepared.
///
/// The one rule under all of it: a number is only ever shown when there is a
/// number worth showing. FluidAudio reports a fraction throughout, but for two
/// of its three phases that fraction means nothing a user would recognise, and a
/// bar that keeps moving during a phase it cannot measure is worse than one that
/// admits it is waiting.
final class ModelPreparationTests: XCTestCase {

    private func progress(_ fraction: Double, _ phase: DownloadUtils.DownloadPhase)
        -> DownloadUtils.DownloadProgress {
        DownloadUtils.DownloadProgress(fractionCompleted: fraction, phase: phase)
    }

    // MARK: - Byte phases carry a percentage

    /// FluidAudio scales byte progress into 0...0.5 of its overall fraction, so a
    /// finished download reports 0.5. Wiring a bar straight to that stops it half
    /// way through every download; this rescales to the download's own span.
    /// See `docs/upstream-issues.md`.
    func testDownloadFractionIsRescaledToTheDownloadsOwnSpan() {
        XCTAssertEqual(
            ModelPreparationStage.from(progress(0.0, .downloading(completedFiles: 0, totalFiles: 4))),
            .downloading(fraction: 0)
        )
        XCTAssertEqual(
            ModelPreparationStage.from(progress(0.25, .downloading(completedFiles: 2, totalFiles: 4))),
            .downloading(fraction: 0.5)
        )
        XCTAssertEqual(
            ModelPreparationStage.from(progress(0.5, .downloading(completedFiles: 4, totalFiles: 4))),
            .downloading(fraction: 1.0)
        )
    }

    /// A producer that reports the full range rather than the documented half is
    /// clamped rather than allowed to render as 160 %.
    func testAnOutOfRangeFractionIsClamped() {
        XCTAssertEqual(
            ModelPreparationStage.from(progress(0.8, .downloading(completedFiles: 1, totalFiles: 1))),
            .downloading(fraction: 1.0)
        )
        XCTAssertEqual(
            ModelPreparationStage.from(progress(-1, .downloading(completedFiles: 0, totalFiles: 1))),
            .downloading(fraction: 0)
        )
    }

    func testPercentageIsRoundedForDisplay() {
        XCTAssertEqual(ModelPreparationStage.downloading(fraction: 0.0).percentage, 0)
        XCTAssertEqual(ModelPreparationStage.downloading(fraction: 0.334).percentage, 33)
        XCTAssertEqual(ModelPreparationStage.downloading(fraction: 1.0).percentage, 100)
    }

    // MARK: - Everything else is indeterminate

    /// The Neural Engine compile takes 65-88 s the first time and publishes no
    /// progress at all. It is the phase this distinction exists for.
    func testTheNeuralEngineCompileIsIndeterminate() {
        let stage = ModelPreparationStage.from(progress(0.5, .compiling(modelName: "SenseVoiceSmall_int8")))

        XCTAssertEqual(stage, .preparing)
        XCTAssertNil(stage.percentage)
        XCTAssertFalse(stage.isDeterminate)
    }

    /// Listing reports 0.0 however much of the repository index has been read, so
    /// "0 %" would be a number that means nothing.
    func testListingIsIndeterminateRatherThanZeroPercent() {
        XCTAssertEqual(ModelPreparationStage.from(progress(0.0, .listing)), .preparing)
    }

    // MARK: - What it says

    func testAnIndeterminatePhaseSaysItIsPreparing() {
        let preparation = ModelPreparation(engine: .sensevoice, stage: .preparing)

        XCTAssertTrue(preparation.statusLine.contains(ModelPreparationStage.preparingMessage))
    }

    /// The model name the licence requires the UI to keep survives into the
    /// progress copy, not just the picker row.
    func testTheStatusLineNamesTheModelBeingFetched() {
        XCTAssertTrue(ModelPreparation(engine: .sensevoice, stage: .preparing).modelName.contains("SenseVoice"))
        XCTAssertTrue(ModelPreparation(engine: .paraformer, stage: .preparing).modelName.contains("Paraformer"))
    }

    /// Engines with no single download still have something to call themselves,
    /// rather than rendering an empty string.
    func testEnginesWithoutASingleDownloadStillHaveAName() {
        for engine: EngineKind in [.whisper, .fluidaudio] {
            XCTAssertFalse(ModelPreparation(engine: engine, stage: .preparing).modelName.isEmpty)
        }
    }

    func testADownloadingStatusLineCarriesThePercentage() {
        let line = ModelPreparation(engine: .sensevoice, stage: .downloading(fraction: 0.42)).statusLine

        XCTAssertTrue(line.contains("42%"), line)
    }
}
