# Changelog

Notable changes to kvoice, for people who use it. Versions follow
[Semantic Versioning](https://semver.org). The first release is 0.1.0.

Each release has a `## X.Y.Z — YYYY-MM-DD` section, written before the
release is tagged; the release notes on GitHub are that section. A tag
without one is refused.

## Unreleased

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
