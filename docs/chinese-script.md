# Chinese output script

Which Chinese a Chinese dictation is written in, and why the app decides it
rather than the model.

## The problem

Speech carries no script. "我們開會" and "我们开会" are the same sentence said out
loud, so which one comes back from a recognizer is a property of its training
data rather than of the speaker:

- **Paraformer** and **SenseVoice** were trained on Simplified corpora and return
  Simplified for a speaker of Taiwanese Mandarin, every time.
- **Whisper** returns whichever the audio reminded it of, and mixes the two
  inside a single sentence: `這個项目的进度很好` is a real shape of its output.
- The **cloud** engine's answer depends on a provider the app does not control.

A user who writes Traditional was therefore correcting the script of every
dictation by hand, and no engine setting could fix it - the script is not an
input any of them takes.

## The decision

The app writes every Chinese transcript in one script, chosen once:

**Settings → Transcription → Chinese Output Script**, `Traditional` by default,
`Simplified` if the user picks it. Stored as `chineseOutputScript`; an install
that predates the setting reads as Traditional, exactly as a fresh one does.

There is deliberately **no third "leave it alone" value**. What the recognizer
returns is not a choice anybody made, and it is not stable from one dictation to
the next, so "leave it alone" would mean "let the model decide, differently each
time" - which is the behaviour this setting exists to end. A user who writes
Simplified gets the same consistency pointed the other way.

`ChineseScriptNormalizer` is the implementation and its documentation is the
detailed version of everything below.

## It is an output setting and only an output setting

This is the boundary the whole feature is drawn around:

- It never makes recognition Chinese. The engine is asked for exactly the
  language the user chose, before and after.
- It never moves the dictation language, and no code on this path writes
  `whisperLanguage`.
- It never tilts auto-detect. Auto-detect is the engine's own decision and this
  runs after it, on the words that came back.
- **English dictation comes back as English**, including on a Mac whose
  dictation language is set to Chinese, because a mostly-Latin transcript is not
  a Chinese transcript.

`ChineseScriptNormalizer` takes the text, the chosen script and the dictation
language as arguments and reads no preference at all, so this is structural
rather than a promise. `ChineseScriptNormalizerTests` pins each clause.

## Where it runs

At the front of the transcript stage - `TextPostProcessor.process`, the single
choke point every engine and every caller passes through, so **every engine
gives the same answer** and none of them can skip it. See
`docs/text-post-processing.md` for the pipeline as a whole.

```
engine output  ──►  script normalization  ──►  personal terms  ──►  CJK spacing
                    (this document)            (the user's own text)
```

Running it **first** is the rule *convert the recognizer's words, never the
user's*:

- a **personal terms** entry is written out in the script the user typed it in,
  and is still matched either way because the matcher folds scripts
  (`ChineseScriptFolding`);
- a **voice snippet** template is inserted byte for byte, because the snippet
  stage replaces the text wholesale after this has run.

## What is converted, and what is not

The conversion is ICU's `Hans-Hant` / `Hant-Hans` transform
(`HanCharacterTransform`), applied one character at a time, and a character
whose transform is not exactly one character back is kept as it was. So the
output has the same character count as the input and:

| Preserved exactly | Converted |
| --- | --- |
| Latin words, digits, emoji | Han characters, and only Han characters |
| Punctuation of both widths, whitespace, newlines | |
| Whisper timestamps (`[00:00:00.000 --> 00:00:02.480]`) | |
| Japanese and Korean, in full | |
| The user's dictionary entries and snippet templates | |
| Recordings already in History | |

Two gates decide whether anything is converted at all, and both have to pass
(`ChineseScriptVariant.isChineseText`):

1. the dictation language leaves Chinese possible - Chinese or Cantonese, or
   auto-detect, or a code the app does not know. Japanese and Korean close it,
   because kanji and hanja are Han characters too and `学 → 學` in a Japanese
   transcript is a corruption, not a normalization;
2. the text itself is Han-dominant, with no kana or Hangul anywhere in it.

That is the same predicate `StyleRewriteLanguage` asks "is this Chinese" with,
on purpose: two answers to that question is how one stage converts a script the
next stage does not think is Chinese.

## ICU rather than a table

The mapping is the platform's. A hand-maintained character map would be a
second, worse copy of something macOS already ships and keeps current, and it
would rot one character at a time with nothing to notice.

The one character table this repository does keep -
`ChineseScriptVariant.traditionalCharacters` - is *evidence for telling the two
scripts apart*, not a conversion, and its own tests check it against this same
ICU transform.

Nothing here reaches a model, a network or a prompt. The conversion is
deterministic, synchronous, offline and identical on every Mac; a source scan in
`ChineseScriptNormalizerTests` fails if that changes.

## How it lines up with the stages after it

- **Style rewriting** is asked for its instruction in the transcript's own
  variant, which is now the chosen one. `StyleRewriteGuard` then refuses a
  rewrite that switched variant, so the model cannot undo the conversion; when a
  Chinese transcript's characters do not say which variant it is, the chosen
  script is the fallback rather than the Mac's region.
- **Translation** is the one stage that may change the language, so it converts
  its own accepted output to the variant that was *asked for*: "翻譯成簡體中文"
  is answered in Simplified even for a Traditional user, because a spoken
  request outranks a setting, and a bare "translate to Chinese" resolves to the
  setting. See `TranslationRewrite`.
- **Spoken commands** are read off the normalized transcript, so every CJK
  spelling in `SpokenIntentGrammar` and `SpokenLanguageLexicon` is listed in
  both scripts - a Simplified speaker whose output is Traditional says
  "翻译成意大利语" and the router is handed "翻譯成意大利語".
  `SpokenIntentRouterTests` converts every entry both ways and fails if one has
  no counterpart.
- **The Ask panel** is outside all of this. Its answers are the model's own text,
  read by the user before it goes anywhere, and normalizing a transcription is
  not a licence to rewrite an answer.

## Nothing stored is rewritten

Normalization is part of transcribing, so it applies to the next dictation and
to nothing before it. Recordings already in History keep the text they were
stored with, and `Recording.rawTranscription` keeps what the engine actually
returned for new ones, so History's "Compare" can still show what changed.
Changing the setting changes what happens next; it never edits the past.
