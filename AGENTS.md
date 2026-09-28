# kvoice: instructions for AI coding assistants

`CLAUDE.md` is a symlink to this file. Human contributors should read
[CONTRIBUTING.md](CONTRIBUTING.md) first; everything here applies to them too.

## What kvoice is

A native Apple Silicon macOS **menu-bar dictation utility**: hold a global
hotkey, speak, and the transcript is inserted into the focused app. Speech is
transcribed on the Mac (WhisperKit with Whisper large-v3-turbo by default;
FluidAudio models and, on macOS 26 or later, Apple Speech are further
choices). AI polish and translation are **optional and off by default**, and
run through an OpenAI-compatible endpoint, Apple's on-device Foundation Models
(macOS 26 or later), or, in the App Store edition only, Apple's Private Cloud
Compute (macOS 27 or later, opt-in).

Two editions from one codebase, bundle ID `io.github.kccarlos.kvoice`: the
**Developer ID** edition (unsandboxed, the DMG) and the sandboxed **Mac App
Store** edition (the `AppStore` build configuration). The edition is a
runtime `DistributionEdition` value chosen by the composition root, never
`#if` in a package.

Swift 6 with strict concurrency, macOS 15+, `LSUIElement` (no Dock icon).

## Build and test: scripts only

**Never run bare `swift build` or `swift test`.** With the Command Line Tools
selected they fail with errors that look like dependency problems (missing
SwiftUI macro plugins, no XCTest). The scripts set `DEVELOPER_DIR` to Xcode:

```sh
./Scripts/test.sh                 # the full suite; 0 failures required
./Scripts/build.sh                # SwiftPM build
./Scripts/build_app.sh Debug      # the signed .app (also Release, TestHost, Bench, AppStore)
./Scripts/install_app.sh Debug    # build, ditto to ~/Applications, verify the signature
```

If you see a wall of dependency errors, you used the wrong entry point. Fix
the command, not the dependency. More: [Docs/Build.md](Docs/Build.md).

## Rules that are not negotiable

Tests enforce most of these. Do not weaken a test to get past one.

1. **Vendor types do not cross `KvoiceDomain` protocols.** WhisperKit,
   FluidAudio, FoundationModels, Speech, KeyboardShortcuts and AppKit stay
   inside their owning adapter package. `import FluidAudio` appears in exactly
   one file (in `KvoiceParakeet`), `import FoundationModels` in exactly one
   (in `KvoiceAppleIntelligence`), and `import Speech` in exactly one (in
   `KvoiceAppleSpeech`).
2. **Secrets never reach `AppSettings`.** API keys live only in
   `SecretSettings`, keyed by the configuration's `id`, in a `0600` file.
3. **Diagnostics carry scalars only**: never transcript text, prompts, audio,
   paths, URLs or secrets. `DiagnosticAttributes` is a typed catalog; add a
   typed field rather than free text.
4. **Insertion:** Accessibility APIs first; typed Unicode keyboard events
   only as the third tier; **never a synthetic paste, never the pasteboard
   when insertion succeeds.** `CGEvent` is used in
   `TypedKeyboardEventPoster.swift` and nowhere else. The App Store edition
   has no Accessibility tiers: typed events are its only path, with the same
   poster and the same pasteboard rule.
5. **Dependency pins are part of the contract.** WhisperKit `1.1.0`,
   KeyboardShortcuts `3.0.1` and FluidAudio `0.15.7` (with `traits: []`) are
   `exact:` in `Package.swift`. Do not bump them as a side effect of other
   work.
6. **Model weights, recordings, API keys and benchmark corpora never enter
   Git.** Only a model's manifest and its digest are committed.
7. **Never disable code signing.** `CODE_SIGNING_ALLOWED=NO` produces a bundle
   macOS refuses to grant Accessibility to, with no error anywhere. Copy app
   bundles with `ditto`, never `cp -R`.
8. **Remote AI endpoints are HTTPS.** Plain HTTP only for loopback; URLs with
   user info or credentials in the query are refused.
9. **Every user-facing string is localized** (English and Simplified Chinese):
   [Docs/Localization.md](Docs/Localization.md).

## Tests: fast, deterministic, comprehensive

The whole suite runs in seconds and must stay that way. A test that waits on
real time, the network, a real model or a microphone does not belong in it:
inject the clock, and use the doubles in `KvoiceTestSupport`. Live tests
exist behind opt-in environment variables and are skipped by default.
Coverage is not traded for speed: every new seam (protocol, reducer case,
settings field, store column) ships with a test at that seam.

## Commits

Conventional Commits (`feat(scope):`, `fix(scope):`, `docs:`, `test(scope):`,
…), checked by the `commit-msg` hook that `./Scripts/bootstrap.sh` installs.
Do not add AI attribution trailers to commit messages.

## Where to read next

| Doing this | Read |
| --- | --- |
| Building, testing, signing, or an incremental build that misbehaves | [Docs/Build.md](Docs/Build.md) |
| Adding a feature, or finding where code belongs | [Docs/Architecture.md](Docs/Architecture.md) |
| Transcription, model download, or the trusted manifest | [Docs/Model-Packages.md](Docs/Model-Packages.md) |
| Any user-facing string | [Docs/Localization.md](Docs/Localization.md) |
| What the app may send, and where | [PRIVACY.md](PRIVACY.md) |

## You cannot verify everything from tests

Permissions, real speech, real models, Spaces and full-screen apps, insertion
into third-party apps, and the absence of network traffic all need a person at
the keyboard. Say what you could not check rather than describing an
unverified path as working.
