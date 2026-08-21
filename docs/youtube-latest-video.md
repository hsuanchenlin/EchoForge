# Opening a channel's latest video by voice

One spoken command: **"open the latest YouTube video from Veritasium"** opens
that channel's newest video in a new Chrome tab. It reaches exactly the channels
the user typed into Settings themselves and can reach nothing else.

It rides on spoken commands, which are off by default
(`Settings → Shortcuts → Ask & Spoken Commands → Spoken commands`), and has its
own switch beside the channel list in `Settings → Dictionary & Snippets →
YouTube Channels`. `docs/spoken-intents.md` is the router's own story; this file
is the command's.

## What it is not

Everything this feature deliberately cannot do, because each one was a way it
could have been built:

- **No model decides anything.** The grammar is a table of prefixes in
  `SpokenIntentGrammar.openLatestVideoMarkers`, matched by `SpokenIntentRouter`.
  Nothing is classified, summarised or interpreted, on-device or in the cloud.
- **No search and no handle resolution.** A channel is named by its canonical
  `UC…` id, which the user supplies. There is no step that asks YouTube who a
  spoken name means, so no spoken name can reach a channel that is not listed.
- **No arbitrary URL, app or command.** The only request this feature makes is
  the documented channel feed; the only thing it opens is a validated
  `youtube.com` / `youtu.be` video URL; the only application it opens it with is
  Google Chrome. There is no shell, no `osascript`, no AppleScript, and no
  string that becomes a command line.
- **No browser automation.** `NSWorkspace.open(_:withApplicationAt:configuration:)`
  hands one URL to Chrome - the same thing clicking a link does. Existing tabs
  are not read, closed, reordered or navigated; nothing is injected into a page;
  nothing scrapes YouTube; nothing logs in. The feed request carries no cookies
  and creates no session.
- **No autoplay tricks.** Whether the video starts on its own, and whether it
  starts muted, is Chrome's autoplay policy and YouTube's. Nothing here tries to
  influence either, and the Settings pane says so.

## The path

```
transcript (deterministic stages already run)
     │
     ▼
SpokenIntentRouter                     marker table, pure string matching
     │  names YouTube, ends in the channel the user said
     ▼
YouTubeChannelAllowlist.resolve        the user's own list, exact match
     │
     ├── .unknown / .ambiguous ──────► nothing happens, and they are told
     ▼
YouTubeFeedEndpoint.url                https://www.youtube.com/feeds/videos.xml
     │                                 ?channel_id=UC…
     ▼
YouTubeFeedFetcher                     ephemeral, cookie-less URLSession
     ▼
YouTubeFeedParser.newestVideo          entity declarations refused, bounded
     ▼
YouTubeVideoURL.validate               HTTPS, allow-listed host, video id
     ▼
ChromeBrowserOpener.openInNewTab       one URL, handed to Chrome
```

## The grammar

| Said | Becomes |
| --- | --- |
| `Open the latest YouTube video from [channel]` (also `newest`, `play`, `open latest`, `open YouTube latest video from`) | `.openLatestVideo(resolution)` |
| `打開YouTube最新影片[頻道]` (also `打开…最新视频`, `播放…`, `開啟…`, with or without spaces) | `.openLatestVideo(resolution)` |
| anything else | `.dictate` - the transcript, byte for byte |

Every spelling names YouTube, and that is load-bearing. It is what keeps the
grammar away from sentences people actually dictate, and it is why this is the
**one** command whose failures are reported rather than falling back to
dictation: a transcript that opens "open the latest YouTube video from …" is not
a sentence somebody was writing, so pasting it would be no better an answer than
saying the channel is not in the list. "Open the latest video from Veritasium",
with no `YouTube` in it, stays dictation.

What follows the marker has to name one channel **in full** - the same rule a
voice snippet trigger and a spoken language name follow. "Veritasium please"
names no channel. Case, surrounding punctuation, doubled-up whitespace and
Traditional against Simplified script are folded away
(`YouTubeChannelAlias.normalize`), because a speech engine varies all of them on
its own. Where a space falls inside a name is not: "小 Lin 說" does not match a
stored "小Lin說", and an alias is how the user records the spelling their engine
actually writes.

The Chinese markers are matched with whitespace ignored on both sides, because a
transcript writes "打開 YouTube 最新影片" or "打開YouTube最新影片" for the same
words depending on the engine.

## The allowlist

`YouTubeChannel` is one row: a display name, any number of spoken aliases, the
canonical `UC…` id, and an enabled flag. `YouTubeChannelStore` stores the list as
JSON in the defaults domain - not a second `terms.json`, because a channel id is
copied out of a browser rather than maintained by hand.

Settings refuses, locally and with a reason
(`YouTubeChannelAllowlist.problems(with:against:)`):

- a row with no name to say;
- an id that is not `UC` plus 22 characters of the URL-safe alphabet - a
  `@handle` is not a channel id, and this app has no way to turn one into one;
- a second row with an id another row already has;
- a spoken name - display name or alias - that another row already answers to,
  since a name two rows answer to is a name neither can be opened by.

Aliases are trimmed and deduplicated on the way in, including against the
display name. A pasted `youtube.com/channel/UC…` address is accepted in the id
field and trimmed down to the id, because it already *is* the id with scenery
around it; a handle URL is not, because it is not.

**How a user finds the id:** on the channel's page, ⋯ → *Share channel* → *Copy
channel ID*; or open its about page and copy the `UC…` part of a
`youtube.com/channel/UC…` address. The Settings pane says this beside the field.

## Failures

Nothing is opened unless the whole path succeeded, and every failure has a
sentence naming what to do about it (`YouTubeLatestVideoReport`,
`YouTubeFeedError`, `BrowserOpenError`). Two surfaces carry them: the dictation
overlay shows the few words it has room for, and the whole sentence is posted as
a VoiceOver announcement (`YouTubeCommandAccessibility`) and printed to the log -
the same division the engine and cloud failures make.

| What happened | What the user is told |
| --- | --- |
| The channel is not in the list | Which name was heard, and where to add it |
| Two rows answer to that name | Which rows, and to give them different names |
| Offline, DNS, a timeout | The lookup did not happen; nothing was opened |
| YouTube answered with a status | The status, and to check the id |
| The feed lists no videos | That channel has published nothing |
| The feed could not be read, or declared entities | It could not be read |
| Every entry pointed off YouTube | No video link, and nothing opened |
| Chrome is not installed | To install it, or open the video themselves |

The recording is stored in history either way, so the words survive whatever
happened next. Nothing is ever inserted into the app the user was typing in: the
transcript was an instruction, not text.

## Hostile feeds

The parser is written to refuse rather than to cope, because the bytes come off
the network and the last step is opening something in a browser.

- **Entity declarations are refused outright** - internal, external or unparsed.
  A channel feed declares none, so a document that does is either not this feed
  or is an attack on the parser (billion laughs, XXE), and both get the same
  answer. External entity resolution is off as well.
- **Bounded**: a megabyte of feed, a hundred entries, four thousand characters of
  any one value.
- **Nothing is repaired.** An entry whose `<link rel="alternate">` is not a valid
  YouTube video URL is dropped - never rebuilt from the `yt:videoId` sitting
  beside it. Guessing a URL out of a document that just failed its own check is
  how the wrong page gets opened. If no entry survives, nothing is opened.
- **The newest is the largest `published`**, not the first entry: the feed
  happens to arrive newest-first and depending on that would make the answer
  depend on YouTube's ordering rather than on the dates it states. Entries with
  no readable date are used only when no entry has one.

`YouTubeVideoURL.validate` is the last check, and `ChromeBrowserOpener` repeats
it: HTTPS only, no credentials, no port, an exactly-matched host from
`YouTubeVideoURL.allowedHosts`, and a video id of the right shape. What is opened
is the canonical watch URL rebuilt from the id that was checked, so a fragment or
a tracking parameter that came with the link does not travel with it. Redirects
on the feed request are followed only while they stay on YouTube's own hosts, the
same rule `UpdateManifest.isAllowedRedirectHost` applies to a download.

## Tests

`SpokenIntentRouterYouTubeTests` (grammar, aliases, and everything that stays
dictation), `YouTubeChannelAllowlistTests` (resolution and the validation
refusals), `YouTubeChannelStoreTests` (what is stored, and the two switches in
front of it), `YouTubeFeedParserTests` (newest-entry selection, empty, malformed
and hostile feeds), `YouTubeVideoURLTests` (every URL that is refused) and
`YouTubeLatestVideoServiceTests` (the whole command against a stub feed and a
mock browser, including offline and a missing Chrome). None of them reach the
network, and none of them open anything.
