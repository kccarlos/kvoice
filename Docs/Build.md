# Building and testing

You need an Apple Silicon Mac and **Xcode 27 or later** (the macOS 27 SDK).
The app runs on macOS 15 and later, but it compiles against APIs that exist
only in the macOS 27 SDK (Foundation Models' Private Cloud Compute model,
`SpeechAnalyzer`, among others); every one of them is behind an `#available`
check at run time. An older Xcode fails with "cannot find type" errors;
`./Scripts/ci_check_toolchain.sh` says so up front.

## Use the scripts, not bare SwiftPM

**Never run bare `swift build` or `swift test`.** They fail with errors that
look like a broken dependency:

```
external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found
extensions must not contain stored properties
no such module 'XCTest'
```

Nothing is wrong with the code or the dependency. These appear whenever the
selected toolchain is `/Library/Developer/CommandLineTools`, which ships
neither the SwiftUI macro plugins nor XCTest. The scripts set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for the one command
they run, so no global `xcode-select` change is needed. If Xcode lives
elsewhere, export `DEVELOPER_DIR` yourself.

If you see a wall of dependency errors, you used the wrong entry point. Fix
the command, not the dependency.

## Entry points

| Command | What it does |
| --- | --- |
| `./Scripts/bootstrap.sh` | Resolve packages and point `core.hooksPath` at `.githooks/` (the Conventional Commits `commit-msg` hook). Run once after cloning. |
| `./Scripts/test.sh` | All package tests. Must pass with 0 failures. Tests that need a real model, microphone or AI provider are skipped unless you opt in. Extra arguments go to `swift test` (for example `--filter DictionaryTests`). |
| `./Scripts/build.sh` | SwiftPM build of every library and tool. |
| `./Scripts/build_app.sh <configuration>` | The signed `.app`. Configurations: `Debug`, `Release`, `TestHost`, `Bench`, and `AppStore` (the sandboxed App Store edition). |
| `./Scripts/install_app.sh Debug` | `build_app.sh`, then `ditto` to `~/Applications/kvoice.app`, then `codesign --verify`. Refuses the `AppStore` configuration (see below). |
| `./Scripts/sync_strings.sh [--build]` | Sync the String Catalogs with the code ([Localization.md](Localization.md)). |
| `./Scripts/make_app_icon.sh` | Regenerate `AppIcon.icns` from its SVG. Only needed after editing the icon. |
| `./Scripts/check_release_signature.sh <app>`, `./Scripts/check_app_store_signature.sh <app>` | Check a Release or AppStore bundle's signature and entitlements. |
| `./Scripts/ci_check_toolchain.sh` | Print the Xcode, SDK and Swift versions and fail when they are too old to build kvoice. CI runs it first. |
| `./Scripts/make_dmg.sh`, `notarize.sh`, `archive_app_store.sh`, `release_notes.sh`, `release_version.sh`, `ci_import_signing_identity.sh`, `ci_remove_signing_identity.sh` | Release tooling, run by the release workflow ([Releases](#releases)). You do not need them to contribute. Their tests: `python3 -m unittest Scripts.test_release_scripts`. |

The built app lands in `.build/xcode-derived/Build/Products/<configuration>/kvoice.app`.
`KVOICE_MARKETING_VERSION` and `KVOICE_BUILD_NUMBER` override the version from
`Config/Base.xcconfig`; a development build leaves them unset.

## Configurations

`Config/*.xcconfig` define five configurations on top of `Base.xcconfig`:

| Configuration | Edition | Purpose |
| --- | --- | --- |
| `Debug` | Developer ID | Day-to-day development |
| `Release` | Developer ID | Optimized, hardened runtime, secure timestamp; what the DMG ships |
| `TestHost` | Developer ID | Hosts XCTest bundles |
| `Bench` | Developer ID | Release optimization with benchmark instrumentation |
| `AppStore` | App Store | Release plus the App Sandbox and `KVOICE_DISTRIBUTION_EDITION = appStore`, signed with `Apps/KvoiceApp/Kvoice-AppStore.entitlements` |

**Never install an `AppStore` build over `~/Applications/kvoice.app`.** Both
editions share a bundle ID, so the sandboxed copy would take over the other's
permissions and settings. Test it on a separate macOS user or a virtual
machine.

## Installing a build to try it

```sh
./Scripts/install_app.sh Debug
# or by hand:
ditto .build/xcode-derived/Build/Products/Debug/kvoice.app ~/Applications/kvoice.app
open ~/Applications/kvoice.app
```

**Use `ditto`, never `cp -R`.** `cp -R` can break the code signature, and an
invalid signature silently loses the Accessibility permission.

## Signing and permissions

macOS ties the Accessibility and Microphone permissions to the app's
**designated requirement**, which comes from its signature. Change the
signature and the permission no longer applies, even though System Settings
may still show it switched on.

`build_app.sh` chooses the identity in this order, and prints the one it
used:

1. `KVOICE_CODE_SIGN_IDENTITY`, if set.
2. For `Release` only, a valid "Developer ID Application" identity in your
   keychain: the one for the team in `KVOICE_DEVELOPER_ID_TEAM` or
   `APPLE_TEAM_ID` when either is set, otherwise the first one found. No team
   is written into the project, so a fork signs with its own.
3. A certificate named **kvoice Local Signing**, when it is in your keychain.
4. Otherwise ad hoc (`-`, "Sign to Run Locally").

An ad-hoc signature changes on every build, so macOS forgets the
Accessibility permission after each rebuild. To keep it across rebuilds,
create your own self-signed code-signing certificate once: Keychain Access ›
Certificate Assistant › Create a Certificate…, name it `kvoice Local Signing`,
identity type Self-Signed Root, certificate type Code Signing. Rebuild, and
grant Accessibility one last time. (`security find-identity -v` will not list
it, because a self-signed certificate is untrusted; `codesign` uses it anyway,
which is why the script searches without `-v`.)

If a permission looks granted but kvoice says it is not, reset it and grant
it again:

```sh
tccutil reset Accessibility io.github.kccarlos.kvoice
tccutil reset Microphone io.github.kccarlos.kvoice
```

**Never build with `CODE_SIGNING_ALLOWED=NO`.** That produces a bundle with
no `Contents/_CodeSignature`, which `codesign --verify` rejects. macOS refuses
to attach an Accessibility permission to it, so the System Settings switch
appears on while `AXIsProcessTrusted()` keeps returning `false`, with no error
anywhere. Check a build before blaming the app:

```sh
codesign --verify --deep --strict --verbose=2 ~/Applications/kvoice.app
```

The app re-reads the Accessibility state when it becomes active, and once a
second while the setup guide's Accessibility step or the Permissions section
is visible, so a new permission shows up within about a second.

## SwiftPM and the keychain (`--disable-keychain`)

`build.sh` and `test.sh` pass `--disable-keychain` to SwiftPM. FluidAudio's
manifest declares a prebuilt binary target that kvoice does not link
(`traits: []`), but SwiftPM still downloads it while resolving, and first
asks the login keychain for a `github.com` credential. If the keychain holds
one (from `gh` or git's credential helper), that lookup can block on an
"allow access" dialog while SwiftPM prints nothing, so the build looks hung.
Every kvoice dependency is public, so the lookup is never needed. If a
hand-run `DEVELOPER_DIR=… swift test` hangs after "Computing version for …",
add `--disable-keychain`.

## When an incremental build lies

Changing a default argument or a public signature can leave a stale object
file and produce a linker error that does not match the source. Clear the
build directory for the architecture and retry:

```sh
rm -rf .build/arm64-apple-macosx
```

For the app, a stale nested resource bundle can break the outer signature
seal (`a sealed resource is missing or invalid`) after two incremental
`build_app.sh` runs. A clean rebuild fixes it.

## Tuning without a rebuild

Thresholds, timings and retry counts are one table, `DeveloperDefaults`
(KvoiceDomain), bundled as `Apps/KvoiceApp/Resources/kvoice.defaults.json`. A
test keeps the file and the compiled values equal, so edit both. To try a
different value without rebuilding, write any subset of the keys to
`~/Library/Application Support/kvoice/config.override.json` and relaunch:

```json
{ "quietPeakThresholdDBFS": -24, "hudSuccessDismissMilliseconds": 1500 }
```

The file is read once at launch and is refused whole, with one
`config.override.rejected` diagnostics line naming the reason, when it is not
a JSON object, has a value of the wrong type, or a value outside
`DeveloperDefaults.validationBounds`. Contracts (pins, digests, the insertion
tiers, the pasteboard rule, secure fields, diagnostics) are not keys.

## Looking at the UI without a screen

Layout cannot be unit-tested, but it can be rendered. `LayoutSnapshotTests`
(skipped by default) hosts every main-window section in a real `NSWindow` at
several sizes, and the recorder HUD in both styles, and writes PNGs:

```sh
KVOICE_LAYOUT_SNAPSHOTS=/tmp/kvoice-snaps ./Scripts/test.sh --filter LayoutSnapshotTests
```

Offscreen rendering has known quirks: materials, blur and Liquid Glass do not
composite, the sidebar selection draws black, nested split views may render
blank, and toggles may draw in their off state. Do not "fix" those.

## The Xcode project

`Kvoice.xcodeproj` uses **classic groups**, not folder-synchronized groups. A
new file under `Apps/KvoiceApp/` is **not** picked up automatically: add it to
the project's `PBXBuildFile`, `PBXFileReference`, the group's `children`, and
the `Sources` build phase (or add it through Xcode). Files under `Packages/`
are covered by SwiftPM and need no project edit.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request, with no secrets and read-only permissions:

- **Commit messages** (pull requests): `Scripts/check_commit_message.sh` over
  the pull request's commits.
- **Script tests**: `python3 -m unittest Scripts.test_release_scripts`.
- **Unit tests**: `./Scripts/test.sh`.
- **Builds**: `Debug`, `Release` and `AppStore` with `build_app.sh`, signed ad
  hoc (`KVOICE_CODE_SIGN_IDENTITY=-`), then `codesign --verify`,
  `check_release_signature.sh` (Release) and `check_app_store_signature.sh`
  (AppStore), and a trial `make_dmg.sh` that is not published.

Every step is a script you can run locally in the same order. Jobs that need
Xcode run on GitHub's `xcode-27` image (Xcode 27 on macOS 27, arm64; a public
preview at the time of writing). `DEVELOPER_DIR` selects
`/Applications/Xcode_27.0.app` there; the repository variables
`KVOICE_DEVELOPER_DIR` and `KVOICE_MACOS_RUNNER` override the Xcode path and,
for pushes and releases only, the runner label (a self-hosted runner, should
the hosted image be unavailable). Pull requests always use the hosted image.
Lint the workflows with `actionlint`; `.github/actionlint.yaml` teaches it the
`xcode-27` label.

## Releases

A release is a tag `vMAJOR.MINOR.PATCH` (optionally `-rc.N`, a pre-release)
on a sync commit of `main`. `.github/workflows/release.yml` then:

1. checks the tag, derives the version (`release_version.sh`; the build
   number is the workflow run number) and refuses the tag when
   [CHANGELOG.md](../CHANGELOG.md) has no section for it;
2. runs the unit tests;
3. in the protected `release` environment, after a maintainer approves:
   - builds `Release` with the Developer ID, checks it
     (`check_release_signature.sh --developer-id`), notarizes and staples the
     app, packages the DMG, notarizes and staples the DMG;
   - archives the `AppStore` configuration with Apple Distribution and the
     Mac App Store profile, checks the archived app, exports the `.pkg`
     (signed with Mac Installer Distribution) and uploads it to App Store
     Connect, where it appears in TestFlight. It is never submitted for
     review by the workflow;
4. publishes a GitHub Release with the DMG, its SHA-256 and the notes
   (`release_notes.sh`: the CHANGELOG section plus the sync commits since
   the previous tag).

Its configuration, all in the repository settings:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | The 10-character Apple team ID. Not secret (every signed binary carries it); a variable so a fork uses its own. |
| Variable | `KVOICE_PCC_ENTITLEMENT` | `1` to sign the App Store build with the managed Private Cloud Compute entitlement, once Apple has granted it and the profile includes it. Unset otherwise. |
| Variable | `KVOICE_MACOS_RUNNER`, `KVOICE_DEVELOPER_DIR` | Optional runner label and Xcode path overrides (above). |
| `release` secret | `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | The "Developer ID Application" certificate and its private key, exported as a `.p12` (base64), and its password. |
| `release` secret | `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD` | The "Apple Distribution" certificate and key, likewise. |
| `release` secret | `MAC_INSTALLER_P12_BASE64`, `MAC_INSTALLER_P12_PASSWORD` | The "Mac Installer Distribution" certificate and key, likewise. |
| `release` secret | `APP_STORE_PROFILE_BASE64` | The "Mac App Store Connect" provisioning profile for `io.github.kccarlos.kvoice` (base64 of the `.provisionprofile`). |
| `release` secret | `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID` | An App Store Connect API key (base64 of `AuthKey_<id>.p8`), its key ID and the issuer ID. Used to notarize and to upload. |

The `release` environment requires a reviewer and is limited to `v*` tags
and the `main` branch (the preview builds below), so no other branch, pull
request or fork can reach these secrets, and every run that reads them
waits for a maintainer's approval. The signing jobs delete their temporary
keychain, key file and profile in `if: always()` steps.

The Developer ID DMG's steps (import the identity, build, check, notarize
and staple the app, package, notarize and staple the DMG) are the composite
action `.github/actions/notarized-dmg`, shared with the preview workflow.

## Preview builds

`.github/workflows/preview.yml` makes notarized DMGs of both editions from
`main` without tagging or publishing anything, to try a build on another
Mac before a release. It runs only when started by hand (Actions ›
**Preview** › *Run workflow*, with an optional label), and its signing jobs
wait in the `release` environment for a maintainer's approval, like a
release. It produces two workflow artifacts, kept for 14 days, each holding
a DMG and its SHA-256:

| Artifact | What it is |
| --- | --- |
| `KVoice-<version>-preview-<sha>-DeveloperID.dmg` | The Developer ID edition, built exactly as a release builds it. |
| `KVoice-<version>-preview-<sha>-AppStoreEdition.dmg` | The sandboxed App Store edition (the `AppStore` configuration), signed with the Developer ID instead of Apple Distribution so it can be notarized and opened outside the store. Its volume is named "KVoice App Store Edition TEST BUILD …". It carries the edition's sandbox entitlements, the hardened runtime and a secure timestamp, no provisioning profile (none of its entitlements needs one) and never the Private Cloud Compute entitlement, so Private Cloud Compute reports itself unavailable in it. It is not a store build and is never uploaded. |

`<version>` is `MARKETING_VERSION` from `Config/Base.xcconfig`; the build
number (`CFBundleVersion`) is the preview workflow's run number. Download
from the run's page, or `gh run download <run-id> --repo <owner>/kvoice`.

**Both editions have the same bundle identifier.** Do not install them side
by side for the same macOS user: install one, test it, quit and delete it
(and, for a clean start, its data), then install the other; or give each
edition its own macOS user. Grant Accessibility and Microphone again after
every switch, from a clean state: both preview DMGs are signed with the same
Developer ID and identifier, so macOS may show an earlier edition's grant as
already on while the new edition needs its own. Before installing the other
edition, reset them with `tccutil reset All io.github.kccarlos.kvoice` — on
the test Mac only: on a Mac that also has a development build installed, the
same identifier resets that build's grants too.

The App Store edition signed this way can be built locally too, without
notarizing:

```sh
KVOICE_CODE_SIGN_IDENTITY="Developer ID Application: <name> (<team>)" \
  ./Scripts/build_app.sh AppStore
./Scripts/check_app_store_signature.sh --developer-id \
  .build/xcode-derived/Build/Products/AppStore/kvoice.app
```

`build_app.sh` adds `--timestamp` to an `AppStore` build only when the
identity is a Developer ID; `notarize.sh` checks an app with the check of
the edition its `Info.plist` names.

## Editor tooling

The root `Package.swift` is what SourceKit-LSP indexes. Run `./Scripts/build.sh`
once after cloning so go-to-definition and diagnostics work across packages.
