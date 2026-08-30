# Voice edit (⌥E)

Highlight text in any app, press ⌥E, speak an instruction, and the selection is
replaced with the rewritten text. If nothing is highlighted, the clipboard is
edited instead.

`OpenSuperWhisper/Utils/SelectedTextExtractor.swift` is the capture,
`OpenSuperWhisper/Rewriting/SelectionEditRewrite.swift` is the stage, and
`DictationPurpose.selectionEdit` is the hotkey's identity.

## Why it has its own key

A dictation is words on their way into somebody's document. A voice edit is an
instruction applied to words that are already there. Sharing the dictation
shortcut would make every dictation ambiguous: "make it concise bullet points"
would have to be guessed as either those words, or an instruction about
whatever happened to be highlighted. With two keys the app never has to guess.

The YouTube command (⌥Y) is the same shape of decision. `DictationPurpose` is
the type that keeps them apart: a `.selectionEdit` capture never routes as
Ask, never expands a snippet, never opens a browser, and never pastes the
spoken instruction.

## Capture

Three sources, in this order, and the first usable one wins:

1. Accessibility `kAXSelectedTextAttribute` on the focused element. No
   clipboard is touched.
2. A simulated ⌘C, with the pasteboard restored afterwards, so a probe copy
   cannot clobber what the user had.
3. The clipboard as it already stood.

The HUD names the source: **Editing Selection...** or **Editing Clipboard...**.
A press that finds nothing at all never takes the microphone; the card says
**Nothing to edit**.

## The rewrite

The spoken instruction is transcribed, then handed to `SelectionEditRewrite`
with the captured text. The stage is a sibling of `StyleRewriteService` the
way `TranslationRewrite` is: same `StyleRewriting` protocol, same on-device
model, same hard budget, **`StyleRewriteGuard` as the boundary**. The
instruction is spoken per press, so it is never stored as a Settings style.

The shape is `StyleRewriteShape.editing`. Length, language, omission and list
markers are whatever the instruction asked for - "translate to Traditional
Chinese" and "make it concise bullet points" both have to be possible - and
the guard still refuses an empty answer, a model talking to the user, and a
number or currency sign that was not in the text. A style may omit; nothing
may invent.

It is on-device only. `OnDeviceModelFeature.selectionEdit` has no
`cloudFeature`. The selected text is whatever the user had on screen, and a
press that quietly posted it to a provider is not a trade this app makes.

If the rewrite is refused, times out or cannot run, the selection is left as
it was. Pasting the original back would replace a rich-text selection with a
plain-string copy of itself.

## History

The row is `RecordingProvenance.Kind.selectionEdit` ("Voice edit"). The
spoken instruction is the sentence under the pill. The original highlighted
text is `rawTranscription` and the rewritten text is `transcription`, which
is what Compare and "Show original" already read. The audio is the spoken
instruction.

## Shortcut

⌥E by default, configurable in Settings → Shortcuts beside the dictation,
Ask and screen-query keys. It uses the same press/hold machinery as
dictation, and the same `RecordingSessionClaim` so a press while another
key is listening is refused rather than seizing the microphone.
