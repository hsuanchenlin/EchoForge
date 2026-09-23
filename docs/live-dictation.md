# Live dictation

Decoding a dictation while it is still being recorded, so the words appear on the capsule as
they are spoken and the wait after the key goes up is one utterance's decode rather than the
whole recording's. On by default (`liveTranscriptionEnabled`), switched off in Settings →
Shortcuts → Recording Behavior → "Live transcription", beside the capsule's own switch. An
install that turned it off keeps it off - the default only fills in for a switch nobody has
touched.

`OpenSuperWhisper/Live/` is the whole implementation. `LiveCutPolicy` and `CommittedTranscript`
are the pure half - where an utterance ends and how the pieces join - and this file is about
the other half: `LiveAudioTap`, `LiveDictationSession`, and how `DictationSession` and the
capsule use them.

The name has an older sense in these docs and in `Settings`: *live dictation* there is a
dictation from the key, as opposed to a dropped file, a queued recording or a regenerate - the
one path that routes spoken intents and corrections - whether or not this switch is on. This
file is about the switch, which the UI calls *Live transcription*.

## What it does and does not do

While a dictation is recording, audio is fed through the bundled Silero VAD, and every
utterance that has ended - a pause after enough speech, by the engine's `LiveCutBudget` - is
written out and decoded by the selected local engine in the background while the microphone
stays open. The committed text grows on the capsule's decoded-so-far line. When the user
stops, only the audio after the last cut is decoded, the pieces are joined, and the joined raw
transcript enters the unchanged post-processing pipeline: script normalisation, spoken
corrections, personal terms, rewriting, paste.

Three things it never does, and they are the design rather than its limits:

- **Nothing is pasted early.** Text reaches the target app once, at the end, after every stage
  of `docs/text-post-processing.md`. The stages run over whole texts and `StyleRewriteGuard`
  compares whole texts; pasting pieces would bypass all of them. (Upstream's unmerged
  `feat/live-text-insertion` branch pasted five-second batches directly and never landed.)
- **Nothing on screen is revised.** The line shows committed utterances only, the rule
  `PartialTranscript` already states. It grows; it never rewrites itself.
- **Nothing new leaves the Mac.** The buffer is in memory, the utterances go to the local engine
  already selected, and the cloud engine is never given a session:
  `LiveCutBudget.preset(for: .cloud)` is nil, so it stays at one request per dictation.
  `CloudPrivacyTests` scans `Live/` for anything that could build a request.

Only `DictationPurpose.dictation` sessions get a live decoder. ⌥A, ⌥S, ⌥E and ⌥Y are unchanged,
and so are file transcription, `echoforge transcribe`, History regenerate and the in-window
recorder - all whole-file. `LiveDictationEligibility.budget` is the one decision: the switch,
the purpose, the engine, and that timestamps are off (whisper's timestamps are offsets into the
file it was handed, which an utterance is not).

## The pieces

**`LiveAudioTap`** is the one hardware object: an `AVAudioEngine` input tap converted to 16 kHz
mono `Float`. It is *additive* to `AudioRecorder` - the recorder keeps writing the WAV that
History stores and that the fallback decodes; the tap is a second client on the same device,
which macOS allows, and owns no file. It pins the device the user chose
(`kAudioOutputUnitProperty_CurrentDevice`) rather than trusting the system default, because the
recorder switches that default on its own work queue after the press and a tap started a few
milliseconds earlier would open the old one. A device it cannot pin is a refusal, not a tap on
the default: that would be a transcript of whichever microphone the default happened to be, not
of the WAV. `start` costs CoreAudio round-trips and runs off the main actor, and a key that goes
up before it has returned is a fallback too - the tap was not hearing the recording, so
`finish` refuses to stand for it (`hasTapStarted`). Once up, the engine can stop itself with no
callback - macOS stops it when the input device is removed or changes format - while the
recorder goes on writing, so `isDelivering` is read on every poll and again before the tail, and
a tap that stopped is the same fallback as one that never started. Unifying both captures onto
one engine is a later change with its own risk.

**`LiveDictationSession`** owns the tap, the buffer, the poll, the policy, the joined text and
its state, and `DictationSession` sees `start`, `finish`, `cancel` and one published
`transcript`. Every `pollInterval` (0.5 s) it snapshots the uncommitted buffer, runs the VAD
off the main actor, and asks `LiveCutPolicy.cut`. A `.commit` is written out by
`LiveUtteranceFile` - the recorder's own format, so the engine sees the same quantisation a
whole-file decode would - and decoded through `TranscriptionService.decodeRaw`, which is the
same serialised, cancellable frame every other transcription runs in. So an utterance decode
queues behind a file-drop transcription and ahead of the next one exactly as a file does, and
`isTranscribing` is true while it runs - which is why the busy check in
`DictationSession.stop` is skipped for a live session (below).

`finish` keeps listening for the recorder's own stop tail (`AudioRecorder.stopTailDuration`, so
the end of the last word reaches both paths), stops the tap, lets the poll finish the step it is
in, then applies `LiveCutPolicy.tail` to what is left. The policy has two answers and the session
reads three: decoded if the tail holds the budget's minimum of detected speech; dropped if the VAD
found no speech in it at all, which is the same answer a whole-file decode gives for silence; and
a **fallback** when the VAD found speech but less than the minimum. The threshold was written for
the breath and key noise after a pause, and it still stands, but the whole-file decode keeps every
segment the VAD reports - so when it is a one-word dictation ("OK") or a short last word after a
pause ("…tag the release. Thanks."), the session cannot answer for the recording and the file is
decoded instead. It returns `.committed(raw:)` - possibly empty, for silence - or
`.fallback(reason)`.

The engine a session compares against is the kind **and the load**: `LiveUtteranceDecoding`
exposes `TranscriptionService.loadGeneration` beside `selection.active`, the session reads both
when it is made, and every poll and the finish check both. The kind alone cannot see another
Whisper model or another FluidAudio version loaded under the same `EngineKind`, and utterances
decoded by two models are not one transcript any more than two engines' are.

**`TranscriptionService.finishTranscribed`** is the third frame beside `transcribeAudio` and
`decodeRaw`: the post-processing pipeline over a raw transcript, with no engine touched, inside
the same `isTranscribing`/generation/serialisation frame. It has to be a frame rather than a
plain call to `finish` because `isTranscribing` is what the busy check and the capsule read: a
dictation pressed during the rewrite of live-decoded text must wait its turn exactly as one
pressed during a whole-file dictation's rewrite does, and the capsule must show that rewrite
as work in flight.

**The capsule** follows the session through `DictationSession.liveTranscript`, republished
by `IndicatorViewModel`, and `CapsuleHUDViewModel.showLiveTranscript` accepts it while recording as
well as during the decode. Once the live line has shown, the global
`TranscriptionService.partialTranscript` is ignored for the rest of the session: the tail
decode reaches that publisher too, as a fresh decode of one short piece, and letting it through
would replace the whole committed transcript with the last utterance's segments the moment the
key went up. `clearLiveTranscript` - what a fallback's `nil` publication calls - hands the line
back, so the whole-file decode's own segments show as they always did.
`docs/capsule-hud.md` has the rest.

## Every failure is a fallback

The recorder is still writing the WAV, so the live path is never allowed to make a dictation
fail; it can only make one slower than it would have been.

| Failure | Behaviour |
| --- | --- |
| The tap will not start (no input, device could not be pinned, format refused, engine refused) | `.unavailable`; the recording goes on; one `print` line; at stop the session counts as no session, so the busy check runs and the audio is queued as a file if the engine is in use, exactly as without the feature |
| The key goes up while the tap is still opening, or the tap fails to open after it | `.failed(.tapUnavailable)` from `finish`, which decodes nothing: the tap was not hearing the recording; a tap that then comes up is stopped the moment it does |
| The engine stops itself mid-recording (input device removed, format changed) | `.failed(.tapUnavailable)` on the next poll, or from `finish` before the tail - the buffer ends where the engine stopped, not where the key went up, and the WAV has the rest |
| An utterance decode throws (not a cancel) | `.failed(.decodeFailed)`; everything committed is dropped - a transcript with a hole in it is worse than a late one; capsule line cleared **first**; whole-file decode at stop |
| The tail decode throws | The same, even though everything before it decoded |
| The engine that would decode now is not the one the session started on (a model finished preparing, ⌥M carried out, the same kind loaded again with another model) | `.failed(.engineChanged)`; two engines' words joined are not one transcript, and neither are two models' |
| Uncommitted audio exceeds 2 × the engine's cap without a pause | `.failed(.bufferExceeded)`; the policy never cuts inside speech, and the WAV has it all |
| The engine changed between the last poll and the key going up | `.failed(.engineChanged)` from `finish`, before the tail is decoded - the same check the poll makes |
| The tail holds speech the VAD found but less than the budget's tail minimum (a one-word dictation, a short last word after a pause) | `.failed(.tailBelowMinimum)` from `finish`, with or without utterances already committed; the line is cleared and the WAV is decoded whole, which keeps every segment the VAD reports. A tail with no detected speech is silence and is dropped, not a fallback |
| Esc / cancel while recording | Buffer, committed text, tap and WAV all discarded; nothing pasted, no row |
| `AudioRecorder.failedStart` for this session | The dictation session ends the live session with the capture that never started (`endLiveSession`); a tap still opening when that lands is stopped the moment it comes up |
| Cancel button after the key went up (tail decode, finish, or a fallback's whole-file decode) | Nothing on the engine is interrupted: the work runs to its end and `DictationSession.transcribe` refuses its result because `didCancelWorkInFlight` is set - nothing pasted, no row, WAV discarded (below) |
| App quits mid-recording | As today: temp WAV survives 24 h, no row; an utterance file left behind is swept with it |

In every fallback the session publishes `transcript = nil` before anything else
(`teardown`), so a capsule following it shows nothing the whole-file decode is about to
contradict. `LiveDictationSessionTests` holds each row against a fake tap and a fake decoder.

A decode already in flight when the session is cancelled is not cancelled on the engine -
`cancelTranscription` cancels whatever is in flight, which may be a queue item's - so it
finishes and its words are dropped. The engine is busy for that utterance's decode, and a
dictation pressed inside it is refused as busy, honestly.

The capsule's cancel button after the key has gone up is the same rule one step later. On the
live path `DictationSession.cancelWorkInFlight` sets `didCancelWorkInFlight` and does **not**
call `cancelTranscription`: the busy check was skipped for this dictation, so the frame in flight
may be a dropped file's that the tail decode or the finish is waiting behind, and stopping that
would cancel somebody else's work. The tail decode, the finish or a fallback's whole-file decode
therefore runs to its end, `transcribe` reads `didCancelWorkInFlight` on either side of it and
throws, and the failure path discards the WAV without reporting a failure the user caused. Cancel
on the live path is a discard, not an interrupt; the engine stays busy until that work unwinds,
and a dictation pressed meanwhile is refused as busy. Without a session the cancel interrupts the
decode exactly as it always did.

## The busy check

`DictationSession.stop` used to ask `isTranscriptionBusy` before anything else and
queue the audio as a file if the engine was in use. A live session's own utterance decode
raises `isTranscribing` exactly like a queue item does, so that check has to come **after** the
live path: with a session, `finish` is awaited and the busy check is skipped; without one, the
check is exactly what it was. A queue item running when the user stops (a file dropped during
the recording) therefore makes the live session's tail decode and finish wait for it rather
than queueing the dictation - its decodes are its own to wait for. The fallback of a session
that failed also waits rather than queueing: `isTranscribing` is cleared a main-actor hop after
the last decode returned, so a busy check there would read the session's own frame. A session
that is `.unavailable` is the exception and is treated as no session: its tap never started and
it decoded nothing, so `isTranscribing` there is somebody else's work and the dictation takes
the queue path it always took.

## Settings are one snapshot

The `Settings` a dictation is finished with are built at the press when a live session starts,
carried on the session, and used both for every utterance decode and for the finish - so one
dictation cannot be decoded under one prompt and language and post-processed under another.
Without a session they are built at stop, as before. The one value a decode may see differently
is the language, below; `LiveDictationSession.settings` itself never changes.

## The language is decided once per session

On `auto`, whisper.cpp detects the language once per `whisper_full` call - on the first 30 s
window - and decodes the rest of the file in it. A live session hands the engine a file per
utterance, so left alone every utterance would be detected again: one extra encode each
(measured below: ~0.6 s of a 1.8 s utterance decode on `ggml-large-v3-turbo`), and a language
that could flip between utterances where the whole-file decode of the same recording would have
held one. `LiveLanguagePin` (`Live/LiveLanguagePin.swift`) restores the whole-file semantics one
utterance at a time: the first utterance decodes on `auto`, and if the engine's answer is a
**confident** detection - at least `minimumConfidence`, 0.5, "more mass than every other language
together" - every utterance after it, the tail at stop included, decodes in that language with no
detection at all.

Three things there are absolute, and `LiveLanguagePinTests` and the language cases in
`LiveDictationSessionTests` hold them:

- **It is per session.** The pin lives on the `LiveDictationSession` that made it and dies with
  it: the next press starts on `auto`, and a cancelled or fallen-back session takes its pin with
  it - the whole-file decode of the WAV runs on the settings the user chose, `auto` included.
- **It never touches an explicit language.** A session started on anything but `auto` decodes in
  that language throughout and no detection is consulted, whatever the engine reports.
- **It never writes a preference.** The pinned language reaches the copy of `Settings` each decode
  is handed (`LiveLanguagePin.applied(to:)`) and nothing else: `session.settings`, which the joined
  transcript is post-processed with and the fallback decodes the WAV with, still says `auto`, and
  `whisperLanguage` is never written by anything on this path.

Nothing pins on less than a detection: a report with no language (the FluidAudio engines, which
cannot say, and any decode that ran in a language it was *given* rather than detected), a
probability under the bar or outside 0...1, or an utterance that decoded to no words - by the rule
`CommittedTranscript` keeps an utterance by, so the `...` whisper writes for a breath the VAD took
for speech is dropped by the transcript and the pin alike, whatever the detector was sure of. Each
of those leaves the next utterance on `auto`.

**The seam.** `DecodedLanguage` and `RawDecode` (`Engines/DecodedLanguage.swift`) are what a decode
hands back beside its text, and `DecodeLanguageReporting` is the engine-side protocol - a separate
one, the way `PartialTranscriptEmitting` is, because exactly one engine has the answer.
`TranscriptionService.decodeRaw` returns `RawDecode`, asking the engine through that protocol when
it conforms and reporting nil otherwise; `transcribeAudio`, the whole-file lane, still calls the
engine's `transcribeAudio` and is unchanged. `WhisperEngine.transcribeAudioReportingLanguage` is
the same decode as `transcribeAudio` with one difference: on `auto` it runs whisper.cpp's own
detector itself (`whisper_lang_auto_detect_with_state`, before `whisper_full`) so the softmax
probability survives - `whisper_full` computes exactly this and keeps only the winner - and hands
`whisper_full` the winner as the language, which is what `whisper_full` does internally. The
encode it spends on window 0 is the one `whisper_full` would have spent on the same detection, so
the decode and its cost are the same; the table below measures both. A decode whose detection could
not run is left to `whisper_full` to detect for itself and reports no language, which the pin
refuses; a given language was not detected and is not reported either. An
English-only model has nothing to detect and would still be charged the encode; it is answered as
English with probability 1 - certain by construction - and `whisper_full` is handed `en`, the
convention whisper.cpp's own CLI applies. Prompt composition is untouched:
`WhisperInitialPrompt` is still composed per utterance exactly as per file.

`LiveDictationParityTests` holds the seam end to end: on `ggml-tiny.en.bin` the first utterance is
asked for `auto`, reports `en` with certainty, and every decode after it - the tail included - is
asked for `en`; an explicit language is asked for on every decode and never pinned over; and, opt-in
on the turbo model, 36 s of synthesised Mandarin is detected on its first utterance, pinned, and
the tail decoded without a second detection.

## Parity

`LiveDictationParityTests` feeds the tracked `jfk.wav` through a session half a second at a
time, cut by the real VAD and decoded by the real `WhisperEngine` on the tracked
`ggml-tiny.en.bin`, and asserts the joined text equals the whole-file decode of the same audio
modulo whitespace and punctuation. The clip three times over with pauses asserts an utterance
is committed *while recording* and that nothing is lost across the cut. The Whisper budget's 8 s
minimum is why it takes three clips: the VAD finds under 8 s of speech in the eleven-second
clip, so the first pause is too early to cut at. Regenerate from History re-decodes the whole
file and may differ at utterance boundaries; the raw text stored is what was pasted.

`LiveDictationEngineParityTests` is the same claim for the other three engines, on the opt-in
fixtures their integration tests document plus one of its own for Parakeet, and it skips rather
than downloads when the weights are absent. Every case was run against the pinned FluidAudio
0.15.4 on the synthesised fixtures; the numbers are what they measured, with the difference stated
as a character error rate over letters and digits (`TranscriptDistance`):

| Engine | Fixture | Cuts while recording | Live vs reference |
| --- | --- | --- | --- |
| SenseVoice-Small, `zh` | 36 s Mandarin | 1, forced by the 28 s cap into a 0.19-0.26 s gap | 0 characters differ from the whole-file decode; marker sentence kept |
| SenseVoice-Small, `auto` | 7 s mixed English/Mandarin | 0 (one tail) | 0 characters differ; both languages kept |
| Paraformer-large-zh | 36 s Mandarin | forced by the ~14 s cap | 0 characters differ; marker kept, no repeated tail |
| Paraformer-large-zh | 22.6 s dense Mandarin, one unbroken VAD segment | 0 - the policy never cuts inside speech; the engine's own chunker splits the tail | 0 characters differ; marker kept |
| Paraformer-large-zh | 7 s English | - | refused on the live path (`.fallback(.decodeFailed)`), then refused again by the whole-file decode: `unsupportedSpokenLanguage`, recording kept, exactly as before |
| Parakeet v3 | 26 s English with 0.9 s pauses | one per sentence, at the pauses | 0 characters differ from the **script**; the whole-file decode is not a reference here (below) |
| Whisper turbo, `auto` | 36 s Mandarin | 1, forced by the 28 s cap | pinned `zh` at p = 0.998; 0 characters differ from the script; the whole-file decode of the stitched clip omits the sentence before the marker and is not a reference either |

Two of those rows are findings rather than confirmations. On the pinned FluidAudio, Parakeet's
whole-file path windows anything over 15 s (`ASRConstants.maxModelSamples`, 240,000 samples) and
merges the windows by token deduplication, and on the 26 s fixture that merge **drops a whole
clause** - deterministically, across three runs, while every clip of 20 s or less kept it.
`docs/upstream-issues.md` has the reproduction. The live path keeps the clause because each
utterance is a sentence inside one window, and that is now what its budget guarantees:
`LiveCutBudget.parakeet` is capped at one window less one encoder frame (14.92 s, read off the
library's constants and pinned in `LiveCutPolicyTests`), so no utterance ever reaches the merge.
Only a tail of unbroken speech longer than that can, since the policy never cuts inside speech,
and the whole-file fallback hands FluidAudio the file whole as it always did. The Whisper row's
whole-file loss is on this app's own whole-file lane: the 36 s clip is stitched to speech-only
audio (`SpeechSegmenter.speechOnlySamples`) and decoded in whisper.cpp's 30 s windows, and the
14-character sentence before the marker is missing from that decode on every run tried - five of
five, `auto` and `zh` alike - while the same clip decoded untrimmed (timestamps on) carries it at
`[27.5->30.3]`, across the window boundary. The live path's utterances each sit inside one window
and keep it. Neither test holds the live path to a lossy reference; both hold it to the script.
The whole-file lane itself is untouched here, deliberately: it is every release's path and not
what this change is about.

What `say` does not exercise is the **pause cut**: it leaves 0.17-0.26 s between sentences
(measured with the bundled VAD on the Mandarin fixtures), under every engine's pause, so the
Mandarin fixtures exercise only the cap-forced cut, and the Parakeet fixture carries explicit
`[[slnc 900]]` marks to exercise the other. The pauses themselves - 0.6 s for the FluidAudio
engines, 0.7 s for Whisper - were not tuned by this: a person leaves more between sentences than a
synthesiser does, and a cut forced into a 0.19 s gap by the cap lost nothing on any fixture.

## What it costs, measured

Debug build, Apple M5, the tracked Silero VAD through `SpeechSegmenter.segments(in:)` on a
buffer of repeated `jfk.wav`, wall clock:

| Uncommitted buffer | One VAD pass |
| --- | --- |
| 0.5 s | 9 ms |
| 4 s | 125 ms |
| 8 s | 173 ms |
| 16 s | 269 ms |
| 28 s (the Whisper cap) | 478 ms |

Linear in the buffer, so every poll re-reads everything uncommitted and a long unbroken
utterance costs more per poll as it grows. The loop is serial - one VAD pass, then one decode,
then the next sleep - so the duty cycle is bounded at one core however slow a pass is, and a
pass that takes longer than `pollInterval` simply delays the next poll rather than stacking.
(whisper.cpp's own `vad time` log line is *cumulative* across calls on one context, which is
why it looks superlinear in a log.) Running the VAD over only the audio since the last pass
would cut this to a constant but the model is stateful across a call, so the segments over a
prefix are not the segments over the whole; it is a later measurement, not made yet.

End to end on the same machine, Debug build, SenseVoice-Small, `jfk.wav` played twice through
the speakers into the built-in microphone with the switch on: the line appeared during the
recording, and the capsule showed "Inserted" 0.7 s after the stop key for a 32 s recording; a
30 s silent recording reported "No speech detected" in 1.2 s. Neither run fell back.

**The language pin**, Debug build, Apple M5, `ggml-large-v3-turbo` with the app's own parameters
(beam 5, no timestamps, no prompt), `WhisperEngine` timed around one decode, best of three, each
clip written out the way an utterance is (`LiveUtteranceFile`):

| Clip | Detected | `auto`, detection by `whisper_full` | `auto`, detection by the reporting decode | Pinned |
| --- | --- | --- | --- | --- |
| `jfk.wav`, 11 s English | en, p = 0.971 | 1.75 s | 1.77 s | **1.17 s** |
| first 3 s of it | en, p = 0.967 | 1.39 s | 1.38 s | **0.82 s** |
| 8 s synthesised Mandarin | zh, p = 0.997 | 1.91 s | 1.89 s | **1.30 s** |
| 3 s of it | zh, p = 0.994 | 1.52 s | 1.62 s | **0.95 s** |
| 7 s synthesised Mandarin with English words | zh, p = 0.9955 | 1.65 s | 1.71 s | **1.08 s** |
| 36 s synthesised Mandarin | zh, p = 0.998 | 4.66 s | 4.74 s | **4.05 s** |
| SenseVoice model-card clips: zh, yue, en, ja, ko (5-7 s) | zh 0.977, zh 0.997, en 0.9996, ja 0.9992, ko 0.9986 | 1.43-1.77 s | 1.45-1.79 s | **0.88-1.19 s** |

Three things the table says. Reading the probability costs nothing: the reporting decode is within
noise of `whisper_full`'s own detection on every clip, because it spends the same encode. The pin
saves **0.55-0.7 s per utterance** however long the utterance is, which is one encode of a 30 s
window on this model - for a live dictation that is the tail decode after the key goes up, and
every utterance before it. And every clip, including the mixed one and Cantonese (which the
detector answers as `zh`), scored between 0.966 and 0.9996: `minimumConfidence` at 0.5 refuses
nothing a clear utterance produces. The pinned decode returned the same text as the `auto` decode
on every clip.

Every utterance file is a fresh `whisper_state`, so the pin is the only context that carries from
one utterance to the next: the typed prompt, the terms and the app vocabulary are composed per
utterance exactly as per file (`WhisperInitialPrompt`), and no previously committed text is fed
back as a prompt. That experiment - a rolling prompt of the last utterance's words - was left
undone on purpose: the parity above found nothing at the cuts for it to fix, and it raises the
repetition-loop risk the whisper.cpp default guards against.

## Rollback

Everything is behind `liveTranscriptionEnabled` and one object. Removing the feature is
deleting `OpenSuperWhisper/Live/LiveAudioTap.swift`, `LiveDictationSession.swift`,
`LiveLanguagePin.swift` and `LiveUtteranceFile.swift`, the `liveSession` wiring in
`DictationSession`, `showLiveTranscript` on the capsule, `finishTranscribed` and the preference
key. `DecodeLanguageReporting` and `RawDecode` can stay or go with it; the whole-file lane never
reads them. No schema, model-pack or CLI change exists to roll back.
