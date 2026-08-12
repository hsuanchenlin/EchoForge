import Foundation

/// Whether this build carries the cloud path at all.
///
/// The app's whole reason for existing is that dictation does not leave the Mac,
/// and that promise is still the default: `docs/cloud-api.md` is the long form.
/// But "off by default" and "not present" are different claims, and there are
/// installs - air-gapped machines, an organisation that has to be able to say the
/// binary cannot talk to a model provider - where only the second one is worth
/// anything.
///
/// So an **offline-only variant** is buildable, and this is the switch:
/// `Scripts/build_release.sh --offline-only` sets `ECHOFORGE_OFFLINE_ONLY`, and
/// with it set `CloudAccess` refuses every feature before it looks at anything
/// else, the Cloud pane is not offered, and `EngineKind.cloud` can never become
/// the active engine. Nothing else in the app changes, which is the point: the
/// offline build is the same build with one door welded shut.
///
/// The gate is a value rather than `#if` scattered through the sources on
/// purpose. `EngineKind` switches exhaustively in eight places and
/// `StyleRewriteAvailability` in two more; conditionally compiling a case out of
/// an enum means conditionally compiling every one of those switches, which is
/// how a variant build stops being the same build. One value, checked first in
/// the one function that decides whether a cloud call may happen, is both easier
/// to read and easier to prove - `CloudAccessTests` drives it with
/// `isCompiledIn: false` and asserts every feature is refused.
enum CloudBuild {
    static let isCompiledIn: Bool = {
        #if ECHOFORGE_OFFLINE_ONLY
        return false
        #else
        return true
        #endif
    }()
}

/// The two things this app can be asked to do somewhere other than on this Mac.
///
/// A feature rather than a single "cloud on/off" switch, because the two send
/// very different things: one uploads the audio of everything the user dictates,
/// the other uploads a transcript they asked to have translated. Consenting to
/// the second is not consenting to the first, so consent, the enable state and
/// the refusal reasons are all per feature.
///
/// Everything else this app asks a model to do - style rewriting, the Ask panel,
/// screen queries - stays on device and is deliberately not listed here. See
/// `docs/cloud-api.md` for why translation is the one rewriting stage that has a
/// cloud option.
enum CloudFeature: String, CaseIterable, Sendable {
    /// Speech transcription: the recorded audio is uploaded.
    case transcription

    /// The spoken `Translate to …` command: the transcript is uploaded.
    case translation

    /// How the feature is named in the Settings pane and in a refusal.
    var name: String {
        switch self {
        case .transcription: return "Speech transcription"
        case .translation: return "Translation"
        }
    }

    /// What actually leaves the Mac when this feature runs in the cloud, in the
    /// words the consent sheet uses. Deliberately concrete: "your data" is not a
    /// disclosure, "the audio of every dictation" is.
    var whatLeavesTheDevice: String {
        switch self {
        case .transcription:
            return "the audio of every dictation you record"
        case .translation:
            return "the text of every dictation you ask to have translated"
        }
    }

    /// The preference key holding whether this feature's consent has been given.
    /// Storage format, so renaming one would silently discard a user's recorded
    /// consent - which would then be re-asked rather than assumed, but is still
    /// not something to do by accident.
    var consentKey: String { rawValue }
}
