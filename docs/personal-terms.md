# Personal terms dictionary

A user-managed list of words the recognizer keeps getting wrong, and words it
must never touch. Deterministic: no model, no network, no macOS version
requirement. It is the first stage of transcript post-processing and works
identically whatever else is or is not configured.

## The toggle

`safeCorrectionEnabled` (`AppPreferences`, default **on**) gates this stage.

It is deliberately a peer of any future style-rewriting setting, never its
child, and it depends on nothing. Turning rewriting off, running an older macOS,
being offline, or having a rewrite rejected must all leave terminology
correction fully working - so nothing else may ever be allowed to gate it.

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
  converts a user's script for them.
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
