# Localization

kvoice ships in English (source) and Simplified Chinese (`zh-Hans`). This
page is the working procedure: where a string goes, how the
catalogs stay in sync with the code, how to translate, and how to add a
language. The design and its reasons are in
[Architecture.md](Architecture.md), "Localization".

## The catalogs

| Catalog | Owns | Filled by |
| --- | --- | --- |
| `Packages/KvoiceUI/Sources/KvoiceUI/Resources/Localizable.xcstrings` | Every string in `KvoiceUI`: SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`, `.accessibilityLabel("…")`, …) and `String(localized: "…", bundle: .module)` in view models, HUD state, panels and card types | `./Scripts/sync_strings.sh` |
| `Apps/KvoiceApp/Resources/Shell.xcstrings` | The AppKit shell: status-menu titles and tooltips, window titles, save panels, HUD copy the shell composes — every `String(localized: "…", table: "Shell")` in `Apps/KvoiceApp` | `./Scripts/sync_strings.sh` |
| `Apps/KvoiceApp/Resources/AppShortcuts.xcstrings` | The App Shortcut phrases (`KvoiceShortcuts`), keyed as `Start dictation with ${applicationName}`. Xcode's App Intents metadata step reads and validates this file; nothing else can localize a phrase | By hand; `StringCatalogTests` covers it |
| `Packages/KvoiceUI/Sources/KvoiceUI/Resources/DomainCopy.xcstrings` | `KvoiceDomain` and `KvoiceAppCore` sentences and enum names, keyed by their English text (`KVoiceErrorCode.userFacingMessage`, `BlockReason.message`, the reducer's warning lines, `displayName`s, `SelectionActionRunner.Outcome.userFacingMessage`) | By hand; `DomainCopyTests` lists what is missing |

English is the key. There is no `en.lproj`; the compiled bundles carry only
`zh-Hans.lproj`, and `CFBundleDevelopmentRegion = en` in the app's
`Info.plist` tells Foundation that English exists (without it an English
user gets Chinese — the only localization present). Do not remove that key.

## Where a new string goes

- **In a SwiftUI view in `KvoiceUI`:** write the literal. `Text`, `Button`,
  `Toggle`, `Picker`, `Label`, `TextField`, `.help`, `.navigationTitle`,
  `.accessibilityLabel/Hint/Value`, `.alert`/`.confirmationDialog` titles
  all take `LocalizedStringKey`. A ternary of two literals is fine. A helper
  that takes a label should declare it `LocalizedStringKey`, not `String`
  (`SettingsFactRow`, `actionRow`, `statusLine`, `metadataRow` do), so the
  caller's literal still localizes and extracts.
- **Anywhere else in `KvoiceUI`** (a view model, `HUDViewState`, an
  `NSSavePanel` message, a `String` that a view later shows):
  `String(localized: "Downloading — \(done) of \(total)", bundle: .module)`.
  Interpolation is fine; the key becomes `Downloading — %@ of %@`. Never
  concatenate two localized fragments into a sentence — make two whole
  sentences (`"Imported 1 term."` / `"Imported \(n) terms."`), because
  Chinese has no plural and other languages reorder.
- **In `Apps/KvoiceApp`:** `String(localized: "Quit kvoice", table: "Shell")`.
  Never omit `table:` there — a shell literal without it lands in the
  `Localizable` table, which the app compiles from KvoiceUI's file.
- **A domain string shown on screen** (`mode.displayName`, `failure.message`,
  `summary.warningMessage`): `Text(domain: value)` in a view, or
  `DomainCopy.localized(value)` where a `String` is needed. Add the English
  to `DomainCopy.xcstrings`, and to `DomainUserFacingCopy` (KvoiceDomain) or
  `SelectionActionRunner.Outcome.userFacingMessageInventory` (KvoiceAppCore)
  if it is a new sentence, so the coverage test sees it.
- **In an App Intent (`Apps/KvoiceApp/Intents`):** titles, descriptions,
  parameter titles and dialogs are `LocalizedStringResource("…", table:
  "Shell")` — the compiler records them like `String(localized:table:)`, so
  they sync into `Shell.xcstrings`. Two exceptions: a `Summary("… \(\.$param)",
  table: "Shell")` is extracted by `appintentsmetadataprocessor`, not the
  compiler, so its key (`Start dictation with ${aiAction}`) is a hand-kept
  `"extractionState" : "manual"` entry in `Shell.xcstrings` that the sync
  never marks stale; and App Shortcut phrases live only in
  `AppShortcuts.xcstrings` (above).
- **Not localized, on purpose:** diagnostics and log text, `settings.json`
  keys, `MainWindowSection.rawValue`, SF Symbol names, the `DiagnosticsReport`
  text (the developer reads it), user data such as action names and
  translation-language labels the user typed, and format-only keys (`%@ · %@`),
  which the catalog marks `shouldTranslate: false`.
- **Language names** (transcription language picker, `Language: …` menu):
  `LanguageNames.transcriptionLanguageName(forCode:)` asks Foundation in the
  interface language — do not add the 100 Whisper names to a catalog.

## The workflow: change code → sync → translate → test

1. Build the app: `./Scripts/build_app.sh Debug`. `SWIFT_EMIT_LOC_STRINGS =
   YES` (`Config/Base.xcconfig`) makes the compiler write one `.stringsdata`
   per source file listing every localizable literal it saw — the same
   extraction Xcode's editor uses, and exact where regex extraction is not.
2. Sync: `./Scripts/sync_strings.sh` (or `--build` to do step 1 first). It
   runs `xcstringstool sync` for the KvoiceUI and Shell catalogs: new keys are
   added; a key no longer in the code is deleted if untranslated and marked
   `"extractionState" : "stale"` if it had a translation. `xcodebuild` does
   not do this on its own — only the Xcode IDE syncs catalogs at build time.
3. Translate: open the catalog (Xcode's String Catalog editor, or the JSON)
   and give every new key a `zh-Hans` value with `"state" : "translated"`.
   Delete stale entries. Keep `%@`/`%lld` counts identical; if you reorder,
   use positional specifiers (`%2$@ … %1$@`) for **every** specifier in that
   string — mixing crashes `String(format:)`.
4. `./Scripts/test.sh`. `StringCatalogTests` fails on a key without a
   translation, a stale key, a changed specifier set, or a language the
   `InterfaceLanguage` enum does not offer; `DomainCopyTests` fails on a
   domain sentence missing from `DomainCopy.xcstrings` and on a catalog key
   the domain no longer produces.

The tests parse the `.xcstrings` JSON from the source tree. `swift build`
copies `.xcstrings` files into the resource bundle **without compiling** them
(only Xcode compiles them to `.lproj`), so under SwiftPM `Bundle.module` has
no translations and every `String(localized:)` resolves to its English key.
That is why the tests read the catalogs directly and why `DomainCopy.Table`
is injectable.

## Seeing it on screen

Settings › General › Interface language: Follow System / English / 简体中文.
Picking one writes `AppleLanguages` into `io.github.kccarlos.kvoice`'s defaults and
offers Relaunch Now; the relaunched app is in that language. Follow System
removes the override. To check the two bundles without the app:

```sh
defaults write io.github.kccarlos.kvoice AppleLanguages '(zh-Hans)'   # what the picker does
open ~/Applications/kvoice.app
defaults delete io.github.kccarlos.kvoice AppleLanguages              # back to the system list
```

## Adding a language

1. Add a case to `InterfaceLanguage` (KvoiceDomain, `Models.swift`) with the
   BCP 47 identifier as its raw value, and a `Text(verbatim: "<native name>")`
   row to the picker in `GeneralSectionView`.
2. Add the identifier to `knownRegions` in `Kvoice.xcodeproj/project.pbxproj`.
3. Translate all three catalogs (Xcode's editor adds a language with one
   click; the JSON shape is `"localizations" : { "<id>" : { "stringUnit" :
   { "state" : "translated", "value" : "…" } } }`).
4. `./Scripts/test.sh` — `StringCatalogTests` now requires that language
   everywhere; `./Scripts/build_app.sh Debug` and check
   `kvoice.app/Contents/Resources/<id>.lproj` and
   `kvoice_KvoiceUI.bundle/Contents/Resources/<id>.lproj` both exist.
5. Launch the app in the new language (below, "Seeing it on screen") and
   look at every section, the setup guide, the menu and the HUD. Say in the
   pull request what you checked.
