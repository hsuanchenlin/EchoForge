# Install and use Kongweh

This guide is for people who just want to use the app. It covers installing the build
published on this fork, getting past the macOS security warning that build triggers,
dictating Chinese, and the day-to-day basics.

Kongweh is a fork of OpenSuperWhisper, named after Taiwanese *kóng-uē* (講話), "to talk".
The upstream project it came from keeps its own name, and so do this repository's source
directories.

**The app is Kongweh; its files are still named EchoForge.** That is what the app was
called until this release, and the names it stores data under were left alone on purpose,
so an existing install keeps its recordings, personal terms and downloaded models instead
of starting empty. In practice this means the download below is `EchoForge.dmg`, it
installs `EchoForge.app`, and its folder in Application Support is
`com.hsuanchenlin.EchoForge` - while Finder, the Dock and the app itself all say Kongweh.
Nothing is wrong if you see both names.

## What you need

- A Mac with Apple Silicon (M1 or newer).
- macOS 14 (Sonoma) or later.
- Disk space for the speech model you choose: from 240 MB (SenseVoice-Small) to about
  1.6 GB (Whisper V3 Large). Models are downloaded inside the app when you pick them, not
  bundled with it.

Everything runs on your Mac. No audio is sent anywhere.

## Install from this fork's releases

1. Open the [releases page for this fork](https://github.com/hsuanchenlin/EchoForge/releases)
   and download `EchoForge.dmg` from the newest release.
2. Double-click the downloaded `.dmg`. A window opens showing `EchoForge.app`.
3. Drag `EchoForge.app` into your `Applications` folder. Running the app from
   inside the mounted disk image works badly, so move it out first.
4. Eject the disk image (drag it to the Trash, or press ⌘E in Finder).

Builds from the upstream project are a separate thing: they are published on the
[Starmel releases page](https://github.com/Starmel/OpenSuperWhisper/releases) and via
`brew install opensuperwhisper`. Those do not include this fork's changes. Kongweh has
its own application identifier, so it installs next to an upstream OpenSuperWhisper rather
than replacing it, and the two keep separate settings, recordings and downloaded models.

### Coming from an upstream OpenSuperWhisper build

Kongweh is a new application as far as macOS is concerned, and everything the app stores
lives in a folder named after that identity
(`~/Library/Application Support/com.hsuanchenlin.EchoForge/`, where the old build used
`~/Library/Application Support/ru.starmel.OpenSuperWhisper/`). So on first launch you get:

- the welcome screen again, and your settings back at their defaults;
- an empty recordings history and an empty personal terms dictionary;
- no models, so the one you want has to be downloaded once more.

Nothing is deleted - the old app keeps its own folder, and both apps can stay installed.
To carry your recordings, personal terms and downloaded models over instead of starting
fresh, quit both apps and copy the contents of the old folder into the new one, then
relaunch Kongweh. Settings are not in that folder (macOS keeps them per app elsewhere),
so those are worth setting again by hand. macOS also asks for Microphone, Accessibility
and Input Monitoring permission again, because those grants are per app too.

## First launch: getting past Gatekeeper

Builds on this fork are **not signed with an Apple Developer ID and not notarized**.
macOS therefore refuses to open the app on the first try, with a message like
"EchoForge.app is damaged and can't be opened" or "Apple could not verify
Kongweh is free of malware". Nothing is wrong with the download; macOS is
telling you it cannot check who built it.

Use either workaround. You only have to do it once.

### Option 1: right-click to open (no Terminal)

1. Open your `Applications` folder in Finder.
2. Right-click (or Control-click) `EchoForge.app` and choose **Open**.
3. In the dialog that appears, click **Open** again.

Double-clicking the app normally works from then on.

If macOS shows no **Open** button at all, open **System Settings → Privacy & Security**,
scroll to the Security section, and click **Open Anyway** next to the message about
Kongweh. Then use option 2 if it still refuses.

### Option 2: remove the quarantine flag (Terminal)

Open Terminal and run:

```shell
xattr -d com.apple.quarantine /Applications/EchoForge.app
```

If you put the app somewhere other than `/Applications`, use that path instead. Then
open the app normally.

### Permissions the app asks for

On first launch macOS asks for a few permissions, in **System Settings → Privacy & Security**:

- **Microphone** - required, this is what it records.
- **Accessibility** - required to paste the transcription into whatever app you are in.
- **Input Monitoring** - only needed if you choose a single modifier key (for example
  Right ⌥) as your recording shortcut, because macOS needs it to see that key globally.
- **Screen Recording** - only asked the first time you press ⌥S to ask a question about
  what is on your screen ([details](screen-context.md)); ordinary dictation never needs it.

## Basic usage

On first run, the welcome screen asks for your language, a recording shortcut
(⌥ + ~, or a single modifier key such as Right ⌥) and a model to download. After that,
put the cursor where you want the text, hold the shortcut, speak, and release: the app
transcribes and pastes the result for you. If you prefer press-to-start and
press-to-stop instead of holding, turn off **Hold to Record** in **Settings → Shortcuts**.
You can also drag and drop audio files onto the app window to transcribe them, and they
queue up if you drop several. All of the first-run choices can be changed later in
Settings.

## Dictating Chinese

This fork adds two Chinese speech engines that run on your Mac. Both are optional
downloads and neither is installed until you pick it.

| Engine | Download | Good for | Trade-offs |
| --- | --- | --- | --- |
| **SenseVoice-Small** (recommended) | 240 MB | Chinese, and it also handles Cantonese, English, Japanese and Korean | Adds punctuation, and writes spoken numbers as digits: say 三點二十分 and you get 3點20分 |
| **Paraformer-large (zh)** | 653 MB | Slightly more accurate on Mandarin characters | Mandarin only, and produces no punctuation at all |

Both models write **Simplified Chinese (简体字)**, and Kongweh writes the result in
**Traditional Chinese (繁體字)** for you - that is the default for every engine,
including Whisper, which otherwise mixes the two inside one sentence. To keep
Simplified instead, open **Settings → Transcription → Chinese Output Script** and
choose Simplified; the choice applies to whatever you dictate next and never changes
recordings already in History.

It is a setting about how Chinese is written down and nothing else. It does not change
which language is recognised: English dictation stays English, Japanese and Korean are
never touched, and your dictionary entries and voice snippets are inserted exactly as
you typed them.

Paraformer refuses nothing: dictate English to it and the model
answers with garbled fragments, which Kongweh catches - the dictation fails, the
recording is kept, and switching engine and regenerating gets you a real transcript.
Cantonese it cannot catch (that comes back as fluent but wrong Mandarin), so leave
Paraformer selected only while you are dictating Mandarin.

### From the first-run screen

Choose **Chinese** in the language menu at the top of the welcome screen. The two
engines above then appear at the top of the model list, with SenseVoice-Small marked
"Recommended for Chinese". Click one to download it. (If you dictate something else,
these rows stay hidden so you are not offered ~900 MB of Mandarin models you do not
want.)

### From Settings, later

Open **Settings → Model → Speech Recognition Engine** and pick SenseVoice-Small or
Paraformer-large (zh). The same descriptions, caveats and download buttons are there.
Selecting an engine that only speaks Mandarin also moves the transcription language for
you, so the picker never promises something the engine cannot do.

### Switching engine without opening Settings

Once you have more than one engine downloaded, **⌥M** moves to the next one and shows a
pill naming it. It only offers engines that could transcribe your next dictation, so
anything not downloaded is skipped, and so is anything that cannot dictate the language
you are set to - which is why Paraformer is not offered while you are dictating English.
Your cloud provider joins the list once you have set it up in **Settings → Cloud**.
Pressed while you are dictating, it applies once that dictation has finished, so the words
you have already spoken are transcribed by the engine you spoke them to. The shortcut is
configurable in **Settings → Shortcuts → Switch Engine**
([details](engine-shortcut.md)).

### What the first download looks like

Downloading takes as long as your connection needs for 240 MB or 653 MB, and the app shows
the percentage while bytes are moving. After that it spends **about a minute preparing the
model for the Neural Engine**, once. That step reports no percentage - the app says
"Preparing model…" instead of freezing a number - and it only happens the first time.
Installing both engines costs both downloads, 893 MB in total.

None of this blocks you. Your history stays open and searchable throughout, and if you
already had a model working, dictation keeps using it until the new one is ready and then
switches over on its own. Your choice of engine in Settings is not changed by any of that:
what is shown as selected is what you picked, even while something else is doing the
transcribing.

### Dictating before anything is downloaded

Some releases ship with SenseVoice-Small already included, so a brand-new install can
dictate straight away with no download at all. When that is the case the Settings row for
it says so. If your release does not include it, the app downloads it the first time you
need it, exactly as above.

Model licences and attribution for everything the app downloads are listed in
[speech-model-attribution.md](speech-model-attribution.md).

## Rewriting what you dictated into a style

**Settings → Style** can rewrite each dictation into a style before it is pasted:
**Grammar & Polishing**, **Formal Business**, **Concise Summary**, **Bullet Points**, **Casual Chat**,
or **Custom Prompt**, where you write the instruction yourself. It is off until you
turn it on, and it changes nothing else - transcription, the dictionary and Chinese
spacing work exactly as before.

It runs on your Mac using Apple Intelligence, so it needs **macOS 26 or later** on a Mac
that supports Apple Intelligence, with Apple Intelligence switched on in System Settings.
The pane tells you which of those is missing. Nothing is sent anywhere.

The same pane can also let the app you are dictating into pick the style: turn on
**Match the style to the app I dictate into** under the style list, and a chat app gets
**Casual Chat**, a mail client **Formal Business**, code editors and terminals
**Grammar & Polishing** - all changeable, per kind of app or for one app. Apps without a
rule, and this switch while it is off, use the style you chose above. Kongweh only ever
reads the frontmost app's identifier - never window titles, documents or web addresses -
and that identifier never leaves your Mac ([details](app-aware-style.md)).

Two things are worth knowing before you rely on it:

- **Your original is always kept.** The words you actually said stay with the recording.
  Open the row in the history list and choose **Show original** to read or copy them, or
  **Compare** to see what changed, with the dropped words struck through.
- **A rewrite is thrown away rather than trusted.** Before it replaces anything, the app
  checks the rewrite against what you said: same language, same numbers and amounts,
  same currency and percent signs, nothing from your dictionary lost, and a sensible
  length for the style you picked. If any of that fails - or the model is too slow, or
  it declines - you get your transcript exactly as it was transcribed. **Try it** in the
  Style pane shows you the result and, when one is refused, the reason.

## Reading your history

Every entry in the main window carries a label saying which key produced it and what
became of the words - a dictation, a question, a voice edit, a YouTube command that
opened something or did not, including a picker you were shown and closed. A command
that opened nothing shows the reason right under the label - which spelling was heard,
and what to change - and the filter beside the search box narrows the list to one kind
at a time. Entries recorded before this existed say **Older recording**: Kongweh does
not guess what they were.

That is where to look first when a shortcut seemed to do nothing
([details](history-provenance.md), which lists every label).

### Finding an entry

The search box at the top of the window - **⌘F** puts the caret in it - searches your
history, not just the page in front of you. It matches, case-insensitively:

- the words in the transcript, and what the engine heard before post-processing;
- the label on the entry, so typing `voice edit` finds your voice edits and `youtube`
  finds both YouTube outcomes;
- the reason under a command that opened nothing;
- a date, written `2026-09-04` for a day, `2026-09` for a month, `2026` for a year, or
  the way the entry itself prints it (`Sep 4, 2026`).

The kind filter beside it narrows a search rather than replacing it. If nothing matches,
**Clear search** puts everything back.

### Exporting an entry

Hover a finished entry that has words (or right-click it) and choose **Export transcript**
to save it to a file. A normal save panel asks where it goes and, in the **Format** menu
at the bottom of it, what to write:

- **Markdown (.md)** - the default. The details are a short list and the words sit in a
  fenced block, so a dictation containing `#`, `*` or `|` reads back as what you said.
- **Plain Text (.txt)** - the same details and the same words, with no markup, for
  anything that has no Markdown reader.

Kongweh never writes the file anywhere you did not choose, and never sends it anywhere.
The file carries the transcript, when it was recorded, how long it was, which key produced
it, and the original text if post-processing changed it. It carries nothing else: no file
paths, no identifiers.

## Using a cloud provider instead (optional)

Everything above happens on your Mac. If you would rather have your speech transcribed by
a provider - or the spoken "Translate to Spanish" command answered by one - **Settings →
Cloud** is where you say so, using your own API key from OpenAI or any OpenAI-compatible
provider.

It is off. Switching either feature from **On my Mac** to **Cloud** shows a sheet naming
exactly what will be uploaded and where, and nothing changes until you accept it. Your key
goes into your Mac's Keychain, never into Kongweh's settings file. If a cloud dictation
fails - no connection, a refused key, the provider having a bad day - your recording is
kept with the reason on it, so nothing you said is lost.

Style rewriting, the Ask panel and screen questions are never offered a cloud option and
always run on your Mac. [docs/cloud-api.md](cloud-api.md) lists exactly what leaves the
device, when, and where it goes.

## Which version am I running, and updating

**Settings → About** shows the version and build number this copy reports, and its bundle
identifier. It is also the only place that offers to update, and it never does anything on
its own: checking, downloading and installing are three separate things you ask for. There
is no background update check and nothing installs automatically.

When an update is offered you see its release notes and download size first. If you take it,
Kongweh downloads the DMG from this repository's GitHub releases - and only from there -
showing how much of it has arrived, the current speed, and the time remaining. The download
belongs to the app rather than to the pane it started in, so it keeps going while you look
at other Settings tabs, and while Settings is closed. A download that fails, is cancelled,
or is cut short by quitting Kongweh keeps what it got: retrying continues from where it
stopped instead of starting over. Before anything is replaced, Kongweh checks that what
arrived really is Kongweh, really is the version it offered, matches the checksum the
release published (releases since v0.5.2 publish one), and passes signature verification.
Anything that does not check out is discarded with a reason rather than installed.
Installing quits the app, swaps it, and opens it again.

These builds are signed **ad-hoc** and are not notarized (this fork has no Developer ID
certificate), so that signature check proves the download was not modified after it was built,
not who built it. What covers the rest is that the download can only ever come from this
repository's release URLs. You can always skip the in-app path and install the DMG by hand from
the release page instead.

## Trouble

- **"The app is damaged and can't be opened"** - this is the unsigned-build warning.
  See [First launch](#first-launch-getting-past-gatekeeper) above.
- **Nothing gets pasted** - grant Accessibility permission in System Settings, then
  return to Kongweh; it picks up the grant on its own, no restart needed.
- **The shortcut does nothing** - if it is a single modifier key, grant Input Monitoring.
- **Anything else** - open an issue with your macOS version, your Mac model, and what
  you did.

## Building it yourself

If you would rather build from source than download a release, see "Building locally" in
the [README](../Readme.md).
