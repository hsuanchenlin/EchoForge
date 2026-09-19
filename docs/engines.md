# Engines: selection, recovery, preparation and the catalog

`OpenSuperWhisper/Engines/` holds every speech engine and everything that decides which one
runs. This document is the map of that directory and the rules that hold it together; the
feature-level stories live beside it:

- [engine-shortcut.md](engine-shortcut.md) - the ⌥M engine shortcut.
- [model-packs.md](model-packs.md) - how weights are published and installed.
- [model-inventory.md](model-inventory.md) - the storage, removal and recommendation rows in Settings.
- [starter-model.md](starter-model.md) - the opt-in bundled model.
- [bilingual-dictation.md](bilingual-dictation.md) - English and Chinese in one utterance.
- [live-dictation.md](live-dictation.md) - decoding while the microphone is open.
- [speech-model-attribution.md](speech-model-attribution.md) - licence obligations per model.
- [upstream-issues.md](upstream-issues.md) - FluidAudio defects the app ships around.

## Registration

`OpenSuperWhisper/Engines/EngineKind.swift` owns the engine registration, persistence, factory
and language-handling contracts. Follow its documentation when adding an engine. `EngineKind`
is switched exhaustively in over a dozen places, which is why the offline-only build variant
is one value (`CloudBuild.isCompiledIn`) rather than `#if` around a case - see
[cloud-api.md](cloud-api.md).

## Chosen versus active

The engine the user *chose* and the engine that can transcribe *now* are two different
values, and keeping them apart is the load-bearing rule of this area. `EngineSelector`
(`Engines/EngineSelection.swift`) is the pure function that picks the active one: the desired
engine when it can load, else the last one that actually loaded (`lastReadyEngine`), else the
starter model - and the interim tiers must also support the dictation language, since
Paraformer returns fluent Mandarin for German rather than refusing it. Nothing in that path
ever writes `selectedEngine`. `TranscriptionService` publishes the result as `selection`,
prepares the desired engine in the background (`ModelPreparation`), and switches over when
it is ready.

`EngineKind.usesCloudProvider` states once that the cloud engine is never chosen *for* the
user: `EngineSelector` skips it in both interim tiers, `EngineConfiguration.recoveryOrder`
never recovers onto it, and `EngineCatalog.pickerOrder` has no row for it - it is first
selected in the Cloud pane, where the consent sheet is.

## Recovery at launch

`OpenSuperWhisper/Engines/EngineConfiguration.swift` is the single answer to "can this app
transcribe, and with what?" - it checks the stored engine against what is downloaded,
recovers onto another downloaded engine when it cannot load, and reports `.unavailable` when
nothing can. `recoverIfNeeded`, the call that writes that recovery, runs only once - at
launch, before anything constructs an engine - and it skips a selection whose download was in
flight when the app quit (`pendingEnginePreparation`), so quitting mid-download does not undo
the choice that started it. Every check after that is read-only.

Anything that would leave the app with an engine it cannot load - a new onboarding path, a
new engine, a new way to reach `hasCompletedOnboarding` - has to go through it.
`EngineConfigurationTests`, `EngineSelectionTests` and `BackgroundModelPreparationTests` pin
the recovery order, that a working configuration is never changed behind the user's back,
and that no fallback ever becomes the user's selection; when nothing can transcribe the user
is told (`DictationFailureOutcome`) and their audio is kept as a failed recording rather
than deleted.

## Carrying out a choice

A user's engine choice is carried out in exactly one place, `EngineSelectionCommand`, shared
by the Settings picker, the Cloud pane's toggle and the ⌥M engine shortcut - it writes
`selectedEngine`, moves the dictation language when the new engine cannot do it, keeps
`CloudTranscriptionSelection`'s bookkeeping, posts `.selectedEngineChanged` for an open pane
to follow, and reloads the service. The shortcut itself is `EngineCycle` plus
`EngineSwitcher`; [engine-shortcut.md](engine-shortcut.md) is its whole story, including the
three absolute rules (never land on an engine that could not transcribe the next dictation,
defer a press during a dictation, offer the cloud engine only on `CloudAccess.isSelectable`)
and why `EngineSwitchHUD` is drawn on every display.

## Preparation is never modal

History stays open, searchable and playable throughout, and dictation is disabled only when
`EngineSelector` finds nothing at all. Progress is a percentage only for byte-download phases
and an indeterminate `Preparing model…` otherwise - `ModelPreparationStage` is the one place
that decides which, and [upstream-issues.md](upstream-issues.md) records why FluidAudio's own
fraction cannot be used as-is. Transcription progress and model-preparation progress are
separate published values and must stay that way; they overlap routinely.

`Engines/EngineWeightsPreparation.swift` is the one place "make this engine's weights ready"
turns into fetched bytes, and all three paths that fetch weights go through it - background
preparation, Settings and onboarding. None of them may call an engine's `prepareModels`
itself; that bypass is what a published pack exists to close, and a source scan in
`EngineWeightsPreparationTests` fails if one appears. `ModelPackSelection` is the pure
decision, and refuses a pack whose cache folder or entries do not match what the engine
loads. A failed pack falls back to the engine's own downloader and a cancelled one does not,
and the engine's own preparation always runs afterwards because only it can pay the Neural
Engine compile. [model-packs.md](model-packs.md) is the whole story, including why a release
is thin and why every field of `OpenSuperWhisper/ModelPacks.json` names bytes that are
already published.

The bundled path still exists and is opt-in (`ECHOFORGE_BUNDLE_STARTER_MODEL=1`):
[starter-model.md](starter-model.md). Bundling weights changed a licence position that
[speech-model-attribution.md](speech-model-attribution.md) had stated absolutely; read that
file before bundling or publishing anything else. Model weights are otherwise downloaded at
runtime and never bundled into the `.app` - some are redistributed under licences that
require attribution and forbid rebranding, so any engine whose model the app downloads needs
an entry there.

## Tests must not download models

`TranscriptionService` skips both the engine load and background preparation under
`OpenSuperWhisperApp.isRunningTests`, because a test pins `availability` to describe a Mac it
is not running on; assert the decision through `refreshSelection(availability:)`, which is
pure. Model-backed regression tests are opt-in on locally generated fixtures under
`OpenSuperWhisperTests/Fixtures/` (gitignored); each engine's integration test documents how
to generate its own, and fixture filenames must be unique across engines because the test
bundle flattens them all into one Resources directory.

## The catalog and onboarding

`OpenSuperWhisper/Engines/EngineCatalog.swift` owns everything user-facing about an engine -
picker name and order, the honest caveats, download size, cache path and the attribution
links. Settings and onboarding both read it; neither may write a second copy of the copy.
`EngineCatalogTests` pins the licence obligations (the model name must survive in the UI,
the credit and three links must exist) and the caveats, so shortening that text fails a test
instead of quietly dropping an obligation.

`OpenSuperWhisper/Onboarding/OnboardingModelCatalog.swift` is the first-run model list: which
rows are offered, in what order, and to whom. A row that exists for one language is shown
only to users dictating it (or who already downloaded it), the same rule Settings applies to
the Hebrew Whisper fine-tune. `OnboardingModelCatalogTests` pins the ordering, the
recommendation and that engine rows take their name, size and caveats from `EngineCatalog`.

Onboarding's one obligation is that the row it shows as selected is the row whose engine is
persisted - including the automatic selection of an already-downloaded row, which for one
release set only `selectedModelId` and shipped users past onboarding with no engine at all.
Every selection goes through `selectModel`, and `commitSelectedModel` is the guard on the
way out; `OnboardingEngineSelectionTests` injects the download state so both hold without a
download.

## The shared audio path

`OpenSuperWhisper/Engines/Audio/` is the engine-neutral audio path every engine shares:
16 kHz PCM decoding, the bundled Silero VAD, and chunking for engines with an input ceiling.
An engine must not reach into another engine for any of it. Engines whose backend rejects or
silently clamps long input take `AudioChunkSource` with an `AudioChunkBudget`; the budget
type documents why each limit exists and `OpenSuperWhisperTests/AudioChunkerTests.swift`
pins them. `LiveCutPolicy` and `CommittedTranscript` (`OpenSuperWhisper/Live/`) are the pure
half of live dictation and are described in [live-dictation.md](live-dictation.md).

## Refusing a language after the fact

Mixed English and Traditional Chinese in one utterance is ordinary speech here, and
`EngineKind.bilingualDictation` is the one place the engine for it is named (SenseVoice
today). `EngineKind.transcribesEnglishAndChineseTogether` is switched exhaustively and true
for exactly one engine; [bilingual-dictation.md](bilingual-dictation.md) is the whole story.

An engine that cannot refuse a language has to refuse its own output instead. Paraformer
takes no language parameter, so `LanguageUtil.paraformerLanguages` locking the picker to
`zh` does nothing about somebody speaking English: the model answers, as the tokeniser's
sub-word units with `@@` continuation markers in them, and that used to be pasted into
whatever the user was typing in. `ParaformerLanguageGuard` reads the joined transcript before
the engine returns it and fails the dictation - `TranscriptionError.unsupportedSpokenLanguage`,
which `DictationFailureOutcome` keeps the recording for, so switching engine and pressing
regenerate is all it costs. Three rules there are absolute:

- It classifies **output only**: nothing retokenises, strips markers or repairs a
  transcript, because text that had to be repaired to be shown is a guess pasted into
  someone's editor.
- The `@@` rule never stands alone - the model also returns whole Latin words, and the
  marker depends on an upstream defect that may be fixed - so every predominantly-English
  marker case in `ParaformerLanguageGuardTests` has a twin without one that the Latin-share
  rule has to catch by itself.
- It is tuned to fire rather than to be certain, because a false positive costs a kept
  recording and one press while a false negative is corruption in the user's document.

Two cases sit outside both rules. Cantonese has no signal in the output at all - it comes
back as fluent, wrong Mandarin - and the engine's caveats say so instead. And a
mostly-Mandarin recording with an embedded English sentence is refused today only by its
`@@` markers: the mixed fixture is 24 Han to 8 Latin letters, about a quarter, a share the
guard accepts by design, so if upstream fixes detokenisation the share rule lets it through
and that mis-transcribed English reaches the user's transcript.

## Measured limits

Engine limits are measured against the pinned FluidAudio, not read off its config constants,
because several of them mislead. Defects found there that the app ships around rather than
patches - and the reasons - live in [upstream-issues.md](upstream-issues.md); add to it
instead of rediscovering them. One of them the app no longer ships around: SenseVoice's
pipeline is app-owned in `OpenSuperWhisper/Engines/SenseVoiceDecoding.swift`, with
`SenseVoiceEngineIntegrationTests.testTheAppSideDecodeMatchesFluidAudiosByteForByte` pinning
its output against the manager's.
