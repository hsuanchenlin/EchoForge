import Foundation
import FluidAudio

/// How far along preparing a set of model weights is, in the only two forms the
/// app can show without lying.
///
/// The split is the whole point. Fetching bytes has a fraction worth showing;
/// the Neural Engine compile that follows has none - it takes 65-88 s, publishes
/// no progress, and a bar left sitting at its last value reads as a hang. So one
/// case carries a number and the other deliberately carries nothing, and every
/// surface renders them differently (determinate bar with a percentage, or an
/// indeterminate bar with `preparingMessage`).
enum ModelPreparationStage: Equatable {
    /// Bytes are moving and `fraction` is the share of the *download* that has
    /// arrived, in 0...1. Not the share of the whole preparation - see
    /// `downloadShareOfOverallProgress`.
    case downloading(fraction: Double)

    /// A phase with no fraction worth showing: listing the repository, or the
    /// one-time CoreML compile for the Neural Engine.
    case preparing

    /// What an indeterminate phase says. One string, so the indicator, Settings
    /// and onboarding cannot drift into three different words for it.
    static let preparingMessage = "Preparing model…"

    /// The percentage to render, or `nil` when there is no trustworthy one.
    var percentage: Int? {
        guard case .downloading(let fraction) = self else { return nil }
        return Int((fraction * 100).rounded())
    }

    var isDeterminate: Bool { percentage != nil }
}

/// The share of FluidAudio's overall `fractionCompleted` that the byte download
/// occupies, which is what makes the raw fraction unusable as-is.
///
/// `DownloadUtils.downloadRepo` scales every byte-progress report by 0.5 and
/// `DownloadUtils.loadModels` spends 0.5...1.0 on the compile, so a download that
/// has finished reports 0.5 and a bar wired straight to it stops half way. The
/// constant is measured against the pinned FluidAudio rather than read off a
/// config value, the same rule the engines follow; `docs/upstream-issues.md`
/// records why it is here at all.
let downloadShareOfOverallProgress = 0.5

extension ModelPreparationStage {
    /// Maps one FluidAudio progress report onto what the app can honestly show.
    ///
    /// `.listing` is deliberately indeterminate: it reports a fraction of 0.0
    /// regardless of how much of the repository index has been read, so showing
    /// "0 %" would be a number that means nothing.
    static func from(_ progress: DownloadUtils.DownloadProgress) -> ModelPreparationStage {
        switch progress.phase {
        case .downloading:
            let share = progress.fractionCompleted / downloadShareOfOverallProgress
            return .downloading(fraction: min(max(share, 0), 1))
        case .listing, .compiling:
            return .preparing
        }
    }
}

/// One model's preparation, as a value the UI can render and a test can assert.
///
/// It names the engine because preparation is no longer something that happens
/// only in front of the user: a model can be preparing in the background while
/// dictation runs on a different, already-ready one, and "which model is this
/// bar about" is then part of the answer rather than obvious from context.
struct ModelPreparation: Equatable {
    let engine: EngineKind
    let stage: ModelPreparationStage

    /// The model name the licence requires the UI to keep, falling back to the
    /// engine's display name for engines whose weights are picked model by model.
    var modelName: String {
        let entry = EngineCatalog.entry(for: engine)
        return entry.download?.modelName ?? entry.displayName
    }

    /// One line for a status row: what is happening, and how far along when that
    /// can be said.
    var statusLine: String {
        switch stage {
        case .downloading(let fraction):
            return "Downloading \(modelName) - \(Int((fraction * 100).rounded()))%"
        case .preparing:
            return "\(ModelPreparationStage.preparingMessage) (\(modelName))"
        }
    }
}
