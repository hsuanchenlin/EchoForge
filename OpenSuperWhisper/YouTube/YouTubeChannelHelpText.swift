import Foundation

/// The words Settings uses to explain the YouTube command.
///
/// They live here rather than inline in the view for the same reason
/// `EngineCatalog` owns its caveats: two of them are obligations rather than
/// decoration, and a test can only hold an obligation that has a name.
///
/// - The **channel id** is the one thing a user cannot guess, and a pane that
///   asks for it without saying where to find it is a pane nobody can fill in.
/// - The **autoplay note** is a promise about what this feature does not do:
///   whether the video starts by itself is the browser's policy, and saying so
///   is what stops the app being blamed for it either way.
/// - The **workflow sentence** answers the question the pane otherwise leaves
///   open: how the command is invoked. It has a key of its own, separate from
///   dictation, and that distinction is the feature's safety story rather than a
///   detail - so the pane says it in the words a user would use.
/// - The **model note** is a disclosure. Everything else here is deterministic
///   string comparison, so the one setting that can put a model in the path has
///   to say what it is given, what it can answer, and that it stays on this Mac.
enum YouTubeChannelHelpText {

    static let sectionSubtitle = "Say a channel from this list, get its newest video in Chrome."

    /// The name of the key, for a sentence written around a binding the user may
    /// have changed.
    static let shortcutName = "YouTube command shortcut"

    /// How the command is invoked, written around the key that is actually
    /// bound. `nil` is a user who cleared the binding, which leaves no way to
    /// use the feature at all - so that is what the sentence says.
    static func shortcutWorkflow(shortcut: String?) -> String {
        guard let shortcut else {
            return "The \(shortcutName) is not set, so there is no way to use this. Bind a key in Shortcuts → YouTube Command."
        }
        return "Hold \(shortcut), say a channel from this list, and let go. That key records a command and nothing else: it never types anything, and your normal dictation shortcut is unchanged - saying “open the latest YouTube video from …” into it still just types those words."
    }

    static let nameHint = "What you say, and what this row is called. Case, punctuation, spacing and Traditional or Simplified script do not have to match - “valley 101” finds a channel stored as “valley101”."

    static let aliasHint = "Optional, comma separated. Add the spellings your dictation actually produces for this channel."

    static let channelIDInstructions = "On the channel's page in a browser: ⋯ → Share channel → Copy channel ID. Or copy the UC… part of a youtube.com/channel/UC… address - pasting the whole address here works too. A @handle is not a channel ID."

    static let autoplayNote = "Whether the video starts playing on its own is Chrome's autoplay policy, not something this app sets."

    static let emptyState = "Add the channels you actually watch. The YouTube command shortcut opens the newest video from one of them in Chrome, and can never open anything else."


    static let pickerToggleTitle = "Let me pick from my channels when a name is not recognised"

    /// What the picker is, and - the part that has to be said before it is
    /// switched on - that it appears in front of whatever the user is doing.
    /// That is the one thing about it a person would want to know in advance,
    /// and the only reason it is a switch at all.
    static let pickerHint = "On by default. When what you said matches no channel above - or matches two - Kongweh shows this list and you choose with the arrow keys and Return, or press Escape to open nothing. It asks nothing and sends nothing anywhere; the list is only the channels you added here. It does take keyboard focus for as long as it is up, so turn this off if you would rather a command that misses simply say so."

    static let modelMatchToggleTitle = "Let the on-device model match a name I said"

    /// What the model is given, what it can answer, and where it runs. All three
    /// are obligations rather than description: this is the only place in the
    /// feature where anything is not a plain string comparison.
    static let modelMatchHint = "Off by default. When what you said matches no channel above - or matches two - Kongweh can ask Apple's on-device model which of these channels you meant. It is given only the words you said and the names and aliases on this list, it can only answer with a channel already here or with nothing, and it never leaves this Mac. If it answers with anything else, nothing is opened."

    static let modelMatchDisclosure = "Nothing else about the command reaches a model: the channel IDs, the feed and the video address are never sent anywhere, and with this off no model sees the command at all. Your dictation never reaches it either way - only what you say into the YouTube command shortcut."

    /// The sentence under the list, written around a channel the user actually
    /// has - so the example is something they can say out loud right now.
    ///
    /// It names **both** families of the grammar, because which one a user
    /// reaches for is not predictable: somebody who says "open YouTube channel
    /// …" and is shown only the video wording has no way to tell whether their
    /// phrasing is unsupported or their channel is missing, and the refusal they
    /// get names the channel. Both are listed here for the same reason the
    /// channel-id instruction is: it is the sentence that stops a fixable
    /// problem looking like a broken feature.
    static func usage(exampleChannel name: String) -> String {
        "Say “\(name)” on its own, or a whole sentence - “open the latest YouTube video from \(name)”, “open YouTube channel \(name)”, or in Chinese “播放YouTube最新影片\(name)” or “打開YouTube頻道\(name)”. Only the channels listed here can be opened; anything else does nothing and says so. \(autoplayNote)"
    }
}
