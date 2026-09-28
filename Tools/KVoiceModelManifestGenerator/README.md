# KVoiceModelManifestGenerator

Generate the app-trusted manifest from a prepared, known-good model package.
The generator walks only the package's artifact directories, rejects symbolic
links and unexpected entries, and records each artifact's relative path, byte
count, SHA-256, and role.

Two layouts (see `Docs/Model-Packages.md`):

- **Whisper** (the default): the package contains `model/` and `tokenizer/`.

  ```text
  swift run KVoiceModelManifestGenerator /path/to/prepared-package /tmp/model-manifest.json
  ```

- **FluidAudio** (ADR-019): one flat `model/` folder holding the Core ML
  bundles and the vocabulary JSON; `--release` names the pinned release in
  `PinnedModelReleases`, which supplies family, format, repository, revision,
  the repository subdirectory (Nemotron's `multilingual/2240ms`), tokenizer
  root (`model`) and the artifact roles. SenseVoice's prepared folder holds
  the preprocessor, the int8 *and* fp32 encoders and `vocab.json` — not the
  fp16 export. Paraformer's holds the preprocessor, `ParaformerEncoder_int8`,
  `ParaformerCifAlphas`, `ParaformerDecoder_int8` and `vocab.json` — not the
  fp16 encoder/decoder pair. Parakeet EOU's holds the `320ms/` folder's
  `streaming_encoder`, `decoder`, `joint_decision` and `vocab.json` — not
  the preprocessor graph, the `.mlpackage` sources or the scripts.

  ```text
  swift run KVoiceModelManifestGenerator ~/Models/parakeet-tdt-0.6b-v3-coreml /tmp/manifest.json \
      --release parakeet-tdt-0.6b-v3-coreml
  ```

The tool prints the file count, the byte total (the catalog's
`downloadBytes`) and `manifestSHA256=` (the catalog's `manifestSHA256`).

The prepared model weights and tokenizer are release evidence, not repository
contents. Do not commit them.
