import Foundation

/// Which of the app's ways of listening produced one history row, and what
/// became of it.
///
/// History used to record only the words. That was enough while a dictation
/// could only ever become text, and stopped being enough the moment a press of
/// one key could open a browser instead: a command that opened nothing, a
/// question that went to the Ask panel and a sentence that was pasted into the
/// user's document all left the same row behind, so the only durable trace of
/// four different outcomes was identical. The app's own diagnostics do not close
/// that gap - `print` goes to a stdout no user has, the overlay carries four
/// words for two seconds while the user is looking at another app, and the
/// VoiceOver announcement reaches nobody who has VoiceOver off. This type is the
/// record that survives all three, and `docs/history-provenance.md` is its whole
/// story.
///
/// Three rules carry it:
///
/// - **It is written, never guessed.** A row stored before provenance existed is
///   `.unknown` and says so in the UI ("Older recording"). Deciding after the
///   fact that an old row "was probably dictation" would put the app's guess
///   where the record belongs.
/// - **It fails closed the way the command does.** A command capture is stored
///   as *not* opened until something says otherwise, so a crash, a quit or a
///   hang can never leave a row claiming a video was opened when none was.
/// - **It carries no secret and no target.** The stored reason is the sentence
///   the user was already shown: it names the channel as *they* named it and
///   what to do next, and never a channel id, a feed URL, a video URL or
///   anything read out of the Keychain. `HistoryProvenancePrivacyTests` holds
///   that.
enum RecordingProvenance: Equatable, Sendable {
    /// Stored by a build that had no provenance to write, or by a path that
    /// genuinely does not know. Never inferred into something else.
    case unknown
    /// The dictation hotkey: words on their way into whatever app the user was
    /// typing in. Text and only text - see `DictationPurpose`.
    case dictation
    /// A file the user dropped, opened with, or whose audio was queued because
    /// the engine was busy. Text, and nothing was inserted anywhere.
    case fileTranscription
    /// A spoken question that went to the Ask panel. Nothing was inserted.
    case ask
    /// The YouTube command hotkey, and the video opened in Chrome. `summary` is
    /// the sentence the user was told, including the on-device model's
    /// disclosure when it took part in the match.
    case youTubeCommandOpened(summary: String)
    /// The YouTube command hotkey, and nothing was opened. `reason` classifies
    /// it for the UI and for tests; `message` is the actionable sentence.
    case youTubeCommandNotOpened(reason: YouTubeCommandRefusal, message: String)
    /// The voice-edit hotkey. `instruction` is what was spoken; the original
    /// and rewritten texts live on the row as `rawTranscription` and
    /// `transcription`, which is what Compare and "Show original" already read.
    case selectionEdit(instruction: String)

    /// The stored discriminator. One string per case, and these strings are
    /// **persisted**: renaming one relabels every row a user already has.
    var kind: RecordingProvenanceKind {
        switch self {
        case .unknown: return .unknown
        case .dictation: return .dictation
        case .fileTranscription: return .fileTranscription
        case .ask: return .ask
        case .youTubeCommandOpened: return .youTubeCommandOpened
        case .youTubeCommandNotOpened: return .youTubeCommandNotOpened
        case .selectionEdit: return .selectionEdit
        }
    }

    /// The refusal class, for the one kind that has one.
    var refusal: YouTubeCommandRefusal? {
        guard case .youTubeCommandNotOpened(let reason, _) = self else { return nil }
        return reason
    }

    /// The sentence shown under the label, or nil when the label says
    /// everything. Never a URL, an id or a credential.
    var detail: String? {
        switch self {
        case .unknown, .dictation, .fileTranscription, .ask:
            return nil
        case .youTubeCommandOpened(let summary):
            return summary.isEmpty ? nil : summary
        case .youTubeCommandNotOpened(_, let message):
            return message.isEmpty ? nil : message
        case .selectionEdit(let instruction):
            return instruction.isEmpty ? nil : instruction
        }
    }

    /// Whether this row came from the dedicated command hotkey, in either
    /// outcome. Read by the surfaces that group the two together.
    var isYouTubeCommand: Bool {
        kind == .youTubeCommandOpened || kind == .youTubeCommandNotOpened
    }

    // MARK: - Storage

    /// The three values exactly as they go into the database.
    ///
    /// One place builds them and one place reads them back (`stored`), so a
    /// column and the value it is meant to hold cannot drift apart.
    var columns: (kind: String, reason: String?, detail: String?) {
        (kind.rawValue, refusal?.rawValue, detail)
    }

    /// Rebuilds a provenance from the three stored columns.
    ///
    /// Total: a kind this build does not know, a `youTubeCommandNotOpened` row
    /// with no reason stored, or any other combination that cannot be trusted
    /// comes back as `.unknown` rather than as a guess. A database written by a
    /// newer build is exactly that case, and saying "older recording" about it
    /// is honest where inventing a kind would not be.
    static func stored(
        kind rawKind: String?, reason rawReason: String?, detail: String?
    ) -> RecordingProvenance {
        guard let rawKind, let kind = RecordingProvenanceKind(rawValue: rawKind) else {
            return .unknown
        }
        switch kind {
        case .unknown: return .unknown
        case .dictation: return .dictation
        case .fileTranscription: return .fileTranscription
        case .ask: return .ask
        case .youTubeCommandOpened:
            return .youTubeCommandOpened(summary: detail ?? "")
        case .selectionEdit:
            return .selectionEdit(instruction: detail ?? "")
        case .youTubeCommandNotOpened:
            // A refusal with no reason is a row this build cannot describe, and
            // "not opened, and I cannot say why" is worse than saying the row
            // predates what would have said it.
            guard let rawReason, let reason = YouTubeCommandRefusal(rawValue: rawReason) else {
                return .unknown
            }
            return .youTubeCommandNotOpened(reason: reason, message: detail ?? "")
        }
    }
}

/// The persisted discriminator of `RecordingProvenance`.
///
/// A `String` raw value because it goes in a column: these strings are in every
/// user's database and are not free to rename. Adding a case is safe - older
/// builds read it back as `.unknown`.
enum RecordingProvenanceKind: String, CaseIterable, Sendable {
    case unknown
    case dictation
    case fileTranscription
    case ask
    case youTubeCommandOpened
    case youTubeCommandNotOpened
    case selectionEdit
}

extension RecordingProvenanceKind {

    /// What the row is called on screen, and the one place that copy lives.
    ///
    /// The two command kinds share a prefix on purpose: they are one feature
    /// with two outcomes, and a user scanning history should be able to see at a
    /// glance which presses did something and which did not.
    var label: String {
        switch self {
        case .unknown: return "Older recording"
        case .dictation: return "Dictation"
        case .fileTranscription: return "File transcription"
        case .ask: return "Ask"
        case .youTubeCommandOpened: return "YouTube command - opened"
        case .youTubeCommandNotOpened: return "YouTube command - not opened"
        case .selectionEdit: return "Voice edit"
        }
    }

    /// The SF Symbol beside the label. Chosen so the two command outcomes are
    /// told apart by shape as well as by colour, which is the half of the
    /// distinction that survives a monochrome display or a colour-blind reader.
    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .dictation: return "text.alignleft"
        case .fileTranscription: return "doc.text"
        case .ask: return "questionmark.bubble"
        case .youTubeCommandOpened: return "play.rectangle.fill"
        case .youTubeCommandNotOpened: return "exclamationmark.triangle.fill"
        case .selectionEdit: return "pencil.and.outline"
        }
    }

    /// What a surface should say about this row for a reader who cannot see the
    /// pill - the label, and for a refusal the fact that it is one.
    ///
    /// The sentence itself is `RecordingProvenance.detail`; this is the part
    /// that comes from the kind alone.
    var accessibilityLabel: String {
        switch self {
        case .youTubeCommandOpened: return "YouTube command, opened"
        case .youTubeCommandNotOpened: return "YouTube command, nothing was opened"
        case .selectionEdit: return "Voice edit"
        default: return label
        }
    }
}

/// Why a spoken YouTube command opened nothing.
///
/// A stable slug beside the sentence rather than instead of it, for the same
/// reason `YouTubeFeedError` carries both a message and a short one: the
/// sentence is what the user reads and is free to be reworded, and this is what
/// the UI groups by and what a test asserts on. Every case is a distinct thing
/// for the user to do about it.
enum YouTubeCommandRefusal: String, CaseIterable, Sendable {
    /// Nothing usable was heard: silence, or a marker with no channel behind it.
    case notRecognised
    /// The transcription itself failed, so there were never any words to read.
    case notTranscribed
    /// The engine was busy, so the capture was queued as a plain transcription
    /// and the command never ran.
    case engineBusy
    /// The YouTube command is switched off.
    case commandDisabled
    /// No allowlisted channel answers to what was heard.
    case channelUnknown
    /// More than one does, so neither can be the one that was meant.
    case channelAmbiguous
    /// The stored row has no usable channel ID.
    case channelIDUnusable
    /// YouTube could not be reached, or answered with a status.
    case feedUnavailable
    /// The feed arrived and carried nothing that could be opened.
    case feedUnusable
    /// Chrome could not open the video.
    case browserUnavailable
    /// The spoken name missed and the channel picker was put on screen. Written
    /// the moment it opens and replaced by whatever the user does about it, so a
    /// quit or a crash with the picker still up leaves a row saying a choice was
    /// offered and nothing was opened - which is true.
    case pickerShown
    /// The picker was up and the user dismissed it without choosing. Its own
    /// class rather than `channelUnknown`, because it is the one refusal the
    /// user made on purpose and there is nothing for them to fix.
    case pickerCancelled
    /// The spoken name missed and there was no channel to offer instead: the
    /// allowlist holds nothing a command could reach. Distinct from
    /// `channelUnknown`, which is a list that has rows and none of them
    /// answering.
    case noChannelsConfigured
    /// Written when the words are stored and the command has not finished. It
    /// survives only when the app never got to replace it - a quit or a crash
    /// mid-command - which is exactly when "nothing was opened" is the true
    /// thing to have recorded.
    case didNotFinish

    /// The few words a compact surface has room for. The sentence stored beside
    /// it is what says what to do.
    var shortLabel: String {
        switch self {
        case .notRecognised: return "Nothing to match"
        case .notTranscribed: return "Not transcribed"
        case .engineBusy: return "Engine was busy"
        case .commandDisabled: return "Command is off"
        case .channelUnknown: return "Channel not in your list"
        case .channelAmbiguous: return "Two channels answer to that"
        case .channelIDUnusable: return "Channel ID is not usable"
        case .feedUnavailable: return "Could not reach YouTube"
        case .feedUnusable: return "Feed had no video"
        case .browserUnavailable: return "Chrome could not open it"
        case .didNotFinish: return "Command did not finish"
        case .pickerShown: return "Waiting on your choice"
        case .pickerCancelled: return "You cancelled the choice"
        case .noChannelsConfigured: return "No channels in your list"
        }
    }
}

