# Opening a channel's latest video by voice

One shortcut of its own - **⌥Y by default** - records a command and nothing
else: hold it, say **"Veritasium"** (or a whole sentence - "open the latest
YouTube video from Veritasium", "open YouTube channel Veritasium"), let go, and
that channel's newest video opens in a new Chrome tab. It reaches exactly the channels the user typed into Settings
themselves and can reach nothing else.

The list lives in `Settings → Dictionary & Snippets → YouTube Channels`, with the
feature's own switch beside it; the key is bound in `Settings → Shortcuts →
YouTube Command`.

## Two keys, and why

This used to ride on the dictation shortcut as a fourth spoken command, matched
off a long marker phrase. It does not any more, and the separation is the
feature's safety story rather than an ergonomic preference:

- **The dictation key produces text and only text.** `SpokenIntentRouter` has no
  case that opens anything - the enum literally does not have one - so no
  transcript that key captured can reach a browser however it is worded. Saying
  "open the latest YouTube video from Veritasium" into it types those words, the
  way it did before this feature existed.
- **The command key produces no text at all.** Its capture is read only as a
  channel name (`YouTubeCommandRouter`), it never reaches the rewriting stage,
  the Ask panel, the snippet expander or the translator, and there is no path
  from it back into the user's document. `SpokenIntentOutcome.insertsText` is
  false for it and `IndicatorViewModel` refuses to paste on that purpose besides.

`DictationPurpose` is where that split is written down, and it is carried on
`Settings` rather than read from preferences, so the decision belongs to the
press that captured the words. Everything else in the app - a dropped file, a
queued recording, a regenerate from history, the Ask panel's own follow-up - is
`.dictation` and cannot become anything else.

Because the key already says what the utterance is for, **the marker is
optional**: saying the channel name on its own is the whole command. A marker is
still accepted and stripped, in English and Chinese, whether it names the video
("open the latest YouTube video from …") or the channel ("open YouTube channel
…"), so an existing habit keeps working - and a habit the grammar has not been
taught does not silently become an unknown channel. See "The grammar" below.

## What it is not

Everything this feature deliberately cannot do, because each one was a way it
could have been built:

- **No dictation can trigger it.** See above. This is the rule the whole shape
  exists for, and `YouTubeCommandRouterTests` asserts it against every wording.
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
- **No model decides what happens.** One optional, off-by-default step lets the
  on-device model *choose between rows the user already stored* - see the model
  fallback below. It cannot produce anything that was not already in the list.

## The path

```
⌥Y pressed ──► IndicatorWindowManager.prepare(purpose: .youTubeCommand)
     │
     ▼
recording, transcription, TextPostProcessor.process()   as any dictation
     │
     ▼
SpokenIntentPipeline.apply()          purpose == .youTubeCommand leaves here
     │                                before any dictation stage runs
     ▼
YouTubeCommandRouter.resolve          optional marker stripped, the rest is
     │                                the channel name
     ▼
YouTubeChannelAllowlist.resolve       tier 1 exact, tier 2 spacing-insensitive
     │
     ├── .unknown / .ambiguous ─┐
     │                          ▼
     │            YouTubeChannelModelMatch.refine    off by default; may only
     │                          │                    pick a row already listed
     ├──────────────────────────┘
     │
     ├── still .unknown / .ambiguous / .disabled ──► nothing happens, and they
     │                                               are told why
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

## Matching a spoken name

`YouTubeChannelAllowlist.resolve` is a pure function over the user's list, and it
answers in two deterministic tiers before anything else is considered. A spoken
name has to match one stored name **in full** in whichever tier answers: nothing
is stemmed, nothing truncated, nothing partial.

1. **The stored spelling**, as `YouTubeChannelAlias.normalize` writes it: case,
   edge punctuation, doubled-up whitespace and Traditional against Simplified
   script folded away, because a speech engine varies all of them on its own.
2. **The same comparison with internal spaces folded away too**
   (`YouTubeChannelAlias.compact`), so a stored `valley101` answers to
   "valley 101" and a stored `小Lin說` to "小 Lin 說". Where a space falls inside
   a name is the one variation a speaker cannot control - they say "valley one oh
   one" and the engine writes it one way today and the other tomorrow - which is
   what makes this safe where stemming would not be. `valley`, `valley 10` and
   `valley 1012` still reach nothing.

**Ambiguity is detected in each tier separately and separately refused**, so
widening the comparison can never quietly pick a winner. Two rows sharing a
spoken name exactly are refused at tier 1 as they always were; two rows differing
only in spacing - `valley101` and `valley 101` - each still resolve from their
own exact spelling at tier 1, so Settings has no reason to refuse the pair, and
only a third spelling matching both compactly is refused as ambiguous.

The resolution carries **how** it was matched (`YouTubeChannelMatchSource`),
which is what lets the one case a model took part in say so out loud.

## The model fallback

`YouTubeChannelModelMatch` is the last resort when both tiers came back unknown
or ambiguous. It is **off by default** (`youTubeChannelModelMatchEnabled`), and
the Settings pane says what it does before it is switched on.

- **It runs last and only on a failure.** A resolved channel is never re-asked,
  so a user whose spellings match pays nothing and waits for nothing.
- **The model is a chooser, never a resolver.** It is given the spoken phrase
  (fenced as content in `StyleRewritePrompt`'s delimiters, the way a transcript
  is) and a numbered list of the display names and aliases already stored -
  **no channel ids, no URLs, no hosts**, which `YouTubeChannelModelMatchTests`
  asserts against the prompt. Its answer is looked up in that same candidate
  list, so a name it invented, a `UC…` id, a URL or an instruction matches
  nothing. There is no code path from its answer to a value that was not already
  in the list.
- **It fails closed.** No model on this Mac, Apple Intelligence off, the model
  still downloading, a timeout, an error, an answer that is not a candidate, an
  answer two candidates answer to, a list longer than `maximumCandidates`, an
  utterance longer than `maximumSpokenCharacters` - every one of them leaves the
  original resolution untouched, which is the resolution that opens nothing and
  tells the user why.
- **It never leaves this Mac.** `OnDeviceModelFeature.channelMatching` returns
  `nil` for `cloudFeature`, the same enforcement `docs/cloud-api.md` describes
  for rewriting and the Ask panel. Translation remains the only feature with a
  cloud path.
- **It is disclosed when it is used, and when it was not.**
  `YouTubeChannelMatchSource.model` carries the phrase it was given, and the
  opened report's sentence says the on-device model made the match - in the log,
  in the VoiceOver announcement and in History. The other four outcomes are
  disclosed too (`YouTubeChannelModelMatchAttempt`): off, could not run, asked
  and gave nothing, or never needed. All of them leave the same refusal behind,
  which is correct and, on its own, invisible - "no channel answers to that"
  reads identically whichever it was - so History says which. It is a report and
  never an input: nothing branches on it, and no value of it can turn a refusal
  into an opened video.

Reading the answer (`interpret`) is deliberately strict: a 1-based index, or
`NONE`, or one candidate's own stored spelling. Anything with a sentence around
it is refused. The index is read off the raw answer rather than the name key,
because that key folds edge punctuation and would turn `-1` into `1`.

## The grammar

| Said into ⌥Y | Becomes |
| --- | --- |
| `[channel]` | that channel, if the list has exactly one answering to it |
| `Open the latest YouTube video from [channel]` (also `newest`, `play`, `open latest`, `open YouTube latest video from`) | the same |
| `Open the YouTube channel [channel]` (also `play`, and without `the`) | the same |
| `打開YouTube最新影片[頻道]` (also `打开…最新视频`, `播放…`, `開啟…`, with or without spaces) | the same |
| `打開YouTube頻道[頻道]` (also `打开…频道`, `播放…`, `開啟…`) | the same |
| a marker with nothing behind it | nothing opens; the utterance is quoted back |
| anything the list does not answer to | nothing opens; the user is told |

The markers come in two families - one naming the **video**, one naming the
**channel** - because both are what people say, and a phrasing the table does not
know is not a near miss: with no marker matched the whole sentence becomes the
spoken name, so "open YouTube channel Valley 101" asked the allowlist for a
channel by that entire name and was refused as one that is not in the list. That
refusal names the allowlist, which is the one thing that was right, so the
missing family cost a user four attempts before it was found.

Widening the marker table is not widening the match. What follows a marker still
has to be one stored spelling **in full**, through the same two tiers below:
`open YouTube channel Valley` and `open YouTube channel Bali 101` still reach
nothing.

The Chinese markers are matched with whitespace ignored on both sides, because a
transcript writes "打開 YouTube 最新影片" or "打開YouTube最新影片" for the same
words depending on the engine. Every CJK spelling is listed in both scripts,
including 頻道 beside 频道, for the reason `SpokenIntentGrammar` records: the
transcript has already been written in the user's own script.

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
- a spoken name - display name or alias - that another row already answers to
  **exactly**, since a name two rows answer to at tier 1 is a name neither can be
  opened by. Two rows that differ only in spacing are not refused: each keeps its
  own exact spelling, and the pair only collides on a third spelling, which the
  ambiguity rule handles.

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
`YouTubeFeedError`, `BrowserOpenError`). **Three** surfaces carry them, and the
third is the one that is still there tomorrow:

- the dictation overlay shows the few words it has room for, for two seconds;
- the whole sentence is posted as a VoiceOver announcement
  (`YouTubeCommandAccessibility`) and printed to the log - the same division the
  engine and cloud failures make;
- and it is **written into History**, on the recording the command was spoken
  into, as `RecordingProvenance` - the label, the class
  (`YouTubeCommandRefusal`) and the sentence.

That third one exists because the first two reach nobody after the fact. `print`
goes to a stdout a shipped app does not have, the overlay is gone in two seconds
while the user is looking at another app, and the announcement reaches nobody
with VoiceOver off - so a command that opened nothing left a history row
indistinguishable from a dictation, and four different causes were one symptom.
`docs/history-provenance.md` is the whole story, including which class each
failure below is filed as.

`YouTubeLatestVideoReport.refusal(for:)` is the pure half of the table: every
resolution that is not `.allowlisted` is already decided before anything is
fetched, so History records the right answer the instant the words are stored
rather than after a round trip that was never going to happen. An allowlisted
channel is stored as *not opened* until the report replaces it, so a quit or a
crash mid-command leaves a row saying nothing was opened - which is true.

| What happened | What the user is told |
| --- | --- |
| The feature is switched off | That it is off, and where to turn it on |
| The channel is not in the list | Which name was heard, and where to add it |
| Two rows answer to that name | Which rows, and to give them different names |
| Offline, DNS, a timeout | The lookup did not happen; nothing was opened |
| YouTube answered with a status | The status, and to check the id |
| The feed lists no videos | That channel has published nothing |
| The feed could not be read, or declared entities | It could not be read |
| Every entry pointed off YouTube | No video link, and nothing opened |
| Chrome is not installed | To install it, or open the video themselves |

The command key stays bound while the feature is off, so a press says what is
wrong rather than doing nothing at all - which is the one answer a user cannot
act on. The recording is stored in history either way, labelled with what became
of it, so both the words and the answer survive whatever happened next. Nothing
is ever inserted into the app the user was typing in: the transcript was an
instruction, not text.

Two presses never reach the command at all and are recorded as their own
refusals rather than as ordinary transcriptions: one made while the engine was
busy with another transcription, which the queue transcribes as plain text
without routing anything (`.engineBusy`), and one the engine could not
transcribe (`.notTranscribed`).

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

`YouTubeCommandRouterTests` (the command grammar, the bare channel name, and -
the half that matters more - that no wording of a dictation can become this
command), `YouTubeChannelAllowlistTests` (both tiers, the ambiguity rules, the
validation refusals and the Settings copy), `YouTubeChannelModelMatchTests`
(every fail-closed path, what the prompt is allowed to contain, and the
disclosure), `SpokenIntentPipelineTests` (which purpose can reach a channel at
all), `YouTubeChannelStoreTests` (what is stored, and the switches in front of
it), `YouTubeFeedParserTests` (newest-entry selection, empty, malformed and
hostile feeds), `YouTubeVideoURLTests` (every URL that is refused) and
`YouTubeLatestVideoServiceTests` (the whole command against a stub feed and a
mock browser, including offline and a missing Chrome).
`YouTubeCommandHistoryRegressionTests` is the one that holds the whole thing
together in the configuration it actually failed in: which spellings reach a
stored `valley101`, which correctly reach nothing, what History records for each
outcome, and that the same words through the dictation key are still only text.
None of them reach the network, none of them reach a model, and none of them
open anything.
