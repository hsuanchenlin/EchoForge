# Personal terms dictionary

A user-managed list of words the recognizer keeps getting wrong, and words it
must never touch. Deterministic: no model, no network, no macOS version
requirement. It is the first stage of transcript post-processing and works
identically whatever else is or is not configured. It also reaches one engine
*before* it decodes - Whisper is shown the dictionary as its initial prompt -
and that half is described below.

## The toggle

`safeCorrectionEnabled` (`AppPreferences`, default **on**) gates this stage,
and it gates the decoding prompt below with it: `Settings.personalTerms` is
resolved once from that toggle and both halves read it, so with safe correction
off the dictionary is inert everywhere rather than only after the engine.

It is deliberately a peer of any future style-rewriting setting, never its
child, and it depends on nothing. Turning rewriting off, running an older macOS,
being offline, or having a rewrite rejected must all leave terminology
correction fully working - so nothing else may ever be allowed to gate it.

## Before decode: Whisper's initial prompt

A post-hoc replacement cannot save a name the recognizer never emitted close
enough to match. whisper.cpp's `initial_prompt` is conditioning text the decoder
treats as preceding transcript, so a name listed in it is one the decoder is
biased to *write* - before the terms stage ever sees the result. `WhisperEngine`
composes that prompt through `WhisperInitialPrompt` (`Engines/`), pinned by
`WhisperInitialPromptTests`:

- **The user's typed Initial Prompt comes first, exactly as typed**, and the
  dictionary follows it as a comma-separated list. An empty dictionary leaves the
  prompt exactly what it was before this path existed - whitespace and all, or
  no prompt at all - so nothing changes for a user who has no terms.
- **What is listed is what an entry writes out**, never what it matches on: the
  replacement for a substituting kind, the matched text for a never-correct one.
  `頂頂群` is the mishearing, and a prompt that showed it would teach the decoder
  the mistake.
- **The list is in the order it should be kept** when the budget runs out:
  names, then preferred spellings, then never-correct text, then mishearing
  fixes (`PersonalTermKind.decodePromptPriority`, switched exhaustively), file
  order within a kind. Disabled and incomplete entries are skipped, duplicates
  are listed once, and a word already in the typed prompt is not repeated.
- **An entry with a context hint is left out.** The hint says the substitution
  is conditional on the rest of the dictation; a prompt is shown before any of
  it exists, and biasing every dictation toward a homophone target such as `再`
  is the outcome the hint exists to prevent.
- **The cap is measured in the model's own tokens**, not characters: a Han
  character is one to three Whisper tokens and a name is rarely one, so a
  character cap either starves an English dictionary or overruns a Chinese one.
  `WhisperInitialPrompt.tokenBudget` is 111, half of the 223 tokens whisper.cpp
  will carry, because every carried prompt token is taken from the same
  224-token budget the decoder keeps its own recent output in
  (`whisper_full_with_state`, measured off the pinned submodule) and a prompt
  that filled it would leave a long recording no memory of what it just wrote.
  The list stops at the first word that does not fit rather than skipping it,
  so a shorter, lower-priority word never squeezes in ahead of a name.
- **The typed prompt is never trimmed to make room.** whisper.cpp keeps the
  *last* tokens of an over-long prompt, so if the user's own text already fills
  the budget it goes through untouched and nothing is appended that could push
  its start out of what the decoder sees.

This is additive bias, not a replacement: the terms stage still runs on the
decoder's output exactly as before, and a name the decoder still missed is
corrected there.

**Whisper is the only engine with this hook.** Parakeet, SenseVoice and
Paraformer take no decoding prompt in the pinned runtimes, so there is nothing
to feed and no per-engine list to maintain - and none is offered in Settings.
The cloud endpoint does take a prompt and is deliberately **never** shown the
dictionary: a list of the names a person works with is the most identifying text
this app holds, and what a cloud request carries is the typed setting alone
(`docs/cloud-api.md`). `CloudTransportTests` shows a real request agrees, and a
source scan in `CloudPrivacyTests` keeps `Cloud/` from ever mentioning the
dictionary; a second scan in `WhisperInitialPromptTests` keeps `WhisperEngine`
the only caller of the composer.

## Entry kinds

| Kind | Example | Behaviour |
|---|---|---|
| `replacement` | `頂頂群` → `釘釘群` | literal substitution, fixes what was misheard |
| `preferredSpelling` | `k8s` → `Kubernetes`, `台北` → `臺北` | literal substitution, fixes orthography |
| `name` | `阿肯` → `阿 Ken` | substitution, and always part of the must-survive set |
| `protect` | `useState`, `恰恰好` | emitted exactly as spoken, excluded from every later stage |

Every entry may carry an optional **context hint**: a short string that must
also appear somewhere in the same dictation for the entry to fire. Mandarin
recognition errors are overwhelmingly homophone substitutions, and a blindly
global `在` → `再` would be catastrophic; the hint is how a user says *when*
they meant it.

## Matching rules

Implemented in `PersonalTermsCorrector`, pinned by `PersonalTermsCorrectorTests`.

- **One left-to-right pass, leftmost-longest.** At each character position the
  longest matching entry wins; scanning then resumes after the span it consumed,
  so one entry can never rewrite what another just produced. Entries of equal
  length resolve in file order, which is how a user breaks a tie deliberately.
- **No tokenisation.** Chinese has no word spaces, and entries such as `阿 Ken`
  or `第 3 個 sprint` straddle scripts and contain spaces. Matching is a
  character scan, not a word split.
- **Traditional / Simplified are matched together.** `ChineseScriptFolding`
  folds Han characters onto one comparison key so an entry written in either
  script matches dictation in the other. Folding decides *matching only*: what
  is written out is always the entry's own `replacement`, exactly as the user
  typed it - or, for `protect`, the source span exactly as spoken. Nothing here
  converts a user's script for them, and the stage that does convert one -
  `ChineseScriptNormalizer`, `docs/chinese-script.md` - deliberately runs
  *before* this one, so what it rewrites is the recognizer's words and an entry
  is still written out exactly as it was typed.
- **Case-sensitive.** A case-insensitive dictionary could not express the
  difference between `useState` and `usestate`, which is exactly what someone
  protecting an identifier needs.

## Ordering against CJK autocorrect

The terms stage runs **before** `AutocorrectWrapper`, and the spans it marked
`protect` are then held out of it. See `TextPostProcessor.process`.

Both halves matter. Terms first, so entries match what the user actually said
rather than a respaced version of it - an entry whose match straddles a CJK/Latin
boundary would stop matching otherwise. Protected spans held out, so a term the
user pinned is not respaced afterwards.

`AutocorrectWrapper.format` is a C function from string to string, so there is
no way to ask it to leave a range alone. Holding a span out means splitting the
text at the protected boundaries and formatting only the gaps, which is what
actually guarantees a pinned span comes out byte-identical. The visible
consequence is that no spacing is introduced immediately next to a protected
span either. That is the honest reading of "never correct", and it is pinned by
`TextPostProcessorTests.testProcess_protectedSpanSurvivesAutocorrectByteForByte`.

## The result surface

`TermsCorrection` carries two things beyond the corrected string, because only
this stage knows them and neither can be reconstructed afterwards:

- `protectedRanges` - character ranges in the corrected text that no later
  **deterministic** stage may alter. Consumed today by CJK autocorrect.
- `mustSurviveTokens` - what every applied entry wrote out. This is the set a
  later **rewriting** stage would have to find intact in its own output before
  that output could be accepted. Nothing consumes it yet; there is no model in
  this pipeline. It reaches callers as `ProcessedText.mustSurviveTokens`.

## Storage

`~/Library/Application Support/<bundle id>/terms.json` - a single global file,
a sibling of `recordings.sqlite`.

Global to the user on purpose: the dictionary outlives any future style profile
and must survive deleting every one of them, so it is not nested inside one. It
is out of `recordings.sqlite` for the same reason - that database has a
retention policy that deletes old rows.

```json
{
  "version" : 1,
  "terms" : [
    {
      "id" : "…",
      "kind" : "replacement",
      "match" : "頂頂群",
      "replacement" : "釘釘群",
      "contextHint" : "報告",
      "enabled" : true
    }
  ]
}
```

Plain, pretty-printed JSON so the file can be backed up, synced, hand-edited and
copied between machines without the app. Decoding is correspondingly forgiving:
`id`, `enabled` and `contextHint` may all be omitted, and an entry the current
build cannot understand - an unknown `kind`, a missing `match` - is skipped
without taking the rest of the dictionary with it.

A file that fails to parse entirely leaves the dictionary empty and is reported
through `PersonalTermsStore.loadFailure`, which the settings screen shows. The
bad file is never overwritten implicitly: it is the user's data.

`PersonalTermsStore` is a plain locked singleton rather than an
`ObservableObject`, following `AppPreferences`, because the transcription
pipeline reads it from a detached task. The settings screen wraps it in
`PersonalTermsViewModel`.
