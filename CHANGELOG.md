# Changelog

Notable changes to kvoice, for people who use it. Versions follow
[Semantic Versioning](https://semver.org). The first release is 0.1.0.

Each release has a `## X.Y.Z — YYYY-MM-DD` section, written before the
release is tagged; the release notes on GitHub are that section. A tag
without one is refused.

## Unreleased

## 0.1.7 — 2026-10-22

A new look for the whole app, in light and dark.

- The recorder is redrawn: an orange mic while you speak, the AI action
  that will run (switch it with ⌘1–⌘0 while recording), live level bars,
  a timer and the words as they are heard.
- The menu bar icon opens a new status panel: what KVoice is doing, the
  last dictation, and the AI action to use, all in one place. Picking an
  action there also turns AI Actions on. Right-click the icon for the full
  menu.
- The settings window has a new sidebar and a Home page with your
  readiness, recent dictations and a short test.
- Every settings page moved onto clear cards. Status always reads as a
  coloured dot with words, never colour alone.
- AI Actions is reorganised: an on/off switch with one line of status
  (which action, where it runs), then where AI runs, then your actions.
  Click an action to make it the default; double-click it (or Edit…) to
  change its name, prompt, trigger words and shortcut in one sheet.
- When you set up an OpenAI-compatible provider, Fetch Models asks it
  which models it serves; filter the list and click one to use it. The
  recommended models are updated to each provider's current ones (for
  example GPT-6 Luna, Gemini 3.5 Flash-Lite, Claude Haiku 5.5).
- History has a stats strip, a "With AI" filter, and shows which model
  transcribed each entry.
- Dictionary terms are chips you can edit in place; select several to
  remove them together.
- Speech Models can be filtered by language and by live text.
- The setup wizard is redrawn, with the same steps.
- Fixed: VoiceOver now reads the menu bar icon, the selected choice on
  every card, chip and row, and the History page without hanging.
- Fixed: while a model downloads, the menu bar icon still shows a warning
  when a dictation is blocked.

## 0.1.6

- The built-in AI Actions now follow you when you correct yourself: say
  "let's do two — no, wait, three" and the result says three.
- Clean Up now also drops the Chinese filler "那个", and Translate and
  Translate 2 drop fillers such as "um" and "嗯" before translating.
- Translate and Translate 2 clean up the speech before translating it, so a
  self-correction or a filler no longer shows up in the translation, and
  the reply is the translation alone.
- TODO List keeps every task you dictate, including changes to a plan such
  as moving a meeting.
- The writing actions (Prompt, Message, Notes, Writing, Email Draft,
  Summarize, TODO List) now consistently keep the language you spoke unless
  you ask for another one.
- If you never edited a built-in action, it picks up the new instructions
  on its own. Actions you edited are left exactly as they are.
- A safeguard for Right Option and the other lone modifier keys as the
  recording key: if KVoice misses the key's release, the next press still
  works, and KVoice checks on its own whether the key is still held. This
  was seen with simulated key presses; we have not reproduced it on a
  physical keyboard.
- With AI Actions on and the Default Action set to "None", KVoice no longer
  runs an AI step on your dictation. As the settings say, nothing runs
  until you choose an action. With action triggers on, starting a sentence
  with an action's trigger word still runs that action.
- The "KVoice Shortcut" window is now shown in Simplified Chinese when the
  interface is in Chinese.

## 0.1.5

- KVoice can now be installed and updated with Homebrew:
  `brew install --cask kccarlos/tap/kvoice`. It is the same notarized build
  as the DMG.

## 0.1.3

- New app icon and menu-bar icon.
- On a Mac with macOS 26 or later, a new setup now starts with Apple Speech
  when it supports your language: it is ready in seconds, with nothing large
  to download. Whisper is one click away in the setup window, which says what
  it downloads and that its first load takes a few minutes.
- The first time a model such as Whisper loads on your Mac, kvoice now says
  "Optimizing for your Mac — first time only" in the setup window, Speech
  Models, the menu bar and the recorder, instead of a plain "Loading" that
  looked stuck. Later loads take seconds and say so.
- Fixed: clicking another model action while a model was loading could throw
  away minutes of first-time optimization and start it over. The load now
  always finishes; an action that has to wait says why instead of doing
  nothing.

## 0.1.2

The first build accepted for the Mac App Store; the app is otherwise the same
as 0.1.1.

- The Mac App Store package now carries everything App Store Connect checks
  for (verified with Apple's validation before release).

## 0.1.1

The first Mac App Store build, and the same app as 0.1.0 for everyone else.

- The Mac App Store edition is now packaged correctly for upload.
- More reliable automated tests on slower build machines; no change to how
  the app behaves.

## 0.1.0

The first public version. It includes:

- Push-to-talk, toggle and hybrid dictation from a global shortcut, with a
  recorder that never takes focus from your app.
- On-device transcription with Whisper large-v3-turbo, plus Parakeet,
  Nemotron, SenseVoice and Paraformer models, and Apple Speech on macOS 26 or
  later.
- Text inserted directly into the focused app through Accessibility, with
  typed keystrokes as a fallback and the clipboard only when there is nowhere
  to insert.
- A Dictionary for names and jargon.
- Optional AI Actions (thirteen built in, editable, plus your own) through
  any OpenAI-compatible endpoint or Apple Intelligence on this Mac.
- Optional History with search, retention settings, re-transcription,
  audio-file transcription and exports.
- Shortcuts, Siri and Spotlight actions.
- English and Simplified Chinese interface.
- Two editions: a notarized direct download and a sandboxed Mac App Store
  version.
