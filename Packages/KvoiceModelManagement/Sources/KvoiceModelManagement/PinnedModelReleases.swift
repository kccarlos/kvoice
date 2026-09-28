import Foundation
import KvoiceDomain
import KvoiceTranscription

/// One model release kvoice may download: the identity a manifest must match
/// exactly before a byte moves (ADR-017 rule "any catalog change is an ADR
/// plus manifest-digest change", generalised by ADR-019 to more than one
/// runtime).
///
/// The manager's pre-download gate, the URL provider and the catalog loader
/// all consult `PinnedModelReleases`; a manifest matching no row is refused.
/// Adding a model is adding a row here, a manifest, and a catalog entry.
public struct PinnedModelRelease: Sendable, Equatable {
    public let modelID: String
    public let runtime: SpeechModelRuntime
    public let family: String
    /// The manifest `format`: `whisperkit-coreml` or `fluidaudio-coreml`.
    public let format: String
    public let repository: String
    public let revision: String
    /// Path under the repository where `model/<rest>` files are published;
    /// empty for a repository whose artifacts sit at the root.
    public let subdirectory: String
    public let runtimePackage: String
    public let runtimeVersion: String
    /// Where the installed tokenizer files live: `"tokenizer"` for Whisper
    /// (a separate tree from the upstream tokenizer repository) or `"model"`
    /// for a FluidAudio package, whose vocabulary sits beside the graphs.
    public let tokenizerRelativeRoot: String
    /// The upstream repository the `tokenizer/…` files are published in,
    /// when they do not come from `repository` (Whisper). `nil` means every
    /// manifest path is published under `repository`.
    public let tokenizerSource: TokenizerSource?

    public struct TokenizerSource: Sendable, Equatable {
        public let repository: String
        public let revision: String
        /// The installed path prefix that maps onto the repository root.
        public let installedPrefix: String

        public init(repository: String, revision: String, installedPrefix: String) {
            self.repository = repository
            self.revision = revision
            self.installedPrefix = installedPrefix
        }
    }

    public init(
        modelID: String,
        runtime: SpeechModelRuntime,
        family: String,
        format: String,
        repository: String,
        revision: String,
        subdirectory: String,
        runtimePackage: String,
        runtimeVersion: String,
        tokenizerRelativeRoot: String,
        tokenizerSource: TokenizerSource? = nil
    ) {
        self.modelID = modelID
        self.runtime = runtime
        self.family = family
        self.format = format
        self.repository = repository
        self.revision = revision
        self.subdirectory = subdirectory
        self.runtimePackage = runtimePackage
        self.runtimeVersion = runtimeVersion
        self.tokenizerRelativeRoot = tokenizerRelativeRoot
        self.tokenizerSource = tokenizerSource
    }

    /// Whether `manifest` names exactly this release, field for field. A
    /// partial match (same ID, different revision) is a different release
    /// and is refused.
    public func matches(_ manifest: ModelManifest) -> Bool {
        manifest.modelID == modelID
            && manifest.family == family
            && manifest.format == format
            && manifest.source.repository == repository
            && manifest.source.revision == revision
            && manifest.source.subdirectory == subdirectory
            && manifest.runtimeCompatibility.swiftPackage == runtimePackage
            && manifest.runtimeCompatibility.exactVersion == runtimeVersion
            && manifest.tokenizer.relativeRoot == tokenizerRelativeRoot
            && manifest.tokenizer.offlineRequired
    }
}

/// The constants of the FluidAudio-driven releases (ADR-019), in one place
/// for the same reason `KvoiceManagedModel` exists: a download URL, a
/// package path and a manifest cannot drift to a different revision.
public enum KvoiceFluidAudioModels {
    public static let format = "fluidaudio-coreml"
    public static let runtimePackage = "FluidInference/FluidAudio"
    /// Must equal the `exact:` pin in `Package.swift`; a test asserts it.
    public static let runtimeVersion = "0.15.7"

    public static let parakeetTDTv3ModelID = "parakeet-tdt-0.6b-v3-coreml"
    public static let parakeetTDTv3Family = "parakeet-tdt-0.6b-v3"
    public static let parakeetTDTv3Repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let parakeetTDTv3Revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"

    public static let parakeetUnifiedENModelID = "parakeet-unified-en-0.6b-coreml"
    public static let parakeetUnifiedENFamily = "parakeet-unified-en-0.6b"
    public static let parakeetUnifiedENRepository = "FluidInference/parakeet-unified-en-0.6b-coreml"
    public static let parakeetUnifiedENRevision = "4252711f6f060f9a2f91e5f081a806d7f45eebd8"

    /// ADR-019 amendment (2026-09-16). The repository publishes two decode
    /// stacks × four chunk tiers as `<latin|multilingual>/<tier>ms/`
    /// folders sharing a byte-identical encoder per tier; kvoice ships the
    /// full-vocabulary `multilingual/` stack at the recommended 2240 ms
    /// tier (the card: zh/ja throughput collapses below 2 s), so the
    /// subdirectory is part of the pinned identity.
    public static let nemotronMultilingualModelID = "nemotron-3.5-asr-streaming-multilingual-0.6b-coreml"
    public static let nemotronMultilingualFamily = "nemotron-3.5-asr-streaming-multilingual-0.6b"
    public static let nemotronMultilingualRepository = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    public static let nemotronMultilingualRevision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
    public static let nemotronMultilingualSubdirectory = "multilingual/2240ms"

    /// ADR-019 amendment (2026-09-16, second model). One repository at its
    /// root: the fp32 CPU preprocessor, three encoder exports of the same
    /// checkpoint (fp16 447 MB, int8 225 MB, fp32 897 MB) and `vocab.json`.
    /// kvoice pins **two encoders in one package**: the int8 graph for the
    /// Neural Engine (accuracy-neutral per the card and measured, half the
    /// footprint) and the fp32 graph for every other compute-unit choice,
    /// because the fp16 *and* int8 encoders are numerically correct only on
    /// the Neural Engine (NaN on the CPU/GPU fp16 path — the card, the
    /// library's doc and the 2026-09-16 measurement agree). The fp16 export
    /// is not downloaded. Which graph runs is `ParakeetModelVariant
    /// .senseVoiceEncoderGraph(for:)`, decided by the Runtime card's choice.
    public static let senseVoiceSmallModelID = "sensevoice-small-coreml"
    public static let senseVoiceSmallFamily = "sensevoice-small"
    public static let senseVoiceSmallRepository = "FluidInference/sensevoice-small-coreml"
    public static let senseVoiceSmallRevision = "cdea3526163035c19915d4a10268992d018ebd46"

    /// ADR-019 amendment (2026-09-16, third model). One repository at its
    /// root: the fp32 CPU preprocessor (the same graph and weights as
    /// SenseVoice's — one FunASR front end), the CIF-alphas graph, two exports each of
    /// the SANM encoder and the parallel decoder (fp16 302 + 109 MB, int8
    /// 152 + 55 MB) and `vocab.json`. kvoice pins the **int8 pair only**
    /// (220 MB in all): the card measures int8 accuracy-neutral (2.12 %
    /// CER on AISHELL-1 either way) and, unlike SenseVoice, the repository
    /// has no fp32 export to fall back on, so every compute-unit choice
    /// runs the same graphs and the pipeline's non-finite check is the
    /// guard. The fp16 pair is not downloaded. Reversible: pinning fp16
    /// instead is a manifest regeneration and a role change, nothing else.
    public static let paraformerLargeZhModelID = "paraformer-large-zh-coreml"
    public static let paraformerLargeZhFamily = "paraformer-large-zh"
    public static let paraformerLargeZhRepository = "FluidInference/paraformer-large-zh-coreml"
    public static let paraformerLargeZhRevision = "5dd557bd06342a3cd07ceccb909d8a45e48b053a"

    /// ADR-019 amendment (2026-09-16, fourth model). The repository publishes
    /// three chunk tiers as `160ms/`, `320ms/` and `1280ms/` folders (a
    /// separately exported cache-aware encoder each; the same LSTM decoder,
    /// joint and 1,026-entry `vocab.json` in every folder), plus the
    /// `.mlpackage` sources, a preprocessor graph `0.15.7` never loads (the
    /// mel front end is native Swift) and the conversion scripts. kvoice
    /// ships **`320ms/` only** — the card's 4.87 % WER / 12.5× tier, against
    /// 8.29 % / 4.8× at 160 ms; the 1280 ms tier is not on the card — so the
    /// subdirectory is part of the pinned identity, as for Nemotron. The
    /// fused `decoder_joint_decision_fused.mlmodelc` the library can opt
    /// into is not published in this repository at all.
    public static let parakeetEOUModelID = "parakeet-realtime-eou-120m-coreml"
    public static let parakeetEOUFamily = "parakeet-realtime-eou-120m"
    public static let parakeetEOURepository = "FluidInference/parakeet-realtime-eou-120m-coreml"
    public static let parakeetEOURevision = "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"
    public static let parakeetEOUSubdirectory = "320ms"
}

public enum PinnedModelReleases {
    private static let whisperTokenizer = PinnedModelRelease.TokenizerSource(
        repository: KvoiceManagedModel.tokenizerRepository,
        revision: KvoiceManagedModel.tokenizerRevision,
        installedPrefix: "tokenizer/models/openai/whisper-large-v3/"
    )

    private static func whisper(modelID: String, revision: String, subdirectory: String) -> PinnedModelRelease {
        PinnedModelRelease(
            modelID: modelID,
            runtime: .whisperKitCoreML,
            family: KvoiceManagedModel.family,
            format: KvoiceManagedModel.format,
            repository: KvoiceManagedModel.repository,
            revision: revision,
            subdirectory: subdirectory,
            runtimePackage: KvoiceManagedModel.runtimePackage,
            runtimeVersion: KvoiceManagedModel.runtimeVersion,
            tokenizerRelativeRoot: "tokenizer",
            tokenizerSource: whisperTokenizer
        )
    }

    private static func fluidAudio(
        modelID: String,
        runtime: SpeechModelRuntime,
        family: String,
        repository: String,
        revision: String,
        subdirectory: String = ""
    ) -> PinnedModelRelease {
        PinnedModelRelease(
            modelID: modelID,
            runtime: runtime,
            family: family,
            format: KvoiceFluidAudioModels.format,
            repository: repository,
            revision: revision,
            subdirectory: subdirectory,
            runtimePackage: KvoiceFluidAudioModels.runtimePackage,
            runtimeVersion: KvoiceFluidAudioModels.runtimeVersion,
            tokenizerRelativeRoot: "model"
        )
    }

    /// Every release this build can download and load. The Whisper rows
    /// mirror `WhisperModelPackageValidator.knownDefinitions` (a test keeps
    /// them in step); the FluidAudio rows are ADR-019 and its 2026-09-16
    /// amendment (Nemotron, SenseVoice, Paraformer, Parakeet EOU).
    public static let all: [PinnedModelRelease] = [
        whisper(
            modelID: KvoiceManagedModel.modelID,
            revision: KvoiceManagedModel.revision,
            subdirectory: KvoiceManagedModel.subdirectory
        ),
        whisper(
            modelID: "whisper-large-v3-turbo-coreml-626mb",
            revision: "7235bbd38ae9ab5476bee007313c0bb327387b84",
            subdirectory: "openai_whisper-large-v3-v20240930_626MB"
        ),
        whisper(
            modelID: "whisper-large-v3-turbo-coreml-632mb",
            revision: KvoiceManagedModel.revision,
            subdirectory: "openai_whisper-large-v3-v20240930_turbo_632MB"
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.parakeetTDTv3ModelID,
            runtime: .fluidAudioParakeetTDT,
            family: KvoiceFluidAudioModels.parakeetTDTv3Family,
            repository: KvoiceFluidAudioModels.parakeetTDTv3Repository,
            revision: KvoiceFluidAudioModels.parakeetTDTv3Revision
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.parakeetUnifiedENModelID,
            runtime: .fluidAudioParakeetUnified,
            family: KvoiceFluidAudioModels.parakeetUnifiedENFamily,
            repository: KvoiceFluidAudioModels.parakeetUnifiedENRepository,
            revision: KvoiceFluidAudioModels.parakeetUnifiedENRevision
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.nemotronMultilingualModelID,
            runtime: .fluidAudioNemotronStreaming,
            family: KvoiceFluidAudioModels.nemotronMultilingualFamily,
            repository: KvoiceFluidAudioModels.nemotronMultilingualRepository,
            revision: KvoiceFluidAudioModels.nemotronMultilingualRevision,
            subdirectory: KvoiceFluidAudioModels.nemotronMultilingualSubdirectory
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.senseVoiceSmallModelID,
            runtime: .fluidAudioSenseVoice,
            family: KvoiceFluidAudioModels.senseVoiceSmallFamily,
            repository: KvoiceFluidAudioModels.senseVoiceSmallRepository,
            revision: KvoiceFluidAudioModels.senseVoiceSmallRevision
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.paraformerLargeZhModelID,
            runtime: .fluidAudioParaformer,
            family: KvoiceFluidAudioModels.paraformerLargeZhFamily,
            repository: KvoiceFluidAudioModels.paraformerLargeZhRepository,
            revision: KvoiceFluidAudioModels.paraformerLargeZhRevision
        ),
        fluidAudio(
            modelID: KvoiceFluidAudioModels.parakeetEOUModelID,
            runtime: .fluidAudioParakeetEOU,
            family: KvoiceFluidAudioModels.parakeetEOUFamily,
            repository: KvoiceFluidAudioModels.parakeetEOURepository,
            revision: KvoiceFluidAudioModels.parakeetEOURevision,
            subdirectory: KvoiceFluidAudioModels.parakeetEOUSubdirectory
        )
    ]

    /// The release `manifest` names exactly, or nil. Whisper rows are also
    /// required to be releases the Whisper validator knows, so the catalog
    /// can never name a Whisper package the engine would refuse to load.
    public static func release(matching manifest: ModelManifest) -> PinnedModelRelease? {
        guard let release = all.first(where: { $0.matches(manifest) }) else { return nil }
        if release.runtime == .whisperKitCoreML {
            guard WhisperModelPackageValidator.isKnownRelease(
                modelID: manifest.modelID,
                revision: manifest.source.revision,
                subdirectory: manifest.source.subdirectory
            ) else { return nil }
        }
        return release
    }

    public static func release(modelID: String) -> PinnedModelRelease? {
        all.first { $0.modelID == modelID }
    }
}
