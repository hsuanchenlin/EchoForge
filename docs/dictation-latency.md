# Dictation latency and queue reliability

What a dictation costs between the key and the paste, what of that turned out to be worth
removing, and what did not. It is here so the next person to go looking does not re-measure
the same four things.

## What was measured

Apple silicon, Debug build, XCTest host, medians over 50 runs unless stated. The harness was
a throwaway test that timed each call and wrote the numbers to a file; it asserts nothing, so
it was not committed. Reproducing it is a dozen lines against the symbols named below.

| Per-dictation step | Median | Notes |
| --- | --- | --- |
| `EngineAvailability.current()` | **0.10 ms** | `refreshSelection()` at the head of every transcription |
| — `WhisperModelManager.getAvailableModels()` | 0.025 ms | directory listing |
| — `EngineAvailability.isFluidAudioDownloaded` | 0.023 ms | |
| — `SenseVoiceEngine.isModelDownloaded` | 0.014 ms | |
| — `ParaformerEngine.isModelDownloaded` | 0.021 ms | |
| `Settings()` | **0.006 ms** | built once per dictation, reads preferences and the terms dictionary |
| `AudioUtil.audioDuration(url:)` | **0.21 ms** | fresh 10 s 16 kHz WAV each time; 2.2 ms on the first asset load in a process, 0.79 ms worst of 20 |
| Progress fan-out, 100 ticks | **3.3 ms** | one whisper recording's worth, engine callback → `TranscriptionService.progress` → the queue's sink |

## What that says

**The app's own glue is not where the time goes.** Everything a dictation pays outside the
engine and the rewriting stage adds up to well under a millisecond. Three hypotheses were
tested and all three came back negative:

- *"`refreshSelection()` does synchronous filesystem work on the main actor at the head of
  every transcription."* It does, and it costs 0.10 ms. Moving it off the main actor, caching
  it behind a TTL, or skipping it when the engine already matches would each trade a documented
  guarantee - that a model cache deleted while the app runs is noticed - for a tenth of a
  millisecond. **Do not.**
- *"`Settings()` re-reads the personal terms dictionary per dictation."* It reads
  `PersonalTermsStore.shared.activeTerms`, which is in memory. 0.006 ms.
- *"~100 progress ticks per whisper recording overwhelm SwiftUI or the database."* They do not.
  Ticks have not touched the database since `updateRecordingProgressTransient` was introduced -
  `TranscriptionQueueBehaviourTests` pins that - and the whole hundred cost 3.3 ms end to end.
  A throttle would be complexity bought with nothing.

What *does* dominate is the engine decode and, when it is on, the style-rewriting stage. The
rewriting stage is the product's chosen quality and may not be traded for a benchmark. The
engine decode turned out to be something else for SenseVoice - an upstream defect, not a
property of the model; see the next section.

## The SenseVoice decode was the whole wait

Measured September 2026, Apple M5, macOS 26.6, against a 36.0 s synthesised-Mandarin fixture
(~100 words, `say -v Tingting`, the recipe in `SenseVoiceEngineIntegrationTests`), engine
sensevoice, language auto:

| Path | Warm | Cold |
| --- | --- | --- |
| Installed 0.9.6, file → settled row (3 runs) | 23-25 s | > 600 s (first use after hours idle, machine under load) |
| Master, XCTest host, pre-fix | 6.99 s | 90.2 s (fresh process: ~85 s ANE compile, ~0.15 s warm load) |
| Master, XCTest host, **post-fix** | **0.93 s** | compile unchanged |

A stack sample of the shipped 0.9.6 mid-transcription put over 90 % of the warm wall time in
`-[MLMultiArray objectForKeyedSubscript:]` and `NSNumber` allocation - FluidAudio 0.15.4's
fp16 CTC decode, reading ~12 M logits one boxed number at a time. Under memory pressure that
allocation churn is also why the cold/contended case ran to minutes rather than seconds. The
fix owns the decode (`OpenSuperWhisper/Engines/SenseVoiceDecoding.swift`, a vDSP argmax - the
same fix upstream later wrote as `LogitsArgmax`), and the same 36 s recording decodes in under
a second; the parity test pins the output byte for byte against the pinned manager. The cold
column is unchanged by it: the ~85 s Neural Engine compile after ANE cache eviction is CoreML's,
and the decode fix neither causes nor cures it - but it is paid once per eviction, not once per
dictation.

For comparison on the same machine: whisper `large-v3-turbo` decodes the same 36 s fixture
whole-file in ~4.7 s (the table below), so pre-fix SenseVoice - the engine chosen for Chinese
speed - was the slowest path the app ships, warm or cold.

## The live path: where the decode goes, and what one encode costs

Live dictation (`docs/live-dictation.md`) does not make the decode cheaper; it
moves it earlier, so the wait after the key goes up is the last utterance's decode rather than
the recording's. What it can make cheaper is the one thing whisper.cpp does once per call rather
than once per window: language detection on `auto`. Measured on `ggml-large-v3-turbo`, Apple M5,
Debug build, `WhisperEngine` timed around one decode, best of three:

| Utterance | `auto` | language pinned | saved |
| --- | --- | --- | --- |
| 3 s English (`jfk.wav`, first 3 s) | 1.38 s | 0.82 s | 0.56 s |
| 11 s English (`jfk.wav`) | 1.77 s | 1.17 s | 0.60 s |
| 8 s synthesised Mandarin | 1.89 s | 1.30 s | 0.59 s |
| 36 s synthesised Mandarin | 4.74 s | 4.05 s | 0.69 s |

The saving is one encode of a 30 s window on this model, ~0.6 s, and it is the same whatever the
utterance holds - which is also why a short utterance costs as much as a long one, and why
`LiveCutBudget.whisper` asks for 8 s of speech before it cuts. `LiveLanguagePin` takes that
encode off every utterance after the first, the tail included: for a live Whisper dictation on
`auto` the post-stop wait is a pinned tail decode, ~1.2 s for a sentence on this model, and the
rewriting stage. Reading the detection's probability, which is what makes the pin safe, costs
nothing measurable - the reporting decode spends the encode `whisper_full` would have spent on
the same detection (the full table, with probabilities, is in `docs/live-dictation.md`).

The FluidAudio engines have no such encode and nothing to pin; on them the live path's whole
gain is the earlier decode. Their per-engine parity, and the one budget it changed, are in the
same file.

## A slow engine is bounded

Every engine load and decode runs inside the same `TranscriptionService` frame, so an engine
call that never returns used to own that frame forever. Later dictations, live utterances and
queued files all waited behind it. Cancellation was not a sufficient bound: Whisper can be
inside `whisper_full`, and the FluidAudio engines can be inside an atomic CoreML prediction,
where task cancellation is not observed until the call returns.

The two waits now use `AsyncDeadline`, whose result does not depend on the losing operation
cooperating with cancellation:

- A load has 900 s. The limit is above the observed cold Neural Engine compile under pressure,
  but finite when model loading or its coordinator is deadlocked.
- A decode has `max(120 s, 10 x audio duration)`. The floor leaves room for a loaded machine and
  first-use overhead on short dictations; the factor keeps long file transcription proportional
  to the work it legitimately has to do.

A decode that exceeds its deadline is cancelled through the engine adapter, the engine instance
is discarded, and the frame is released. The next caller loads a fresh instance rather than
sharing state with work that may still be stuck in the old one. A load timeout also releases the
frame and lets the next caller retry. Both paths return `processingTimedOut`; dictation keeps the
recording and tells the user it timed out, so History can regenerate it. There is no automatic
engine fallback because changing engines can change language support and output semantics without
the user choosing that tradeoff.

`TranscriptionLatencyAndTimeoutTests` is the regression harness. Its non-cooperative stub engines
reproduce permanently hung load and decode calls, then prove the deadline releases the frame,
queued and concurrent callers resolve, and a retry reloads instead of reusing the suspect engine.
It also generates 5 s, 30 s and 60 s 16 kHz audio fixtures and measures the whole service path
against proportional decode work. The timing assertions are intentionally loose enough for CI;
they detect a serialization wedge or pathological pipeline overhead, not ordinary machine speed.

## What was changed

**The duration read now overlaps the transcription** rather than preceding it
(`DictationSession.stop`). Its answer is not needed until a row is written, so
there is no reason to pay even 0.21 ms before the engine can start. The bigger version of
this fix - returning the duration from `AudioRecorder.stopRecording`, which already computes
it as `recorder.currentTime` and throws it away, so the file is never reopened at all - was
**not** done: it changes a return type across four call sites to save a fraction of a
millisecond, and the measurement does not justify it.

**A cancelled queue item is no longer transcribed again.** This is the one large avoidable cost
on this path and it is worth stating in latency terms as well as reliability terms: a whole
duplicate engine run, in front of every dictation queued behind it, with live dictation refused
for the duration - and on the cloud engine, a second paid request the user never asked for.
`RecordingStore.getNextPendingRecording` counts `.pending`, `.converting` **and**
`.transcribing` as pending; cancelling only added the id to a set and `processRecording`
returned without touching the row, so the loop was handed the same row back on the next turn.
`TranscriptionQueueStep` is the rule now, and it is a decision about progress rather than about
identity - a row the user regenerates while the loop is still draining is new work, not a repeat.

That rule is only as good as what a pass reports, so the writes report:
`updateRecordingProgressOnlySync`, `updateRecordingStatusOnly` and `deleteRecordingSync` return
whether the write landed instead of printing the error and swallowing it, and every exit of
`processRecording` hands that answer back. A pass that answered `true` regardless was the same
bug in different clothes - a cancelled row whose write never landed stayed `.converting`, came
round again, and was read as a regenerate. A row that is already gone still counts as settled;
only a write that failed does not, and such a row is written out once and then left alone.

## Reliability fixed alongside it

- **A microphone that never opens now says so.** `AudioRecorder.startRecording` claims the
  microphone synchronously and returns, then pays CoreAudio's 20-35 ms on its work queue, so
  both ways a start can fail happen *after* the caller has been handed its session. The claim
  was given back there and nothing else was: the dictation card blinked "Recording..." over a
  microphone that never started, and the press that ended it got `nil` from `stopRecording` and
  closed the session without a word. The Ask panel had the same hole and reported it as "No
  speech detected". `AudioRecorder.failedStart` is the report, and it names its session because
  five keys share one recorder and `@Published` replays. Every surface that takes the microphone
  subscribes to it - the dictation card, the Ask panel and the main window's record button,
  which had only `isRecording` going false to go on and never sees that at all when the start
  found no audio input. `FailedRecordingStart.ends(_:)` is the whole subscription rule, and a
  source scan in `FailedRecordingStartTests` keeps every surface that takes the microphone
  watching it.
- **Cancelling a transcription now cancels it, and only it.** `cancelTranscription` used to
  raise a shared `isCancelled` flag and drop it again inside one synchronous main-actor call,
  so every check of it in the running task read `false` and an engine that answered a moment
  too late still had its transcript pasted. It also cleared `transcriptionTask` and
  `isTranscribing` - the handle the serialization loop waits on and the app's answer to "is the
  engine free" - so a dictation started right after a cancel could run concurrently with the one
  it cancelled, on the same whisper context. Both are generation-scoped now
  (`transcriptionGeneration`, `cancelledGeneration`): a transcription's teardown may publish
  only over its own generation, and one dictation's cancellation cannot reach the next.
- **The engine is reserved before it is loaded, not after.** The handle the serialization loop
  waits on used to be a box around the work task, stored only once that task existed - and
  between the loop and the task sits the engine load, a detached task the frame suspends on.
  A second caller arriving during that suspension found no task, passed the loop, and ran
  beside the first on the same engine: an utterance decode from a live session beside a queued
  file, or the queue's first item at launch beside the first dictation. `runTranscription` now
  reserves a `TranscriptionFrame` synchronously with the generation bump, before `prepare` can
  suspend, binds the work task to it once prepared, and releases it in its own `defer` - so a
  load that throws or a frame cancelled mid-load gives the engine back rather than holding
  every later transcription for the life of the process. `TranscriptionSerializationTests`
  stands a second caller inside the load and asserts that it waits, that a cancel during the
  load stops that frame, that a failed load releases it, and that a dozen concurrent callers
  never overlap.
- **The queue always stops being busy.** `isProcessing` gates
  `DictationSession.isTranscriptionBusy`, which refuses to start a dictation at all, so a loop
  that does not return is not a stuck row - it is an app that no longer dictates. The flag now
  comes down in a `defer`, the loop has a bounded escape when a row will not leave the pending
  set, and the cancelled-id set is cleared rather than growing for the life of the process.

Nothing here retries. A cancelled item is written out as cancelled and a failed one as failed;
neither is re-run without the user pressing regenerate.
