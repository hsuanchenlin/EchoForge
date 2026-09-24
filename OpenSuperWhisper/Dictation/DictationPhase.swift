import Foundation

/// Where one dictation has got to.
///
/// This is the session's own account of itself, and the only thing a surface
/// following a dictation has to read: `IndicatorViewModel` derives the card's
/// `RecordingState` from it, and the capsule follows that in turn. It is
/// deliberately shorter than `RecordingState` - the cases here are the stages
/// of the *work*, and every way a session can stop early is one `.ended`
/// carrying the line the user still has to be shown.
///
/// Nothing here says how long a message stays on screen. That is a property of
/// the overlay, not of the dictation, and it lives with the overlay's other
/// timers in `IndicatorViewModel`.
enum DictationPhase: Equatable {
    /// Nothing has been claimed yet, or this session is over and said so.
    case idle
    /// The microphone is being reached - a Bluetooth headset takes a moment.
    case connecting
    /// Capturing.
    case recording
    /// The audio has stopped and the engine is turning it into text.
    case decoding
    /// The words are read and the channel picker is on screen; what remains is
    /// the user's answer, not the app's work.
    case awaitingChannelChoice
    /// Over. `notice` is what the user still has to be told, and `nil` means
    /// the session ended with nothing to add - every ordinary success, and
    /// every cancel, because they already know what they did.
    case ended(DictationNotice?)
}

/// The short line a dictation leaves behind when it stops early.
///
/// One vocabulary for both overlays and for both dictation entry points, so a
/// failure the user can fix cannot be worded one way on the card and another on
/// the capsule. Every case is written for a 200 pt card and a pill: the
/// sentence the user can act on lives on the recording that was kept and in the
/// main window's banner.
enum DictationNotice: Equatable {
    /// Another transcription is still running. The reason says what became of
    /// this dictation because of it, so an overlay can be honest about whether
    /// the user's words are coming later.
    case busy(BusyReason)
    /// There was no input device to record with.
    case noMicrophone

    /// The microphone never opened for this session.
    ///
    /// Its own case rather than `.noMicrophone` because it is reached from a
    /// different place and means something different: `.noMicrophone` is the
    /// synchronous refusal before anything was claimed, while this is a start
    /// that was accepted, drawn as a recording, and then failed on the
    /// recorder's work queue (`AudioRecorder.failedStart`). Until it existed the
    /// card blinked "Recording..." over a microphone that never started and then
    /// vanished without a word.
    case recordingFailed(String)

    /// A recording decoded with no engine set up.
    case noEngine

    /// A cloud transcription that never produced a transcript: no network, a
    /// refused key, a rate limit, a provider outage.
    ///
    /// Its own case rather than `noEngine` because they need different words. An
    /// engine that is not set up is a settings problem the user fixes once; a
    /// cloud call that failed is usually transient and the same press would
    /// have worked a minute later.
    case cloudFailed(String)

    /// The engine did not answer inside its deadline and the decode was stopped.
    ///
    /// Its own case for the same reason `cloudFailed` is: nothing is wrong with
    /// the setup, the audio was kept, and the fix is to try again - so the words
    /// are "timed out", not a sentence that sends the user to a pane where
    /// everything is correct.
    case transcriptionTimedOut

    /// The engine refused the language that was spoken.
    case wrongLanguage(String)

    /// A spoken command that was understood and could not be carried out, or
    /// was not read as a command at all.
    case commandFailed(String)
}

/// What a dictation that failed to transcribe does with the user's audio.
///
/// One rule for both places a dictation can be started - the mini indicator and
/// the main window - so a failure the user can fix cannot keep the recording in
/// one of them and delete it in the other.
enum DictationFailureOutcome: Equatable {
    /// Delete the temporary audio, as every failure did before: there is nothing
    /// the user could do with it that would go any better.
    case discard

    /// Keep the audio and say why it has no transcript yet. The reason is stored
    /// on the recording, so it is still there after the indicator has gone, and
    /// the regenerate button transcribes it once the reason is dealt with.
    case keep(reason: String, notice: DictationNotice)

    static func forError(_ error: Error) -> DictationFailureOutcome {
        if EngineConfiguration.isNotConfigured(error) {
            return .keep(reason: EngineConfiguration.unavailableMessage, notice: .noEngine)
        }
        // Every way a cloud request can fail is either transient or something
        // the user can fix, and the audio transcribes perfectly well afterwards -
        // on the provider once the key is right, or on a local engine. Deleting
        // it because a network call failed would be the app throwing away work it
        // never even attempted.
        if let cloud = error as? CloudRequestError, cloud.keepsTheRecording {
            return .keep(
                reason: cloud.errorDescription ?? cloud.shortMessage,
                notice: .cloudFailed(cloud.shortMessage)
            )
        }
        // A timeout is transient in the same way a cloud failure is: the engine
        // was stopped, not disproven, and the recording transcribes on a retry.
        // Deleting it would be the app punishing the user for its own hang.
        if let transcription = error as? TranscriptionError, transcription == .processingTimedOut {
            return .keep(
                reason: transcription.errorDescription ?? "Transcription timed out.",
                notice: .transcriptionTimedOut
            )
        }
        // The audio is good and a different engine transcribes it, so deleting
        // it would throw away work over a choice the user can change in one
        // press. The engine that refused supplies both strings.
        if let transcription = error as? TranscriptionError,
            case .unsupportedSpokenLanguage(let message, let shortMessage) = transcription
        {
            return .keep(reason: message, notice: .wrongLanguage(shortMessage))
        }
        return .discard
    }
}

/// Why a dictation was refused, or what became of the audio when it was.
enum BusyReason: Equatable {
    /// The start was refused: nothing was captured and nothing is queued.
    case startRefused
    /// The audio was captured and queued behind the transcription in flight.
    case audioQueued
}

/// What a dictation that ran to its end actually produced.
///
/// The indicator card never needed this - it decodes, hides, and says nothing
/// either way - but a HUD that ends every dictation on a success badge would show
/// a checkmark for a recording that was silent or a transcription that failed.
/// So the outcome is recorded rather than inferred, and `nil` means "the session
/// ended with nothing to add": cancelled, or already showing why it stopped.
enum DictationResult: Equatable {
    /// Text was produced and handed to whatever the user was typing in.
    ///
    /// `styleNotice` is `StyledTranscript.dictationStyleNotice` when a rewrite
    /// was expected but the deterministic transcript was kept instead - refused
    /// by the guard, timed out, failed - and nil for a plain success and for a
    /// Mac that cannot rewrite at all, which that property explains. The text is
    /// inserted and stored identically either way; the notice only changes what
    /// the badge says.
    case inserted(styleNotice: String?)
    /// The words were a spoken question and went to the Ask panel instead of
    /// into another app. Nothing was inserted, and that is the point.
    case asked
    /// The words asked for a channel's latest video and it is open in the
    /// browser. Nothing was inserted, for the same reason `asked` inserts
    /// nothing.
    case openedVideo(channel: String)
    /// The recording decoded to nothing. The audio is discarded, as it always was.
    case noSpeech
    /// It failed for a reason worth telling the user.
    case failed(String)
}

extension FailedRecordingStart.Reason {
    /// What a dictation says for a microphone that never opened.
    ///
    /// `.noAudioInput` reuses `.noMicrophone` deliberately: it is the same fact
    /// the synchronous pre-check reports, arriving a few milliseconds later, and
    /// two different messages for one fact would be the app being precise about
    /// its own plumbing instead of about the user's microphone.
    var notice: DictationNotice {
        switch self {
        case .noAudioInput: return .noMicrophone
        case .recorderFailed: return .recordingFailed(shortMessage)
        }
    }
}
