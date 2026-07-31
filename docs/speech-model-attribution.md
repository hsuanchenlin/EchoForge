# Speech model attribution

This is the app's attribution surface for speech models it downloads but does not own.
An entry lands here in the same change as the engine that uses it, and must name the model,
its author, and the licence its weights are distributed under.

No model weights are bundled into the `.app`. Every model is fetched from Hugging Face at
runtime, on the user's machine, at the user's request. Keep it that way: the CoreML
conversions the app fetches assert no licence of their own and defer to their upstream, so
redistributing them inside a build would be making a claim nobody upstream has made.

## Paraformer-large (zh)

**Paraformer-large (zh) by FunASR/FunAudioLLM.** Mandarin speech recognition, used by the
Paraformer engine (`OpenSuperWhisper/Engines/ParaformerEngine.swift`).

| | |
|---|---|
| Model | Paraformer-large, Chinese, `vocab8404` |
| Author | FunASR / FunAudioLLM (Alibaba Group) |
| Upstream model card | <https://www.modelscope.cn/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch> - `license: Apache License 2.0` |
| Hugging Face mirror | <https://huggingface.co/funasr/paraformer-zh> - `license: apache-2.0` |
| What the app downloads | <https://huggingface.co/FluidInference/paraformer-large-zh-coreml> - a CoreML format conversion, no retraining, `license: other` deferring to the upstream model licence |
| Runtime | [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), the version already pinned in `Package.resolved` |
| FunASR toolkit | <https://github.com/modelscope/FunASR> - MIT |

Both first-party cards for these weights publish Apache-2.0. A FunASR maintainer has also
stated publicly that the family's weights fall under the [FunASR Model Open Source License
Agreement](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) v1.1, which permits
commercial use but requires that you **attribute the source and author and retain the model
name**. The two readings are not identical, and the stricter one costs nothing to satisfy, so
this project satisfies it: the model is named and credited here, and any user-facing name for
this engine must keep "Paraformer" in it rather than rebranding it to an OpenSuperWhisper-only
label.

The engine is opt-in and has no UI in this build. When it gets one, this notice needs a
reachable in-app equivalent - naming the model and linking the cards and the licence - not
just this file.
