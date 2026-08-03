# Upstream issues

Defects this project has measured in a dependency and decided to live with, rather than work
around in the app. Each entry says what was measured, what the app does about it today, and what
would change if it were fixed - so a dependency bump has something to re-check against, and so
nobody re-diagnoses a known problem from scratch.

An entry belongs here when all three are true: the defect is reproducible, it is in code this
project does not own, and the app is shipping anyway. Fixes we *did* work around belong in the
code that works around them, not here.

## FluidAudio: SenseVoice decode reads fp16 logits through `NSNumber`

**Status:** to be filed against <https://github.com/FluidInference/FluidAudio>. Not filed yet.

**Measured** on FluidAudio 0.15.4 (`b9d43724`, the pin this app carries), Apple M5:
SenseVoice-Small runs at ~8x real time - about 3.4 s for a 28 s utterance - against Paraformer's
~65x. The model is not the problem: the ANE encoder returns in ~0.09 s (~310x). About 97 % of the
wall time is in `SenseVoiceManager.decode`, which falls to its `else` branch because the encoder
emits **float16** `ctc_logits`, and then reads all ~11.9 M elements one boxed
`logits[[0, t, v]].floatValue` at a time. The float32 branch immediately above it does the same
work over a raw pointer.

**Fix:** an fp16 fast path mirroring the existing float32 one.

**What the app does:** ships at the measured speed. 3.4 s for a 28-second thought is usable for
record-then-transcribe dictation and still far faster than whisper-large; it is just not the
"instant" the vendor's numbers imply. `SenseVoiceEngine` reports progress per chunk for exactly
this reason. The app deliberately does **not** run the encoder and decode CTC itself - that would
be ~40 lines and an ~8x win, at the price of owning a decoder that has to stay in step with
upstream.

**On a FluidAudio bump:** re-measure. If the fast path landed, SenseVoice should jump to roughly
Paraformer's order of magnitude and the per-chunk progress becomes cosmetic rather than load-bearing.

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
