import Foundation

/// How a live session turns into a stored provenance.
///
/// Split from `RecordingProvenance` itself, which is in `EchoForgeCore` because
/// the `echoforge` command-line tool reads history and has to know what a stored
/// row *means*. This half is about how one is *produced*, and it names the
/// running app's own types - a resolved YouTube command, a report, a
/// `DictationPurpose`. None of that exists in a process that only reads rows,
/// and none of it should: a tool that could construct these could write them.
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
        case .selectionEdit:
            return .selectionEdit(
                instruction: "The transcription engine was busy, so this was queued as a plain transcription and the edit never ran. Try the shortcut again once the queue is clear."
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
        case .selectionEdit:
            return .selectionEdit(
                instruction: "This edit could not be transcribed, so the instruction was never applied and the selection was left as it was. \(reason)"
            )
        }
    }

    private static func joined(_ sentence: String, _ addition: String?) -> String {
        guard let addition, !addition.isEmpty else { return sentence }
        guard !sentence.isEmpty else { return addition }
        return "\(sentence) \(addition)"
    }
}
