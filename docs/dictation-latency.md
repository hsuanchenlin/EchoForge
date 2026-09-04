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

What *does* dominate is the engine decode and, when it is on, the style-rewriting stage. Both
are the product's chosen quality, not overhead, and neither may be traded for a benchmark.

## What was changed

**The duration read now overlaps the transcription** rather than preceding it
(`IndicatorViewModel.startDecoding`). Its answer is not needed until a row is written, so
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

## Reliability fixed alongside it

- **A microphone that never opens now says so.** `AudioRecorder.startRecording` claims the
  microphone synchronously and returns, then pays CoreAudio's 20-35 ms on its work queue, so
  both ways a start can fail happen *after* the caller has been handed its session. The claim
  was given back there and nothing else was: the dictation card blinked "Recording..." over a
  microphone that never started, and the press that ended it got `nil` from `stopRecording` and
  closed the session without a word. The Ask panel had the same hole and reported it as "No
  speech detected". `AudioRecorder.failedStart` is the report, and it names its session because
  five keys share one recorder and `@Published` replays.
- **Cancelling a transcription now cancels it, and only it.** `cancelTranscription` used to
  raise a shared `isCancelled` flag and drop it again inside one synchronous main-actor call,
  so every check of it in the running task read `false` and an engine that answered a moment
  too late still had its transcript pasted. It also cleared `transcriptionTask` and
  `isTranscribing` - the handle the serialization loop waits on and the app's answer to "is the
  engine free" - so a dictation started right after a cancel could run concurrently with the one
  it cancelled, on the same whisper context. Both are generation-scoped now
  (`transcriptionGeneration`, `cancelledGeneration`): a transcription's teardown may publish
  only over its own generation, and one dictation's cancellation cannot reach the next.
- **The queue always stops being busy.** `isProcessing` gates
  `IndicatorViewModel.isTranscriptionBusy`, which refuses to start a dictation at all, so a loop
  that does not return is not a stuck row - it is an app that no longer dictates. The flag now
  comes down in a `defer`, the loop has a bounded escape when a row will not leave the pending
  set, and the cancelled-id set is cleared rather than growing for the life of the process.

Nothing here retries. A cancelled item is written out as cancelled and a failed one as failed;
neither is re-run without the user pressing regenerate.
