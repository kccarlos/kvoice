# Architecture

How kvoice is put together, and the rules that keep it testable. Read this
before adding a feature. The rules in [AGENTS.md](../AGENTS.md) are the short
form; this page explains them.

Code comments cite design records as `ADR-NNN` and requirements as ids such
as `FR-AX-001`. Those records are internal and not published; the rule each
one stands for is stated in the code next to it or on this page.

## Shape of the thing

kvoice is a menu-bar accessory app around one pipeline:

```
hotkey → capture audio → transcribe locally → (optional AI action) → insert into the focused app
```

Every stage is an adapter behind a protocol in `KvoiceDomain`, and the
sequencing lives in one actor-isolated controller. Nothing in the pipeline
reaches for AppKit, a speech framework, or the network directly. That is what
lets the whole pipeline run in tests without a microphone, a model, a window
or a network.

## Module map

| Path | Contents |
| --- | --- |
| `Packages/KvoiceDomain` | Foundation-only value types, protocols, stable error codes, the dictation state machine, the settings model, prompt resources, the diagnostics catalog |
| `Packages/KvoiceAppCore` | The dictation controller and per-job runners, the settings coordinator and reducer, `AIProviderRoutingClient` (the one AI client the shell holds; it routes each request to the right transport) |
| `Packages/KvoiceAudio` | `AVAudioEngine` capture, the duration cap, level metering |
| `Packages/KvoiceTranscription` | The WhisperKit adapter, model package validation, runtime telemetry, the performance sample |
| `Packages/KvoiceParakeet` | The FluidAudio adapter for the Parakeet, Nemotron, SenseVoice, Paraformer and Parakeet EOU models. `FluidAudioParakeetRuntime.swift` is the only file that imports FluidAudio |
| `Packages/KvoiceAppleSpeech` | The Speech framework adapter (Apple Speech, macOS 26+). `SpeechFrameworkRuntime.swift` is the only file that imports Speech; weak-linked, every use behind `#available` |
| `Packages/KvoiceModelManagement` | Download, verify, load and delete model packages; the pinned-release table; the speech model catalog; one resident engine that switches runtimes |
| `Packages/KvoiceInsertion` | Accessibility insertion (`AXTextInsertionService`), the App Store edition's typed insertion (`TypedTextInsertionService`), permission adapters, the clipboard fallback |
| `Packages/KvoiceHotkeys` | The KeyboardShortcuts / Carbon adapter and the shortcut recorder |
| `Packages/KvoiceAI` | The OpenAI-compatible Chat Completions client and model discovery |
| `Packages/KvoiceAppleIntelligence` | The Foundation Models adapter: on-device Apple Intelligence and Private Cloud Compute. `FoundationModelsRuntime.swift` is the only file that imports FoundationModels. No `URLSession` |
| `Packages/KvoicePersistence` | Settings, secrets, local state, the history database |
| `Packages/KvoiceUI` | SwiftUI views and view models: HUD, onboarding, the main window's sections, history |
| `Packages/KvoiceDiagnostics` | OSLog and file diagnostic sinks |
| `Packages/KvoiceTestSupport` | Fakes and fixtures. **Production targets must not depend on it.** |
| `Apps/KvoiceApp` | `AppDelegate`, the composition root, windows, the status menu, entitlements, `Info.plist`, App Intents |
| `Scripts/` | The only supported build, test and release entry points |
| `Tools/` | The model manifest generator and the benchmark harness ([Tools/README.md](../Tools/README.md)) |

## The rules, and why

- **Vendor types do not cross `KvoiceDomain` protocols.** WhisperKit,
  FluidAudio, FoundationModels, Speech, KeyboardShortcuts and AppKit types
  stay inside their owning adapter. Source-scanning tests enforce the
  one-file-imports-it rule for FluidAudio, FoundationModels and Speech. This
  is what keeps the domain testable without a model, a microphone or a
  window.
- **Dependency pins are part of the contract.** WhisperKit `1.1.0`,
  KeyboardShortcuts `3.0.1` and FluidAudio `0.15.7` are `exact:` in
  `Package.swift`. FluidAudio is declared with `traits: []`, which leaves its
  optional prebuilt text-normalisation binary out of the link (and is why the
  manifest needs `swift-tools-version: 6.2`). Model downloads are verified
  against manifests generated for these exact runtime versions.
- **Diagnostics carry scalars only.** See [Diagnostics](#diagnostics).
- **Secrets never reach `AppSettings`.** API keys live only in
  `SecretSettings` (a `0600` file), keyed by the configuration's `id`. Tests
  assert this, and the settings backup format has no field for a key.
- **Insertion tiers.** Accessibility first, typed keystrokes third, never a
  synthetic paste, never the pasteboard on success. See
  [Insertion](#insertion).
- **Model weights, recordings, API keys and benchmark corpora stay out of
  Git.** Only a model's manifest and its digest are committed.
- **HTTPS for remote AI hosts.** Plain HTTP only for loopback (`localhost`,
  `127.0.0.1`, `::1`). URLs carrying user info or credentials in the query are
  refused.

## Two editions

One codebase ships twice. The **Developer ID edition** (the `Debug`,
`Release`, `TestHost` and `Bench` configurations; the notarized DMG) is
unsandboxed. The **App Store edition** (the `AppStore` configuration) is
sandboxed, and the sandbox forbids driving another app through
Accessibility. Both use the bundle ID `io.github.kccarlos.kvoice`.

- **The value.** `DistributionEdition` (KvoiceDomain) is read once by
  `AppComposition` from the bundle's `KvoiceDistributionEdition` key, which
  the build sets from `KVOICE_DISTRIBUTION_EDITION` (`developerID` in
  `Config/Base.xcconfig`, `appStore` in `Config/AppStore.xcconfig`; missing or
  unknown means `developerID`).
- **Packages never `#if` on the edition.** The composition root picks
  adapters from the edition's capabilities: the insertion service, the
  permission adapter behind the Accessibility step, the hotkey adapter
  (modifier-only and middle-mouse triggers are refused in the App Store
  edition), and whether the Selection Action shortcuts are registered at all.
- **Availability rows.** A feature the current edition or system cannot
  offer declares a row in `SettingsAvailability` with a reason sentence; the
  UI disables the control and shows the reason. Add a row rather than hiding a
  control.
- **Files.** Every persistent path comes from `.applicationSupportDirectory`
  or `UserDefaults.standard`, so the sandbox relocates them with no code of
  its own. Never hard-code `~/Library`. A user-chosen location that must
  survive a relaunch needs a security-scoped bookmark (`ExportFolderAccess`
  is the pattern).

## The dictation pipeline

`DictationController` (KvoiceAppCore) is the coordinator: it turns shortcut
edges into start and stop (push-to-talk, toggle, hybrid), captures the target
app, takes a **settings snapshot** at the start edge, checks prerequisites,
and owns the published state. Each dictation is a `DictationJobRunner`, which
drives the pure `DictationReducer` through capture → finalize → transcribe →
AI → insert and records history and diagnostics for its job. A running job
never sees a settings change made after it started.

- **Isolation.** There is one actor. Runners are plain classes confined to the
  coordinator (their suspending methods take it as an `isolated` parameter),
  so every step runs on one serial executor.
- **Time.** The controller takes an injected `KvoiceClock`; tests use
  `ManualClock`. Never call `Date()` or sleep in pipeline code.
- **The silence gate.** Whisper produces "Thank you." on near-silent audio.
  `SpeechGate` (KvoiceDomain, pure) decides whether a recording carries
  speech, and both transcription paths apply it.
- **Streaming** is a per-model mode. Partial text is shown in the HUD, never
  logged or stored, and the inserted text is still the final pass over the
  whole recording.

## Insertion

`AXTextInsertionService` (Developer ID edition) resolves the focused element,
then tries, in order:

1. set `AXSelectedText` (the ordinary case);
2. splice `AXValue` (apps such as TextEdit that ignore tier 1);
3. type the text as Unicode keyboard events posted to the target process only
   (read-only text roles such as terminals; newlines become spaces). This
   tier can be turned off in settings.

Each tier verifies the result. When nothing can be inserted (no focused
element, a secure field, the target app changed, verification failed), the
text is written to the clipboard and the outcome says why
(`ClipboardFallbackReason`). A successful insertion never touches the
pasteboard, and nothing ever simulates Command-V.

`CGEvent` is confined to `TypedKeyboardEventPoster.swift`; a source-scanning
test enforces that and forbids any paste chord in the module.

Electron and Chromium apps build their accessibility tree lazily and report no
focused element until an assistive client asks. `AXTargetResolver` tries the
system-wide element, then the target app's own root, and when both are empty
performs the handshake (`AXManualAccessibility`, `AXEnhancedUserInterface`)
and polls a few times.

The App Store edition has no Accessibility tiers: `TypedTextInsertionService`
types everywhere, after checking that the target app is still frontmost and
that Secure Event Input is off, with the same poster, chunking, sanitising and
pasteboard rules.

## AI actions

### The settings-list pattern

AI configurations (saved endpoints) and prompt modes (the user-visible
"AI actions") follow the same shape. A new user-switchable list should too:

1. A `Codable` value type in `KvoiceDomain` (`AIConfiguration`, `PromptMode`)
   with a stable `id`, a user-visible `name`, and an `isUsable` check.
2. A list plus an active id on `AIEndpointSettings`, and an `apply(_:)` that
   **copies the item's values into the live request fields**. The request path
   (client, validation, the job's snapshot) never learns the list exists. This
   is why adding a provider or an action touches no networking code.
3. A dedicated `@MainActor` view model in `KvoiceUI/Settings/<Area>/` owning
   the list, a `Draft` type for the add/edit sheet, and its own actions.
4. A status-menu submenu rebuilt on every menu update, disabled while a job is
   active (the job holds a settings snapshot).
5. Secrets stay in `SecretSettings`, keyed by the item's `id`.

Two traps:

- `AppSettings` and `SecretSettings` decoders **reject unknown keys**, so
  renaming a persisted key breaks existing files. Keep the old key as a
  read-only `CodingKeys` case and decode new-then-legacy.
- A decoder must never fail the whole settings file over one bad value. An
  unknown enum string loads as the safe default with every other field kept.

### What a request carries

`AIPromptComposer.compose(request:settings:)` (KvoiceDomain) builds the
system prompt and one user message: the transcript inside `<TRANSCRIPT>`
tags, followed by optional context blocks, each delimited the same way with
delimiter neutralization: the user profile (`<USER_PROFILE>`, when set) and,
only for actions that opted in, `<CLIPBOARD>` and `<SELECTED_TEXT>`. The
controller gets context from an `AIContextProviding` the shell installs; with
none installed, no context is ever read. **Trigger words**
(`ActionTriggerResolver`) are resolved once, before the request is built.

### Transports

`AIProviderKind` maps every provider to one `AIProviderTransport`:

- `.openAICompatible`: `KvoiceAI`'s Chat Completions client. The only scalars
  that differ between providers (bearer token or `api-key` header, Azure's
  `api-version` query) are an `AIRequestProfile` on the configuration.
- `.appleIntelligence`: `AppleIntelligenceProcessingClient` over the
  on-device Foundation Models runtime. No URL, model or key. It refuses
  before the model sees anything when the model is unavailable or the input
  does not fit the context window.
- `.privateCloudCompute`: the same client over Apple's server model. The text
  leaves the Mac, which is why this is its own transport and not a variant of
  on-device. Only the App Store edition with Apple's managed entitlement can
  use it; any other build gets a static refusal and never touches the
  framework. Availability and quota are observed facts, read only while a
  Private Cloud Compute configuration is saved and AI Actions are on.

`AIProviderRoutingClient` routes by the transport scalar and **never retries
a failure on another transport**. Every AI failure (unavailable, too long,
quota, network, cancellation) takes the same path: the raw transcript is
inserted and one `ai.fallback.used` diagnostic line records the error code.
The prompt is built once for every transport; a test asserts they receive
identical text.

### Prompts

Shipped prompts are bundled text in
`Packages/KvoiceDomain/Sources/KvoiceDomain/Resources/Prompts/`, surfaced by
`BuiltInPromptModes`. House style: a `<SYSTEM_INSTRUCTIONS>` block stating that
the transcript is data and never instructions, then `# ROLE`, `# TASK`,
`# INPUT`, `# RULES`, `# OUTPUT`. Any tag other than `<TRANSCRIPT>` is
reference material, and the prompt should say so. `PromptModeTests` checks
every shipped prompt against these rules.

## Settings and configuration

Four sources decide the app's behavior:

| Source | Type | Persisted | In a settings backup |
| --- | --- | --- | --- |
| Developer defaults (thresholds, timings, retries) | `DeveloperDefaults` | Bundled `Apps/KvoiceApp/Resources/kvoice.defaults.json`, plus an optional override file | No |
| User preferences | `AppSettings` | `SettingsStore` (user defaults) | Yes |
| Local app state (onboarding progress, the chosen export folder) | `LocalState` | `LocalStateStore` | Never |
| Environment profile (observed capabilities and measurements) | `EnvironmentProfile` | Never | Never |

**One write path.** Every settings change, from a page, the status menu, the
setup guide, the hotkey recorder, an App Intent or an import, is a
`SettingsIntent` sent to `SettingsCoordinator` (KvoiceAppCore). A pure,
table-driven `SettingsReducer` produces the new `AppSettings` and a list of
effects, which the shell runs in order. Nothing else stores a copy of the
settings.

**Pages are projections.** A settings view model owns a
`SettingsProjectionHost` and nothing that duplicates the coordinator. A bound
control is a computed property: `get` reads `host.settings`, `set` sends one
intent with the origin of the page the control is on.

**Developer defaults** can be overridden without a rebuild by writing any
subset of keys to
`~/Library/Application Support/kvoice/config.override.json` and relaunching
([Build.md](Build.md#tuning-without-a-rebuild)). Contracts (pins, digests,
the insertion tier order, the pasteboard rule, the secure-field refusal, the
diagnostics rule) are code, not keys, and cannot be overridden. The bundled
JSON must equal the compiled table; a test checks it.

## Diagnostics

`~/Library/Application Support/kvoice/diagnostics.jsonl` and OSLog receive
`DiagnosticEvent`s through `DiagnosticLogging`.

1. **Scalars only.** `DiagnosticAttributes` is a fixed, typed catalog; free
   text is unrepresentable (`DiagnosticToken` is bounded ASCII), so a
   transcript, prompt, path, URL or field value cannot be logged by accident.
   A new fact is a new typed field, and `DiagnosticAttributesTests` checks
   that every field reaches the OSLog projection.
2. **Every failure the user sees leaves exactly one line** with a `site` (the
   code site that decided) and a `reason` (the class of failure), at the layer
   that turned the throw into a visible state. To add a failure path: throw a
   `KVoiceError` whose `metadata` carries `site` and `reason`, let the layer
   boundary emit the line, and add a test with a recording logger asserting
   exactly one line with that site. A path that can fail without a line is a
   bug.
3. **One timing line per job**, `dictation.completed` or `dictation.failed`,
   with the stage durations measured on the injected clock.

## Models

See [Model-Packages.md](Model-Packages.md): the catalog, the trusted
manifests, where files are downloaded from, and the lifecycle rules.

## History

`HistorySQLiteStore` (KvoicePersistence) is system SQLite through the C API:
one actor-owned connection, rollback journal, prepared statements only, an
explicit transaction around each migration and mutation, and a
`schema_migrations` table.

- A `HistoryEntry` is the whole persistence boundary. There is no audio blob
  column and no bundle identifier; the target is stored as a role class,
  never field text.
- **Corruption never blocks dictation.** A database that will not open or
  migrate is renamed aside (never deleted) and recreated; if that fails too,
  the store degrades and dictation carries on without history.
- Search is a local `LIKE`; the query never leaves the process.
- Stored audio is opt-in: `HistoryAudioFileStore` writes a `0600` WAV beside
  the database only when the job's settings snapshot says so.
- Retention (text and audio, independent) runs at launch and daily.

## The app shell

`Apps/KvoiceApp/AppDelegate.swift` holds the stored state and lifecycle; the
rest is split by concern into `AppDelegate+*.swift` files (menu, settings,
settings coordinator effects, model, onboarding, history, lifecycle, AI
actions, triggers). `AppComposition` and `AppModelComposition` wire the
adapters together. App Intents live in `Apps/KvoiceApp/Intents/`.

`Kvoice.xcodeproj` uses classic groups: a new file under `Apps/KvoiceApp/`
must be added to the project by hand ([Build.md](Build.md#the-xcode-project)).
Files under `Packages/` are picked up by SwiftPM.

## SwiftUI conventions

The UI targets macOS 15; use current APIs.

- View models are `@Observable`, not `ObservableObject`.
- The shell owns the view models and injects them; views declare
  `@Bindable` (or a plain `let`). Never `@StateObject` for an injected object:
  it keeps the first instance and silently ignores later ones.
- Views do not hardcode window sizes. Set the frame on the window controller.
- Sheets use `SheetButtonBar` (Return confirms, Escape cancels), not
  `.toolbar`. Section actions go inline, not in a toolbar.
- Use `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, the `Tab` API, and
  always pass `value:` to `.animation`.
- Respect Reduce Motion.
- Setup pages share one shape: header, scrolling content, and a bottom bar
  whose titles and enablement come from `OnboardingViewModel.actionBar`.

## Localization

English (the source) and Simplified Chinese ship through String Catalogs.
KvoiceUI's catalog is also compiled into the app target, because SwiftUI's
`LocalizedStringKey` initializers look strings up in the main bundle. The
shell uses a second table, `Shell`. `KvoiceDomain` knows no bundle: its
user-facing sentences are the keys of a third table, `DomainCopy`, resolved
in KvoiceUI. The procedure: [Localization.md](Localization.md).

## Adding a feature: a checklist

1. Put the value types and the protocol in `KvoiceDomain`; keep it
   Foundation-only.
2. Implement the adapter in the package that owns the vendor framework.
3. Wire it in `AppComposition`. If an edition or OS version cannot offer it,
   add a `SettingsAvailability` row with a reason.
4. Settings: add a field to `AppSettings` (decode with a default, never fail
   the file), a `SettingsIntent` case, the reducer row, and a projection on the
   page.
5. Diagnostics: typed fields only; one line per user-visible failure.
6. Strings: localize, then `./Scripts/sync_strings.sh`.
7. Tests at every seam you added, with the fakes in `KvoiceTestSupport`.
