import Foundation

/// What part the optional on-device channel chooser played in one command.
///
/// The chooser fails closed - every way it can go wrong leaves the deterministic
/// resolution exactly as it was (`YouTubeChannelModelMatch`) - which is correct
/// and, on its own, invisible: "no allowlisted channel answers to that" reads
/// identically whether the fallback was off, could not run, or ran and chose
/// nothing. That is one of the questions the user cannot answer about their own
/// failed command, so the answer is recorded beside the refusal.
///
/// It is a report, never an input: nothing downstream branches on it, and no
/// value of it can turn a refusal into an opened video.
enum YouTubeChannelModelMatchAttempt: String, Equatable, Sendable, CaseIterable {
    /// The deterministic tiers answered, so there was nothing to fall back to.
    /// Also the answer for a switched-off command, which is not a name that
    /// could not be placed.
    case notNeeded
    /// The user has the fallback switched off. Its default.
    case off
    /// It was on and could not be asked: no on-device model on this Mac, Apple
    /// Intelligence off, the model still downloading, a list longer than
    /// `maximumCandidates`, an utterance longer than `maximumSpokenCharacters`,
    /// or no reachable channel to choose between.
    case unavailable
    /// It was asked and its answer was not usable: a timeout, an error, `NONE`,
    /// an invented name, or an answer two stored rows answer to.
    case rejected
    /// It chose a row that was already in the user's list.
    case matched

    /// The sentence recorded beside the outcome, or nil when there is nothing
    /// to disclose.
    ///
    /// `.notNeeded` says nothing because nothing happened; `.matched` is
    /// disclosed by `YouTubeChannelMatchSource.disclosure` on the match itself,
    /// which can also name the phrase it was given.
    var disclosure: String? {
        switch self {
        case .notNeeded, .matched:
            return nil
        case .off:
            return "The on-device channel matcher is switched off, so only your stored spellings were tried."
        case .unavailable:
            return "The on-device channel matcher could not run on this Mac, so only your stored spellings were tried."
        case .rejected:
            return "The on-device channel matcher was asked and did not recognise that name either."
        }
    }
}

/// A command capture, resolved: which channel the words named, and what part the
/// optional on-device chooser played in deciding that.
///
/// The two travel together because they are one answer. The resolution alone is
/// what the command runs on - nothing branches on the attempt - and carrying it
/// beside rather than inside `YouTubeChannelResolution` keeps that lookup the
/// pure function over "these words, these channels" it has always been.
struct YouTubeCommandResolution: Equatable, Sendable {
    let resolution: YouTubeChannelResolution
    let modelMatch: YouTubeChannelModelMatchAttempt
    /// The channels this press could have reached: the allowlist snapshot the
    /// lookup was made against.
    ///
    /// Carried rather than re-read later, so the recovery picker offers exactly
    /// the rows the command itself was resolved against. Reading the store again
    /// at the moment the picker opens would let a Settings edit made in between
    /// put a row in front of the user that this command never had access to.
    /// Empty on every path that had no allowlist at all - which is every
    /// dictation, and a command capture made while the feature is off.
    let candidates: [YouTubeChannel]

    init(
        resolution: YouTubeChannelResolution,
        modelMatch: YouTubeChannelModelMatchAttempt = .notNeeded,
        candidates: [YouTubeChannel] = []
    ) {
        self.resolution = resolution
        self.modelMatch = modelMatch
        self.candidates = candidates
    }

    /// What the user said, in every case, so a message can quote it back.
    var spokenName: String { resolution.spokenName }

    /// The same answer, remembering which channels it was reached among.
    ///
    /// Attached by the stage that owns the allowlist rather than passed through
    /// every step that does not, so the on-device chooser keeps returning
    /// exactly what it always did and cannot be the thing that decides which
    /// rows a later surface may show.
    func withCandidates(_ candidates: [YouTubeChannel]) -> YouTubeCommandResolution {
        YouTubeCommandResolution(
            resolution: resolution, modelMatch: modelMatch, candidates: candidates)
    }
}
