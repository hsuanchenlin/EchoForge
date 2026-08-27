import Foundation

/// Everything the channel picker is shown with: what was heard, and the user's
/// own channels ordered so the likely one is first.
///
/// A value rather than a view model so the **decision** to offer a picker is
/// pure and testable, and so the list a picker can contain is fixed before any
/// window exists. `channels` is built from the allowlist snapshot the command
/// resolved against, which is what makes "the picker can only contain configured
/// channels" a property of the type rather than of the view.
struct YouTubeChannelPickerRequest: Equatable, Sendable {
    /// The phrase the command heard, as the user said it. Shown to them,
    /// because "which of these did you mean" is only answerable next to what the
    /// app thought it heard.
    let spokenName: String
    /// Why the deterministic tiers could not place it, which is what decides the
    /// sentence above the list.
    let cause: Cause
    /// The user's reachable channels, ranked. Never empty: an empty list is a
    /// refusal, not a picker.
    let suggestions: [YouTubeChannelSuggestion]

    enum Cause: Equatable, Sendable {
        /// No stored spelling answers to the phrase - the near miss this picker
        /// exists for.
        case unknown
        /// More than one does, and the user's list is the only thing that can
        /// say which. The names are carried so the sentence can name them.
        case ambiguous(matches: [String])
    }

    /// The row the picker starts on: the best-scoring one.
    ///
    /// Always a real row rather than "nothing selected", because Return has to
    /// mean something the moment the panel opens - a keyboard-first picker whose
    /// first keystroke has to be an arrow key is a picker that costs a press for
    /// nothing. It is still a selection the user makes: nothing opens until they
    /// press it.
    var initialHighlight: Int { 0 }

    /// The sentence above the list.
    var prompt: String {
        switch cause {
        case .unknown:
            return "No channel is stored under that spelling. Choose the one you meant, or press Escape to open nothing."
        case .ambiguous(let matches):
            // The names are channels being pointed at, so they are written the
            // way the rows below are; the phrase that was heard, above, is not.
            let named = YouTubeChannelHandle.format(all: matches).joined(separator: ", ")
            return "More than one of your channels answers to that (\(named)). Choose the one you meant, or press Escape to open nothing."
        }
    }
}

/// Whether a resolution that opened nothing should put a picker on screen, and
/// what happens if it should not.
///
/// The whole decision, in one pure function, for the same reason
/// `YouTubeLatestVideoReport.refusal(for:)` is one: the runner and history must
/// not be able to disagree about whether a press was offered a recovery.
enum YouTubeChannelPickerOffer: Equatable, Sendable {
    /// Put this picker up and wait for the user.
    case picker(YouTubeChannelPickerRequest)
    /// Do not. The resolution keeps whatever answer it already had - which for
    /// an allowlisted channel is "open it", and for everything else is the
    /// refusal it was always going to be.
    case none(NotOffered)

    /// Why no picker was offered. Recorded in History, because "nothing
    /// happened" reads identically whichever of these it was - the same reason
    /// `YouTubeChannelModelMatchAttempt` exists.
    enum NotOffered: Equatable, Sendable {
        /// The channel resolved. Nothing to choose between.
        case resolved
        /// The feature, or the picker itself, is switched off.
        case switchedOff
        /// There was no phrase to be near a miss of: silence, or a marker with
        /// nothing behind it. A picker that appeared and took focus after a
        /// stray press of the key would be the app interrupting somebody who
        /// asked for nothing.
        case nothingHeard
        /// The phrase missed, and there is no channel to offer instead. The
        /// answer is the existing refusal, which already says where to add one.
        case noChannelsConfigured
    }
}

extension YouTubeChannelPickerOffer {

    /// What to do about a resolution once every automatic tier has had its turn.
    ///
    /// Reached only from the dedicated command route: its only input is a
    /// `YouTubeChannelResolution`, which nothing but a `.youTubeCommand` session
    /// can produce (see `DictationPurpose` and `Settings.youTubeChannels`). No
    /// dictation, dropped file, queued recording or Ask follow-up has a value of
    /// this type to hand it, so none of them can raise this picker however they
    /// are worded.
    ///
    /// - Parameters:
    ///   - resolution: what the allowlist, and then the optional on-device
    ///     chooser, made of the words.
    ///   - candidates: the channels that command could have reached - the
    ///     snapshot it resolved against, so the picker cannot offer a row the
    ///     lookup would not have accepted.
    ///   - isEnabled: the user's picker preference.
    static func make(
        for resolution: YouTubeChannelResolution,
        candidates: [YouTubeChannel],
        isEnabled: Bool
    ) -> YouTubeChannelPickerOffer {
        let cause: YouTubeChannelPickerRequest.Cause
        switch resolution {
        case .allowlisted:
            return .none(.resolved)
        case .disabled:
            return .none(.switchedOff)
        case .unknown(let spoken):
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .none(.nothingHeard)
            }
            cause = .unknown
        case .ambiguous(_, let matches):
            cause = .ambiguous(matches: matches)
        }

        guard isEnabled else { return .none(.switchedOff) }

        // Only rows a command could actually have opened. A half-finished or
        // disabled row is kept in Settings and shown there, but offering one
        // here would be offering a choice that fails the moment it is made.
        let reachable = candidates.filter { $0.isEnabled && $0.isValid }
        guard !reachable.isEmpty else { return .none(.noChannelsConfigured) }

        let spoken = resolution.spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .picker(
            YouTubeChannelPickerRequest(
                spokenName: spoken,
                cause: cause,
                suggestions: YouTubeChannelSuggestions.rank(spoken, among: reachable)
            )
        )
    }
}

/// How the runner asks the user which channel they meant.
///
/// A protocol so the whole command path can be driven in a test with no window
/// server, no focus and nothing opened - the same seam
/// `YouTubeLatestVideoService` takes its fetcher and its browser through.
protocol YouTubeChannelChoosing: Sendable {
    /// Puts the picker up and waits. Returns the channel the user chose, or nil
    /// if they cancelled - which opens nothing.
    @MainActor
    func chooseChannel(_ request: YouTubeChannelPickerRequest) async -> YouTubeChannel?
}
