# Model packages and trust material

Transcription runs on the Mac against a Core ML package: Whisper through
WhisperKit, or a Parakeet-family model through FluidAudio. **kvoice will not
load a package it cannot verify** against a manifest that ships inside the
app. The one exception is a system-managed entry (Apple Speech), whose assets
macOS owns and verifies; see the last section.

## The catalog is the trust root

`KvoiceModelManagement` bundles the speech model catalog,
`Resources/SpeechModelCatalog.json`, plus one manifest per entry under
`Resources/Manifests/`. The catalog records each manifest's SHA-256, and each
manifest records every file's relative path, byte count, SHA-256 and role.
A package is never accepted just because a folder contains a manifest.

`Apps/KvoiceApp/ModelManifest.json` and `ModelManifest.sha256` are the app
bundle's copy for the High-Accuracy Whisper package. The loader fails closed
without them, and a test keeps them byte-identical to the catalog's copy.

`PinnedModelReleases.all` is the one list of releases kvoice may download:
model id, runtime, family, format, repository, revision, subdirectory, runtime
package and version, tokenizer root. The catalog loader, the pre-download gate
and the URL provider all consult it. A manifest that matches a row by model id
but differs in any other field is a different release and is refused.

| Catalog id | Runtime | Size |
| --- | --- | --- |
| `whisper-large-v3-turbo-coreml-632mb` (recommended) | WhisperKit | 646 MB |
| `whisper-large-v3-turbo-coreml-uncompressed` | WhisperKit | 1.64 GB |
| `parakeet-tdt-0.6b-v3-coreml` | FluidAudio | 483 MB |
| `parakeet-unified-en-0.6b-coreml` | FluidAudio | 1.21 GB |
| `nemotron-3.5-asr-streaming-multilingual-0.6b-coreml` | FluidAudio | 664 MB |
| `sensevoice-small-coreml` | FluidAudio | 1.18 GB |
| `paraformer-large-zh-coreml` | FluidAudio | 222 MB |
| `parakeet-realtime-eou-120m-coreml` | FluidAudio | 224 MB |
| `apple-speech` | Speech framework (system-managed) | managed by macOS |

Model licenses and attributions are in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Optional catalog fields
(`promptTokenLimit`, `punctuation`, `license`, `attribution`) are decoded with
defaults, so adding one needs no schema bump and changes no manifest digest.

## Where the files come from

A manifest describes the **installed** layout, which is not always the
published one. `PinnedHuggingFaceModelURLProvider` looks the release up in
`PinnedModelReleases` (refusing anything not in the table) and maps each
installed path to `huggingface.co/<repository>/resolve/<pinned revision>/<subdirectory>/<path>`.
Whisper's tokenizer comes from `openai/whisper-large-v3` at its own pinned
revision. `PinnedHuggingFaceModelURLProviderTests` pins the exact URLs.

## Regenerating a manifest: never hand-edit

Use the generator ([Tools/KVoiceModelManifestGenerator](../Tools/KVoiceModelManifestGenerator/README.md))
on a prepared, known-good package:

```sh
# Whisper: the package holds model/ and tokenizer/models/openai/whisper-large-v3/
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run KVoiceModelManifestGenerator /path/to/prepared-package /tmp/ModelManifest.json

# FluidAudio: one flat model/ folder; --release names the pinned row
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run KVoiceModelManifestGenerator ~/Models/parakeet-tdt-0.6b-v3-coreml \
    Packages/KvoiceModelManagement/Sources/KvoiceModelManagement/Resources/Manifests/parakeet-tdt-0.6b-v3-coreml.json \
    --release parakeet-tdt-0.6b-v3-coreml
```

The tool prints `files=`, `downloadBytes=` and `manifestSHA256=`; the last two
go into the catalog entry. Cross-check every large file's digest against the
Hugging Face tree API (`lfs.oid` is the SHA-256) before committing a manifest,
and hash small non-LFS files locally.

Weights are **never committed**; only manifests and digests are.
`~/Models/<catalog id>/` is the conventional place for a prepared package, and
the opt-in live model tests read it.

## Lifecycle rules

`ModelPackageManager.refresh()` runs at launch **and on every app
activation**, which makes it easy to break. It must:

- keep an externally selected package (a folder the user chose) across
  activations, failing closed when the folder is missing and loading it again
  when it returns. External files are never written or deleted;
- never re-hash and recompile a resident managed package on activation;
- keep a terminal failure (`corrupt`, `incompatible`, `error`) visible rather
  than resetting it behind the user's back.

Refresh also retries interrupted deletions and cleans stale download staging
(each model stages under `.staging/<modelID>/`). Before a download starts, a
free-space gate refuses with `MODEL-INSUFFICIENT-DISK` when the volume lacks
room. One `ModelPackageManager` exists per catalog entry, and only the default
model is loaded: `RuntimeSwitchingTranscriptionEngine` routes each load to the
engine for that model's runtime and unloads the other runtime first.

## First load is slow

Core ML compiles a model for the Neural Engine on first load, which takes
minutes for the Whisper packages. The UI shows determinate progress for
download and verification, then an indeterminate state for the load, and says
that the first load is slow. Changing compute units (Speech Models ›
Runtime: Neural Engine + CPU, GPU + CPU, All, CPU only) reloads the model at
the same cost; the choice is persisted only after the engine accepts it. Some
models refuse some compute units before loading (for example, graphs that
produce invalid output off the Neural Engine).

## System-managed entries

The `apple-speech` entry carries no manifest: its catalog row says
`"assetSource": "system-managed"`, with an empty manifest and digest, zero
download bytes and revision `"system"`. The loader refuses such an entry if it
claims a digest. The weights are never on kvoice's disk: macOS fetches,
verifies, stores and shares them between apps, and kvoice only holds a
per-language **reservation**.

- State is per transcription language. Switching to a language whose assets
  are missing shows Install and releases the resident engine.
- Install asks macOS to download and reserve the language; Delete releases
  the reservation, and macOS removes the files on its own schedule when no
  other app uses them.
- macOS limits how many languages one app can reserve; past the limit,
  Install fails with a message saying to delete another language.
- On macOS 15 the entry is listed but unavailable ("Requires macOS 26 or
  later."), so one settings file works on every system.
