# Tools

Command-line utilities, wired into the root `Package.swift` and built by
`./Scripts/build.sh`.

| Tool | Purpose |
| --- | --- |
| `KVoiceModelManifestGenerator` | Generates a model's trusted manifest and its digest from a prepared package. See [KVoiceModelManifestGenerator/README.md](KVoiceModelManifestGenerator/README.md) and [../Docs/Model-Packages.md](../Docs/Model-Packages.md). |
| `KVoiceBench` | Transcription accuracy and latency harness. It reads a corpus manifest and recordings you supply (`KVoiceBench run --manifest <corpus.json> --model-package <verified-package> …`); no corpus or recordings are part of this repository. |

Run them with `DEVELOPER_DIR` pointing at Xcode, as the scripts do:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run KVoiceModelManifestGenerator /path/to/prepared-package /tmp/ModelManifest.json
```
