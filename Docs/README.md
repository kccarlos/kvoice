# kvoice documentation

## Using kvoice

| Document | Contents |
| --- | --- |
| [User-Guide.md](User-Guide.md) | Setup, dictating, speech models, the Dictionary, AI Actions, History, the two editions, and the FAQ |
| [../PRIVACY.md](../PRIVACY.md) | What kvoice stores, and exactly what it can send, and where |
| [../CHANGELOG.md](../CHANGELOG.md) | What changed in each release |

## Working on the code

Start with [../CONTRIBUTING.md](../CONTRIBUTING.md). AI coding assistants read
[../AGENTS.md](../AGENTS.md).

| Document | Read it when |
| --- | --- |
| [Build.md](Build.md) | Before your first command. Bare `swift build` does not work here. Also signing, permissions, and tuning without a rebuild |
| [Architecture.md](Architecture.md) | Before adding a feature: the module map, the rules and why they exist, the pipeline, insertion, AI transports, settings, diagnostics |
| [Model-Packages.md](Model-Packages.md) | Touching transcription, model download, the catalog or a manifest |
| [Localization.md](Localization.md) | Adding or changing any user-facing string, translating, adding a language |
| [../Tools/README.md](../Tools/README.md) | The model manifest generator and the benchmark harness |
| [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) | Dependency and model licenses |

## Reporting problems

- Bugs and feature requests: [GitHub issues](https://github.com/kccarlos/kvoice/issues).
- Security problems: privately, as described in [../SECURITY.md](../SECURITY.md).
