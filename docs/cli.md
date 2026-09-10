# `echoforge` - the command-line tool

A local control and inspection surface for Kongweh: start it, see what it is
doing, read your own history and settings, and update it, from a terminal or a
script.

It is **local-first, like the app**. Five of the eight commands only read;
`start` launches the app, `transcribe` hands it a file, and `update install` can
replace it. Nothing reaches the network except the update check and install,
which use the app's own updater. There is no server, no daemon, no telemetry, no
second copy of the recordings database - and no second copy of a speech model.

---

## Build and install

The tool is a target in the app's own Xcode project, so it needs the same
submodules and toolchain the app does:

```sh
git submodule update --init --recursive
```

Build it on its own:

```sh
xcodebuild -scheme echoforge -configuration Release \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages build
```

`./run.sh build` also builds it, because it is in the `OpenSuperWhisper`
scheme - so CI compiles it on every pull request and a change that breaks it
fails there rather than later.

Put it on your `PATH`:

```sh
sudo cp build/Build/Products/Release/echoforge /usr/local/bin/echoforge
echoforge --version
```

The tool is **not** shipped inside `EchoForge.dmg`. The release artifact is the
app and nothing else (`Scripts/build_release.sh`), and adding a second product
to it would change what `Scripts/verify_release_package.sh` verifies. Build it
from the repository.

---

## Which app it acts on

Resolution is fixed and documented rather than clever, because a command that
updates an application has to be certain which application it is about to
replace:

1. `--app <absolute-path>`, when given.
2. `/Applications/EchoForge.app`
3. `~/Applications/EchoForge.app`

The first one that exists wins. LaunchServices is deliberately **not** asked
"where is the app with this bundle identifier" - it answers with whichever copy
it saw last, including one in `~/Downloads` or inside a mounted disk image, so
the same command would resolve differently on two Macs and differently on one
Mac over time.

The bundle on disk is called `EchoForge.app` even though the product is called
Kongweh; that split is the release identity, and the naming section of
`AGENTS.md` says why.

`--app` is for a build you have not installed yet. Three rules apply to it:

- it must be an **absolute** path, so it cannot resolve against whatever
  directory a script happened to be in;
- the bundle must identify itself as `com.hsuanchenlin.EchoForge`, so pointing
  it at another application cannot report that application's version as
  Kongweh's, nor have an update installed over it;
- `start` still refuses while any copy is running, because macOS activates a
  running copy rather than starting a second one - so a test copy would silently
  bring the installed one forward.

---

## Commands

Every command takes `--help` and `--json`. Results go to **stdout**; errors,
progress and notes go to **stderr**, so `--json | jq` always gets a document and
nothing else.

### `echoforge version`

```
$ echoforge version
Kongweh 0.9.4 (34)
  app: /Applications/EchoForge.app
  cli: 0.9.5 (35)
```

Both numbers, because they are routinely different - the app was installed
months ago, the tool was built from today's checkout. The app's version is read
from the bundle's own `Info.plist` and from nowhere else: never from the
repository, never from a cache, never from what the updater last installed.

Exits `3` when no app is installed.

### `echoforge start`

```
$ echoforge start
Started Kongweh 0.9.4 from /Applications/EchoForge.app.

$ echoforge start
Kongweh is already running (pid 4050) from /Applications/EchoForge.app.
```

Uses `NSWorkspace.openApplication`, the macOS-native launch, and waits for the
answer. Never starts a second copy: two Kongwehs share one microphone, one set
of global shortcuts and one database. Already running is exit `0`, not a
failure.

### `echoforge status`

```
$ echoforge status
app       0.9.4 (34)  /Applications/EchoForge.app
process   running, pid 4050, since 9/2/26, 11:05 PM
recording unavailable - live capture state exists only inside the running app, …
activity  226 recordings, 0 still in flight in the newest 1000
engine    selected whisper, language auto
models    whisper 1 (ggml-large-v3-turbo.bin); on-device engines 4 (…)
```

Every section says whether it could be read. **"Unavailable" is never reported
as "false"**: an unreadable model directory does not become "no models", and a
database that does not exist yet does not become "no dictations".

**Known limitation - live recording state.** Whether the microphone is open at
this instant lives only in a `@Published` property inside the running process.
Kongweh has no IPC server, no status file and no application log, so there is
nothing to read it from, and answering it would mean adding a
permanently-listening local surface to an app whose whole design is that it does
not have one. `status` reports the durable half instead - what the app has
actually written down - and says so in both renderings rather than approximating
it.

`activity` is that durable half: the recordings the app has stored, and how many
of them are still `pending`, `converting` or `transcribing`. A row sitting in
`transcribing` while the app is not running is worth seeing.

### `echoforge transcribe`

```
$ echoforge transcribe ~/Recordings/interview.m4a
So the first thing we should talk about is the migration…

$ echoforge transcribe meeting.wav --json | jq -r .transcript
$ for f in *.m4a; do echoforge transcribe "$f" > "${f%.m4a}.txt"; done
```

**The tool does not load a model.** It hands the file to Kongweh exactly as the
Finder's "Open With" does - starting it if it is not running - and then watches
the recordings database, read-only as always, until the row the app wrote for
that file settles. So everything the app does to a dropped file happens here
too: the engine you selected, your personal terms, your Chinese output script,
your rewriting style, and a row in History like any other file you drop.

That is a design decision, and not one about binary size. The app is the single
owner of the microphone, the model cache and the recordings database
(`AGENTS.md`). A tool that loaded its own model would be a second process holding
the same 200 MB of weights, competing for the Neural Engine with the app that is
dictating; a tool that wrote its own rows would be a second writer to a database
exactly one thing is allowed to migrate. Handing the file over adds neither - and
it is the only design in which `echoforge transcribe` and a file dragged onto the
window cannot produce different text.

The consequences are worth being plain about:

- **Kongweh has to be installed**, and it is started if it is not running. Exit
  `3` when there is no app to hand the file to.
- **There is no `--engine` and no `--language`.** The app owns those preferences
  and this tool never writes one. Change them in Settings, or with
  `echoforge settings` to see what they currently are.
- **The file is checked before anything is started**: it has to exist and to
  carry an audio extension, so a text file cannot leave a row in your History for
  something that was never a recording. Exit `4` for a missing file, `2` for one
  that is not audio.
- **One file at a time.** Loop in the shell; the app's queue handles the rest.
- `--timeout` defaults to 600 s and may not exceed 7200 s. A first transcription
  can include a model download and a Neural Engine compile, so the default is
  generous. Timing out exits `1` and says the app is **still working** - the
  transcript still lands in History, because nothing was cancelled.
- A transcription the app failed exits `1` and prints the app's own sentence.

`--json` carries the transcript, the engine's own words when post-processing
changed them (`originalTranscript`, null when it did not - the same rule
`history --json` follows), the status, the duration, the row id and the
provenance kind.

### `echoforge history`

```
$ echoforge history --limit 5
2026-09-06 09:31  Dictation   這個蛋糕感覺要用手吃
2026-09-04 23:43  Dictation   好那你幫我下載全部論文然後也是匯入 Zotero…

Showing 5 of 226. Use --limit for more.

$ echoforge history --query "voice edit" --limit 3
$ echoforge history --json | jq '.recordings[0].transcript'
```

- Read-only. The database is opened read-only and the migrator never runs: the
  app is the only thing that migrates and writes. No delete, no regenerate, no
  re-transcription, no network.
- `--query` runs Kongweh's own History search (`HistorySearchQuery`,
  `RecordingSchema.query`), so it is case-insensitive over the transcript, the
  original a rewrite kept and the sentence under the badge, and it also matches
  the badge's *label* ("voice edit" finds a `selectionEdit` row) and dates the
  card shows. `%` and `_` are literals, not wildcards.
- `--limit` defaults to 20 and may not exceed 1000. There is no "all": this
  database holds every dictation you have ever made.
- The text preview is one line, control characters removed, truncated. `--json`
  carries the whole transcript untouched.

### `echoforge logs`

```
$ echoforge logs --tail 20 --since 30m
$ echoforge logs --source update-install
$ echoforge logs --follow
```

Two sources, and it is worth being plain about what they are:

- `--source unified` (default) reads the **macOS unified log** for the app's
  process. That carries the *system's* messages about Kongweh - CoreAudio
  opening an input device, the capture stack, a crash - and not Kongweh's own.
  Kongweh has no logging framework: it writes `print`, and a shipped app
  launched by the Finder has no stdout for that to reach.
- `--source update-install` reads the update installer's log file, the one real
  log this project writes, because its swap script is detached and has no other
  way to report a failure.

`--since` takes `30s`, `15m`, `2h`, `7d`; the default is `1h`. `--tail` defaults
to 50 and may not exceed 5000. `--follow` streams until Ctrl-C, which stops the
reader process too; it cannot be combined with `--json`.

Everything printed is redacted first: credential-labelled values and key-shaped
tokens, transcript content, and your home directory (folded to `~`). Long
messages are truncated. A source that could not be read exits `4` and says why -
which is different from reading it and finding nothing, which is exit `0`.

### `echoforge settings`

```
$ echoforge settings
ENGINE
  Selected engine                 whisper
  Last engine that loaded         whisper
  Whisper model                   ~/Library/Application Support/…/ggml-large-v3-turbo.bin
…
CLOUD
  API key                         <redacted>  (stored in the Keychain by CloudCredentialStore; …)
```

- It reports **what is stored**. A setting you have never changed reads as `not
  set`, not as its default: the defaults live in the app beside the reasons they
  were chosen, and a copy here would be right until one of them changed.
- **No credential is ever printed**, and that is true by construction rather
  than by filtering - the API key lives only in the Keychain and this tool never
  opens it. The row is listed as `<redacted>` rather than omitted, so its
  absence is visible: an omitted row would read as "there is no key".
- Things you *wrote* rather than switched - the personal terms dictionary, voice
  snippet templates, the custom style instruction - are listed as withheld with
  where to find them.
- The text rendering folds your home directory to `~`; `--json` keeps paths
  verbatim, because a script needs a usable path.

### `echoforge update`

```
$ echoforge update check
Kongweh 1.0.0 is available (you have 0.9.4).
  asset:   EchoForge.dmg, 11.4 MB
  release: https://github.com/hsuanchenlin/EchoForge/releases/tag/1.0.0
  install: echoforge update install

$ echoforge update install
Replace Kongweh 0.9.4 at /Applications/EchoForge.app with 1.0.0? [y/N]
```

This command **adds no security rule and skips none**. Every check between
release metadata and "replace the application" is the app's own, in
`EchoForgeCore`, and is the same code the About pane runs:

- `UpdateManifest` accepts only an HTTPS URL on GitHub's release hosts under
  this repository, with the exact asset name `EchoForge.dmg` and a parseable
  `X.Y.Z` tag, and re-checks every redirect against the same host allow-list;
- `UpdateChecker` never offers a downgrade and refuses to compare a version it
  cannot parse;
- `UpdateInstaller` checks the declared size, the published SHA-256 sidecar, the
  downloaded bundle's identifier and version, and its signature, before anything
  is staged.

`--yes` answers the confirmation for a script. It skips **the question and
nothing else**. There is no `--force` and no "install anyway".

**Quit Kongweh before installing.** The swap runs in a detached script that
waits for a process to exit and then renames the app bundle, and a running
application cannot be replaced. The command checks this *before* downloading, so
you are told at the start rather than after 11 MB. It checks again immediately
before the swap in case Kongweh started while the update was downloading; the
verified update is not installed in that case.

The outcomes are distinct, in the text, in `--json` and in the exit code:

| Outcome | Exit | `--json` |
| --- | --- | --- |
| No update | 0 | `installed: false, reason: "upToDate"` |
| Update available (`check`) | 0 | `updateAvailable: true` |
| Cancelled | 6 | `installed: false, reason: "cancelled"` |
| Kongweh running | 1 | `installed: false, reason: "appRunning"` |
| Failed verification | 5 | `installed: false, reason: "verificationFailed"` |
| Failed download | 1 | `installed: false, reason: "downloadFailed"` |

A verification failure is its own exit code on purpose: those bytes are wrong
and no amount of retrying will help, which a dropped connection is not.

---

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Ran and could not finish |
| 2 | Bad arguments; nothing was read or done |
| 3 | No Kongweh app at the expected path or at `--app` |
| 4 | A local source could not be read (history, log, or a file to transcribe) |
| 5 | A download failed verification |
| 6 | Cancelled, or the user said no |

---

## Tests

```sh
xcodebuild test -scheme OpenSuperWhisper -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO -only-testing:EchoForgeCLITests
```

They need no microphone, no Accessibility or Screen Recording grant, no model
weights and no cloud credential, and they cannot start the app, replace an
installation or reach the network: everything outside the tool goes through
`CLIEnvironment`, and `CLISeamTests` scans the sources to keep it that way.

`BuiltToolSmokeTests` is the exception that runs the built binary - `--help` and
`--version` only - because linking and starting is a thing a unit test cannot
see. It is the same idea as `Scripts/verify_release_package.sh` starting the app
it verifies, one size down.

---

## Where the code lives

- `EchoForgeCLI/` - the tool. `CommandRouter` returns its output rather than
  printing it, so every command, failure and exit code is reachable from a test;
  `main.swift` is the only thing that prints.
- `EchoForgeCore/` - the code the app and the tool share, so there is one
  updater, one schema and one set of preference keys rather than two. `AGENTS.md`
  has the boundary.
