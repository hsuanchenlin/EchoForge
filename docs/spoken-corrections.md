# Spoken corrections

People do not dictate finished sentences. They say *"send it Friday, scratch
that, Monday"*, they say *"replace Friday with Monday"*, and they say *"um"*.
This stage reads those retractions off the transcript and carries them out,
deterministically and on this Mac.

It is **off by default**
(`Settings → Dictionary & Snippets → Spoken Corrections`), and the reason for
that default is the same reason every rule below is written the way it is: this
is the one stage in the app that **deletes** words, into an application the user
is not looking at, after the audio has stopped.

---

## Where it sits

```
engine output
     │
     ▼
TextPostProcessor.process()          the transcript stage, four passes:
     │
     │  1. Chinese output script     ChineseScriptNormalizer
     │  2. spoken corrections   ◄──  SpokenCorrector          THIS FILE
     │  3. personal terms            PersonalTermsCorrector
     │  4. CJK spacing               AutocorrectWrapper
     ▼
SpokenIntentPipeline.apply()         "Ask: …", "Translate to …", snippets
     ▼
StyleRewriteService.apply()          the on-device model, guarded
```

`docs/text-post-processing.md` owns the pipeline as a whole. Two things about
the position above are load-bearing:

- **After normalization.** The transcript has already been written in the user's
  chosen script by the time this runs, so the trigger tables need each Chinese
  spelling in **both** scripts and nothing else - exactly the rule
  `SpokenIntentRouter` follows, and `SpokenCorrectionGrammarTests` converts every
  entry both ways and fails if the result is not also an entry.
- **Before the dictionary.** `PersonalTermsCorrector` hands back character ranges
  that CJK spacing is held out of, and an edit made after that would move the
  text under them. It also splices in words the *user typed* - a dictionary
  entry, and later a snippet template - which a retraction has no business
  reading as one of its own triggers. `SpokenCorrectionPipelineTests` pins both
  directions.

---

## Two gates, not one

The stage runs only when **both** hold:

- the user switched `spokenCorrectionsEnabled` on, and
- the caller passed `Settings(correctsSpokenEdits: true)`.

Only **live dictation** passes it, and the reasons are different for each caller
that does not:

| Caller | Why not |
| --- | --- |
| A dropped file, "Open With", `echoforge transcribe` | Somebody's recording, not this user's utterance. "Scratch that" in an interview is a thing the speaker said. |
| A regenerate from History | The same recording again; the transcript stored beside it already had this decision made once. |
| A ⌥E voice-edit instruction | *"Replace Friday with Monday"* **is** the instruction. Eating it here would leave the edit with nothing to do. |
| A ⌥Y command capture | The words are a channel name. |

The last two are refused by `Settings` itself, on `purpose`, so no caller can
pass the flag and get them.

---

## The rule that makes it safe

**A trigger only fires when it is the whole of a clause.**

A clause is what sits between the punctuation a speaker's pause becomes -
`TranscriptClauses` is the whole definition, in both widths, with Latin `.`, `!`
and `?` additionally requiring whitespace after them so `3.5` and `e.g.` stay
one clause.

That single rule is the entire defence against the failure that costs a user
anything:

| Said | Becomes |
| --- | --- |
| `Send it Friday, scratch that, Monday.` | `Monday.` |
| `I want to scratch that itch.` | unchanged |
| `Could you delete that when you have a moment?` | unchanged |
| `We should start over on the design, but not today.` | unchanged |
| `他說錯了地方。` | unchanged |

It has a cost, and the cost is documented rather than worked around: an engine
that returns **no punctuation at all** produces one clause, so no trigger can
fire. Paraformer is that engine (`docs/upstream-issues.md`). That is the safe
direction, and it is the same trade `SpokenIntentGrammar` makes when it requires
punctuation behind `ask`.

---

## What it does

| Kind | Said | Effect |
| --- | --- | --- |
| Drop a phrase | `scratch that` `delete that` `strike that` `never mind` `說錯了` `講錯了` `算了` | Drops the clause before it |
| Drop a sentence | `delete the last sentence` `delete that sentence` `刪掉上一句` `刪掉那句` | Drops everything back to the last full stop |
| Replace | `replace Friday with Monday` `change three to four` `把星期五改成星期一` | Rewrites the **last** occurrence of the old text in what was already said |
| Start again | `start over` `start again` `delete everything` `重新開始` `從頭開始` | Drops everything said before it |

`SpokenCorrectionGrammar` is the whole table and Settings shows it verbatim, so
a user can read the exact phrases before switching the stage on.

Two asymmetries in that table are deliberate. The Chinese `…句` forms all delete
a **sentence**, because 句 *is* a sentence - the phrase-scoped Chinese triggers
are the bare retractions a speaker interjects with. And `算了` is the one entry
that is also an ordinary phrase; the whole-clause rule is what makes it safe
(`我覺得算了` is its own clause and does not match), and it is called out here
rather than hidden.

### An edit it cannot place is not made

`scratch that` with nothing in front of it, or `replace Friday with Monday` when
Friday was never said, leaves the words **exactly** as they arrived and records a
`SpokenCorrectionRefusal`. The alternative - deciding on the user's behalf what
they must have meant - is the one thing this stage may not do. A missed
correction costs a retry; a wrong one costs a sentence.

### Untouched text comes back byte for byte

`TranscriptClause` *partitions* the transcript - `prefix + text + terminator`,
concatenated over every clause, reproduces it exactly - so removing whole clauses
cannot introduce a doubled space or strand a comma between two survivors. The
only cleanup is at the very end, where a comma can be left with nothing after it.
A dictation containing no correction is returned unchanged, character for
character; `SpokenCorrectorTests` asserts that over the awkward cases.

---

## Hesitation sounds

A second toggle, a child of the first, and deliberately the smaller half.

- **Removed anywhere, as whole words:** `um`, `umm`, `uh`, `uhh`, `uhm`, `er`,
  `erm`, `ahem`. Every one is a *sound* rather than a word in any language this
  app transcribes, so removing one cannot change what was said.
- **Removed only when they are a clause of their own:** `like`, `you know`,
  `i mean`, `sort of`, `kind of`. *"It's, like, complicated"* is a tic and *"I
  like this"* is a sentence, and the difference between them is exactly the
  punctuation the pause became.
- **Never removed:** anything inside quotation marks (both widths, plus 「」 and
  『』) or backticks. A transcript that says ``the token is `uh` in the parser``
  is quoting the sound rather than making it, and code dictated into an editor is
  the one place a two-letter token means something exact.

There are **no Chinese fillers in the list**, and that is a decision rather than
an omission: 嗯, 那個 and 就是 are ordinary words in Mandarin far more often than
they are noise, and the price of getting one wrong is a sentence that no longer
says what the user said.

Removing a whole filler clause takes one bracketing comma with it, so *"It's,
like, complicated"* comes back as *"It's complicated"* rather than *"It's,
complicated"*. A terminator that ends a **sentence** is left alone: *"Hello. Um.
We ship."* is two sentences with a noise between them and still is afterwards.

---

## What the user keeps

The engine's own words are never the thing that gets lost. `ProcessedText.raw`
is the transcript exactly as the engine returned it, `StyledTranscript`
carries it through, and every path that writes a row stores it as
`Recording.rawTranscription` (`styled.originalWorthKeeping`). So:

- History's **"Show original"** shows what was actually said;
- History's **Compare** diffs it against the corrected text, which is exactly
  the list of what the stage removed;
- `echoforge history --json` carries it as `originalTranscript`.

`ProcessedText.corrections` additionally carries the **typed** operations - the
kind, the trigger, what was removed and what was put in its place - so a surface
that wants to explain the difference does not have to infer it from two strings.
Nothing is carried when the stage did not run, so "no corrections were made"
cannot be mistaken for "corrections were never considered".

---

## Testing

- `SpokenCorrectorTests` - the reducer, table-driven, English and Chinese,
  including a false-positive set (`I want to scratch that itch`, `Could you
  delete that when you have a moment?`, `他說錯了地方`) and the byte-for-byte
  property.
- `TranscriptClausesTests` - the split-and-join round trip over newlines,
  doubled punctuation, decimals, emoji and full-width forms.
- `SpokenCorrectionGrammarTests` - both scripts, no colliding keys, and that
  every hesitation sound really is a sound.
- `SpokenCorrectionPipelineTests` - both gates, the purposes that are refused,
  the order against the dictionary, and what reaches `Recording`.

The release gate is the **false-positive rate**, not coverage: a missed
correction is cheap and a deleted sentence is not. When in doubt, do not add the
trigger.
