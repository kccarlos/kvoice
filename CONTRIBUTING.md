# Contributing to kvoice

Thanks for your interest. Bug reports, fixes, translations and ideas are all
welcome. This page covers how to build, what a change needs before it can be
accepted, and what happens to your pull request.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Before you start

- **Bugs:** open an issue using the bug report template. Include the kvoice
  version and edition, the macOS version, and the app you were dictating into.
- **Features:** open an issue first, so we can agree on the shape before you
  write code. kvoice deliberately does a small number of things, and some
  ideas conflict with its privacy rules.
- **Small fixes** (typos, docs, an obvious bug) can go straight to a pull
  request.

## Building

You need an Apple Silicon Mac and Xcode 27 or later (the macOS 27 SDK; the
app itself runs on macOS 15 and later).

```sh
./Scripts/bootstrap.sh            # resolve packages, install the commit-message hook
./Scripts/test.sh                 # the whole test suite
./Scripts/build.sh                # SwiftPM build of every library and tool
./Scripts/build_app.sh Debug      # the signed app, in .build/xcode-derived/Build/Products/Debug/
```

**Always use the scripts; never bare `swift build` or `swift test`.** If your
`xcode-select` points at the Command Line Tools, bare SwiftPM fails with errors
that look like broken dependencies. The scripts point at Xcode for the one
command they run. [Docs/Build.md](Docs/Build.md) has the details, and what to do
when an incremental build misbehaves.

To try your build, copy it with `ditto` (never `cp -R`, which can break the
signature) and grant it Microphone and Accessibility. Without a signing
certificate, `build_app.sh` signs ad hoc, and macOS forgets the Accessibility
permission after every rebuild. [Docs/Build.md](Docs/Build.md#signing-and-permissions)
explains how to reset it, and how to keep it across rebuilds.

## What a change needs

1. **Tests pass:** `./Scripts/test.sh` with no failures. Some tests are skipped
   by default because they need a real model, a microphone or a live AI
   provider; that is expected.
2. **New behavior has a test at the seam it adds:** a new protocol, reducer
   case, stored setting or database column comes with a test. Tests must be
   fast and deterministic: no real time (inject the clock), no network, no
   real model, no microphone. The fakes in `Packages/KvoiceTestSupport` are
   there for this.
3. **The architecture rules hold.** They are short and they are enforced by
   tests: read [AGENTS.md](AGENTS.md) and
   [Docs/Architecture.md](Docs/Architecture.md). The ones people trip over:
   - vendor types (WhisperKit, FluidAudio, FoundationModels, Speech,
     KeyboardShortcuts, AppKit) stay inside their adapter package;
   - API keys live only in the secrets store, never in settings;
   - diagnostics carry scalars only, never transcript text, audio or keys;
   - text is inserted through Accessibility or typed keystrokes, never by a
     simulated paste, and the clipboard is not touched when insertion works;
   - dependency versions are pinned exactly and are not bumped casually.
4. **User-facing strings are localized.** kvoice ships in English and
   Simplified Chinese. [Docs/Localization.md](Docs/Localization.md) shows where a
   string goes and how to sync the catalogs. If you cannot translate, say so in
   the pull request and we will help.
5. **Commit messages follow Conventional Commits:**
   `<type>(<scope>): <summary>`, for example
   `fix(insertion): keep the caret after the inserted text`. Accepted types are
   `feat fix docs test refactor perf build ci chore style revert`. The hook that
   `./Scripts/bootstrap.sh` installs checks this, and so does CI.
6. **Code signing stays on.** Never set `CODE_SIGNING_ALLOWED=NO`. macOS will
   not grant Accessibility to an unsigned app, and it fails silently.

## Pull requests

- Keep a pull request to one change, and describe what it fixes and how you
  tested it. The template asks for this.
- CI runs the commit-message check, the test suite and the release-script
  tests, and builds both editions on every pull request
  ([Docs/Build.md](Docs/Build.md#continuous-integration) lists each step, all
  of which you can run locally). No secrets are available to pull request
  builds, so the app is signed ad hoc there; that is expected.
- Pull requests are **reviewed here in public**, but they are **not merged
  with the merge button**. This repository is published from the maintainers'
  main line: when a change is accepted, a maintainer applies it there, and it
  arrives here in the next sync commit. We then close the pull request with a
  link to that commit.
- **Credit:** the sync commit's message names your pull request and your
  GitHub handle, and user-visible changes are credited to you in
  [CHANGELOG.md](CHANGELOG.md). This repository's history is made of sync
  commits, so you will not appear here as a git author.
- Please do not edit `CHANGELOG.md` yourself; the maintainers write it.

## Where things are

| Path | What |
| --- | --- |
| `Apps/KvoiceApp` | The app shell: composition root, windows, menu, entitlements |
| `Packages/` | One Swift package per concern. `KvoiceDomain` holds the protocols everything else implements |
| `Scripts/` | The only supported build, test and release entry points |
| `Tools/` | The model manifest generator and the benchmark harness |
| `Docs/` | Contributor documentation: [Docs/README.md](Docs/README.md) is the index |

## License

kvoice is MIT-licensed. By submitting a contribution you agree that it is
licensed under the same terms ([LICENSE](LICENSE)).
