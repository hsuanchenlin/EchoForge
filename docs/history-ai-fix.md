# Fix with AI

The ✨ action on a history card. It reads one stored transcript back to the on-device
model and asks for the one class of error the rest of the pipeline cannot reach:
characters the recognizer *heard* wrong. Chinese homophones - 「我**再**開會」 for
「我**在**開會」 - mis-heard words, and word boundaries split in the wrong place.

`OpenSuperWhisper/Rewriting/TranscriptCorrection.swift` is the stage,
`OpenSuperWhisper/History/TranscriptCorrectionCoordinator.swift` is what a press does
to the card, and `RecordingRow` only draws it.

## Why it is a stage and not a style

`StyleRewriteCatalog` is the list Settings offers for **dictation**, and its identifiers
are persisted in the user's preferences. This one is never stored anywhere: it is a
button on a card, not a way to dictate. So it is a sibling of `StyleRewriteService` in
exactly the way `TranslationRewrite` is - it shares the `StyleRewriting` protocol,
`StyleRewriterFactory`'s availability, `AsyncDeadline`'s hard budget,
`StyleRewriteGuard` and `StyledTranscript`, and brings its own instruction, its own
budget and its own moment.

It runs through `StyleRewriteService.apply` with a synthetic
`StyleRewriteConfiguration` whose `isEnabled` is unconditional, and that is deliberate:
a user who never switched dictation-time rewriting on can still fix one row. This is a
press they made, not a stage that runs behind them.

## Three things that are absolute

**It is on-device only.** `OnDeviceModelFeature.correction` has no `cloudFeature`, the
same way rewriting, Ask and channel matching have none. A history row is every dictation
the user ever made, and a button that quietly posted one to a provider is not a trade
this app makes. `docs/cloud-api.md` names the two features that may leave the Mac;
this is not one of them, and `CloudPrivacyTests` holds that.

**It can only correct a transcript or leave it alone.** Every path out returns the row
unchanged or a candidate that survived the guard, so a press costs a wait and nothing
else. The audio file is never touched, no recording is ever deleted, and no row but the
pressed one is written.

**The original is kept.** What the card said before the press becomes its
`rawTranscription`, which is what "Show original" and "Compare" already read - so a
correction is always inspectable, and never the only copy. A row post-processing had
already changed keeps the engine's own words rather than the text the earlier stage
produced: that copy is the only record of what was actually said, and a second press
must not overwrite it.

## The guard is the boundary

`StyleRewriteShape.preserving` - the strictest shape there is, and the right one. A
homophone fix changes characters and nothing else, so anything wider would be permission
for something the user did not ask for. The correction has to come back the same length,
in the same script and the same Chinese variant, with every number and currency symbol
intact, or the row keeps what it had.

The personal terms dictionary is carried through as well.
`ProcessedText.mustSurviveTokens` is produced at dictation time and is not stored, so
`TranscriptCorrection.mustSurviveTokens(in:terms:)` reconstructs it: every enabled entry
whose own output is literally present in the transcript. Those are spellings the user
typed themselves to say how their vocabulary is written, and a model asked to fix
homophones is exactly the thing that would "correct" a name back into one.

## The budget

`TranscriptCorrectionBudget`, not `StyleRewriteBudget`, and the difference between the
two is the difference between the stages. A dictation's rewrite is racing text on its
way into the app the user was typing in, where anything past a few seconds is worth
less than the transcript arriving now. Nothing is racing here: the user pressed a button
on a card and is watching a spinner on it. So the ceiling is 45 s rather than 12 - and
it is still a ceiling, because a request that never returns leaves that spinner up for
the rest of the session.

## What a press does to the card

`TranscriptCorrectionCoordinator` is **app-lifetime, not row-lifetime**, and that is why
it exists rather than a `@State` in `RecordingRow`. History is a `LazyVStack`: a card
the user scrolls past is torn down, and a correction started from a card's own state
would be cancelled by scrolling away from it - which is what somebody does while waiting
several seconds for a model. The same lesson `UpdateViewModel.shared` records for the
update pane.

It owns no data. The words live in `RecordingStore`; what it holds is the two things the
store has no place for - which rows have a press in flight, and the sentence a press
that changed nothing left behind. One press per row: a second press while the first is
running is ignored rather than queued, because two corrections racing to write the same
row would decide the winner by which model call returned first.

Every failure is **non-blocking and inline**. The press cost the user a wait and nothing
else - every word the row had is still there - so interrupting them with an alert would
be the most disruptive part of the whole feature. The sentence is
`StyleRewriteAvailability.explanation(for: .correction)` or the stage's own, named for
this feature: a user who pressed ✨ must not be told about a stage they never switched
on.

The shimmer while a correction runs is drawn as an **overlay** on the transcript rather
than a `ZStack` sibling. `ShimmerOverlay` is a `GeometryReader`, so stacked beside the
transcript it takes every point it is offered and the card grows by hundreds; laid over
it, it is the size of what it covers. `HistoryRowRenderTests` measures that the height
does not move - and a correction does not raise the action bar either, for the same
reason a regeneration does not: the bar is 15 pt taller than the footer without it.

## Storage

One nullable column, `Recording.aiCorrectedAt`, added by `v5_add_ai_correction`. Nothing
is back-filled: every recording a user already has reads back as one nobody has
corrected, which is exactly what it is.

Its own column rather than a `RecordingProvenance` case, and that is a decision rather
than an omission. Provenance records *which way of listening* produced a row
(`docs/history-provenance.md`), so filing a corrected dictation as something other than
a dictation would overwrite the one fact that record exists to keep. A correction is
something that happened to a row afterwards, and it is stored as such - which is also
why the "AI Polished" chip sits beside the timestamp and duration rather than inside the
provenance pill.

The mark is **cleared by a regeneration**, in the same write that replaces the
transcript. The row's words are the engine's again, and a badge saying a model wrote
them would be a lie.
