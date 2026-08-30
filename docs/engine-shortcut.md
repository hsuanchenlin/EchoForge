# The engine shortcut

**⌥M moves dictation to the next engine that is ready, and says which one on
screen.**

It exists because changing engine was a five-step trip - open the main window,
open Settings, find the Models pane, pick a row, close it - for a decision people
make constantly and mid-sentence: this recording is Mandarin, that one is English,
this one is worth sending to a provider and the next one is not. The shortcut is
the Models pane's picker without the trip.

Configurable like the other hotkeys, in Settings → Shortcuts → Switch
Engine. ⌥M is the default because it is free alongside ⌥` (record), ⌥A (Ask),
⌥S (ask about the screen), ⌥Y (the YouTube command) and ⌥E (voice edit) -
`EngineSwitcherTests` fails if a later default collides.

## Where a user finds it

Two places, and the second one exists because the first was not enough. Settings
→ Shortcuts → Switch Engine is where the key is *changed*. Settings → Models is
where someone stands when they realise they are on the wrong engine, and it now
opens with one line naming the shortcut that would have saved them the trip
(`EngineShortcutHintView`).

That line prints the binding **in force**, never the literal ⌥M: the user most
likely to read it is the one who moved the shortcut, and a hint naming a key that
does nothing is worse than no hint. A cleared shortcut is described rather than
repaired - having none is a setting. Nothing on that path writes a shortcut, and
`EngineShortcutHintTests` scans the two files to keep it that way.

## What it cycles through

`EngineCycle.available` is the whole answer, and it is a pure function of a
snapshot so it can be asserted without a download or a provider. One rule:

> A press never lands on an engine that could not transcribe the next dictation.

Which means an engine is offered only when **both** hold:

1. **It can load.** `EngineConfiguration.isConfigured` - the same check
   `EngineSelector` makes, so "downloaded" means one thing everywhere. For Whisper
   that includes the stored model file still existing; a Whisper configuration
   naming a deleted file is repaired at launch by
   `EngineConfiguration.recoverIfNeeded`, not by a shortcut, because *which*
   replacement file to use is a choice and this shortcut changes engines rather
   than making choices.
2. **It can dictate the language being dictated.** Paraformer does not refuse
   German, it returns fluent Mandarin for it. The Settings picker is allowed to
   reset the dictation language when the user chooses such an engine, because they
   are looking at the language control while it happens; a shortcut pressed into
   another app must not change two things at once, so the engine is skipped
   instead. **The shortcut therefore never changes the dictation language** - a
   pinned invariant, not a coincidence.

The order is `EngineCatalog.pickerOrder` with `EngineKind.cloud` appended: the
shortcut walks the engines exactly as the picker lists them, and the one engine
that leaves the Mac is last, so no press reaches it before every local engine has
been offered. It wraps around. An engine that is *not* in the cycle - a cloud
selection that has become misconfigured, a cache deleted while the app ran - moves
to the first entry rather than being an error, because the user pressed a key
asking for a working engine.

With one engine in the cycle a press changes nothing and says so; with none it
says `EngineConfiguration.unavailableShortMessage`. Neither is silent: the
shortcut is pressed with no window open, so a press that reads as a dead key has
no other way of explaining itself.

## The cloud engine

`CloudAccess.isSelectable(.transcription)` is what puts it in the cycle: consent
recorded, base URL usable, model named, key present. Not `EngineAvailability`'s
`usableEngines`, which contains it only while it is *already* selected -
transcription's enable state is `selectedEngine == .cloud`, so "would the cloud
work if chosen" cannot be asked without pretending it already was, which is what
`CloudSettings.enabling` is for.

Two consequences are load-bearing and are what `docs/cloud-api.md` promises:

- **A press never gives consent.** With no recorded consent the cloud engine is
  simply not in the cycle, and the probe answers `false` at the consent gate -
  before the Keychain - so an install that has never chosen the cloud pays nothing
  for the question.
- **A misconfigured cloud selection is not silently abandoned.** It leaves the
  cycle (nothing can transcribe with it), so each dictation keeps surfacing the
  refusal that names the missing field, exactly as before. A press moves off it -
  but a press is a deliberate act, which is the whole difference from the
  `EngineSelector` and recovery rules that must never choose it *for* the user.

## A press during a dictation

It is **deferred**, not applied and not refused.

Not applied, because the words already spoken were spoken to a particular model
and must be decoded by it - and because replacing the engine object underneath a
decode in flight is a different kind of bug entirely. Not refused, because someone
pressing this has usually just realised they are on the wrong engine, and a dead
key at that moment is the least useful possible answer. So the overlay says
"… after this dictation", and `EngineSwitcher` applies it the moment nothing is in
flight.

Three details there are easy to get wrong:

- **"In flight" spans the whole session, not each of its parts.** Between the
  recorder stopping and the transcription starting every individual flag is
  briefly false, and applying a switch in that gap would hand the words just
  spoken to the new engine - the exact thing being avoided.
  `IndicatorWindowManager`'s session outlives that gap, so it is what is asked,
  alongside the queue and the main window's recorder for the dictations that never
  had an indicator.
- **The pending target is re-checked, not replayed.** A wait can be long enough
  for it to stop being usable, and applying it then would land the user on an
  engine that cannot transcribe. When that happens the press is carried out as
  though it had been made now - the user asked for a working engine, so they get
  the next one - and the overlay names what was actually selected. It may never
  name an engine that was not: announcing a switch that did not happen is worse
  than announcing nothing.
- **An engine chosen anywhere else while the press waits cancels it.** The
  Settings picker and the Cloud pane can both be used mid-dictation, and a choice
  made after the press is the newer decision - a pending target applied over it
  would undo, moments later, something the user watched themselves do. The press
  is dropped silently (the cancelling choice happened in a visible pane, and a
  pill may only name an engine the shortcut actually selected), and a later press
  advances from the newer choice. `EngineSwitcher` hears about such a choice on
  `.selectedEngineChanged`, which while a press is pending can only mean one made
  elsewhere: the switcher clears the pending press and its subscriptions before
  it ever applies anything itself.

A second press while one is pending advances from the pending engine, so two
presses move two places whether or not a dictation happens to be running.

## What it writes

Nothing of its own. `AppPreferences.selectedEngine` is still the single stored
answer to "which engine transcribes", and `EngineSelectionCommand` is the one path
that writes it - shared with the Settings picker and the Cloud pane's toggle, so
the three cannot come to mean three slightly different things. It also carries the
language rule, the cloud engine's come-back-to bookkeeping
(`CloudTranscriptionSelection`), the `.selectedEngineChanged` notification an open
Settings pane follows, and the reload that tells `TranscriptionService`.

`lastReadyEngine` is untouched: only a load that succeeded may write it.

## The overlay

`EngineSwitchHUD` - a pill at the top of the screen for two seconds, drawn like the
dictation capsule because it appears in the same place, and non-activating for the
same load-bearing reason: the shortcut is pressed while the user is typing
somewhere else, and a HUD that took focus would move the insertion point they are
about to dictate into.

It is **not** the dictation capsule and is deliberately not routed through it. The
capsule is one presentation of one dictation (`docs/capsule-hud.md`), it is off by
default, and a press during a dictation would otherwise have to overwrite what the
capsule is saying. When the capsule is switched on this pill sits clear of its slot
so the two never overlap.

**It is drawn on every attached display at once.** It used to go to the one screen
holding the focused window, and that is how the whole feature came to look absent
on a two-display Mac: 0.8.0 switched the engine correctly, put the pill on the
monitor the user was not looking at, and took it away two seconds later - a working
shortcut, indistinguishable from a dead key. Choosing a screen at all is a guess
about where someone's eyes are, and this confirmation is the only thing a press
shows, so it does not guess. `EngineSwitchHUD.placements` is the pure function, one
panel per `CGDirectDisplayID`; on a single display nothing about it changed.
`EngineSwitchHUDViewModelTests` asserts it against the two-display arrangement it
was reported on, which no checkout machine has.

A HUD that never takes focus is also invisible to VoiceOver - there is no focus
move to follow and no interaction to describe - so the same sentence is posted as
an announcement (`EngineSwitchAccessibility`), at high priority because a queued
one would arrive after the pill it belongs to has gone. It is the same string, so
a deferred press is spoken as deferred and never as a switch that has happened.

The wording is in `EngineSwitchMessage`, so it can be asserted. Whisper and the
cloud engine are named with their model - "Whisper - large-v3-turbo", "Cloud -
whisper-1" - because their engine name alone does not say what a dictation will run
on. Every other name comes from `EngineCatalog`, which is where the licence
obligation to retain a model's name lives
(`docs/speech-model-attribution.md`).

The pill also carries a **cloud glyph instead of a waveform** for the one engine
that is not on this Mac, so that reads in the second the pill is up rather than
needing the model name to be parsed. It comes from
`EngineSwitchAnnouncement.isCloud`, derived from the engine, because a view matching
on the word "Cloud" in a sentence is a rule that breaks the first time the wording
changes.

`EngineSwitchHUDRenderTests` draws each message offscreen, reads the words back
with OCR and checks the pill still fits inside its panel - the same tactic
`UpdateCardRenderTests` uses, because this overlay lives for two seconds over
another app and cannot be screenshotted from outside. The renders are written to
`/tmp/EchoForgeEngineSwitchRenders/` for a human to open.
