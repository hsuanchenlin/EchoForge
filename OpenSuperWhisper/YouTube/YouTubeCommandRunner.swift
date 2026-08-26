import Foundation

/// Carries out one press of the YouTube command key, from the resolution the
/// pipeline produced to the sentence the user is told - including the recovery
/// the picker adds in the middle.
///
/// It exists because that middle step made the command a **conversation** rather
/// than a function: a miss can now be answered by the user, so the path has more
/// than one durable state and history has to be told about each of them as it
/// happens. Keeping that in `IndicatorWindow` would put it where nothing can
/// drive it without a window server, a focus change and a real browser.
///
/// Every step is behind a seam: `YouTubeLatestVideoService` already takes its
/// feed and its browser through one, this takes the user's choice through
/// `YouTubeChannelChoosing`, and history through `record`. So the whole thing -
/// miss, picker, choice, open, and each way it can be refused - is a
/// deterministic test.
///
/// See `docs/youtube-latest-video.md`.
struct YouTubeCommandRunner: Sendable {
    private let service: YouTubeLatestVideoService
    private let chooser: YouTubeChannelChoosing

    init(service: YouTubeLatestVideoService, chooser: YouTubeChannelChoosing) {
        self.service = service
        self.chooser = chooser
    }

    /// What became of one press, and everything it wrote down on the way.
    struct Outcome: Sendable {
        let report: YouTubeLatestVideoReport
        /// How the channel was reached, or nil when nothing was opened. Carried
        /// so a caller can tell an ordinary success from one the user had to
        /// pick out of a list.
        let match: YouTubeChannelMatchSource?
        /// Whether the picker was put on screen at all.
        let showedPicker: Bool
    }

    /// Runs the command, offering the picker when every automatic tier missed.
    ///
    /// - Parameters:
    ///   - command: the pipeline's answer, including what the optional on-device
    ///     chooser did about it.
    ///   - isPickerEnabled: the user's preference. Off restores exactly the
    ///     behaviour that shipped before the picker existed.
    ///   - willShowPicker: called immediately before the picker is presented, so
    ///     the dictation overlay can stop showing a spinner for work that has
    ///     finished. Never called when no picker is offered.
    ///   - record: writes one provenance onto the row the words were stored in.
    ///     Called more than once on purpose - the picker's own state is written
    ///     while it is up, so a quit with it on screen leaves the truth behind.
    @MainActor
    func run(
        _ command: YouTubeCommandResolution,
        isPickerEnabled: Bool,
        willShowPicker: @MainActor (YouTubeChannelPickerRequest) -> Void = { _ in },
        record: @MainActor (RecordingProvenance) async -> Void
    ) async -> Outcome {
        let offer = YouTubeChannelPickerOffer.make(
            for: command.resolution,
            candidates: command.candidates,
            isEnabled: isPickerEnabled
        )

        switch offer {
        case .none(.noChannelsConfigured):
            let report = YouTubeLatestVideoReport.noChannelsConfigured(
                spoken: command.spokenName.trimmingCharacters(in: .whitespacesAndNewlines))
            await record(.command(report, modelMatch: command.modelMatch))
            return Outcome(report: report, match: nil, showedPicker: false)

        case .none:
            // Resolved, switched off, or nothing heard: exactly the path this
            // command took before the picker existed, message for message.
            let report = await service.run(command.resolution)
            await record(.command(report, modelMatch: command.modelMatch))
            return Outcome(report: report, match: source(of: report), showedPicker: false)

        case .picker(let request):
            await record(.pickerShown(request))
            willShowPicker(request)
            guard let chosen = await chooser.chooseChannel(request) else {
                let report = YouTubeLatestVideoReport.pickerCancelled(
                    spoken: request.spokenName, cause: request.cause)
                await record(.command(report, modelMatch: command.modelMatch))
                return Outcome(report: report, match: nil, showedPicker: true)
            }
            // The chosen row is one of the ones offered, and the ones offered
            // are the reachable rows of the allowlist the command resolved
            // against. Re-checked here rather than trusted, so a chooser that
            // answered with anything else opens nothing - the allowlist stays
            // the boundary even when a person is the one pointing at it.
            guard request.suggestions.contains(where: { $0.channel == chosen }) else {
                let report = YouTubeLatestVideoReport.refused(
                    reason: .channelUnknown,
                    message: "That choice is not one of your allowlisted channels, so nothing was opened.",
                    shortMessage: YouTubeCommandRefusal.channelUnknown.shortLabel
                )
                await record(.command(report, modelMatch: command.modelMatch))
                return Outcome(report: report, match: nil, showedPicker: true)
            }

            let report = await service.run(
                .allowlisted(chosen, matchedBy: .picker(spoken: request.spokenName)))
            await record(.command(report, modelMatch: command.modelMatch))
            return Outcome(report: report, match: source(of: report), showedPicker: true)
        }
    }

    private func source(of report: YouTubeLatestVideoReport) -> YouTubeChannelMatchSource? {
        guard case .opened(_, _, let match) = report else { return nil }
        return match
    }
}
