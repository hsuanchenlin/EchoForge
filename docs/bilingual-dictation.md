# Bilingual dictation: English inside Mandarin

Kongweh's users say sentences like:

> 把 PR 開到 `feature/login` 再 @James

One utterance, two languages, and the English half is not loanwords - it is
branch names, product names, handles and identifiers, which are long. This file
is the whole story of what the app does with that: which engine transcribes it,
what the text stage does to the result, and what the other engines do instead.

## The engine

`EngineKind.bilingualDictation` names it, and it is **SenseVoice-Small**. Nothing
else in the app hard-codes an engine for this; `EngineCatalog`'s copy, the
Settings hint and `EngineSelector.bilingualEngine` all read that one constant.

| Engine | A sentence that switches language halfway through |
| --- | --- |
| **SenseVoice-Small** | Transcribes it. Six language embeddings, English among them, and `auto` is picked per utterance rather than per recording. |
| Whisper | Auto-detect settles on **one** language for the whole decode, so the other half comes back translated or transliterated rather than transcribed. |
| Parakeet | No Chinese at all, in either model version. |
| Paraformer-large (zh) | `vocab8404` has no English in it. The English comes back as raw BPE fragments and `ParaformerLanguageGuard` refuses the whole transcript. |
| Cloud | The endpoint is the Whisper API, which detects one language per request. The app never proposes this engine for anything (`EngineKind.usesCloudProvider`), so it is not an answer here either. |

`EngineKind.transcribesEnglishAndChineseTogether` is that column, switched
exhaustively so a new engine has to answer it.

**Paraformer is not asked to pass English, and the guard stays.** Its refusal is
the correct behaviour, not a gap to close: a transcript that had to be repaired
to be shown is a guess pasted into somebody's editor, so the recording is kept
and one press of regenerate on the bilingual engine recovers it.
`ParaformerLanguageGuard` documents the two rules and its own known limit.

## The Settings hint

Settings → Model, directly under the engine rows, unconditionally:

> **Mixed English and Chinese: use SenseVoice-Small**
> It is the only engine here that transcribes both in one recording - Whisper
> settles on one language per recording, Parakeet has no Chinese, and Paraformer
> refuses English rather than guess at it. Your Chinese still comes out in the
> script you chose.

Both sentences are `EngineCatalog.bilingualHint` and
`EngineCatalog.bilingualHintDetail`, so the pane cannot become a second copy of
the copy, and the model name the FunASR licence requires cannot be dropped from
this surface while it survives in the picker.

It is a **statement, not a suggestion**: no `selected:` parameter, no Switch
button, shown to everyone. The rows above it are one tap each; what four names
cannot carry is which of them survives a sentence that switches language
halfway through. A user who has not started mixing languages yet is exactly the
one who does not know the app can.

## What the text stage does with the result

Nothing new. A mixed transcript goes through the same three deterministic passes
as any other (`docs/text-post-processing.md`), and the first of them is the one
that matters here: `ChineseScriptNormalizer` writes the **Chinese half** in the
user's chosen script - Traditional by default - and leaves the **English half**
byte for byte as the engine returned it. That is a property rather than a
promise: the conversion is ICU applied one character at a time and refused
unless it returns exactly one character, so Latin words, digits, `@handles`,
`feature/login` and punctuation cannot move (`docs/chinese-script.md`).

### The one thing that had to change: Han is weighed against words

The gate in front of that conversion is `ChineseScriptVariant.isHanDominant`, and
it used to weigh Han characters against **letters**. That undercounts the Chinese
in a code-switched sentence, and it undercounts it hardest in exactly the
sentences this app is for:

| | Han | Latin letters | Latin words |
| --- | --- | --- | --- |
| `把 PR 开到 feature/login 再 @James` | 4 | 19 | 4 |

Four Han characters against nineteen letters is 17%, under the 30% gate - so the
sentence was classified as *not Chinese*, the conversion never ran, and a
Traditional user got `开` back from SenseVoice exactly as the model wrote it.
Against four Latin words it is 50%, and the sentence is Chinese.

A Han character is a word; a Latin letter is a fraction of one. Counting both as
"letters" compares unlike things, and the fix is to compare like with like:
`isHanDominant` now counts runs of non-Han letters as one unit each, and keeps
the 0.3 threshold (`ChineseScriptVariant.hanShareThreshold`).

Two consequences, both deliberate:

- `StyleRewriteLanguage` reads the same predicate, so a code-switched dictation
  is now addressed in Chinese rather than English. That is the right way round -
  an English instruction is what makes the on-device model answer Chinese
  dictation in English (`docs/style-rewriting.md`).
- An English sentence naming **two** Chinese people is now Chinese to this
  predicate, where one is not. Every threshold has a shape; this side of it is
  the cheap one - a name written in the script the user writes in, against a
  whole daily utterance coming back in the wrong script.

`StyleRewriteGuard` still counts letters and stays that way: it asks whether a
*rewrite* changed script, which is a comparison of two texts against each other
rather than a claim about either, so both sides of it move together whatever the
unit.

## Where the tests are

- `BilingualDictationTests` is the story end to end on committed text fixtures -
  the mixed utterances, Traditional output, English surviving byte for byte,
  Paraformer refusing the same shapes, and the engine facts above.
- `SenseVoiceEngineIntegrationTests` has the audio half, opt-in on a locally
  generated fixture (its header says how to make one); model-backed tests never
  run in an ordinary test run.
- `EngineCatalogTests`, `EngineKindTests` and `EngineSelectionTests` hold the
  copy, the capability and the selection consequences.
- `ChineseScriptNormalizerTests` and `ChineseScriptVariantTests` hold the
  counting change and the counter-cases it must not swallow.

## What this is not

No new cloud path, no second bilingual model, and no model classifying a
dictation before it is transcribed. The engine already handles it; what was
missing was saying so, and a text gate that could see it.
