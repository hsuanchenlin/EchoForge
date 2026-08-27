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

// MARK: - Building one from a command

extension RecordingProvenance {

    /// The provenance of a command capture at the moment its words are stored,
    /// before the feed has been fetched or Chrome asked to open anything.
    ///
    /// Everything but an allowlisted channel is already decided here, which is
    /// what keeps the row the user is most likely to be looking at - "that name
    /// is not in your list" - correct from the instant it appears rather than
    /// after a flicker. An allowlisted channel is stored as `.didNotFinish`
    /// until the report says otherwise: the command may still fail at the feed
    /// or at the browser, and a row that claimed "opened" while that was still
    /// unknown would be the one lie this record must never tell.
    static func pendingCommand(_ command: YouTubeCommandResolution) -> RecordingProvenance {
        guard let refusal = YouTubeLatestVideoReport.refusal(for: command.resolution) else {
            return .youTubeCommandNotOpened(
                reason: .didNotFinish,
                message: "This command had not finished when the recording was stored, so nothing was opened."
            )
        }
        return .command(refusal, modelMatch: command.modelMatch)
    }

    /// The provenance of a finished command.
    ///
    /// - Parameter modelMatch: what part the optional on-device chooser played,
    ///   appended to the sentence so a row records that a model was - or was not
    ///   - consulted. That disclosure is the same obligation
    ///   `YouTubeChannelMatchSource.disclosure` carries on the overlay.
    static func command(
        _ report: YouTubeLatestVideoReport,
        modelMatch: YouTubeChannelModelMatchAttempt = .notNeeded
    ) -> RecordingProvenance {
        switch report {
        case .opened:
            return .youTubeCommandOpened(
                summary: joined(report.spokenSummary, modelMatch.disclosure))
        case .refused(let reason, let message, _):
            return .youTubeCommandNotOpened(
                reason: reason, message: joined(message, modelMatch.disclosure))
        }
    }

    /// The provenance of a command that missed and put the channel picker up.
    ///
    /// Written when the panel opens rather than when it closes, and it says
    /// nothing was opened - the same fail-closed rule `pendingCommand` follows.
    /// A picker can be left on screen for as long as the user likes, and a quit
    /// while it is up must leave a row saying they were offered a choice and no
    /// video was opened.
    static func pickerShown(_ request: YouTubeChannelPickerRequest) -> RecordingProvenance {
        let message: String
        switch request.cause {
        case .unknown:
            message = "No channel is stored under “\(request.spokenName)”, so Kongweh offered your own channel list to choose from. Nothing has been opened."
        case .ambiguous(let matches):
            // The phrase *is* a stored spelling - of every one of these rows -
            // so the unknown wording would be a lie, and the fix it implies is
            // not one that exists: adding another spelling cannot split a tie.
            // Named back as handles, like the picker sentence the user just
            // read and the report the same collision writes elsewhere.
            let named = YouTubeChannelHandle.format(all: matches).joined(separator: ", ")
            message = "“\(request.spokenName)” answers to more than one of your channels (\(named)), so Kongweh offered your channel list to choose between them. Nothing has been opened."
        }
        return .youTubeCommandNotOpened(reason: .pickerShown, message: message)
    }

    /// What a row says after the user transcribed it again from History.
    ///
    /// Only a command row changes, and only its sentence. The kind and the class
    /// are what that press actually did and stay exactly as they were; the
    /// sentence goes, because it quotes the spelling the *old* transcript had
    /// and would now sit under a different one - a stale quote beside fresh
    /// words is worse than no quote. Regenerating does not re-run the command:
    /// the queue transcribes and never routes, which is why the replacement says
    /// so out loud.
    func reTranscribed() -> RecordingProvenance {
        guard case .youTubeCommandNotOpened(let reason, _) = self else { return self }
        return .youTubeCommandNotOpened(
            reason: reason,
            message: "This recording was transcribed again from History. The command itself was not run again, and nothing was opened. Press the YouTube command shortcut to try it."
        )
    }

    /// How history files a session whose audio went to the transcription queue
    /// because the engine was busy with another one.
    ///
    /// The queue transcribes and never routes (`Settings.routesSpokenIntents`),
    /// so a command capture that lands there becomes plain text and the command
    /// never runs at all. That is the press a user is least able to explain
    /// afterwards - it produced a history row and no answer - so it is the one
    /// that most needs saying out loud.
    static func queued(for purpose: DictationPurpose) -> RecordingProvenance {
        switch purpose {
        case .dictation:
            return .fileTranscription
        case .youTubeCommand:
            return .youTubeCommandNotOpened(
                reason: .engineBusy,
                message: "The transcription engine was busy, so this was queued as a plain transcription and the command never ran. Nothing was opened. Try the shortcut again once the queue is clear."
            )
        }
    }

    /// How history files a session the engine could not transcribe at all.
    ///
    /// A failed **command** capture is a command that opened nothing, not a
    /// failed dictation: "I pressed the YouTube key and nothing happened" and
    /// "my dictation did not transcribe" are otherwise the same row.
    static func notTranscribed(
        for purpose: DictationPurpose, reason: String
    ) -> RecordingProvenance {
        switch purpose {
        case .dictation:
            return .dictation
        case .youTubeCommand:
            return .youTubeCommandNotOpened(
                reason: .notTranscribed,
                message: "This command could not be transcribed, so there was never a channel name to look up and nothing was opened. \(reason)"
            )
        }
    }

    private static func joined(_ sentence: String, _ addition: String?) -> String {
        guard let addition, !addition.isEmpty else { return sentence }
        guard !sentence.isEmpty else { return addition }
        return "\(sentence) \(addition)"
    }
}
