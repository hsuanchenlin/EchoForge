# Model inventory and disk management

Settings → Model, below the engine picker: every engine's weights as they exist
on this Mac, what they cost, and the safe things to do about them.

It exists because the app knew all of this and showed none of it. The catalog
knows what a cold machine downloads, each engine knows whether its cache will
load, and the recordings directory has always had a size - but a user asking
"what is this app costing me, and what can I delete" had a folder of `.mlmodelc`
directories and a Finder window. Worse, the two states that matter most were
invisible: a half-finished download, which looks exactly like nothing, and the
one remaining engine that can transcribe, which looks exactly like the others.

## What a row says

Each row leads with the **outcome** and keeps the model name beside it.

| Engine | Outcome | Model name |
| --- | --- | --- |
| Whisper | The widest language coverage | Whisper |
| Parakeet | Fast English and European dictation | Parakeet |
| SenseVoice | English and Chinese in one sentence, and Chinese on its own | SenseVoice-Small |
| Paraformer | The most accurate Mandarin characters | Paraformer-large (zh) |
| Cloud | Someone else's server, with your own key | Cloud (OpenAI-compatible) |

Both halves are load-bearing and neither replaces the other. The picker above
this list asks a user to choose an implementation before anything has told them
what the implementations are for, which is what `EngineCatalogEntry.outcome`
answers; and retaining the model name is a licence obligation
(`docs/speech-model-attribution.md`), which is why `displayName` is on every row
too. `EngineCatalogEntry.character` is the third line - how the engine trades
quality against speed, as a measurement rather than an adjective.

## Readiness is not a badge

`ModelReadiness` distinguishes what a "downloaded" checkmark could not:

- **Ready** - the engine's own `modelsExist` check says it will load.
- **Incomplete** - bytes are on the disk and the engine's check says no. An
  interrupted download leaves exactly this, and without a name for it the only
  visible symptom is a model that downloads itself again on every launch.
- **Not installed** - nothing there.
- **Downloading n% / Preparing** - in flight. The percentage exists only for the
  byte phases; the Neural Engine compile publishes no fraction, so the row says
  `Preparing` rather than showing a bar that has stopped moving
  (`ModelPreparationStage`).
- **No local weights** - the cloud engine, whose model is the provider's. It is
  listed rather than hidden, because a user counting what is on their disk is
  entitled to see the one engine that puts nothing there.

Sizes are **measured**, not advertised. `DirectorySize.bytes` walks the cache and
reports allocated size, because the advertised figure and the real one disagree
in both directions: a CoreML cache is larger than the archive it arrived in, a
half-finished download is smaller, and a cache the user deleted from Finder is
zero while every "240 MB" label in the app goes on claiming otherwise. Parakeet's
two model versions both count - a user who has tried both is paying for both.

## Removing weights

`ModelRemoval.decide` is a pure function and the only thing that decides. It
**refuses** four cases, each with a sentence rather than a disabled button:

| Refusal | Why |
| --- | --- |
| `engineIsInUse` | A transcription is running on it. Its CoreML models are mapped, and deleting the files under them is how a decode ends in a crash rather than a transcript. |
| `engineIsBeingPrepared` | A download is writing into that directory. Deleting it leaves the half-cache above. |
| `nothingInstalled` | There is nothing there. |
| `engineHasNoWeights` | The cloud engine keeps none. |

and it names the **consequence** of every removal it allows:

| Consequence | The user is told |
| --- | --- |
| `none` | It is not what dictation is running on. A download gets it back. |
| `losesTheActiveEngine(fallback:)` | It *is* what dictation runs on, and this is what takes over. |
| `leavesNothingThatCanTranscribe` | Dictation stops until a model is downloaded again. |

The fallback is resolved against what would be left - `availability` minus this
engine - because "what still works afterwards" is a different question from
"what works now". A configured cloud engine is **never** the answer: the same
rule `EngineSelector`'s interim tiers and `EngineConfiguration.recoveryOrder`
keep, for the same reason. Nothing may move a user's audio off their Mac without
being asked.

Removal never writes `selectedEngine`. The user's choice survives the deletion of
its weights, the status row goes on naming it, and `TranscriptionService`
re-resolves which engine can transcribe *now* afterwards. This is the same
desired-versus-active split the rest of the engine code keeps.

## Recommendations, and what they never do

`EngineRecommendation` produces a name and a sentence. Its whole contract is what
it does not do: **it never downloads, never deletes, never writes
`selectedEngine`, and never proposes the cloud engine.**

The order is:

1. **Mixing English into Chinese** ends the question -
   `EngineKind.bilingualDictation` is the only engine that does it at all.
2. **Chinese** gets `EngineKind.defaultChineseDictation`, which punctuates.
3. **A language Parakeet covers** gets Parakeet, which is the fastest.
4. **Everything else** gets Whisper, the only engine that does every language.

Auto-detect says nothing about what the user speaks, so the system language
stands in rather than the recommendation quietly defaulting to English.

**Memory is a note, never a choice.** All four engines run on any Apple Silicon
Mac; what memory decides is whether Whisper's largest models are a good trade, so
under 16 GB the pane says so once and the recommended *engine* is unchanged.
`ModelInventoryTests` asserts that a low-memory Mac and a large one get the same
recommendation.

## Where the seams are

| Type | Answers |
| --- | --- |
| `ModelInventory` | Where each engine's bytes are, and what state they are in. Pure, given a size reader and an `EngineAvailability`. |
| `ModelRemoval` | Whether a delete is allowed and what it costs. Pure. |
| `EngineRecommendation` | Which engine this Mac would be best served by, and why. Pure, given a `Machine`. |
| `ModelInventoryViewModel` | The work those three cannot do: reading the disk off the main thread, and performing a delete a person agreed to. |
| `ModelInventoryRow` | The drawing. Takes values, not a view model, so `ModelInventoryRenderTests` can render a half-installed cache without breaking one. |

Downloads still go through `EngineWeightsPreparation` -
`SettingsViewModel.downloadEngineModel` is the caller, unchanged - so a published
model pack is still what installs when there is one (`docs/model-packs.md`). The
inventory adds no second downloader, and offers no Download button at all for the
two engines that pick between several models: for those the safe action is to
select the engine and choose from its own list, which is directly above.
