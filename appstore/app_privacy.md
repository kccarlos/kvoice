# App Privacy answers (App Store Connect)

The answers given in App Store Connect › App Privacy for KVoice, and why.
They describe the code in this repository; [PRIVACY.md](../PRIVACY.md) has
the full account of what is stored and what can be sent.

## Answer: Data Not Collected

**"Do you or your third-party partners collect data from this app?" — No.**

Apple defines *collect* as transmitting data off the device in a way that
allows the developer or third-party partners to access it for longer than
needed to service the request in real time. KVoice has no server, no
account, no analytics, no crash reporter, no advertising and no third-party
SDK that sends data anywhere. The app's privacy manifest
(`Apps/KvoiceApp/PrivacyInfo.xcprivacy`) declares no tracking and no
collected data types.

| Data | What happens | Collected? |
| --- | --- | --- |
| Audio (microphone) | Transcribed on the Mac, never uploaded. Saved recordings are optional and stay on the Mac | No |
| Transcripts, History, Dictionary, settings | Stored on the Mac only | No |
| Diagnostics | A local log of counters and state names, never words; not sent anywhere | No |
| Speech model downloads | Plain HTTPS file downloads from Hugging Face; nothing of the user's is sent | No |
| Apple Speech assets (macOS 26+) | Managed by macOS under Apple's terms; KVoice sends nothing | No |
| Apple Intelligence on this Mac (optional) | Runs on the device; nothing leaves the Mac | No |
| AI Actions with an online service (optional, off by default) | See below | No |
| Feedback (Help › Feedback) | Opens a draft in the user's own mail app; the user decides whether to send it | No |

## Why optional AI services do not change the answer

When a user turns on AI Actions and chooses an online service, the
transcript (and any context the user opted into for an action) is sent
**directly from the Mac to the provider the user configured**, with the
user's own endpoint and API key: for example OpenAI, Gemini, or an Ollama
server on their own network. The request never passes through the
developer, and the developer has no access to it. This is the user
choosing a service, not the app collecting data, so the transmission is
not "collection" by the developer or a third-party partner of the developer.
Each provider's own privacy policy applies to what the user sends it.

## Other answers

- **Tracking:** No. KVoice does not track users across apps or websites
  and has no advertising identifiers.
- **Export compliance:** answered in the app by
  `ITSAppUsesNonExemptEncryption = NO` (HTTPS through `URLSession` only).
- **Privacy Policy URL:** <https://github.com/kccarlos/kvoice/blob/main/PRIVACY.md>

## When to revisit

Revisit these answers before any change that adds a server, an SDK,
analytics, crash reporting, or a new kind of network request, and before
enabling Apple's Private Cloud Compute as an AI engine (not available in
any build yet).
