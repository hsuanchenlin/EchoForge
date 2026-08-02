# Install and use EchoForge

This guide is for people who just want to use the app. It covers installing the build
published on this fork, getting past the macOS security warning that build triggers,
dictating Chinese, and the day-to-day basics.

EchoForge is a renamed fork of OpenSuperWhisper. The GitHub repository is still called
OpenSuperWhisper, and releases 0.2.0 and earlier were published under that name; the app
itself is EchoForge from here on.

## What you need

- A Mac with Apple Silicon (M1 or newer).
- macOS 14 (Sonoma) or later.
- Disk space for the speech model you choose: from 240 MB (SenseVoice-Small) to about
  1.6 GB (Whisper V3 Large). Models are downloaded inside the app when you pick them, not
  bundled with it.

Everything runs on your Mac. No audio is sent anywhere.

## Install from this fork's releases

1. Open the [releases page for this fork](https://github.com/hsuanchenlin/OpenSuperWhisper/releases)
   and download `EchoForge.dmg` from the newest release (releases 0.2.0 and earlier ship
   `OpenSuperWhisper.dmg` instead - same app, older name).
2. Double-click the downloaded `.dmg`. A window opens showing `EchoForge.app`.
3. Drag `EchoForge.app` into your `Applications` folder. Running the app from
   inside the mounted disk image works badly, so move it out first.
4. Eject the disk image (drag it to the Trash, or press ⌘E in Finder).

Builds from the upstream project are a separate thing: they are published on the
[Starmel releases page](https://github.com/Starmel/OpenSuperWhisper/releases) and via
`brew install opensuperwhisper`. Those do not include this fork's changes. EchoForge has
its own application identifier, so it installs next to an upstream OpenSuperWhisper rather
than replacing it, and the two keep separate settings, recordings and downloaded models.

### Coming from an OpenSuperWhisper build (0.2.0 or earlier)

EchoForge is a new application as far as macOS is concerned, and everything the app stores
lives in a folder named after that identity
(`~/Library/Application Support/com.hsuanchenlin.EchoForge/`, where the old build used
`~/Library/Application Support/ru.starmel.OpenSuperWhisper/`). So on first launch you get:

- the welcome screen again, and your settings back at their defaults;
- an empty recordings history and an empty personal terms dictionary;
- no models, so the one you want has to be downloaded once more.

Nothing is deleted - the old app keeps its own folder, and both apps can stay installed.
To carry your recordings, personal terms and downloaded models over instead of starting
fresh, quit both apps and copy the contents of the old folder into the new one, then
relaunch EchoForge. Settings are not in that folder (macOS keeps them per app elsewhere),
so those are worth setting again by hand. macOS also asks for Microphone, Accessibility
and Input Monitoring permission again, because those grants are per app too.

## First launch: getting past Gatekeeper

Builds on this fork are **not signed with an Apple Developer ID and not notarized**.
macOS therefore refuses to open the app on the first try, with a message like
"EchoForge.app is damaged and can't be opened" or "Apple could not verify
EchoForge is free of malware". Nothing is wrong with the download; macOS is
telling you it cannot check who built it.

Use either workaround. You only have to do it once.

### Option 1: right-click to open (no Terminal)

1. Open your `Applications` folder in Finder.
2. Right-click (or Control-click) `EchoForge.app` and choose **Open**.
3. In the dialog that appears, click **Open** again.

Double-clicking the app normally works from then on.

If macOS shows no **Open** button at all, open **System Settings → Privacy & Security**,
scroll to the Security section, and click **Open Anyway** next to the message about
EchoForge. Then use option 2 if it still refuses.

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
| **SenseVoice-Small** (recommended) | 240 MB | Chinese, and it also handles Cantonese, English, Japanese and Korean | Adds punctuation, and writes spoken numbers as digits: say 三點二十分 and you get 3点20分 |
| **Paraformer-large (zh)** | 653 MB | Slightly more accurate on Mandarin characters | Mandarin only, and produces no punctuation at all |

Both write **Simplified Chinese (簡體字)**, and the app does not convert the result to
Traditional (繁體字). Paraformer does not refuse other languages, it mis-transcribes
them, so leave it selected only while you are dictating Mandarin.

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

### What the first download looks like

Downloading takes as long as your connection needs for 240 MB or 653 MB. After that the
app spends **about a minute preparing the model for the Neural Engine**, once, before
your first dictation. The app has not hung; that step is invisible work and only happens
the first time. Installing both engines costs both downloads, 893 MB in total.

Model licences and attribution for everything the app downloads are listed in
[speech-model-attribution.md](speech-model-attribution.md).

## Trouble

- **"The app is damaged and can't be opened"** - this is the unsigned-build warning.
  See [First launch](#first-launch-getting-past-gatekeeper) above.
- **Nothing gets pasted** - grant Accessibility permission, then restart the app.
- **The shortcut does nothing** - if it is a single modifier key, grant Input Monitoring.
- **Anything else** - open an issue with your macOS version, your Mac model, and what
  you did.

## Building it yourself

If you would rather build from source than download a release, see "Building locally" in
the [README](../Readme.md).
