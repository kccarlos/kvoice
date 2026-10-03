# kvoice User Guide

kvoice turns speech into text in whatever app you are using. You hold a
shortcut, speak, let go, and the words appear at the cursor. This guide walks
through setup and every part of the app.

- [First launch](#first-launch)
- [Dictating](#dictating)
- [The menu bar](#the-menu-bar)
- [Speech models](#speech-models)
- [Dictionary](#dictionary)
- [AI Actions](#ai-actions)
- [History](#history)
- [Data & Privacy](#data--privacy)
- [Shortcuts, Siri and Spotlight](#shortcuts-siri-and-spotlight)
- [The two editions](#the-two-editions)
- [FAQ](#faq)

## First launch

kvoice has no Dock icon. It lives in the menu bar. The first time it opens, a
setup guide takes you through six steps:

1. **Welcome.**
2. **Speech model.** Downloads the recommended model (Whisper v3 Turbo
   Standard, about 650 MB). The first time the model loads, Core ML compiles it
   for your Mac's Neural Engine. This takes a few minutes, once; later
   launches are quick.
3. **Microphone.** macOS asks for permission, and you can test the level.
4. **Accessibility.** Needed to put the text into other apps. Setup opens the
   right page of System Settings. Turn kvoice on there and come back.
5. **Shortcut.** Record your own, or use the recommended **Control-Shift-Space**,
   then try it.
6. **Ready.**

You can skip a step and come back later. Settings › General and Help can
show the setup guide again, and **Show Tutorial** replays the short tour.
Settings › General also exports and imports your settings as a backup file
(API keys are never included).

## Dictating

1. Click into a text field in any app.
2. Hold the shortcut and speak.
3. Release. kvoice transcribes, and the text appears at the cursor.

A small recorder shows the state: recording (with a level meter and a clock),
transcribing, and inserted. It never takes focus from your app. Press
**Escape** to cancel a dictation. Nothing is inserted.

### Recording modes

Settings › Shortcuts:

| Mode | How it works |
| --- | --- |
| Push-to-Talk | Hold to record, release to stop. |
| Toggle | Press once to start, again to stop. Good for long dictation. |
| Hybrid | A quick tap starts a hands-free recording that the next tap stops. A press-and-hold works as push-to-talk. |

The direct-download edition can also use a modifier key on its own, or the
middle mouse button, as the trigger. Settings ›
Recording sets the maximum recording length.

### How text is inserted

kvoice writes the text into the focused field through the macOS Accessibility
APIs. It does not paste, so your clipboard stays as it was. For apps that
refuse direct insertion, such as terminals, it types the text as keystrokes
instead. You can turn this off in Settings › Recording ("Type into apps that
block direct insertion").

If there is nowhere to put the text (no text field is focused, the field is a
password field, or you switched apps while kvoice was working), the text is
copied to the clipboard and kvoice tells you. From the menu you can insert
the last result again, or copy it.

Settings › Recording › Inserted Text has three more options:

- **Add space after inserting**, so the next dictation continues the sentence.
- **Automatic text formatting**, which trims spaces. It never changes case or
  punctuation.
- **Keep the transcript on the clipboard after inserting**, off by default.

### The recorder

Settings › Recording › Recorder chooses the style: **Mini**, a small floating
panel, or **Notch**, which grows out of the notch on Macs that have one.
You can also choose the start and stop sounds, and whether kvoice mutes other
audio while you dictate.

## The menu bar

Click the kvoice icon for:

- the current state and the speech model;
- **Use AI Actions** on or off, and which action runs by default. Command-1 to
  Command-0 pick an action by its position;
- the transcription language;
- History, Settings, and Quit.

## Speech models

Speech Models lists every model kvoice can use. All of them run on your Mac.
Download one, make it the default, and delete the ones you do not use. Only
the default model is loaded into memory.

| Model | Languages | Size | Notes |
| --- | --- | --- | --- |
| Whisper v3 Turbo Standard (recommended) | About 100 | 646 MB | The default |
| Whisper v3 Turbo High-Accuracy | About 100 | 1.64 GB | The uncompressed version of the same model |
| Parakeet TDT v3 Multilingual | 25 European languages | 483 MB | Fast |
| Parakeet Unified English | English | 1.21 GB | |
| Nemotron 3.5 Streaming Multilingual | 64, including Chinese, Japanese and Korean | 664 MB | |
| SenseVoice Small | Chinese, Cantonese, English, Japanese, Korean | 1.18 GB | |
| Paraformer-large | Mandarin Chinese | 222 MB | No punctuation |
| Parakeet Realtime EOU | English | 224 MB | No punctuation or capitals |
| Apple Speech | The languages macOS supports | Managed by macOS | macOS 26 or later. macOS downloads and stores the language files |

Every download is checked against a manifest built into the app before it is
used. A model that does not match is refused.

The **Runtime** card shows how the model runs on your Mac: load time, speed,
and which processor (Neural Engine, GPU or CPU) it uses. You can change the
processor there. Changing it reloads the model, which takes as long as the
first load.

Set the transcription language in Speech Models or from the menu bar.
**Auto-detect** lets the model decide.

## Dictionary

Settings › Dictionary holds names, product names and jargon you want spelled
your way. kvoice gives the list to the speech model as a hint with every
dictation. It stays on your Mac. Models have a limited budget for hints, and
the page shows how much of it you are using. Not every model takes hints.
You can import and export the list as a text file.

## AI Actions

AI Actions are **off by default**. When on, kvoice sends each transcript to a
language model with instructions, and inserts the result instead of the raw
text. If the model fails or times out, the original transcript is inserted.

### Choosing an engine

In Settings › AI Actions, add a configuration:

- **An OpenAI-compatible endpoint**: Ollama (local), OpenAI, Gemini,
  Anthropic, OpenRouter, Groq, Cerebras, Azure OpenAI, or a custom URL. Enter
  the URL, the model name, and an API key if the service needs one. Use
  **Test Active Configuration** to check it. Remote endpoints must use HTTPS;
  plain HTTP is only accepted for `localhost`.
- **Apple Intelligence (on-device)**, on macOS 26 or later with Apple
  Intelligence turned on. There is nothing to fill in, and nothing leaves your
  Mac. Long transcripts may not fit the on-device model; kvoice then inserts
  the original text and tells you.
- **Private Cloud Compute**, in the Mac App Store edition on macOS 27 or
  later, where Apple makes it available. Nothing to fill in, but the text is
  processed on Apple's servers. Apple sets a usage limit, which the page
  shows.

You can save several configurations and switch between them from the menu
bar. Saving with **Verify & Save**, and **Test Active Configuration**, send
one short fixed test request (never a transcript) to that engine, even while
AI Actions are off.

### Actions

Thirteen actions ship: **Clean Up, Polish, Message, Notes, Prompt, Writing,
Email Draft, Summarize, TODO List, Q&A, Terminal, Translate** and **Translate 2**.
Edit any of them (Reset restores the original), or write your own.

- The **default action** runs after every dictation while AI Actions are on.
- **Trigger words** run a different action for one dictation: start with the
  action's trigger phrase and kvoice removes it and runs that action.
- Per-action options include a formal or professional tone, a second
  translation language, and showing the original text beside the result.
- An action can be set to include your **clipboard text** or **selected
  text** as extra context. Both are off unless you turn them on, and they are
  sent to the engine only when you do.
- You can write a short **user profile** (for example, your role and how you
  like to write). When set, it is sent with every request.

### Selection Actions (direct-download edition)

Up to three shortcuts that run an action on the text you have selected in any
app, and replace it with the result. They work whether or not AI Actions are
on.

## History

History is on by default and stored only on your Mac. Every entry keeps the
raw transcript and the final text. You can:

- search, filter by date and length, and see totals;
- copy an entry, or delete it (Undo is available for a few seconds);
- **Retranscribe** an entry with another model, if you keep recordings;
- **Transcribe File…** to turn an audio or video file into an entry;
- export to CSV, Markdown or plain text, or turn on **Auto Daily Export** to
  append each day's entries to a Markdown file in a folder you choose.

Turning History off stops new entries. It does not delete old ones; use
**Clear All** for that.

## Data & Privacy

- How long History keeps text, and, separately, whether and how long it keeps
  **recordings** (off by default).
- A summary of what kvoice sends where, for your current settings.
- **Copy Diagnostics**: a summary of versions, permission and model states
  and settings switches for a bug report. It never contains transcript text,
  keys or endpoint paths.
The full picture: [PRIVACY.md](../PRIVACY.md).

## Shortcuts, Siri and Spotlight

kvoice provides **Start Dictation** (optionally with an AI action), **Stop
Dictation**, **Toggle Dictation**, **Cancel Dictation** and **Get Last
Transcription** to the Shortcuts app, Siri and Spotlight.

## The two editions

| | Direct download | Mac App Store |
| --- | --- | --- |
| Insertion | Accessibility, then typed keystrokes | Typed keystrokes only |
| Selection Actions | Yes | No |
| Modifier-only and middle-mouse triggers | Yes | No |
| Private Cloud Compute | No | Where available |

Install the direct-download edition with Homebrew
(`brew install --cask kccarlos/tap/kvoice`, updated with
`brew upgrade --cask kvoice`) or from the DMG on
[GitHub Releases](https://github.com/kccarlos/kvoice/releases/latest). Both
are the same notarized build.

The App Store edition is sandboxed, which is why it cannot edit another app's
text fields directly or read their selection. It types the text as
keystrokes instead, after checking that the app you started in is still in
front and that no password field is active. Choose a key combination as your
shortcut there.

## FAQ

**The first dictation takes minutes.**
That is Core ML compiling the model for your Mac, once per model and after
changing the processor in the Runtime card. Later loads are fast.

**Accessibility is on in System Settings, but kvoice says it is not.**
macOS ties the permission to the app's code signature. If the app was
replaced by a differently signed copy (for example, a build from source, or a
copy made with `cp -R`), the old permission no longer applies. Remove kvoice
from the Accessibility list, add it again, and relaunch kvoice.

**Nothing is inserted, and the text is on the clipboard instead.**
The focused app did not expose a text field kvoice could write to, the field
was a password field, or a different app came to the front. Paste with
Command-V. If a particular app always fails, please
[report it](https://github.com/kccarlos/kvoice/issues).

**The transcript says "Thank you." when I did not speak.**
Whisper sometimes produces this on silence. kvoice discards recordings that
are too quiet to contain speech. If it still happens, check the microphone
level in Settings › Microphone.

**Can I use kvoice offline?**
Yes, once a model is downloaded. AI Actions need the network unless you use
Apple Intelligence on-device or a local Ollama.

**Where are my files?**
`~/Library/Application Support/kvoice/`, or for the App Store edition,
`~/Library/Containers/io.github.kccarlos.kvoice/Data/Library/Application Support/kvoice/`.

**How do I change the interface language?**
Settings › General › Interface language: follow the system, English, or
Simplified Chinese. kvoice offers to relaunch.

**How do I uninstall?**
Quit kvoice, delete it from Applications, and delete the folder above. The
settings are removed with `defaults delete io.github.kccarlos.kvoice`.
