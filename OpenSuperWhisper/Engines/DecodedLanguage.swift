import Foundation

/// The language one decode ran in.
///
/// Two ways it can have been decided, told apart by `probability`. A language the
/// caller **gave** (`Settings.selectedLanguage` other than `auto`) is what the
/// decode ran in and nothing was measured: `probability` is nil. A language the
/// engine **detected** carries the detector's own softmax probability for it -
/// for whisper.cpp, the mass `whisper_lang_auto_detect` put on the winner over
/// every language it knows - which is what makes one detection worth pinning a
/// session on and another not (`LiveLanguagePin`).
///
/// The code is the engine's own (`whisper_lang_str`: "en", "zh", "yue", …), so
/// it can be handed straight back as `selectedLanguage` for the next decode on
/// that engine. It is never written to a preference and never reaches the
/// post-processing stages, which read the language the user chose.
struct DecodedLanguage: Equatable, Sendable {
    let code: String
    /// The detector's probability for `code`, in 0...1, or nil when none was
    /// measured because the language was given.
    let probability: Float?

    /// A language the caller chose. Nothing was detected.
    static func given(_ code: String) -> DecodedLanguage {
        DecodedLanguage(code: code, probability: nil)
    }

    /// A language the engine detected, with how sure it was.
    static func detected(_ code: String, probability: Float) -> DecodedLanguage {
        DecodedLanguage(code: code, probability: probability)
    }
}

/// What a raw decode hands back: the engine's text and, from an engine that
/// can say, the language it ran in. Nothing here has been through any stage of
/// `docs/text-post-processing.md`.
struct RawDecode: Equatable, Sendable {
    let text: String
    /// Nil from an engine that does not report one (`DecodeLanguageReporting`).
    let language: DecodedLanguage?

    init(text: String, language: DecodedLanguage? = nil) {
        self.text = text
        self.language = language
    }
}

/// An engine that can say which language a decode ran in.
///
/// A separate protocol rather than a change to `TranscriptionEngine`, for the
/// reason `PartialTranscriptEmitting` is: one engine in this app has the
/// answer, and giving the others a value they could never fill would make
/// "does this engine report its language" a runtime question. Whisper is that
/// engine - whisper.cpp's detector reports a probability beside the language
/// it picks - and live dictation is the caller, which pins a session's
/// language on the first confident answer so the utterances after it skip the
/// detection encode.
protocol DecodeLanguageReporting: AnyObject {
    /// `transcribeAudio(url:settings:)` and the language it ran in.
    ///
    /// On `auto` the engine detects the language itself, before the decode, so
    /// the probability is its own rather than inferred; the decode then runs
    /// in the language found, which is what the engine's own auto-detection
    /// does internally. It costs no more than `transcribeAudio` on `auto`.
    func transcribeAudioReportingLanguage(url: URL, settings: Settings) async throws -> RawDecode
}
