# Spoken commands

Two things a user can say instead of dictating: **"Ask: …"**, which sends the
question to the Ask panel, and **"Translate to Spanish: …"**, which translates
what follows instead of pasting it. Everything else is dictation, unchanged.

It is off by default (`Settings → Shortcuts → Ask & Spoken Commands → Spoken
commands`). `docs/ask-panel.md` is the panel's own story; this file is the
router and the translation.

## Where it sits

```
engine output
     │
     ▼
TextPostProcessor.process()        deterministic, cannot fail
     │                             ProcessedText { raw, final, mustSurviveTokens }
     ▼
SpokenIntentPipeline.apply()       only when the caller asked AND the user
     │                             switched it on
     │
     ├── .dictate ──► StyleRewriteService.apply()   the chosen style
     ├── .translate ► TranslationRewrite.apply()    the spoken target
     └── .ask ──────► nothing at all
     │
     ▼
StyledTranscript { raw, transcript, final, status, intent }
     │
     ├── intent == .ask ─────► AskPanelWindowController, NOT inserted
     └── otherwise ──────────► pasted, stored, searched, as always
```

`SpokenIntentRouter` (`Utils/`) is the whole grammar and is pure string
matching. Asking the on-device model to classify the dictation instead would
put a model in front of *every* dictation, make "did my words get pasted"
depend on how the model felt about them, and cost a second of latency on the
plain path that is almost all of the traffic.

## Two conditions, not one

Routing runs only when **both** hold:

- the user switched `spokenIntentsEnabled` on, and
- the caller passed `Settings(routesSpokenIntents: true)`.

Only live dictation passes it. A dropped file, a queued recording, a regenerate
from history and the Ask panel's own voice follow-up all take the plain path -
which is what stops a transcript that happens to begin "Ask:" from opening a
panel nobody was looking at, and what stops a follow-up from routing itself back
into the panel it came from.

## The grammar

| Said | Becomes |
| --- | --- |
| `Ask: …` `Ask, …` | `.ask(query:)` - marker and punctuation stripped |
| `請問…` `请问…` `問 …` `问：…` | `.ask(query:)` |
| `Translate to Spanish: …` (also `into` / `this to` / `it to` / bare `Translate Spanish`) | `.translate(target:text:)` |
| `翻譯成西班牙文：…` (also `翻译成` `翻成` `譯成` `翻譯為` `幫我翻譯成`) | `.translate(target:text:)` |
| anything else | `.dictate` - the transcript, byte for byte |

**Everything that is not recognised is dictation.** That bias is the whole
design: a mis-read command sends the user's words somewhere they did not ask
for, and a missed command costs them a retry.

### Why some markers need punctuation

A marker that is also an ordinary word is only promoted when the transcript
shows the pause a real command has:

- **`ask`** needs punctuation (`:` or `,`). "Ask him to call me back" is a
  sentence people dictate, and accepting a bare space would route it. The cost
  is that a speech engine which drops the comma leaves the command undetected -
  the safe direction.
- **`問` / `问`** needs punctuation or a space, which is exactly what the space
  in the spec's `問 [問題]` is doing.
- **`請問` / `请问`** needs nothing behind it. This is a documented compromise:
  Mandarin transcripts do not come back with a space after it, so requiring a
  delimiter would make the Chinese form unusable, and the price is that
  "请问他什么时候来" - *please ask him when he is coming* - is read as a question.
- **`translate to …`** needs no delimiter of its own, because a language name
  has to follow and that is a far stronger constraint. "Translate the document
  before Friday" names no language and stays dictation.

### Language names

`SpokenLanguageLexicon` maps what a user says onto an ISO code. The English
names come from `LanguageUtil.languageNames` - the app's one list of what a
language is called, so the picker and the spoken form cannot drift - and the
file adds the Chinese names and the aliases nobody says out loud
("auto-detect") or says differently ("Mandarin").

Names are matched longest first, so `traditional chinese` beats `chinese`, and
a Latin name must not run into another letter, so "Frenchman" is not French.
An unknown language is not a translation: `Translate to Klingon: …` is
dictation.

`SpokenTranslationTarget` carries a Chinese variant when the user named one
(`繁體中文`, `simplified chinese`). A bare "Chinese" carries none, and the
caller's fallback - in the app, `ChineseScriptVariant.systemPreferred` - stands
in. The distinction is not cosmetic: it decides every character of the answer.

## Translation

`TranslationRewrite` is a sibling of `StyleRewriteService`, not a style inside
it, and the reason is the prompt. Every rule the rewriting stage sends says
*stay in the transcript's language and never translate it*, written in the
transcript's own language, because that is what stops Chinese dictation coming
back in English (`docs/style-rewriting.md`). Translation is the one request
where all of that is backwards.

What is shared stays shared: the `StyleRewriting` protocol and its on-device
backend, `StyleRewriterFactory`'s availability, `AsyncDeadline`'s hard budget,
`StyleRewriteGuard`, and `StyledTranscript` as the result. What is not:

- **The instruction is written in the target language**, where this app has one
  (English, Traditional, Simplified), and names the target explicitly either
  way. It is the same measured behaviour the rewriting stage exploits in the
  other direction - the model answers in the language it was addressed in - so
  writing the instruction in the target is what makes the answer come out in it.
- **`StyleRewriteShape.translating`** is the guard rule that is relaxed, and it
  is relaxed in exactly one place. It turns off the script check and the Chinese
  variant check, because a translation changing the script is the point.

Everything else the guard does still applies to a translation: numbers, currency
symbols, dictionary terms, the model addressing the user instead of translating,
and a length ratio.

The stage's contract is the rewriting stage's contract: **it can translate the
text or leave it alone.** When it fails - no model, timed out, refused - the
user gets the *body*, with the spoken command stripped. Pasting "Translate to
Spanish: hello" into their document would be worse than pasting nothing.

## Known limits

- The length ratio for `translating` is 0.1 … 8.0, which is barely a check.
  "會議三點開始。" is seven characters and a correct English translation of it is
  fifty-two, so anything tight enough to be informative would refuse real
  translations. The checks that carry a translation are the ones that do not
  depend on length.
- The target Chinese variant is asked for in the instruction and **not**
  enforced by the guard - the variant check compares the rewrite against the
  *transcript*, which for a translation says nothing.
- Personal terms are still required to survive a translation. They are almost
  always proper nouns, which do; a dictionary entry for an ordinary word could
  refuse a correct translation, and the failure is the safe one - the user keeps
  their own text.
- A marker only counts at the front of a dictation. "Tell them I will ask: what
  is the deadline?" is dictation.
- The router runs on the *deterministic* output, so a personal terms entry can
  change what is matched. That is deliberate: it is also what makes a user's own
  spelling of a language name work.

`SpokenIntentRouterTests`, `SpokenIntentPipelineTests` and
`TranslationRewriteTests` pin all of the above.
