# Reading History: what each entry was, and what became of it

Every entry in History carries a label saying which key produced it and what the
app did with the words. Some presses type text into whatever you were using,
some open a panel, and one opens a video in Chrome - and until you can tell them
apart, a press that did nothing looks exactly like a press that worked.

The label is the first line of every row. When there is something to say beyond
the label - a video that opened, a command that did not - the sentence is right
underneath it, with no disclosure to open.

## The labels

| Label | What it means |
| --- | --- |
| **Dictation** | The dictation shortcut. The words were typed into whatever app you were in. Spoken translations and voice snippets are dictation too: they are text, and they were inserted. |
| **Ask** | A spoken question that went to the Ask panel (`Ask: …`, `請問…`). Nothing was inserted into your document. |
| **YouTube command - opened** | The YouTube command shortcut, and the channel's newest video opened in Chrome. The sentence names the channel and the video. |
| **YouTube command - not opened** | The YouTube command shortcut, and **nothing was opened**. The sentence says why and what to do about it. |
| **File transcription** | A file you dropped on the window or opened with EchoForge, or a dictation whose audio was queued because the engine was busy with another one. |
| **Older recording** | Made before EchoForge recorded any of this, so the app does not know. It is never guessed at: an entry from before the upgrade says "older recording" rather than being relabelled as something it might not have been. |

Use the filter beside the search box to show one kind at a time. **Not opened**
is the one to reach for after a command that seemed to do nothing; the filter
searches your whole history, not just the entries currently on screen, and
combines with whatever you have typed in the search box.

## Why a command did not open anything

Every one of these leaves an entry with the full sentence under the label. The
short version and what to do:

| What the entry says | What happened | What to do |
| --- | --- | --- |
| No allowlisted YouTube channel answers to "…" | The name in quotes is exactly what the app heard. It is not one of your stored spellings. If you said a command phrase with no channel behind it - "open the YouTube channel" and nothing else - the whole phrase is what gets quoted back, which is how you can tell. | Add that spelling as a **spoken name** on the channel you meant, in Settings → Dictionary & Snippets → YouTube Channels. See below. |
| No channel name was heard | The press produced nothing usable to read as a channel name at all. | Hold the shortcut, say the channel name, let go. |
| "…" answers for more than one channel | Two rows in your list answer to the same spoken name, so neither can be the one you meant. | Give them different spoken names. |
| The YouTube command is switched off | The shortcut is still bound so a press can tell you this instead of doing nothing. | Turn it on in Settings → Dictionary & Snippets → YouTube Channels. |
| "…" has no usable channel ID | The row is stored with something that is not a `UC…` id - a `@handle`, usually. | Fix the id. The Settings pane says how to find it. |
| Could not reach YouTube / YouTube answered with HTTP … | The channel feed lookup failed. Nothing was opened, and nothing was fetched more than once. | Check your connection, or check the channel id. |
| That channel's feed … | The feed arrived and carried nothing that could be opened - no videos, or no video link this app will follow. | Nothing to do; that channel has published nothing openable. |
| Google Chrome was not found / could not open | The video was found and Chrome would not take it. | Install Chrome, or open the video yourself. |
| The transcription engine was busy | The audio was queued as a plain transcription, so the command never ran at all. | Try the shortcut again once the queue is clear. |
| This command could not be transcribed | There were never any words to read as a channel name. | The sentence carries the engine's own reason. |
| This command had not finished | EchoForge quit or was interrupted between hearing the words and finishing the command. | Try it again. |
| This recording was transcribed again from History | You pressed the row's Regenerate transcription button. The label and the outcome stay what that press actually did, but the old sentence quoted the old transcript, so it is replaced. Regenerating never re-runs the command. | Press the YouTube command shortcut to run the command again. |

### "It heard the name wrong"

This is the common one, and the entry is what makes it fixable: the name in
quotes is what the speech engine actually wrote. A stored `valley101` is matched
case-insensitively and with spacing ignored, so "Valley 101" and "valley101"
both reach it - but "Vali101" is a different name, and EchoForge will not guess
that one name means another. That refusal is deliberate: a near miss that opened
*something* would be the app choosing a channel you did not.

The fix takes one paste. Copy the spelling out of the History entry and add it as
a spoken name (an alias) on that channel in Settings. From then on both
spellings reach it.

If you would rather not collect spellings by hand, there is an off-by-default
on-device matcher in the same pane that can pick between channels you have
*already stored* when your spelling does not match one exactly. When it is off,
or when it ran and could not help, the History entry says so - so you never have
to wonder whether it was going to save you.

## What History does not contain

The sentence under a label is written for you and holds nothing else. It names
the channel the way *your own list* names it, and never a channel ID, a feed
address, a video URL, or anything from your Keychain. Nothing in History leaves
your Mac.

## Related

- `docs/youtube-latest-video.md` - the command itself: the shortcut, the
  grammar, the allowlist and the safety rules.
- `docs/ask-panel.md` - the Ask panel.
- `docs/spoken-intents.md` - what else a dictation can be.
