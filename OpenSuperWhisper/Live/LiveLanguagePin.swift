import Foundation

/// The language a live session's utterances decode in, decided once per
/// session from what the first utterance was spoken in.
///
/// On `auto`, whisper.cpp detects the language once per `whisper_full` call -
/// on the first 30 s window - and decodes the rest of the file in it. A live
/// session hands the engine a file per utterance, so without this every
/// utterance would be detected again: one extra ~0.5 s encode each, and a
/// language that can flip between utterances where the whole-file decode of
/// the same recording would have held one. The pin restores the whole-file
/// semantics one utterance at a time: the first utterance decodes on `auto`,
/// and if the engine's answer is a **confident** detection, every utterance
/// after it - the tail at stop included - decodes in that language, with no
/// detection at all.
///
/// Three things are absolute. It is **per session**: a pin lives on the
/// `LiveDictationSession` that made it and dies with it, so the next press
/// starts on `auto` again, and a cancelled or fallen-back session takes its pin
/// with it - the whole-file decode of the WAV runs on the settings the user
/// chose. It **never touches an explicit language**: a session started on
/// anything but `auto` decodes in that language throughout, and no detection is
/// consulted. And it **never writes a preference**: the pinned language reaches
/// the decode `Settings` copy the session builds (`applied(to:)`) and nothing
/// else - the `Settings` the joined transcript is post-processed with still
/// carry `auto`, and `whisperLanguage` is never written by anything on this
/// path.
///
/// Pure, so the rules can be stated against a fake decoder. `LiveLanguagePinTests`
/// holds them.
struct LiveLanguagePin: Equatable {

    /// The probability a detection needs before the session is pinned to it.
    ///
    /// The detector's answer is a softmax over every language the model knows,
    /// so `0.5` means the winner has more mass than all the others together -
    /// a language rather than a guess. Measured on `ggml-large-v3-turbo`
    /// (`docs/live-dictation.md`): every clip tried scored between 0.966 and
    /// 0.9996 - English and Mandarin as short as 3 s, Japanese, Korean,
    /// Cantonese (as `zh`), and a Mandarin sentence with English words in it
    /// at 0.9955 - so the bar sits far below anything a clear utterance
    /// produces and costs those speakers nothing. What it refuses is a first
    /// utterance the detector genuinely split over two languages, which then
    /// decodes on `auto` again next time. A wrong pin costs every later
    /// utterance; a missed pin costs one encode per utterance until one lands.
    static let minimumConfidence: Float = 0.5

    /// What the session started with: the user's `selectedLanguage`, which is
    /// `auto` or a code.
    let selectedLanguage: String

    /// The language the first confident detection named, or nil while none has.
    private(set) var pinnedLanguage: String?

    init(selectedLanguage: String) {
        self.selectedLanguage = selectedLanguage
        self.pinnedLanguage = nil
    }

    /// Whether the user asked for detection at all.
    var isAutomatic: Bool { selectedLanguage == Self.automatic }

    /// Whether a detection has been pinned.
    var isPinned: Bool { pinnedLanguage != nil }

    /// Whether the next utterance decodes on `auto`: the user asked for
    /// detection and nothing confident has been heard yet.
    var isDetecting: Bool { isAutomatic && !isPinned }

    /// The language the next utterance decodes in.
    var decodeLanguage: String { pinnedLanguage ?? selectedLanguage }

    /// `settings` with the language the next utterance decodes in. The copy is
    /// what a decode is handed; the original is what the transcript is
    /// finished with, and is never changed.
    func applied(to settings: Settings) -> Settings {
        guard isPinned else { return settings }
        var decodeSettings = settings
        decodeSettings.selectedLanguage = decodeLanguage
        return decodeSettings
    }

    /// Reads one utterance's decode and pins the session if it is the first
    /// confident detection. Returns whether this call pinned.
    ///
    /// Nothing pins unless every one of these holds: the user asked for
    /// detection; nothing is pinned yet; the engine reported a detection, with
    /// at least `minimumConfidence`; and the utterance decoded to words by the
    /// rule `CommittedTranscript` keeps one by - a detection over an utterance
    /// the transcript drops, `...` on a breath, is not one to hold a session
    /// to.
    mutating func observe(_ decode: RawDecode) -> Bool {
        guard isDetecting,
              let language = decode.language,
              (Self.minimumConfidence...1).contains(language.probability),
              CommittedTranscript.kept(decode.text) != nil
        else { return false }
        pinnedLanguage = language.code
        return true
    }

    static let automatic = "auto"
}
