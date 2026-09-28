import Foundation
import KvoiceDomain

/// The FluidAudio model shapes this adapter knows (ADR-019). A variant is
/// resolved from the verified manifest's `family`, never from a folder name,
/// so a package cannot be driven by the wrong decoder.
///
/// Adding a model is a case here plus a row in `PinnedModelReleases`, a
/// manifest and a catalog entry; the engine itself does not change.
/// Nemotron, SenseVoice, Paraformer and Parakeet EOU (all 2026-09-16) were
/// the second pass.
public enum ParakeetModelVariant: String, Sendable, Equatable, CaseIterable {
    /// NVIDIA Parakeet TDT 0.6B v3: 25 European languages, batch only,
    /// punctuation and capitalisation (NVIDIA's card lists both, and the
    /// bundled sample came back capitalised with a full stop on 2026-09-14
    /// — the planning table's "no punctuation" was wrong). Driven by
    /// FluidAudio's `AsrManager`.
    case tdtV3 = "parakeet-tdt-0.6b-v3"
    /// NVIDIA Parakeet Unified EN 0.6B: English with punctuation and
    /// capitalisation, batch (`UnifiedAsrManager`) and streaming
    /// (`StreamingUnifiedAsrManager`) from one checkpoint.
    case unifiedEN = "parakeet-unified-en-0.6b"
    /// NVIDIA Nemotron 3.5 ASR Streaming 0.6B, the `multilingual/` decode
    /// stack at the 2240 ms tier: a cache-aware streaming RNNT whose encoder
    /// takes a `prompt_id` language hint (`metadata.json`'s
    /// `prompt_dictionary`, ~80 languages including Chinese, Japanese and
    /// Korean) and emits a leading `<xx-XX>` tag the library strips and
    /// reports as the detected language. One `StreamingNemotronMultilingualAsrManager`
    /// serves both the batch pass (the recording is fed through the same
    /// chunked pipeline, then `finish()`) and the live streaming session, so
    /// the graphs are loaded once. Punctuation and capitalisation per the
    /// card; FluidAudio notes punctuation thins at the 560 ms tier only.
    case nemotronMultilingual = "nemotron-3.5-asr-streaming-multilingual-0.6b"
    /// FunAudioLLM SenseVoice Small (234M): a non-autoregressive SANM
    /// encoder with one CTC head — the whole utterance in one forward pass,
    /// so batch only. Five language embeddings (zh / en / yue / ja / ko, or
    /// auto); the model emits a leading `<|lang|><|emotion|><|event|><|itn|>`
    /// tag run that `SenseVoiceTranscriptParser` strips, reporting only the
    /// language. Two encoder exports are pinned in one package and the
    /// compute-unit choice picks the graph (`senseVoiceEncoderGraph`): the
    /// int8 export on the Neural Engine, the fp32 export everywhere else,
    /// because the fp16/int8 graphs produce NaN on the CPU/GPU fp16 path.
    /// The pipeline (preprocessor, encoder, greedy CTC, detokenise) is
    /// driven by `FluidAudioParakeetRuntime` over the library's graphs, not
    /// its `SenseVoiceManager`, which discards the language tag.
    case senseVoiceSmall = "sensevoice-small"
    /// FunASR Paraformer-large (Mandarin, 220M): a non-autoregressive SANM
    /// encoder, a CIF predictor that fires one acoustic embedding per
    /// character (the alphas come from a small Core ML graph, the
    /// integrate-and-fire runs on the host — `ParaformerCIF`) and a
    /// parallel decoder whose logits are read once per token. Batch only.
    /// Mandarin only, so it takes no language hint and always reports
    /// `zh`; no punctuation (the plain checkpoint — the vocabulary's one
    /// punctuation token is `.`). One export per graph in the package (the
    /// int8 pair; the card measures it accuracy-neutral and the three
    /// `say` samples decoded character-identical under fp16 and int8), and
    /// the encoder is NaN off the Neural Engine with no fp32 export to fall
    /// back on, so GPU + CPU and CPU only are refused
    /// (`supportsComputeUnits`) and the pipeline refuses a non-finite
    /// encoder output at run time.
    /// Driven by `FluidAudioParakeetRuntime` over the library's public
    /// `ParaformerModels` graphs (`ParaformerPipeline`), not its
    /// `ParaformerManager`, which keeps a literal `<unk>` in the text,
    /// truncates silently past 30 s and hides the logits.
    case paraformerLargeZh = "paraformer-large-zh"
    /// NVIDIA Parakeet Realtime EOU 120M, the `320ms/` export: a cache-aware
    /// streaming FastConformer-RNNT whose joint emits an `<EOU>` token when
    /// an utterance ends. One `StreamingEouAsrManager` serves both modes —
    /// batch is the streaming pipeline run to completion (the Nemotron
    /// shape), the live session the same manager driven a chunk (630 ms
    /// of audio, advancing 320 ms) at a time. English only, no hint, **no
    /// punctuation and no capitalisation** (NVIDIA's card; the vocabulary
    /// has no punctuation piece). The end-of-utterance signal is surfaced
    /// on the streaming session (`endOfUtteranceDetected`) and acted on by
    /// nothing: FR-AUD-007 forbids ending a recording on silence, and the
    /// opt-in is the planned ADR-023.
    case parakeetEOU = "parakeet-realtime-eou-120m"

    /// The manifest format every FluidAudio package declares.
    public static let manifestFormat = "fluidaudio-coreml"

    public init?(manifest: ModelManifest) {
        guard manifest.format == Self.manifestFormat,
              let variant = ParakeetModelVariant(rawValue: manifest.family) else { return nil }
        self = variant
    }

    /// The `model/` entries that must exist for the runtime to construct the
    /// pipeline. Checked against the manifest *and* the disk before any
    /// Core ML call, so a missing bundle is a validation error, never a
    /// reason for the library to look elsewhere.
    public var requiredArtifactRoots: [String] {
        switch self {
        case .tdtV3:
            return [
                "model/Preprocessor.mlmodelc",
                "model/Encoder.mlmodelc",
                "model/Decoder.mlmodelc",
                "model/JointDecisionv3.mlmodelc",
                "model/parakeet_vocab.json"
            ]
        case .unifiedEN:
            return [
                "model/parakeet_unified_encoder_int8.mlmodelc",
                "model/parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc",
                "model/parakeet_unified_decoder.mlmodelc",
                "model/parakeet_unified_joint_decision_single_step.mlmodelc",
                "model/vocab.json"
            ]
        case .nemotronMultilingual:
            // `preprocessor.mlmodelc` is published but never loaded by
            // 0.15.7 (native Swift mel front end), so it is not part of the
            // package. `decoder_joint` is the fused inner loop the library
            // prefers; `decoder` and `joint` are its unfused fallback.
            return [
                "model/encoder.mlmodelc",
                "model/decoder.mlmodelc",
                "model/joint.mlmodelc",
                "model/decoder_joint.mlmodelc",
                "model/metadata.json",
                "model/tokenizer.json"
            ]
        case .senseVoiceSmall:
            // Both encoders are required: the choice between them is made
            // per compute-unit setting at load time, and a package missing
            // either would have a choice the Runtime card offers fail at
            // load rather than at verification. The fp16 export is not part
            // of the package (same Neural-Engine-only limit as int8, twice
            // the size, no measurable accuracy gain on the card's sets).
            return [
                "model/" + SenseVoiceEncoderGraph.preprocessorBundle,
                "model/" + SenseVoiceEncoderGraph.int8NeuralEngine.bundle,
                "model/" + SenseVoiceEncoderGraph.fp32.bundle,
                "model/vocab.json"
            ]
        case .paraformerLargeZh:
            // The int8 encoder and decoder only; the fp16 pair is not part
            // of the package (`ParaformerGraph.shippedPrecision`).
            return [
                "model/" + ParaformerGraph.preprocessorBundle,
                "model/" + ParaformerGraph.shippedPrecision.encoderBundle,
                "model/" + ParaformerGraph.cifAlphasBundle,
                "model/" + ParaformerGraph.shippedPrecision.decoderBundle,
                "model/" + ParaformerGraph.vocabularyFile
            ]
        case .parakeetEOU:
            // `parakeet_eou_preprocessor.mlmodelc` is published but never
            // loaded by 0.15.7 (native Swift mel front end); the fused
            // decoder+joint the library can opt into is not published.
            return [
                "model/" + ParakeetEOUGraph.encoderBundle,
                "model/" + ParakeetEOUGraph.decoderBundle,
                "model/" + ParakeetEOUGraph.jointBundle,
                "model/" + ParakeetEOUGraph.vocabularyFile
            ]
        }
    }

    /// Whether the variant's graphs can be loaded under `units`. The Unified
    /// int8 encoder cannot take the GPU: Core ML hands its quantised ops to
    /// MPSGraph, whose MLIR pass fails and **aborts the process** (observed
    /// on 2026-09-14 under GPU + CPU, signal 6; FluidAudio itself coerces
    /// `.all` to CPU + Neural Engine for the same reason but leaves
    /// `.cpuAndGPU` alone). Refusing here, before any Core ML call, is the
    /// only safe answer; the Runtime card shows the message.
    ///
    /// Nemotron's mixed-precision encoder (int8 cuff + 6-bit palettised
    /// middle) was checked under every choice on 2026-09-16, each in its own
    /// process: none aborts (numbers in the Changelog), so every choice is
    /// allowed; the card's own caveat is only that `.all` and GPU + CPU are
    /// far slower than the Neural Engine.
    ///
    /// SenseVoice takes every choice too, but not with one graph: its
    /// fp16/int8 encoders are NaN off the Neural Engine, so every non-ANE
    /// choice loads the fp32 export instead (`senseVoiceEncoderGraph`);
    /// each (graph, choice) pair was run in its own process on 2026-09-16.
    /// The adapter also refuses a NaN logit tensor at run time, so a
    /// misplaced graph is an error, never garbage text.
    ///
    /// Paraformer's SANM encoder is **NaN off the Neural Engine** — both
    /// the int8 and the fp16 export, under GPU + CPU and under CPU only,
    /// each measured in its own process on 2026-09-16 — and, unlike
    /// SenseVoice, the repository has no fp32 export to fall back on. The
    /// CIF-alphas graph then turns the NaN into `sigmoid(NaN) = 0`, so
    /// nothing fires and the result is an *empty transcript*, not an error
    /// (the CIF and decoder graphs themselves are correct on the CPU and
    /// GPU). Those two choices are refused here; Neural Engine + CPU and
    /// All (Core ML places the encoder on the ANE under `.all`) decoded
    /// correctly. The pipeline also refuses a non-finite encoder output at
    /// run time, so a misplaced graph on another machine is an error.
    /// Reversible: the alternative is the library's own answer — pin the
    /// encoder to the ANE whatever the choice — at the price of a Runtime
    /// card that plans a graph the choice does not run.
    ///
    /// Parakeet EOU's fp16 encoder, LSTM decoder and joint were checked
    /// under every choice on 2026-09-16, one process each: no abort, no
    /// non-finite output, the same text under all four (numbers in the
    /// Changelog), so every choice is allowed.
    public func supportsComputeUnits(_ units: SpeechComputeUnits) -> Bool {
        switch (self, units) {
        case (.unifiedEN, .gpuAndCPU): return false
        case (.paraformerLargeZh, .gpuAndCPU), (.paraformerLargeZh, .cpuOnly): return false
        default: return true
        }
    }

    /// Why `supportsComputeUnits` refuses a choice, for the error message.
    var computeUnitsRefusalReason: String {
        switch self {
        case .unifiedEN:
            return "its quantized encoder is not supported on that device by Core ML"
        case .paraformerLargeZh:
            return "its encoder returns NaN off the Neural Engine (there is no fp32 export), which decodes as an empty transcript"
        case .tdtV3, .nemotronMultilingual, .senseVoiceSmall, .parakeetEOU:
            return "its graphs cannot run there"
        }
    }

    public var supportsStreaming: Bool {
        switch self {
        case .tdtV3, .senseVoiceSmall, .paraformerLargeZh: return false
        case .unifiedEN, .nemotronMultilingual, .parakeetEOU: return true
        }
    }

    /// Whether the model itself writes punctuation and capitalisation. The
    /// first four do — SenseVoice only under its `withitn` text-norm query,
    /// which the adapter always sends (`SenseVoiceEncoderGraph
    /// .textNormWithITN`; `woitn`, the library's default, drops punctuation
    /// and writes numbers as words). Paraformer-large does not: the plain
    /// checkpoint's vocabulary has no Chinese punctuation at all (measured
    /// 2026-09-16 — a `say` sentence with a comma and a full stop came back
    /// without either); FunASR adds punctuation with a separate model kvoice
    /// does not ship. Parakeet EOU does not either: NVIDIA's card says so
    /// and its vocabulary holds no punctuation piece and no capital letter.
    public var emitsPunctuation: Bool {
        switch self {
        case .tdtV3, .unifiedEN, .nemotronMultilingual, .senseVoiceSmall: return true
        case .paraformerLargeZh, .parakeetEOU: return false
        }
    }

    /// The Whisper-style language codes the model covers. A hint outside
    /// this list is dropped (the model then detects the language itself);
    /// the Models section warns and suggests Whisper (ADR-019 fallback rule).
    public var languageCodes: [String] {
        switch self {
        case .tdtV3: return TranscriptionLanguage.parakeetTDTv3LanguageCodes
        case .unifiedEN: return ["en"]
        case .nemotronMultilingual: return TranscriptionLanguage.nemotronMultilingualLanguageCodes
        case .senseVoiceSmall: return TranscriptionLanguage.senseVoiceSmallLanguageCodes
        case .paraformerLargeZh: return TranscriptionLanguage.paraformerLargeZhLanguageCodes
        case .parakeetEOU: return TranscriptionLanguage.parakeetEOULanguageCodes
        }
    }

    /// The hint to hand the runtime for `code`, or nil when the model takes
    /// none for it. Unified is English-only and takes no hint at all;
    /// Nemotron takes a `prompt_dictionary` key, not the bare Whisper code;
    /// SenseVoice takes the bare code and the adapter turns it into the
    /// language embedding index (`senseVoiceLanguageEmbedding`); Paraformer
    /// is Mandarin-only like Unified and EOU are English-only, and takes none.
    public func runtimeLanguageHint(for code: String?) -> String? {
        switch self {
        case .tdtV3, .senseVoiceSmall:
            guard let code, languageCodes.contains(code) else { return nil }
            return code
        case .unifiedEN, .paraformerLargeZh, .parakeetEOU:
            return nil
        case .nemotronMultilingual:
            return code.flatMap(Self.nemotronPromptKey(forLanguageCode:))
        }
    }

    /// The language the transcript is reported in when the runtime gives
    /// none: the hint it accepted, or the single language of a monolingual
    /// model. TDT without a hint detects the language internally and does
    /// not report it, so `nil`. Nemotron and SenseVoice normally report the
    /// language themselves (their leading tag); this is the fallback when
    /// no tag was emitted.
    public func reportedLanguage(forHint code: String?) -> String? {
        switch self {
        case .tdtV3: return runtimeLanguageHint(for: code)
        case .unifiedEN, .parakeetEOU: return "en"
        case .paraformerLargeZh: return "zh"
        case .nemotronMultilingual, .senseVoiceSmall:
            guard let code, languageCodes.contains(code) else { return nil }
            return code
        }
    }

    // MARK: - SenseVoice

    /// The encoder export the runtime loads for `units`: the int8 graph only
    /// on the Neural Engine, the fp32 graph for every other choice. Pure, so
    /// the rule the Runtime card relies on ("a CPU-only choice must pick
    /// the fp32 graph") is unit-tested without Core ML.
    public static func senseVoiceEncoderGraph(for units: SpeechComputeUnits) -> SenseVoiceEncoderGraph {
        switch units {
        case .neuralEngineAndCPU: return .int8NeuralEngine
        case .gpuAndCPU, .all, .cpuOnly: return .fp32
        }
    }

    /// The `language` query-embedding index for a Whisper code, or nil
    /// (auto-detect, index 0) outside the model's five. The indices are
    /// FunASR's `lid_dict` (`auto` 0, `zh` 3, `en` 4, `yue` 7, `ja` 11, `ko`
    /// 12; `nospeech` 13 is never sent), which the card restates as its
    /// `lid_int_dict` — an embedding row, not the tag's vocabulary id.
    public static func senseVoiceLanguageEmbedding(forLanguageCode code: String?) -> Int32? {
        guard let code else { return nil }
        return senseVoiceLanguageEmbeddings[code]
    }

    private static let senseVoiceLanguageEmbeddings: [String: Int32] = [
        "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12
    ]

    // MARK: - Nemotron prompt keys

    /// The `prompt_dictionary` key for a Whisper code, or nil outside the
    /// model's coverage. Most languages have a bare key (`"de"`); the rest
    /// only a regioned one, chosen here once so the settings value stays a
    /// Whisper code: Chinese maps to Simplified (`zh-CN`; the dictionary
    /// also has `zh-TW`), Japanese to `ja-JP`. Korean is mapped to `ko-KR`
    /// although a bare `ko` key exists, so the regioned key the tokenizer's
    /// `<ko-KR>` tag corresponds to is the one sent. A live test checks
    /// every key against the real `metadata.json`.
    public static func nemotronPromptKey(forLanguageCode code: String) -> String? {
        guard TranscriptionLanguage.nemotronMultilingualLanguageCodes.contains(code) else { return nil }
        return nemotronRegionedPromptKeys[code] ?? code
    }

    /// The Whisper code for a language tag Nemotron reports (`"es-419"`,
    /// `"zh-CN"`, `"en"`), or nil for a tag outside the coverage list. The
    /// tokenizer has 39 tags; a language with a prompt but no tag (Amharic,
    /// Swahili, …) reports nothing and the engine falls back to the hint.
    /// Bokmål's tag (`nb-NO`) is Whisper's Norwegian.
    public static func nemotronLanguageCode(forReportedTag tag: String) -> String? {
        let bare = tag.split(separator: "-", maxSplits: 1).first.map { String($0).lowercased() } ?? tag
        if bare == "nb" { return "no" }
        return TranscriptionLanguage.nemotronMultilingualLanguageCodes.contains(bare) ? bare : nil
    }

    private static let nemotronRegionedPromptKeys: [String: String] = [
        "af": "af-ZA", "am": "am-ET", "az": "az-AZ", "bn": "bn-IN", "fa": "fa-IR",
        "gu": "gu-IN", "ha": "ha-NG", "haw": "haw-US", "he": "he-IL", "hy": "hy-AM",
        "id": "id-ID", "ja": "ja-JP", "ka": "ka-GE", "km": "km-KH", "kn": "kn-IN",
        "ko": "ko-KR", "ln": "ln-CD", "mi": "mi-NZ", "ml": "ml-IN", "mr": "mr-IN",
        "ms": "ms-MY", "mt": "mt-MT", "ne": "ne-NP", "si": "si-LK", "so": "so-SO",
        "sw": "sw-KE", "ta": "ta-IN", "te": "te-IN", "tg": "tg-TJ", "th": "th-TH",
        "ur": "ur-PK", "uz": "uz-UZ", "vi": "vi-VN", "yo": "yo-NG", "zh": "zh-CN"
    ]
}
