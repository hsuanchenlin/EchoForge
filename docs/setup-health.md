# Setup Health

Settings → Setup. The first tab, and the only one that answers a question rather
than exposing a subsystem.

The other eight panes are organised by the part of the app they configure, which
is the right shape for changing a setting and the wrong shape for finding out
whether the settings you already have add up to a working dictation. A user had
to understand engines, models, languages, permissions, shortcuts and the cloud
boundary before they could tell whether the next press of a key was going to
produce text. This pane is that answer in seven lines.

## What it says

| Row | Reads | Links to |
| --- | --- | --- |
| Transcription engine | `EngineSelection` - the engine chosen, the engine running, and why they differ | Model |
| Model | `ModelInventory` and `TranscriptionService.modelPreparation` - ready, downloading, half-installed, and the disk total | Model |
| Language | `whisperLanguage`, and `chineseOutputScript` where it applies | Transcription |
| Microphone | `MicrophoneService` and the TCC grant | - |
| Permissions | Accessibility (required) and Screen Recording (conditional) | Shortcuts |
| Dictation shortcut | `DictationTrigger`, plus collisions between this app's own shortcuts | Shortcuts |
| Where your speech goes | `CloudBuild`, `selectedEngine`, `cloudTranslationEnabled`, and the provider's host | Cloud |

Three rules carry the whole pane.

**It reads.** Nothing on this path writes a preference, downloads a model,
selects an engine or grants a permission. Where a Settings pane owns the fix,
the row carries a button that moves the sheet there and a person does it there.
This is the same separation `EngineSelector` keeps between the
engine a user *chose* and the engine that can run *now*: describing a state is
not the same act as changing it.

**It duplicates no facts.** Engine names and caveats come from `EngineCatalog`,
readiness and disk from `ModelInventory`, the desired-versus-active split from
`EngineSelection`, the trigger from `DictationTrigger`, the cloud position from
`CloudAccess` and `CloudEndpoint`. A second copy of any of them is a second thing
to keep true.

**It is a pure function of a snapshot.** `SetupHealth.checks(SetupHealthInputs)`
takes every input as a value, so every combination of readiness is asserted in
`SetupHealthTests` without a microphone, a model, a TCC grant or a network. The
view gathers the snapshot and draws it; it decides nothing.

## Rows do not reorder

Statuses are `blocked`, `attention` and `ok`, and the rows are shown in **topic
order regardless**. A pane whose rows sort themselves worst-first moves under the
reader every time the state changes, and the topics are a fixed list somebody
learns the shape of. The one-line summary above them carries the urgency:
"Kongweh is ready", "…with a few things worth knowing", or "Kongweh cannot
dictate yet".

## What it will and will not claim about shortcuts

`DictationTrigger` resolves the three trigger modes in the same order
`ShortcutManager.setupRecordingTrigger` does - a configured mouse button beats a
modifier key, which beats the ordinary shortcut - so the pane names the key the
app is actually listening on. Before it existed, three surfaces re-derived that
from the same three preferences.

`ShortcutConflicts` reports collisions **between this app's own shortcuts only**.
macOS exposes no supported way to enumerate another application's global hotkeys,
so a check that claimed to find conflicts in general would be claiming something
it cannot know. Two of Kongweh's six on the same keys is a real state, reachable
from the Shortcuts pane in two clicks, and one where exactly one of them silently
stops working - so that is what it looks for and all it looks for.

## The microphone test

Five seconds, and the audio is thrown away.

It is the one thing on the pane that does something, and it is the only place in
the app where a user can find out whether the input they are on actually hears
them: every other microphone answer arrives *during* a dictation, when they are
looking at another application.

Three rules:

- **The same microphone owner as everything else.** It goes through
  `AudioRecorder.startRecording()`, so it takes the single `RecordingSession`
  claim, is refused while a dictation is in flight, and cannot start a second
  capture behind one. It watches `$failedStart` and acts only on a failure naming
  its own session, like every other surface that holds the microphone.
- **The audio is discarded, always.** It ends with `cancelRecording`, which
  deletes the file, so a test leaves no `.wav`, no history row and nothing for
  the retention policy to reason about. There is no path here that keeps a
  recording: this measures a level, and audio captured to measure a level is not
  something a user asked to store.
- **The verdict is the shipped one.** It reads `MicrophoneSignalMonitor` - the
  same thresholds and the same grace period the capsule uses
  (`docs/capsule-hud.md`) - so a test that says "Low signal" is telling the user
  what their dictations are going to look like, not running a second, kinder
  opinion.

## The privacy row

The only place the whole position is stated in one line, so it is the row that
has to be exactly right. It reports **configuration, not intent**: "the cloud
engine is selected" is a fact and is stated whether or not the user thinks of it
as switched on. It names the provider's **host** and nothing else - never a path,
never a key (`CloudRedaction`). A build with no cloud path at all
(`Scripts/build_release.sh --offline-only`) says so, because that is a stronger
claim than a default and the user is entitled to know which build they have. And
whenever a cloud feature *is* on, the second line still names the six features
that stay on the Mac, so one configured feature does not read as the whole app
having moved. See `docs/cloud-api.md`.

## The sheet got wider

The tab bar is one row of titles, so the titles and the sheet's width are a
single decision (`SettingsSheetLayout`). A ninth tab needed about 60 pt more, so
the sheet went from 680 pt to 760 pt. `SettingsTabBarFitTests` is what said so,
at test time, rather than the app shipping "Se...", "Di...", "Ab...".
