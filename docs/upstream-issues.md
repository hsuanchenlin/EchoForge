# Upstream issues

Defects this project has measured in a dependency and decided to live with, rather than work
around in the app. Each entry says what was measured, what the app does about it today, and what
would change if it were fixed - so a dependency bump has something to re-check against, and so
nobody re-diagnoses a known problem from scratch.

An entry belongs here when all three are true: the defect is reproducible, it is in code this
project does not own, and the app is shipping anyway. Fixes we *did* work around belong in the
code that works around them, not here.

## FluidAudio: SenseVoice decode reads fp16 logits through `NSNumber`

**Status:** worked around in the app; fixed on upstream's main (`LogitsArgmax`,
a vDSP per-frame argmax) but not in any tagged release through 0.15.5. Not filed
separately - upstream already wrote the same fix.

**Measured** on FluidAudio 0.15.4 (`b9d43724`, the pin this app carries), Apple M5:
the encoder emits **float16** `ctc_logits`, and `SenseVoiceManager.decode` then
reads all ~11.9 M elements of a 28 s utterance one boxed
`logits[[0, t, v]].floatValue` at a time - ~97 % of the wall time, about 3.4 s
for a 28 s utterance in a quiet process and ~20 s for a 36 s recording sampled
in the shipped app, degrading catastrophically under memory pressure (the loop
is pure allocation churn). The encoder itself returns in ~0.09 s.

**What the app does:** owns the decode. `SenseVoiceCoreMLTranscriber`
(`OpenSuperWhisper/Engines/SenseVoiceDecoding.swift`) runs the same three model
stages and does the greedy CTC with a vDSP argmax over raw storage, the same fix
upstream made. `SenseVoiceEngineIntegrationTests.testTheAppSideDecodeMatchesFluidAudiosByteForByte`
pins its output against the pinned manager's, byte for byte, on the real
encoder's tensors.

**On a FluidAudio bump:** if the tagged release contains `LogitsArgmax`, the
app-side transcriber can be handed back to `SenseVoiceManager` - keep the parity
test either way, flipping its reference to the new manager. If it does not, the
app-side decode stays.

## FluidAudio: Paraformer returns raw `@@` BPE continuation markers instead of detokenising

**Status:** to be filed against <https://github.com/FluidInference/FluidAudio>. Not filed yet.

**Measured** on FluidAudio 0.15.4 (`b9d43724`, the pin this app carries): `ParaformerManager.transcribe`
returns the decoder's sub-word units joined as they are, so any token that carries the BPE
continuation marker keeps it. On Mandarin this is invisible - vocab8404's Han tokens are whole
characters - but the vocabulary also holds Latin sub-words, and non-Mandarin speech is decoded into
those. English therefore comes back looking like `@@`-spattered fragments rather than words: the
marker is a tokeniser internal that a detokeniser is supposed to consume by joining the piece to the
one before it, and here it reaches the caller as text.

The two halves are separable, and only one of them is this defect. That Paraformer answers English
at all is the model: it takes no language parameter and refuses nothing, so a Mandarin-only ASR
being fed English is a user error, not a bug. That the *string handed back* contains the
tokeniser's own control markers is the library's, and it would be worth fixing even if every
transcript were Mandarin - a caller has no way to tell a marker apart from text the model meant.

**Fix:** detokenise before returning - join a piece carrying the continuation marker onto its
predecessor and drop the marker, the standard BPE inverse. Failing that, document the returned
string as sub-word units rather than as text.

**What the app does:** treats a transcript containing `@@` as a failed dictation rather than
repairing it (`ParaformerLanguageGuard`). Repairing it would mean this app owning a detokeniser for
a vocabulary it does not ship, and the repaired text would still be English guessed at by a
Mandarin model - so the recording is kept, the user is told the engine is Mandarin-only, and
switching engine and pressing regenerate produces a real transcript. The guard has a second rule
behind the marker test because the markers are not guaranteed: the model also returns whole Latin
words, so a predominantly-Latin transcript is refused too.

**On a FluidAudio bump:** re-check whether `@@` still appears. If it stops, the marker rule becomes
dead weight and the Latin-share rule is the one carrying the case - but only for predominantly-Latin
recordings. A mostly-Mandarin recording with an embedded English sentence sits below the share
threshold by design (the guard's mixed fixture is 24 Han to 8 Latin letters, about a quarter), so
with the markers gone its mis-transcribed English reaches the transcript.
`ParaformerLanguageGuardTests` is written so the two rules can be seen failing independently.
Cantonese stays undetectable either way - it comes back as fluent, wrong Mandarin with no signal in
the output - which is why the engine's caveats say so instead.

## FunASR SenseVoice: inverse text normalisation mangles bare Chinese numerals

**Status:** to be filed against <https://github.com/FunAudioLLM/SenseVoice>. Not filed yet.

**Measured** on SenseVoiceSmall int8 and fp16 alike, `textNorm 14` (withitn):
`语音识别技术在过去十年里…` came back as `…在过去1年里…`. `十年` ("ten years") should normalise to
`10年`; it became `1年`, which is not a formatting difference, it is a different number. Times,
prices and dates in the same fixture are all correct (`3点20分`, `1250块钱`, `2026年7月30号`).

**How reproducible it is, honestly:** not universally. The original investigation hit it
repeatedly on one machine. Two later attempts on a different Apple-silicon machine, using the
fixture recipe in `SenseVoiceEngineIntegrationTests` verbatim (`say -v Tingting`, int8,
`textNorm 14`), got `过去十年` back intact - both through the engine's chunked path and through a
single unchunked call. So the failure is real and was observed directly, but it depends on
something not yet isolated: the acoustics of the particular synthesised audio, the exact
FluidAudio build, or the hardware. Treat it as a defect class - ITN can silently change a
numeral's value - rather than as a behaviour that fires on every run. That distinction is why
`EngineCatalog`'s SenseVoice copy says the conversion "can occasionally turn a bare numeral into
the wrong number" instead of quoting an example that does not reproduce for everyone, and
`EngineCatalogTests` asserts the copy does not overclaim.

**What the app does:** nothing, on purpose. Punctuation and ITN are one switch in the pinned
runtime - `14` gives both, `15` gives neither - so turning ITN off means shipping an unpunctuated
Chinese engine, which is the gap SenseVoice was chosen to close. Post-processing that tried to
undo ITN for bare numerals would be the app rewriting model output on a guess. The behaviour is
documented in engine-facing copy instead (`docs/speech-model-attribution.md`,
`SenseVoiceEngine.textNorm`, and the Settings copy in `EngineCatalog`).

**If it were fixed,** or if a future runtime separated punctuation from ITN, the fixed
`textNorm 14` becomes a choice worth revisiting rather than a forced pairing.
`SenseVoiceEngineIntegrationTests.testPunctuationAndInverseTextNormalisationAreOneSwitch` is what
notices the separation.

## FluidAudio: Parakeet's stateless window merge drops a clause on long audio

**Status:** to be filed against <https://github.com/FluidInference/FluidAudio>. Not filed yet.

**Measured** on FluidAudio 0.15.4 (`b9d43724`, the pin this app carries), `parakeet-tdt-0.6b-v3`,
Apple M5. `AsrManager.transcribeWithState` decodes a file of at most `ASRConstants.maxModelSamples`
(240,000 samples, 15 s) in one encoder call and hands anything longer to `ChunkProcessor`:
~14.96 s windows with 2 s of overlap, merged by token deduplication. On a 26.0 s synthesised
English fixture (`say -v Samantha`, four sentences with 0.9 s pauses;
`LiveDictationEngineParityTests` documents it) the whole-file decode returns
"Latency matters as well, many applications. The last sentence is a marker, …" - the clause
"expect an answer within a few hundred milliseconds of the speaker falling silent" is gone. Three
runs, identical output. The same file cut to 0-14 s, 14-26 s, 0-16 s, 16-26 s, 0-20 s, 8-26 s,
10-26 s and 12-26 s decodes every word, and so does a 35 s file made of `jfk.wav` three times, so
it is not the length alone but where this recording's windows and their merge fall.

**What the app does:** ships around it on the live path only. `LiveCutBudget.parakeet` caps an
utterance at one window less one encoder frame (`ASRConstants.maxModelSamples -
ASRConstants.samplesPerEncoderFrame`, 14.92 s), so a live utterance never reaches the merge;
`LiveCutPolicyTests` pins the value. The whole-file lane still hands FluidAudio the file whole,
so a Parakeet dictation of more than 15 s decoded from the WAV - every one with the live switch
off, and every fallback - can still lose words at a seam. Chunking Parakeet through
`AudioChunkSource` the way SenseVoice and Paraformer are chunked would close that and is a change
to the whole-file lane, not made here.

**On a FluidAudio bump:** run `LiveDictationEngineParityTests` with the Parakeet fixture and
compare the whole-file decode to the script. If the clause is back, the live cap can return to
28 s like the other engines' and the whole-file lane needs no chunker.

## FluidAudio: model-preparation progress is only half a download

**What was measured**, against the pinned FluidAudio: the `fractionCompleted` on
`DownloadUtils.DownloadProgress` is not the fraction of the thing the user is waiting for. In
`DownloadUtils.downloadRepo` every byte-progress report is scaled by `0.5` and explicitly capped
there (`fractionCompleted: min(fraction, 0.5)`, with the comment "Download phase occupies
0.0–0.5 of the overall range"), and `DownloadUtils.loadModels` spends `0.5...1.0` emitting
`.compiling`. So a finished 240 MB download reports `0.5`.

The compile half is worse than merely coarse: it reports `0.5 + 0.5 * index / count` over the
*model count*, which for SenseVoice is two models. It jumps 0.5 → 0.75 → 1.0 across a phase that
takes 65-88 s on a cold machine, so as a progress signal it is three values and a long silence.

**What the app does:** `ModelPreparationStage.from(_:)` is the one place that reads these reports,
and it makes exactly two kinds of statement:

- `.downloading` → a percentage, rescaled by `downloadShareOfOverallProgress` (0.5) so the bar
  spans the download the user is actually waiting on rather than stopping at half. The result is
  clamped to `0...1`, so a producer that ever reports the full range renders as a full bar rather
  than as 160 %.
- `.listing` and `.compiling` → no number at all. Both are shown as an indeterminate bar and
  `Preparing model…`. `.listing` reports `0.0` however much of the repository index has been read,
  and the compile's three steps are not a progress bar; a bar that keeps moving through a phase it
  cannot measure is a worse lie than one that admits it is waiting.

`ModelPreparationTests` pins all of it, including the clamp.

**If it were fixed** - if the phases carried their own fraction, or if the compile reported real
progress - `downloadShareOfOverallProgress` disappears and `.compiling` could become determinate.
`ModelPreparationTests.testDownloadFractionIsRescaledToTheDownloadsOwnSpan` is what notices the
scaling changing underneath.
