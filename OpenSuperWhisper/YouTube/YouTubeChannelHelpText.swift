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
enum YouTubeChannelHelpText {

    static let sectionSubtitle = "Say a channel from this list, get its newest video in Chrome."

    static let nameHint = "What you say, and what this row is called. Case, punctuation and Traditional or Simplified script do not have to match."

    static let aliasHint = "Optional, comma separated. Add the spellings your dictation actually produces for this channel."

    static let channelIDInstructions = "On the channel's page in a browser: ⋯ → Share channel → Copy channel ID. Or copy the UC… part of a youtube.com/channel/UC… address - pasting the whole address here works too. A @handle is not a channel ID."

    static let autoplayNote = "Whether the video starts playing on its own is Chrome's autoplay policy, not something this app sets."

    static let emptyState = "Add the channels you actually watch. Saying “open the latest YouTube video from …” opens the newest video from one of them in Chrome, and can never open anything else."

    static let spokenCommandsOffNotice = "This only works while Spoken commands is on, in Shortcuts → Ask & Spoken Commands."

    /// The sentence under the list, written around a channel the user actually
    /// has - so the example is something they can say out loud right now.
    static func usage(exampleChannel name: String) -> String {
        "Say “open the latest YouTube video from \(name)” - in Chinese, “播放YouTube最新影片”, then the same name. Only the channels listed here can be opened; anything else is left alone. \(autoplayNote)"
    }
}
