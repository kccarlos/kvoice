# Privacy

kvoice is built so your voice and your words stay on your Mac unless you
choose otherwise. This page lists everything the app stores, and everything
it can send, and where. It describes the code in this repository. If the two
ever disagree, the code is right and this page is a bug: please
[open an issue](https://github.com/kccarlos/kvoice/issues).

## The short version

- **Speech is transcribed on your Mac.** Audio is never uploaded.
- **No analytics, telemetry, crash reporting, advertising or accounts.** The
  app's privacy manifest (`Apps/KvoiceApp/PrivacyInfo.xcprivacy`) declares no
  tracking and no collected data.
- **The network is used for two things only:** downloading the speech models
  you choose, and AI Actions: processing when you turn them on and pick an
  online engine, and the test request when you check a configuration
  yourself (below).
- **AI Actions are off by default.** With them off, kvoice is designed to make
  no network requests beyond model downloads and the checks you start by
  hand: **Verify & Save** and **Test** send one short fixed test request
  (never a transcript) to the engine being checked, and asking for an
  endpoint's model list fetches it. "Designed to" is deliberate: this is how
  the code is written and tested, not yet something confirmed by a recorded
  network capture.

## What stays on your Mac

| Data | Where | Kept for |
| --- | --- | --- |
| Audio while you dictate | In memory only | Discarded once the text is inserted, unless you turn on keeping recordings |
| Saved recordings (off by default) | `~/Library/Application Support/kvoice/History/Audio/`, as WAV files readable only by your user account | Your audio retention setting in Data & Privacy |
| History (on by default, can be turned off) | `~/Library/Application Support/kvoice/History/history.sqlite3` | Your text retention setting. Turning History off stops new entries; Clear All deletes them |
| Settings | macOS user defaults for kvoice | Until you reset or delete them |
| API keys for AI endpoints | `~/Library/Application Support/kvoice/secrets.json`, readable only by your user account (mode `0600`), never in the settings file | Until you delete the configuration |
| Speech models | `~/Library/Application Support/kvoice/Models/` | Until you delete them in Speech Models |
| Diagnostics | `~/Library/Application Support/kvoice/diagnostics.jsonl` and the macOS unified log | Local only |
| Exports | Files and folders you choose | Yours |

The App Store edition is sandboxed, so macOS puts the same files under
`~/Library/Containers/io.github.kccarlos.kvoice/Data/Library/Application Support/kvoice/`.

**Diagnostics hold scalars only:** event names, state names, error codes,
timings, counts, and model identifiers. Transcripts, prompts, audio, file
paths, endpoint URLs and keys cannot be written to it; the log format has no
field that could carry free text. Nothing sends the diagnostics anywhere. If
you use Help › Feedback, kvoice opens a draft in your mail app, and includes a
diagnostics summary only if you tick the box to include it. You see the draft
before anything is sent. The summary shows your AI endpoint as scheme and host
only.

The **Dictionary** (names and jargon you add) is given to the local speech
model as a hint. It stays on the Mac, like the audio.

## What can leave your Mac

### Speech model downloads

When you install a model in Speech Models (or during setup), kvoice downloads
its files over HTTPS from `huggingface.co`, at revisions pinned in the app, and
checks every file against a manifest that ships inside the app. The requests
are ordinary file downloads: no audio, text, settings or identifiers of yours
are sent.

**Apple Speech** (macOS 26 or later) is different: macOS downloads and manages
its language assets itself, under Apple's terms. kvoice only asks macOS to
install or release a language.

### AI Actions (off by default)

When AI Actions are on, each dictation's transcript is sent for processing to
the engine you chose, together with the action's instructions. Two optional
extras go with it, and only if you set them up:

- **Your user profile**, a short text about you that you can write in AI
  Actions. When set, it is sent with every request.
- **Clipboard text or selected text**, only for an action whose settings you
  changed to include them. Both are off for every action unless you turn them
  on.

Nothing else is sent: no audio, no history, no information about the app you
were typing into. If processing fails, kvoice inserts your original
transcript.

The engines:

| Engine | Where the text goes | Needs |
| --- | --- | --- |
| **OpenAI-compatible endpoint** (Ollama, OpenAI, Gemini, Anthropic, OpenRouter, Groq, Cerebras, Azure OpenAI, or a custom URL) | The endpoint you configured, and nowhere else. That provider's privacy policy then applies | A URL, a model name, and usually an API key |
| **Apple Intelligence (on-device)**, macOS 26 or later | Nowhere. It runs on your Mac through Apple's Foundation Models framework | Apple Intelligence turned on in System Settings |
| **Private Cloud Compute**, App Store edition only, macOS 27 or later, where Apple makes it available | Apple's Private Cloud Compute servers, through the same framework. Apple's Private Cloud Compute privacy terms apply | Choosing it explicitly. It is never used automatically, never as a fallback for another engine, and never for dictation while AI Actions are off (checking the configuration sends one test request) |

Rules the app enforces for endpoints:

- Remote endpoints must use `https://`. Plain `http://` is accepted only for
  `localhost`, `127.0.0.1` and `::1`, so a local Ollama works but nothing
  leaves the Mac unencrypted.
- A URL that carries a user name, a password or credentials in its query is
  refused.
- The API key is sent only to the endpoint it belongs to, as the
  `Authorization` header (or the `api-key` header for Azure).
- Besides processing requests, kvoice talks to an engine only when you ask
  it to, whether or not AI Actions are on: **Verify & Save** (when you save a
  configuration) and **Test Active Configuration** send one short fixed test
  request, and asking for an endpoint's list of models sends a
  `GET …/models`. This applies to Private Cloud Compute too: checking such a
  configuration sends one test request to Apple.

macOS may ask whether kvoice can find devices on your local network. That is
only needed if your AI endpoint runs on another machine on your network.

### Links you click

Help links (the user guide, this repository) open in your browser. Feedback
opens your mail app with a draft you can edit or discard.

## Permissions

| Permission | Used for |
| --- | --- |
| Microphone | Recording while you dictate. Requested at your first dictation or the setup microphone test |
| Accessibility | Inserting text into the focused app (the App Store edition uses only the keystroke part of it). Requested during setup |

Neither is requested at launch. kvoice reads the focused text field only to
insert your text, and reads the selected text only for an action set up to use
it.

## Deleting your data

- History: Data & Privacy › Clear All, or set retention.
- Models: Speech Models › Delete.
- API keys: delete the AI configuration.
- Everything: quit kvoice and delete `~/Library/Application Support/kvoice/`
  (or the container folder above for the App Store edition), then run
  `defaults delete io.github.kccarlos.kvoice`.
