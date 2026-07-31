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

**Measured** on SenseVoiceSmall int8 and fp16 alike, `textNorm 14` (withitn), reproducible on
every run: `语音识别技术在过去十年里…` comes back as `…在过去1年里…`. `十年` ("ten years") should
normalise to `10年`; it becomes `1年`, which is not a formatting difference, it is a different
number. Times, prices and dates in the same fixture are all correct (`3点20分`, `1250块钱`,
`2026年7月30号`).

**What the app does:** nothing, on purpose. Punctuation and ITN are one switch in the pinned
runtime - `14` gives both, `15` gives neither - so turning ITN off means shipping an unpunctuated
Chinese engine, which is the gap SenseVoice was chosen to close. Post-processing that tried to
undo ITN for bare numerals would be the app rewriting model output on a guess. The behaviour is
documented in engine-facing copy instead (`docs/speech-model-attribution.md`,
`SenseVoiceEngine.textNorm`).

**If it were fixed,** or if a future runtime separated punctuation from ITN, the fixed
`textNorm 14` becomes a choice worth revisiting rather than a forced pairing.
`SenseVoiceEngineIntegrationTests.testPunctuationAndInverseTextNormalisationAreOneSwitch` is what
notices the separation.
