# Third-party notices

KVoice itself is licensed under [MIT](LICENSE). Every dependency below is MIT or
Apache-2.0, both of which are compatible with redistributing this app under MIT.
The speech models are downloaded, not redistributed; their licenses (MIT,
CC-BY-4.0, OpenMDW-1.1, the FunASR Model Open Source License 1.1, Apache-2.0,
the NVIDIA Open Model License) are listed under "Speech models".

Versions are pinned exactly in `Package.swift` and `Package.resolved`; the pins
are part of the architecture contract, not a convenience.

| Dependency | Version | License | Linked into the app | Purpose |
| --- | --- | --- | --- | --- |
| [`argmaxinc/argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (`WhisperKit`, `ArgmaxOSS`) | `1.1.0` exact | MIT | **Yes**, by `KvoiceTranscription` | On-device Whisper inference through CoreML |
| [`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) | `3.0.1` exact | MIT | **Yes**, by `KvoiceHotkeys` | Global push-to-talk hotkey registration |
| [`FluidInference/FluidAudio`](https://github.com/FluidInference/FluidAudio) | `0.15.7` exact | Apache-2.0 | **Yes**, by `KvoiceParakeet` (ADR-019) | On-device Parakeet inference through CoreML |
| [`apple/swift-argument-parser`](https://github.com/apple/swift-argument-parser) | `1.8.2` | Apache-2.0 | Transitive, via `argmax-oss-swift` | Command-line parsing in upstream tooling |

No runtime makes a network request during dictation. The Whisper adapter
loads explicit model and tokenizer paths from a package the user has already
verified; the Parakeet adapter builds its Core ML models from the verified
package folder with FluidAudio's downloader switched off (`offlineMode`);
the hotkey adapter is local-only. The single outbound request KVoice can make
is the optional AI processing call to an endpoint the user configures, which
is off by default.

No dependency is embedded as a framework; all are statically linked, so the app
bundle contains no separate third-party binaries. FluidAudio's optional
`NemoTextProcessing` binary target (a prebuilt Rust text-normalisation
xcframework for its TTS features) is declared with `traits: []` in
`Package.swift` and is not linked.

---

## MIT license text

Applies to `argmax-oss-swift` and `KeyboardShortcuts`, reproduced as required by
the license. The full upstream text ships in each package's repository.

> Copyright (c) 2024 argmax, inc.
>
> Copyright (c) Sindre Sorhus \<sindresorhus@gmail.com\> (https://sindresorhus.com)
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
> the Software, and to permit persons to whom the Software is furnished to do so,
> subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
> FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
> IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
> CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Apache-2.0

`FluidAudio` (Copyright FluidInference) and `swift-argument-parser` are licensed
under the Apache License, Version 2.0, available at
<https://www.apache.org/licenses/LICENSE-2.0>. `swift-argument-parser` is a
transitive dependency of `argmax-oss-swift` and is not imported by any KVoice
target; `FluidAudio` is imported only by `KvoiceParakeet`.

## Speech models

Model weights are **not** part of this repository and are not covered by this
project's license. KVoice downloads each model the user chooses from the
bundled catalog and verifies it against a manifest shipped in the app bundle;
the weights carry their own upstream terms. See
[Docs/Model-Packages.md](Docs/Model-Packages.md).

| Model | Upstream | License | Attribution |
| --- | --- | --- | --- |
| Whisper large-v3-turbo (Standard, High-Accuracy) | OpenAI; CoreML conversion by Argmax (`argmaxinc/whisperkit-coreml`) | MIT | — |
| Parakeet TDT 0.6B v3 | NVIDIA (`nvidia/parakeet-tdt-0.6b-v3`); CoreML conversion by FluidInference (`FluidInference/parakeet-tdt-0.6b-v3-coreml`) | CC-BY-4.0 | "Parakeet TDT 0.6B v3 by NVIDIA, licensed under CC-BY-4.0; CoreML conversion by FluidInference." |
| Parakeet Unified EN 0.6B | NVIDIA (`nvidia/parakeet-tdt-0.6b-v2` lineage); CoreML conversion by FluidInference (`FluidInference/parakeet-unified-en-0.6b-coreml`) | CC-BY-4.0 | "Parakeet Unified EN 0.6B by NVIDIA, licensed under CC-BY-4.0; CoreML conversion by FluidInference." |
| Nemotron 3.5 ASR Streaming Multilingual 0.6B (`multilingual/2240ms` ship) | NVIDIA (`nvidia/nemotron-3.5-asr-streaming-0.6b`); CoreML conversion by FluidInference (`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`) | OpenMDW-1.1 | "Nemotron 3.5 ASR Streaming 0.6B by NVIDIA, licensed under OpenMDW-1.1; CoreML conversion by FluidInference." |
| SenseVoice Small (int8 + fp32 encoders) | FunAudioLLM / Alibaba (`FunAudioLLM/SenseVoiceSmall`, FunASR); CoreML conversion by FluidInference (`FluidInference/sensevoice-small-coreml`) | FunASR Model Open Source License 1.1 | "SenseVoice Small by FunAudioLLM / Alibaba (FunASR Model Open Source License 1.1); CoreML conversion by FluidInference." |
| Paraformer-large zh (int8 encoder + decoder) | Alibaba DAMO Academy / FunASR (ModelScope `iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch`); CoreML conversion by FluidInference (`FluidInference/paraformer-large-zh-coreml`) | Apache-2.0 | "Paraformer-large by Alibaba DAMO Academy / FunASR (Apache-2.0); CoreML conversion by FluidInference." |
| Parakeet Realtime EOU 120M (`320ms/` ship) | NVIDIA (`nvidia/parakeet_realtime_eou_120m-v1`); CoreML conversion by FluidInference (`FluidInference/parakeet-realtime-eou-120m-coreml`) | NVIDIA Open Model License | "Parakeet Realtime EOU 120M by NVIDIA (NVIDIA Open Model License); CoreML conversion by FluidInference." |

The Creative Commons Attribution 4.0 International license is available at
<https://creativecommons.org/licenses/by/4.0/>. It requires this attribution
to accompany the models; the Speech Models cards show it beside each Parakeet
entry and this notice is the app's Acknowledgments text.

The Open Model, Data & Weights License 1.1 (OpenMDW-1.1) is available at
<https://openmdw.ai/license/1-1/>. The source of the license and attribution
claims for the Nemotron weights is the Hugging Face model card of the pinned
revision (`README.md` @ `1a41b757…`, front matter `license_name:
openmdw-1.1` and its "License & attribution" section); the pinned FluidAudio
checkout carries no OpenMDW text, and the download itself ships no license
file. NVIDIA marks the Nemotron base model ready
for commercial use under it; FluidInference distributes the CoreML port under
the same license and asks that the attribution to NVIDIA and the OpenMDW-1.1
notice be retained — the Nemotron card shows it, and this notice is the
Acknowledgments text. The weights are quantized and pruned post-training only
(no retraining or fine-tuning), per the port's card.

The FunASR Model Open Source License Agreement 1.1 (Alibaba Group) is at
<https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE>. It grants
free use, copying, modification and sharing of the weights on the condition
that the source and author are attributed and the model name retained; it has
no SPDX identifier, so the catalog's `license` field carries the short name
`FunASR-Model-License-1.1`. The source of the claim is the FluidInference
card (`license: other`, `license_name: sensevoice-upstream`, pointing at the
SenseVoice project), which states the port is a format conversion of
`FunAudioLLM/SenseVoiceSmall` with no retraining and that the upstream model
license applies; the upstream card names that license (`model-license`,
linking the FunASR text above). The SenseVoice card shows the attribution,
and this notice is the Acknowledgments text.

The Paraformer-large weights are under **Apache-2.0**, the standard text at
<https://www.apache.org/licenses/LICENSE-2.0>. The chain of the claim: the
FluidInference card (`README.md` @ `5dd557bd…`, front matter `license: other`,
`license_name: paraformer-upstream`, `license_link` to the FunASR repository)
states the port is a format conversion of FunASR's Paraformer-large with no
retraining and that "the upstream license applies", naming the upstream
ModelScope model; that model's own card declares `license: Apache License
2.0` (read 2026-09-16) and does not link the FunASR Model Open Source
License Agreement, which the FunASR README says applies only "when a model
card links to" it — so the FunASR model license that covers SenseVoice does
not cover this checkpoint. Apache-2.0 asks that the license notice be
retained; this notice is the Acknowledgments text and the card carries the
attribution line.

The Parakeet Realtime EOU weights are under the **NVIDIA Open Model
License**, at
<https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/>.
It has no SPDX identifier, so the catalog's `license` field carries the
short name `NVIDIA-Open-Model-License`. The source of the claim is both
cards: the FluidInference card (`README.md` @ `40a23f4c…`, front matter
`license: other`, `license_name: nvidia-open-model-license`, `license_link`
to the NVIDIA text, `base_model: nvidia/parakeet_realtime_eou_120m-v1`) and
NVIDIA's own card for the base model, which names the same license and
marks the model "ready for commercial/non-commercial use". The license
grants use, modification and redistribution of the model and derivatives,
asks that the license notice be retained and that NVIDIA be attributed,
and disclaims warranty; the port's card states it is a format conversion
with no retraining. The EOU card shows the attribution line and this
notice is the Acknowledgments text.

## Maintaining this file

When a dependency is added, removed, or re-pinned, update the table in the same
commit. If a future dependency introduces a license that is not MIT or
Apache-2.0, resolve the compatibility question before merging it.
