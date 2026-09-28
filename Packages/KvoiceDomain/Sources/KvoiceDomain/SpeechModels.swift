import Foundation

// MARK: - Speech model catalog (ADR-017)

/// The runtime a catalog entry is executed by. `whisperKitCoreML`, the
/// FluidAudio cases (ADR-019) and `appleSpeech` (ADR-025) have adapters in
/// this revision; `mlxQwen3ASR` is reserved so a catalog written for a later
/// release still decodes here and is shown as unavailable.
public enum SpeechModelRuntime: String, Codable, Sendable, Equatable, CaseIterable {
    case whisperKitCoreML = "whisperkit-coreml"
    /// ADR-019: NVIDIA Parakeet TDT (0.6B v3) through FluidAudio's `AsrManager`.
    /// Batch only; the language hint is honoured for the codes the model
    /// knows and dropped otherwise.
    case fluidAudioParakeetTDT = "fluidaudio-parakeet-tdt"
    /// ADR-019: NVIDIA Parakeet Unified EN (0.6B) through FluidAudio's
    /// `UnifiedAsrManager` (batch) and `StreamingUnifiedAsrManager`
    /// (streaming) — one checkpoint, two encoder exports.
    case fluidAudioParakeetUnified = "fluidaudio-parakeet-unified"
    /// ADR-019 amendment (2026-09-16): NVIDIA Nemotron 3.5 ASR Streaming
    /// Multilingual (0.6B) through FluidAudio's
    /// `StreamingNemotronMultilingualAsrManager` — a cache-aware streaming
    /// RNNT that also serves the batch pass (the whole recording is fed
    /// through the same chunked pipeline). Language hint via `prompt_id`.
    case fluidAudioNemotronStreaming = "fluidaudio-nemotron-streaming"
    /// ADR-019 amendment (2026-09-16, second model): FunAudioLLM's
    /// SenseVoice Small (234M) through FluidAudio's `SenseVoiceModels`
    /// graphs — a non-autoregressive SANM encoder with one CTC head, so the
    /// whole utterance decodes in one forward pass. Batch only. The language
    /// hint is an embedding index (zh / en / yue / ja / ko, 0 = auto); the
    /// model emits leading `<|lang|><|emotion|><|event|><|itn|>` tags the
    /// adapter strips, reporting the language and never the rest.
    case fluidAudioSenseVoice = "fluidaudio-sensevoice"
    /// ADR-019 amendment (2026-09-16, third model): FunASR's Paraformer-large
    /// (Mandarin, 220M) over FluidAudio's `ParaformerModels` graphs — a
    /// non-autoregressive SANM encoder, a CIF predictor that fires one
    /// acoustic embedding per character (the integrate-and-fire runs on the
    /// host) and a parallel decoder. Batch only, Mandarin only, no
    /// language hint (monolingual) and no punctuation (the plain checkpoint;
    /// FunASR adds punctuation with a separate model kvoice does not ship).
    case fluidAudioParaformer = "fluidaudio-paraformer"
    /// ADR-019 amendment (2026-09-16, fourth model): NVIDIA Parakeet
    /// Realtime EOU 120M through FluidAudio's `StreamingEouAsrManager` — a
    /// cache-aware streaming FastConformer-RNNT (the `320ms/` export) whose
    /// joint emits an `<EOU>` token at the end of an utterance. Streaming
    /// and batch from one resident pipeline (batch is the streaming run to
    /// completion, like Nemotron). English only, no language hint, **no
    /// punctuation and no capitalisation** (NVIDIA's card). The EOU signal
    /// is surfaced as a scalar on the streaming events and acted on by
    /// nothing: FR-AUD-007 forbids ending a recording on silence, and the
    /// opt-in is the planned ADR-023.
    case fluidAudioParakeetEOU = "fluidaudio-parakeet-eou"
    /// Reserved: Qwen3-ASR through MLX (`soniqo/speech-swift`). No adapter yet.
    case mlxQwen3ASR = "mlx-qwen3-asr"
    /// ADR-025 (2026-09-16): Apple's `SpeechAnalyzer` + `SpeechTranscriber`
    /// (macOS 26) through `KvoiceAppleSpeech`. The model assets are the
    /// OS's (`AssetInventory`, no kvoice manifest — the catalog entry is
    /// `assetSource: .systemManaged`); batch and streaming (volatile →
    /// partial, finalized → final); punctuation from the model; the
    /// Dictionary as `AnalysisContext.contextualStrings`; languages observed
    /// from `SpeechTranscriber.supportedLocales` at runtime. On macOS 15 the
    /// entry is shown with "Requires macOS 26 or later." and cannot install.
    case appleSpeech = "apple-speech"

    /// Whether this build ships an engine for the runtime. The *OS* may
    /// still lack it (Apple Speech on macOS 15); that is a lifecycle fact
    /// (`ModelLifecycleState.unavailable`), not a build fact.
    public var isAvailableInThisBuild: Bool {
        switch self {
        case .whisperKitCoreML, .fluidAudioParakeetTDT, .fluidAudioParakeetUnified, .fluidAudioNemotronStreaming,
             .fluidAudioSenseVoice, .fluidAudioParaformer, .fluidAudioParakeetEOU, .appleSpeech:
            return true
        case .mlxQwen3ASR: return false
        }
    }

    public var displayName: String {
        switch self {
        case .whisperKitCoreML: return "WhisperKit (CoreML)"
        case .fluidAudioParakeetTDT, .fluidAudioParakeetUnified, .fluidAudioNemotronStreaming, .fluidAudioSenseVoice,
             .fluidAudioParaformer, .fluidAudioParakeetEOU:
            return "FluidAudio (CoreML)"
        case .mlxQwen3ASR: return "MLX"
        case .appleSpeech: return "Apple Speech"
        }
    }

    /// Whether the runtime reads `TranscriptionRequest.initialPrompt`
    /// (ADR-018). Only Whisper conditions on text; the Dictionary section
    /// consults the engine at run time, this is the catalog-level answer.
    /// Apple Speech takes the same list as contextual phrases, not as a
    /// prompt (`PromptTokenLimit.phrases`), so it is `false` here.
    public var acceptsInitialPrompt: Bool {
        self == .whisperKitCoreML
    }

    /// ADR-025: whether the runtime exposes a compute-unit choice. Core ML
    /// runtimes do (the Runtime card's picker reloads the graphs); Apple
    /// Speech places its own models and offers no such control, so the
    /// picker is refused with a reason for it (`SettingsAvailability`).
    public var hasComputeUnitChoice: Bool {
        self != .appleSpeech
    }
}

/// ADR-025: where a catalog entry's weights come from and who verifies
/// them. Optional in the JSON (`decodeIfPresent`); absent means
/// `.kvoiceManifest`, the shape every entry had before this revision.
public enum SpeechModelAssetSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// The package is downloaded by kvoice from the pinned release and
    /// verified against the bundled manifest and its digest
    /// (Docs/Model-Packages.md). `manifestResource` / `manifestSHA256` are
    /// required.
    case kvoiceManifest = "kvoice-manifest"
    /// The OS owns the assets: they are fetched, verified and stored by the
    /// platform (Apple Speech through `AssetInventory`), never by kvoice,
    /// so the entry carries no manifest, no digest and no download size.
    /// The trust path is Apple's — the accepted deviation from the per-file
    /// digest rule is recorded in ADR-025.
    case systemManaged = "system-managed"
}

public enum SpeechModelHosting: String, Codable, Sendable, Equatable, CaseIterable {
    case onDevice = "on-device"
    case cloud

    public var displayName: String {
        switch self {
        case .onDevice: return "On-Device"
        case .cloud: return "Cloud"
        }
    }
}

/// How a model is driven during a dictation. Batch transcribes after the
/// recording stops; streaming additionally shows live partial text while the
/// user speaks (FR-STT-001 as amended by ADR-017).
public enum SpeechTranscriptionMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case batch
    case streaming

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .batch: return "Batch"
        case .streaming: return "Streaming"
        }
    }
}

/// One model the app can download and run, as shipped in the bundled catalog.
///
/// The catalog is the trust root: `manifestResource` names the bundled
/// `ModelManifest` for the entry and `manifestSHA256` is the digest of that
/// manifest's canonical bytes, in the same shape as the app-bundled manifest
/// the first release used.
public struct SpeechModelCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: ModelID
    /// The family name shown on the card, e.g. "Whisper v3 Turbo".
    public let displayName: String
    /// The variant shown beside the name, e.g. "Standard" or "High-Accuracy".
    public let variantName: String
    public let family: String
    public let runtime: SpeechModelRuntime
    public let hosting: SpeechModelHosting
    public let supportsStreaming: Bool
    public let supportsBatch: Bool
    /// Sum of the manifest's file sizes; shown on the card before download.
    public let downloadBytes: Int64
    /// Whisper language codes the model accepts, or `nil` for the full Whisper
    /// list (`TranscriptionLanguage.whisperLanguages`).
    public let languageCodes: [String]?
    /// Card copy for the language coverage, e.g. "99 languages, auto-detect".
    public let languageSummary: String
    /// One or two sentences for the card.
    public let summary: String
    public let isRecommended: Bool
    public let revision: String
    public let manifestResource: String
    public let manifestSHA256: String
    /// The model's own initial-prompt capacity in tokens, or `nil` when the
    /// model takes no prompt (ADR-018). Whisper: 224, half of the decoder's
    /// 448-token text context (`n_text_ctx / 2`, the rule OpenAI's reference
    /// decoder applies to `initial_prompt`). The runtime may enforce less —
    /// `TranscriptionEngine.promptTokenLimit` reports the effective cap for
    /// the resident model; this value stands in while nothing is loaded.
    /// Optional in the JSON, so adding it changed neither the catalog schema
    /// nor any manifest digest.
    public let promptTokenLimit: Int?
    /// ADR-019: whether the model emits punctuation and capitalisation
    /// itself. `nil` when the catalog does not say (older entries); the card
    /// then shows nothing rather than guessing. Every shipped entry but one
    /// says `true` (Whisper, both Parakeets, Nemotron, SenseVoice);
    /// Paraformer-large is the first `false` (the plain checkpoint writes
    /// none — measured 2026-09-16). `decodeIfPresent`, no schema bump.
    public let punctuation: Bool?
    /// ADR-019: SPDX identifier of the *weights'* license (e.g. `MIT`,
    /// `CC-BY-4.0`), or the license's own short name when it has no SPDX
    /// identifier (SenseVoice's `FunASR-Model-License-1.1`), shown on the
    /// card. `decodeIfPresent`.
    public let license: String?
    /// ADR-019: the attribution sentence the license requires, when it
    /// requires one (CC-BY). Rendered on the card and in the Acknowledgments
    /// sheet. `decodeIfPresent`.
    public let attribution: String?
    /// ADR-025: who owns the weights. `nil` reads as `.kvoiceManifest`
    /// (`decodeIfPresent`, no schema bump). A `.systemManaged` entry has an
    /// empty `manifestResource` and `manifestSHA256`, `downloadBytes` 0, and
    /// the card says "System-managed" where the others show a size.
    public let assetSource: SpeechModelAssetSource?

    public init(
        id: ModelID,
        displayName: String,
        variantName: String,
        family: String,
        runtime: SpeechModelRuntime,
        hosting: SpeechModelHosting,
        supportsStreaming: Bool,
        supportsBatch: Bool,
        downloadBytes: Int64,
        languageCodes: [String]? = nil,
        languageSummary: String,
        summary: String,
        isRecommended: Bool,
        revision: String,
        manifestResource: String,
        manifestSHA256: String,
        promptTokenLimit: Int? = nil,
        punctuation: Bool? = nil,
        license: String? = nil,
        attribution: String? = nil,
        assetSource: SpeechModelAssetSource? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.variantName = variantName
        self.family = family
        self.runtime = runtime
        self.hosting = hosting
        self.supportsStreaming = supportsStreaming
        self.supportsBatch = supportsBatch
        self.downloadBytes = downloadBytes
        self.languageCodes = languageCodes
        self.languageSummary = languageSummary
        self.summary = summary
        self.isRecommended = isRecommended
        self.revision = revision
        self.manifestResource = manifestResource
        self.manifestSHA256 = manifestSHA256
        self.promptTokenLimit = promptTokenLimit
        self.punctuation = punctuation
        self.license = license
        self.attribution = attribution
        self.assetSource = assetSource
    }

    /// ADR-025: the OS fetches and verifies this entry's assets.
    public var isSystemManaged: Bool {
        assetSource == .systemManaged
    }

    /// ADR-025: the same entry with the language coverage the runtime
    /// *observed* (Apple Speech: `SpeechTranscriber.supportedLocales` on this
    /// Mac) in place of the catalog's shipped list. Everything else — the
    /// identity, the manifest fields, the badges — is unchanged, so the
    /// overlay is safe to apply on every refresh.
    public func observingLanguages(codes: [String], summary: String) -> SpeechModelCatalogEntry {
        SpeechModelCatalogEntry(
            id: id,
            displayName: displayName,
            variantName: variantName,
            family: family,
            runtime: runtime,
            hosting: hosting,
            supportsStreaming: supportsStreaming,
            supportsBatch: supportsBatch,
            downloadBytes: downloadBytes,
            languageCodes: codes,
            languageSummary: summary,
            summary: self.summary,
            isRecommended: isRecommended,
            revision: revision,
            manifestResource: manifestResource,
            manifestSHA256: manifestSHA256,
            promptTokenLimit: promptTokenLimit,
            punctuation: punctuation,
            license: license,
            attribution: attribution,
            assetSource: assetSource
        )
    }

    /// "Whisper v3 Turbo — Standard".
    public var fullDisplayName: String {
        variantName.isEmpty ? displayName : "\(displayName) — \(variantName)"
    }

    /// The modes a user may pick for this entry, batch first.
    public var availableModes: [SpeechTranscriptionMode] {
        var modes: [SpeechTranscriptionMode] = []
        if supportsBatch { modes.append(.batch) }
        if supportsStreaming { modes.append(.streaming) }
        return modes
    }

    /// Whether the language code is accepted as a hint by this model.
    public func supportsLanguage(_ code: String) -> Bool {
        guard let languageCodes else {
            return TranscriptionLanguage.whisperLanguages.contains { $0.code == code }
        }
        return languageCodes.contains(code)
    }

    /// "Punctuation" / "No punctuation" for the card, nil when the catalog
    /// does not say.
    public var punctuationSummary: String? {
        punctuation.map { $0 ? "Punctuation and capitalization" : "No punctuation" }
    }

    /// ADR-019 fallback rule: the sentence the Models section shows when the
    /// chosen transcription language is outside this model's coverage, or
    /// nil when the language is auto-detect or covered. Names the Whisper
    /// family because it is the catalog's full-coverage runtime.
    public func languageCoverageWarning(forLanguageCode code: String?) -> String? {
        guard let code, !supportsLanguage(code) else { return nil }
        let language = TranscriptionLanguage.displayName(forCode: code)
        return "\(fullDisplayName) does not support \(language) (\(languageSummary)). Choose Auto-detect or a covered language, or use a Whisper model for \(language)."
    }
}

public struct SpeechModelCatalog: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entries: [SpeechModelCatalogEntry]

    public init(schemaVersion: Int = SpeechModelCatalog.currentSchemaVersion, entries: [SpeechModelCatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// The entry used when `AppSettings.defaultSpeechModelID` is unset: the
    /// first recommended one, else the first entry.
    public var recommended: SpeechModelCatalogEntry? {
        entries.first(where: \.isRecommended) ?? entries.first
    }

    public func entry(id: ModelID) -> SpeechModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Resolves a stored default to a catalog entry, falling back to the
    /// recommended entry when the stored ID is unknown.
    public func defaultEntry(preferring id: ModelID?) -> SpeechModelCatalogEntry? {
        id.flatMap(entry(id:)) ?? recommended
    }

    /// Entries this build can actually run.
    public var runnableEntries: [SpeechModelCatalogEntry] {
        entries.filter { $0.runtime.isAvailableInThisBuild }
    }

    /// ADR-025: the catalog with one entry replaced (the runtime-observed
    /// language overlay). Order and every other entry are untouched; an
    /// `id` the catalog does not hold returns the catalog unchanged.
    public func replacing(_ entry: SpeechModelCatalogEntry) -> SpeechModelCatalog {
        SpeechModelCatalog(
            schemaVersion: schemaVersion,
            entries: entries.map { $0.id == entry.id ? entry : $0 }
        )
    }
}

// MARK: - Transcription language

/// A language the user can force for transcription. Codes are Whisper's
/// ISO-639-1 style codes; `nil` in settings means auto-detect.
public struct TranscriptionLanguage: Sendable, Equatable, Hashable, Identifiable {
    public let code: String
    public let displayName: String

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public var id: String { code }

    public static func displayName(forCode code: String?) -> String {
        guard let code else { return "Auto-detect" }
        return whisperLanguages.first { $0.code == code }?.displayName ?? code
    }

    /// ADR-019: the 25 languages NVIDIA lists for Parakeet TDT 0.6B v3. All
    /// are Whisper codes too, so the picker and the settings value need no
    /// second vocabulary. Kept here rather than in the catalog JSON alone so a
    /// test can pin the catalog entry to this list.
    public static let parakeetTDTv3LanguageCodes: [String] = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]

    /// ADR-019 amendment (2026-09-16): the Whisper codes for which the
    /// Nemotron 3.5 ASR Streaming Multilingual `multilingual/` ship has a
    /// `prompt_id` (its `metadata.json` `prompt_dictionary`, 121 keys for
    /// ~80 languages; the 16 keys with no Whisper code — Aymara, Guarani,
    /// Igbo, Kurdish, Kyrgyz, Nahuatl, Chichewa, Quechua, Kinyarwanda,
    /// Samoan, Tongan, Zulu, `or-KE`, Bokmål `nb` and the malformed `enGB` /
    /// `esES` — are not selectable). The adapter maps each code to the key
    /// (`ParakeetModelVariant.nemotronPromptKey`); a live test checks the
    /// mapping against the real file. 64 codes.
    public static let nemotronMultilingualLanguageCodes: [String] = [
        "af", "am", "ar", "az", "bg", "bn", "cs", "da", "de", "el", "en", "es", "et", "fa",
        "fi", "fr", "gu", "ha", "haw", "he", "hi", "hr", "hu", "hy", "id", "it", "ja", "ka",
        "km", "kn", "ko", "ln", "lt", "lv", "mi", "ml", "mr", "ms", "mt", "ne", "nl", "nn",
        "no", "pl", "pt", "ro", "ru", "si", "sk", "sl", "so", "sv", "sw", "ta", "te", "tg",
        "th", "tr", "uk", "ur", "uz", "vi", "yo", "zh"
    ]

    /// ADR-019 amendment (2026-09-16, second model): the five languages
    /// SenseVoice Small has a language embedding for (its card and FunASR's
    /// `lid_dict`: `zh`, `en`, `yue`, `ja`, `ko`; `auto` covers the "50+"
    /// the card mentions without a selectable id). All are Whisper codes,
    /// Cantonese included — the one CJK language Nemotron lacks. The
    /// adapter maps each to its embedding index
    /// (`ParakeetModelVariant.senseVoiceLanguageEmbedding`).
    public static let senseVoiceSmallLanguageCodes: [String] = ["zh", "en", "yue", "ja", "ko"]

    /// ADR-019 amendment (2026-09-16, third model): Paraformer-large is a
    /// Mandarin-only checkpoint (the card's `language: zh`; its 8,404-token
    /// vocabulary is Chinese characters plus English BPE pieces for the
    /// loanwords in its training data). One code, so the Models section
    /// warns for every other language and the model takes no hint at all.
    public static let paraformerLargeZhLanguageCodes: [String] = ["zh"]

    /// ADR-019 amendment (2026-09-16, fourth model): Parakeet Realtime EOU
    /// 120M is English-only (the card's `language: en`; its 1,024-piece
    /// SentencePiece vocabulary is lowercase English with no punctuation).
    /// One code, so the Models section warns for every other language and
    /// the model takes no hint, like Unified.
    public static let parakeetEOULanguageCodes: [String] = ["en"]

    /// ADR-025: the Whisper codes among the 45 locales
    /// `SpeechTranscriber.supportedLocales` reported on macOS 27.0 (observed
    /// 2026-09-16 on a test Mac; the report also lists `ks`, `mai`,
    /// `mul` and `or`, which have no Whisper code and are not selectable).
    /// This is the catalog's *shipped* list — what a macOS 15 Mac shows
    /// under "Requires macOS 26 or later." and what stands until the runtime
    /// has observed the real list; `SpeechModelLibrary` overlays the
    /// observed codes on every refresh, so a newer OS with more locales
    /// shows them without a catalog change. 21 codes.
    public static let appleSpeechShippedLanguageCodes: [String] = [
        "bn", "de", "en", "es", "fr", "gu", "hi", "it", "ja", "kn", "ko", "ml", "mr",
        "ne", "pa", "pt", "ta", "te", "ur", "yue", "zh"
    ]

    /// Whisper's 99 languages, one display name per code, sorted by name.
    public static let whisperLanguages: [TranscriptionLanguage] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"),
        ("hy", "Armenian"), ("as", "Assamese"), ("az", "Azerbaijani"), ("ba", "Bashkir"),
        ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("my", "Burmese"), ("yue", "Cantonese"),
        ("ca", "Catalan"), ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"),
        ("da", "Danish"), ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"),
        ("fo", "Faroese"), ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"),
        ("ka", "Georgian"), ("de", "German"), ("el", "Greek"), ("gu", "Gujarati"),
        ("ht", "Haitian Creole"), ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"),
        ("hi", "Hindi"), ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"),
        ("it", "Italian"), ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"),
        ("kk", "Kazakh"), ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"),
        ("la", "Latin"), ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"),
        ("lb", "Luxembourgish"), ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"),
        ("ml", "Malayalam"), ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"),
        ("mn", "Mongolian"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"),
        ("oc", "Occitan"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"),
        ("te", "Telugu"), ("th", "Thai"), ("bo", "Tibetan"), ("tr", "Turkish"),
        ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba")
    ].map { TranscriptionLanguage(code: $0.0, displayName: $0.1) }
}

// MARK: - Streaming audio

/// A run of converted samples handed from the capture service to a streaming
/// engine while the recording continues. Always mono 16 kHz Float32 at the
/// transcription boundary; the capture adapter guarantees the invariant.
public struct AudioSampleChunk: Sendable, Equatable {
    public let samples: ContiguousArray<Float>
    public let sampleRate: Double
    public let channelCount: Int

    public init(
        samples: ContiguousArray<Float>,
        sampleRate: Double = 16_000,
        channelCount: Int = 1
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isEngineCompatible: Bool {
        sampleRate == 16_000 && channelCount == 1
    }
}
