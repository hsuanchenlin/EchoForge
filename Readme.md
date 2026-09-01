# Kongweh

Kongweh is a macOS application that provides real-time audio transcription using on-device speech models. It offers a seamless way to record and transcribe audio with customizable settings and keyboard shortcuts.

Everything runs on your Mac by default - no account, no server, nothing uploaded. There is one
opt-in exception: you can point speech transcription and the spoken translation command at an
OpenAI-compatible provider using your own API key. It is off until you turn it on and accept a
sheet saying what is uploaded and where; [docs/cloud-api.md](docs/cloud-api.md) lists exactly what
leaves the device, when, and where it goes.

It is a fork of [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) - which this
repository's source directories are still named after - given its own bundle identifier
(`com.hsuanchenlin.EchoForge`) so it installs and runs alongside an upstream build instead of
replacing it.

**On the name.** The app is Kongweh, after Taiwanese *kóng-uē* (講話), "to talk". This
repository, its releases and the files they publish are still named EchoForge, which is what
the app was called before, so the download is `EchoForge.dmg` and it installs
`EchoForge.app` - Finder and the Dock show it as Kongweh. That is deliberate: the bundle
identifier names the folder holding every existing user's recordings, personal terms and
downloaded models, and the updater finds new versions by those exact file names, so renaming
them would strand installs rather than rebrand them.

<p align="center">
<img src="docs/image.png" width="400" /> <img src="docs/image_indicator.png" width="400" />
</p>

## Features

- 🎙️ Real-time audio recording and transcription
- 🧠 Four transcription engines: [Whisper](https://github.com/ggerganov/whisper.cpp), [Parakeet](https://github.com/AntinomyCollective/FluidAudio), [SenseVoice-Small](docs/speech-model-attribution.md#sensevoice-small), and [Paraformer-large (zh)](docs/speech-model-attribution.md#paraformer-large-zh) - download models directly from the app
- ⌨️ Global keyboard shortcuts - key combination or single modifier key (e.g. Left ⌘, Right ⌥, Fn)
- 🔀 Switch engine without opening Settings - press ⌥M (configurable) to move to the next engine that is ready, wrapping around, with a pill naming it. Skips engines that are not downloaded or cannot dictate your language, and includes your cloud provider once you have set it up ([details](docs/engine-shortcut.md))
- 🖱️ Mouse button trigger - bind the middle or an extra (thumb) mouse button to start/stop recording
- ✊ Hold-to-record mode - hold the shortcut, modifier key or mouse button to record, release to stop
- 📁 Drag & drop audio files for transcription with queue processing
- 🎤 Microphone selection - switch between built-in, external, Bluetooth and iPhone (Apple Continuity) mics from the menu bar
- 🌍 Support for multiple languages with auto-detection, including mixed English and Mandarin in one recording with SenseVoice-Small; Chinese is written in your chosen script ([details](docs/bilingual-dictation.md))
- 🇯🇵🇨🇳🇰🇷 Asian language autocorrect ([autocorrect](https://github.com/huacnlee/autocorrect))
- 📖 Personal terms dictionary for deterministic replacements, preferred spellings, names, and protected text
- ✨ Optional style rewriting - turn what you dictated into formal, concise, bulleted or casual writing, or write your own prompt. Runs on device (macOS 26 with Apple Intelligence), off by default, and always keeps the original transcript ([details](docs/style-rewriting.md))
- ✨ Fix with AI from History - press the sparkles on any recording card to have mis-heard characters, Chinese homophones and typos corrected from the sentence around them. Runs on device (macOS 26 with Apple Intelligence), keeps what the card said before the press one click away under "Show original", and never touches the audio ([details](docs/history-ai-fix.md))
- 🎯 Optional app-aware style - let the app you dictate into pick the rewriting style: chat apps get casual, mail gets formal, code editors get grammar polish, with per-app rules on top. Reads only the frontmost app's bundle identifier - never window titles or web addresses. Off by default ([details](docs/app-aware-style.md))
- 💊 Optional floating capsule HUD - a pill at the top of the screen with live input level, duration and progress, shown instead of the card beside the cursor. Off by default ([details](docs/capsule-hud.md))
- ❓ Ask panel - press ⌥A (configurable) and start talking: a floating card opens and records, a second press finishes the question, and it is answered on device (macOS 26 with Apple Intelligence). You can type the question instead, and copy the answer or insert it into the app you were using. Esc closes the card ([details](docs/ask-panel.md))
- 🖥️ Ask about your screen - press ⌥S (configurable) to capture the window you are looking at and speak a question about it; the Ask panel answers on device from the text it reads off the screenshot, with a thumbnail showing exactly what was captured. Asks for Screen Recording permission only when you use it ([details](docs/screen-context.md))
- ✏️ Voice edit selected text - highlight text in any app, press ⌥E (configurable), and speak an instruction ("fix the grammar", "make it concise bullet points", "translate to Traditional Chinese"): the selection is replaced with the rewritten text. If nothing is highlighted, your clipboard is edited instead. Runs on device (macOS 26 with Apple Intelligence), leaves your text exactly as it was when the model is unavailable or the edit is refused, and keeps the original beside the edit in History under "Compare" ([details](docs/selection-edit.md))
- 🗣️ Optional spoken commands - start a dictation with "Ask: …" / "請問…" to send the question to the Ask panel, or "Translate to Spanish: …" / "翻譯成西班牙文：…" to paste the translation instead of the words themselves. Off by default ([details](docs/spoken-intents.md))
- ☁️ Optional cloud transcription and translation - use an OpenAI-compatible provider with your own API key, kept in your Keychain, with a per-feature Local/Cloud choice and a one-time consent sheet. Off by default; everything else always stays on your Mac ([details](docs/cloud-api.md))
- 📋 Voice snippets - save the boilerplate you retype (an email signoff, a meeting template) and say "insert email signoff" / "插入會議記錄", or the trigger alone, to type it exactly as stored - never rewritten. Part of spoken commands, so off until those are on ([details](docs/voice-snippets.md))
- ▶️ Open a channel's latest YouTube video by voice - allowlist channels by their canonical channel ID in Settings, then hold the YouTube command shortcut (⌥Y) and say the channel's name. If the engine writes the name a way your list does not hold, your own channels appear to choose from with the arrow keys and Return, closest spelling first - nothing is opened until you pick one, and Escape opens nothing. It can reach only the channels you listed, and the one request it makes is that channel's public feed - no account, no cookies, nothing of yours sent. It is its own key on purpose: your dictation shortcut only ever types text and can never open a browser ([details](docs/youtube-latest-video.md))
- 🏷️ History says what each entry was - Dictation, Ask, YouTube command opened, YouTube command not opened - with the reason under any command that opened nothing, and a filter to show one kind at a time. Entries made before this shipped are labelled "Older recording" rather than relabelled as a guess ([details](docs/history-provenance.md))

## Installation

### Kongweh (this fork, includes the Chinese engines)

Download the newest `.dmg` from
[this fork's releases page](https://github.com/hsuanchenlin/EchoForge/releases)
(`EchoForge.dmg`), drag the app into `Applications`, then right-click it and choose
**Open** the first time - these builds are unsigned, so macOS blocks a normal
double-click until you do.

**[Full install and usage guide → docs/install.md](docs/install.md)** covers the Gatekeeper
warning and both ways around it, the permissions macOS asks for, how to dictate Chinese
with SenseVoice-Small or Paraformer-large, and the basics of recording and pasting.

### Upstream builds

```shell
brew update # Optional
brew install opensuperwhisper
```

Or from the [upstream GitHub releases page](https://github.com/Starmel/OpenSuperWhisper/releases).
These are signed and notarized, and do not include this fork's changes. They install as
`OpenSuperWhisper.app` under `ru.starmel.OpenSuperWhisper`, so an upstream install and an
Kongweh install can sit side by side; each keeps its own settings, recordings and
downloaded models.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon/ARM64

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the repository
2. Create a new issue with detailed information about your problem
3. Include system information and logs when reporting bugs

## Building locally

To build locally, you'll need:

    git clone git@github.com:hsuanchenlin/OpenSuperWhisper.git
    cd OpenSuperWhisper
    git submodule update --init --recursive
    brew install cmake libomp rust ruby
    gem install xcpretty
    ./run.sh build

In case of problems, consult `.github/workflows/build.yml` which is our CI workflow
where the app gets built automatically on GitHub's CI.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

### Contribution TODO list

- [ ] Streaming transcription
- [x] Personal terms dictionary ([#19](https://github.com/Starmel/OpenSuperWhisper/issues/19))
- [ ] Intel macOS compatibility ([#15](https://github.com/Starmel/OpenSuperWhisper/issues/15))
- [ ] Agent mode ([#14](https://github.com/Starmel/OpenSuperWhisper/issues/14))
- [x] Background app ([#8](https://github.com/Starmel/OpenSuperWhisper/issues/8))
- [x] Support long-press single key audio recording ([#18](https://github.com/Starmel/OpenSuperWhisper/issues/18))

## License

Kongweh is licensed under the MIT License, inherited from OpenSuperWhisper, whose
copyright notice it keeps. See the [LICENSE](LICENSE) file for details.

Speech models are downloaded at runtime and carry their own licences and attribution
requirements. See [docs/speech-model-attribution.md](docs/speech-model-attribution.md).

## Whisper Models

You can download Whisper model files (`.bin`) from the [Whisper.cpp Hugging Face repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Place the downloaded `.bin` files in the app's models directory. On first launch, the app will attempt to copy a default model automatically, but you can add more models manually.

### Hebrew (ivrit.ai)

For Hebrew transcription, download the **"Turbo V3 Hebrew"** model from Settings → Model. It is [ivrit.ai](https://www.ivrit.ai/)'s Hebrew fine-tune of `whisper-large-v3-turbo` ([whisper-large-v3-turbo-ggml](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml)) - the same base model as the other "Turbo V3" entries, but tuned for Hebrew. Selecting it automatically sets the input language to Hebrew, which these models require to be set explicitly.
