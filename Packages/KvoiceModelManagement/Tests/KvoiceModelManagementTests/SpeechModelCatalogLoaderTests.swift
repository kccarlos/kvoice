import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// ADR-017: the bundled catalog is the trust root for every downloadable
/// model. These tests guard the shipped resources and the loader's
/// fail-closed rules.
final class SpeechModelCatalogLoaderTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceModelManagementTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceModelManagement
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    func testBundledCatalogLoadsAndEveryManifestVerifies() throws {
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let catalog = loaded.catalog

        XCTAssertEqual(catalog.schemaVersion, 1, "ADR-019 added optional fields only; no schema bump")
        XCTAssertEqual(
            catalog.entries.map(\.id),
            [
                "whisper-large-v3-turbo-coreml-632mb", "whisper-large-v3-turbo-coreml-uncompressed",
                "parakeet-tdt-0.6b-v3-coreml", "parakeet-unified-en-0.6b-coreml",
                "nemotron-3.5-asr-streaming-multilingual-0.6b-coreml", "sensevoice-small-coreml",
                "paraformer-large-zh-coreml", "parakeet-realtime-eou-120m-coreml",
                "apple-speech"
            ]
        )
        XCTAssertEqual(catalog.recommended?.id, "whisper-large-v3-turbo-coreml-632mb", "product decision 2: Whisper stays recommended")
        XCTAssertEqual(catalog.runnableEntries.count, 9)

        // ADR-025: the system-managed entry has no anchor — the platform owns
        // and verifies its assets — and no size, manifest or digest.
        let appleSpeech = try XCTUnwrap(catalog.entry(id: "apple-speech"))
        XCTAssertNil(loaded.anchor(for: "apple-speech"))
        XCTAssertTrue(appleSpeech.isSystemManaged)
        XCTAssertEqual(appleSpeech.runtime, .appleSpeech)
        XCTAssertEqual(appleSpeech.downloadBytes, 0)
        XCTAssertEqual(appleSpeech.manifestResource, "")
        XCTAssertEqual(appleSpeech.manifestSHA256, "")
        XCTAssertEqual(appleSpeech.revision, InstalledModelPackage.systemManagedRevision)
        XCTAssertEqual(appleSpeech.languageCodes, TranscriptionLanguage.appleSpeechShippedLanguageCodes)
        XCTAssertEqual(appleSpeech.punctuation, true)
        XCTAssertTrue(appleSpeech.supportsStreaming)
        XCTAssertNil(appleSpeech.promptTokenLimit, "the dictionary is a phrase list, not a prompt")
        XCTAssertFalse(appleSpeech.isRecommended, "Whisper stays the default")
        XCTAssertTrue(appleSpeech.summary.contains("KVoice"), "product name spelling")
        XCTAssertFalse(appleSpeech.summary.contains("kvoice"))

        let provider = PinnedHuggingFaceModelURLProvider()
        for entry in catalog.entries where !entry.isSystemManaged {
            let anchor = try XCTUnwrap(loaded.anchor(for: entry.id), entry.id)
            XCTAssertEqual(anchor.manifest.modelID, entry.id)
            XCTAssertEqual(anchor.manifest.source.revision, entry.revision)
            XCTAssertEqual(anchor.manifest.family, entry.family)
            XCTAssertEqual(try WhisperModelReleaseTrustAnchor.digest(for: anchor.manifest), entry.manifestSHA256)
            XCTAssertEqual(
                entry.downloadBytes,
                anchor.manifest.files.reduce(0) { $0 + $1.bytes },
                "the card size is the manifest's byte sum"
            )
            XCTAssertEqual(entry.hosting, .onDevice)
            XCTAssertTrue(entry.supportsBatch)
            XCTAssertFalse(entry.summary.isEmpty)
            XCTAssertNotNil(entry.punctuation, "every shipped entry states its punctuation")
            XCTAssertNotNil(entry.license, "every shipped entry states the weights' license")
            let release = try XCTUnwrap(PinnedModelReleases.release(matching: anchor.manifest), "every entry is a pinned release")
            XCTAssertEqual(release.runtime, entry.runtime)
            // Every file resolves to a pinned URL without discovery.
            for descriptor in anchor.manifest.files {
                let url = try provider.url(for: descriptor, manifest: anchor.manifest)
                XCTAssertEqual(url.host(), "huggingface.co")
                XCTAssertTrue(url.path.contains("/resolve/"))
                if descriptor.role != .tokenizer || entry.runtime != .whisperKitCoreML {
                    // Whisper's tokenizer tree comes from the upstream repo at
                    // its own revision; everything else is the entry's.
                    XCTAssertTrue(url.path.contains("/resolve/\(entry.revision)/"), url.absoluteString)
                }
            }
        }

        // Whisper: two packages sharing the tokenizer tree, full language list, a prompt.
        for entry in catalog.entries where entry.runtime == .whisperKitCoreML {
            let anchor = loaded.anchors[entry.id]!
            XCTAssertEqual(anchor.manifest.source.repository, KvoiceManagedModel.repository)
            XCTAssertEqual(anchor.manifest.runtimeCompatibility.exactVersion, KvoiceManagedModel.runtimeVersion)
            XCTAssertTrue(entry.supportsStreaming)
            XCTAssertNil(entry.languageCodes, "Whisper entries accept the full language list")
            XCTAssertEqual(entry.promptTokenLimit, 224)
            XCTAssertEqual(entry.punctuation, true)
            XCTAssertEqual(entry.license, "MIT")
            let tokenizerPaths = anchor.manifest.files.filter { $0.role == .tokenizer }.map(\.path)
            XCTAssertEqual(tokenizerPaths.count, 7)
            XCTAssertTrue(tokenizerPaths.allSatisfy { $0.hasPrefix("tokenizer/models/openai/whisper-large-v3/") })
        }

        // ADR-019: the two Parakeet entries.
        let tdt = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.parakeetTDTv3ModelID))
        XCTAssertEqual(tdt.runtime, .fluidAudioParakeetTDT)
        XCTAssertFalse(tdt.supportsStreaming, "TDT is batch only")
        XCTAssertEqual(tdt.languageCodes, TranscriptionLanguage.parakeetTDTv3LanguageCodes)
        XCTAssertEqual(tdt.languageCodes?.count, 25)
        XCTAssertNil(tdt.promptTokenLimit, "no initial prompt (ADR-018 rule 3)")
        XCTAssertEqual(tdt.punctuation, true, "NVIDIA lists punctuation for v3; the live sample confirmed it")
        XCTAssertEqual(tdt.license, "CC-BY-4.0")
        XCTAssertTrue(tdt.attribution?.contains("NVIDIA") == true)
        XCTAssertFalse(tdt.isRecommended)
        XCTAssertTrue(tdt.supportsLanguage("de"))
        XCTAssertFalse(tdt.supportsLanguage("zh"))
        XCTAssertNotNil(tdt.languageCoverageWarning(forLanguageCode: "zh"))
        XCTAssertNil(tdt.languageCoverageWarning(forLanguageCode: nil))

        let unified = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.parakeetUnifiedENModelID))
        XCTAssertEqual(unified.runtime, .fluidAudioParakeetUnified)
        XCTAssertTrue(unified.supportsStreaming)
        XCTAssertEqual(unified.languageCodes, ["en"])
        XCTAssertNil(unified.promptTokenLimit)
        XCTAssertEqual(unified.punctuation, true)
        XCTAssertEqual(unified.license, "CC-BY-4.0")
        XCTAssertEqual(unified.availableModes, [.batch, .streaming])

        // ADR-019 amendment (2026-09-16): the Nemotron entry — one package,
        // the `multilingual/2240ms` ship, 18 files, no preprocessor.
        let nemotron = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.nemotronMultilingualModelID))
        XCTAssertEqual(nemotron.runtime, .fluidAudioNemotronStreaming)
        XCTAssertTrue(nemotron.supportsStreaming)
        XCTAssertEqual(nemotron.availableModes, [.batch, .streaming])
        XCTAssertEqual(nemotron.languageCodes, TranscriptionLanguage.nemotronMultilingualLanguageCodes)
        XCTAssertEqual(nemotron.languageCodes?.count, 64)
        XCTAssertTrue(nemotron.supportsLanguage("zh"))
        XCTAssertTrue(nemotron.supportsLanguage("ja"))
        XCTAssertTrue(nemotron.supportsLanguage("ko"))
        XCTAssertTrue(nemotron.supportsLanguage("en"))
        XCTAssertFalse(nemotron.supportsLanguage("yue"), "Cantonese has no prompt id")
        XCTAssertNotNil(nemotron.languageCoverageWarning(forLanguageCode: "yue"))
        XCTAssertNil(nemotron.promptTokenLimit, "no initial prompt (ADR-018 rule 3)")
        XCTAssertEqual(nemotron.punctuation, true)
        XCTAssertEqual(nemotron.license, "OpenMDW-1.1")
        XCTAssertTrue(nemotron.attribution?.contains("NVIDIA") == true)
        XCTAssertFalse(nemotron.isRecommended)
        XCTAssertEqual(nemotron.downloadBytes, 664_235_399)
        let nemotronAnchor = loaded.anchors[nemotron.id]!
        XCTAssertEqual(nemotronAnchor.manifest.source.subdirectory, "multilingual/2240ms")
        XCTAssertEqual(nemotronAnchor.manifest.files.count, 18)
        XCTAssertFalse(nemotronAnchor.manifest.files.contains { $0.path.hasPrefix("model/preprocessor") }, "0.15.7 never loads it")
        for required in ["encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc", "decoder_joint.mlmodelc"] {
            XCTAssertTrue(nemotronAnchor.manifest.files.contains { $0.path == "model/\(required)/weights/weight.bin" }, required)
        }
        XCTAssertEqual(nemotronAnchor.manifest.files.filter { $0.role == .configuration }.map(\.path), ["model/metadata.json"])
        XCTAssertEqual(nemotronAnchor.manifest.files.filter { $0.role == .tokenizer }.map(\.path), ["model/tokenizer.json"])

        // ADR-019 amendment (2026-09-16, second model): SenseVoice — one
        // package, two encoders, no decoder graph, 13 files.
        let senseVoice = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.senseVoiceSmallModelID))
        XCTAssertEqual(senseVoice.runtime, .fluidAudioSenseVoice)
        XCTAssertFalse(senseVoice.supportsStreaming, "non-autoregressive, batch only")
        XCTAssertEqual(senseVoice.availableModes, [.batch])
        XCTAssertEqual(senseVoice.languageCodes, TranscriptionLanguage.senseVoiceSmallLanguageCodes)
        XCTAssertEqual(senseVoice.languageCodes, ["zh", "en", "yue", "ja", "ko"])
        XCTAssertTrue(senseVoice.supportsLanguage("yue"), "Cantonese — the one CJK language Nemotron lacks")
        XCTAssertFalse(senseVoice.supportsLanguage("de"))
        XCTAssertNotNil(senseVoice.languageCoverageWarning(forLanguageCode: "de"))
        XCTAssertNil(senseVoice.promptTokenLimit, "no initial prompt (ADR-018 rule 3)")
        XCTAssertEqual(senseVoice.punctuation, true)
        XCTAssertEqual(senseVoice.license, "FunASR-Model-License-1.1")
        XCTAssertTrue(senseVoice.attribution?.contains("FunAudioLLM") == true)
        XCTAssertTrue(senseVoice.attribution?.contains("FluidInference") == true)
        XCTAssertFalse(senseVoice.isRecommended)
        XCTAssertEqual(senseVoice.downloadBytes, 1_180_930_332)
        let senseVoiceAnchor = loaded.anchors[senseVoice.id]!
        XCTAssertEqual(senseVoiceAnchor.manifest.source.subdirectory, "")
        XCTAssertEqual(senseVoiceAnchor.manifest.files.count, 13)
        XCTAssertFalse(
            senseVoiceAnchor.manifest.files.contains { $0.path.hasPrefix("model/SenseVoiceSmall.mlmodelc") },
            "the fp16 export is not part of the package"
        )
        for required in ["SenseVoicePreprocessor.mlmodelc", "SenseVoiceSmall_int8.mlmodelc", "SenseVoiceSmall_fp32.mlmodelc"] {
            XCTAssertTrue(senseVoiceAnchor.manifest.files.contains { $0.path == "model/\(required)/weights/weight.bin" }, required)
        }
        XCTAssertEqual(
            senseVoiceAnchor.manifest.files.filter { $0.role == .melSpectrogram }.map(\.path).sorted().first,
            "model/SenseVoicePreprocessor.mlmodelc/analytics/coremldata.bin"
        )
        XCTAssertEqual(senseVoiceAnchor.manifest.files.filter { $0.role == .textDecoder }.count, 0, "greedy CTC on the host")
        XCTAssertEqual(senseVoiceAnchor.manifest.files.filter { $0.role == .tokenizer }.map(\.path), ["model/vocab.json"])
        XCTAssertEqual(
            senseVoiceAnchor.manifest.files.filter { $0.role == .audioEncoder && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/SenseVoiceSmall_int8.mlmodelc/weights/weight.bin"],
            "the Neural Engine graph is the one the Runtime card plans"
        )
        XCTAssertEqual(
            senseVoiceAnchor.manifest.files.filter { $0.role == .otherRequired && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/SenseVoiceSmall_fp32.mlmodelc/weights/weight.bin"]
        )

        // ADR-019 amendment (2026-09-16, third model): Paraformer-large —
        // Mandarin only, no punctuation, a real decoder graph, 17 files.
        let paraformer = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.paraformerLargeZhModelID))
        XCTAssertEqual(paraformer.runtime, .fluidAudioParaformer)
        XCTAssertFalse(paraformer.supportsStreaming, "non-autoregressive, batch only")
        XCTAssertEqual(paraformer.availableModes, [.batch])
        XCTAssertEqual(paraformer.languageCodes, TranscriptionLanguage.paraformerLargeZhLanguageCodes)
        XCTAssertEqual(paraformer.languageCodes, ["zh"])
        XCTAssertTrue(paraformer.supportsLanguage("zh"))
        for other in ["en", "yue", "ja", "ko", "de"] {
            XCTAssertFalse(paraformer.supportsLanguage(other), other)
            XCTAssertNotNil(paraformer.languageCoverageWarning(forLanguageCode: other), "the picker must warn for \(other)")
        }
        XCTAssertNil(paraformer.languageCoverageWarning(forLanguageCode: "zh"))
        XCTAssertNil(paraformer.languageCoverageWarning(forLanguageCode: nil))
        XCTAssertNil(paraformer.promptTokenLimit, "no initial prompt (ADR-018 rule 3); the plain checkpoint has no hotwords")
        XCTAssertEqual(paraformer.punctuation, false, "the first shipped entry without punctuation")
        XCTAssertEqual(paraformer.punctuationSummary, "No punctuation")
        XCTAssertEqual(paraformer.license, "Apache-2.0")
        XCTAssertTrue(paraformer.attribution?.contains("FunASR") == true)
        XCTAssertTrue(paraformer.attribution?.contains("FluidInference") == true)
        XCTAssertFalse(paraformer.isRecommended)
        XCTAssertEqual(paraformer.downloadBytes, 222_136_057)
        let paraformerAnchor = loaded.anchors[paraformer.id]!
        XCTAssertEqual(paraformerAnchor.manifest.source.subdirectory, "")
        XCTAssertEqual(paraformerAnchor.manifest.files.count, 17)
        for fp16 in ["model/ParaformerEncoder.mlmodelc", "model/ParaformerDecoder.mlmodelc"] {
            XCTAssertFalse(paraformerAnchor.manifest.files.contains { $0.path.hasPrefix(fp16 + "/") }, "the fp16 export is not part of the package")
        }
        for required in ["ParaformerPreprocessor.mlmodelc", "ParaformerEncoder_int8.mlmodelc", "ParaformerCifAlphas.mlmodelc", "ParaformerDecoder_int8.mlmodelc"] {
            XCTAssertTrue(paraformerAnchor.manifest.files.contains { $0.path == "model/\(required)/weights/weight.bin" }, required)
        }
        XCTAssertEqual(
            paraformerAnchor.manifest.files.filter { $0.role == .audioEncoder && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/ParaformerEncoder_int8.mlmodelc/weights/weight.bin"]
        )
        XCTAssertEqual(
            paraformerAnchor.manifest.files.filter { $0.role == .textDecoder && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/ParaformerDecoder_int8.mlmodelc/weights/weight.bin"],
            "a real decoder graph: the Runtime card's decoder row is the executing graph"
        )
        XCTAssertEqual(
            paraformerAnchor.manifest.files.filter { $0.role == .otherRequired && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/ParaformerCifAlphas.mlmodelc/weights/weight.bin"]
        )
        XCTAssertEqual(paraformerAnchor.manifest.files.filter { $0.role == .tokenizer }.map(\.path), ["model/vocab.json"])
        XCTAssertEqual(
            paraformerAnchor.manifest.files.filter { $0.role == .melSpectrogram }.map(\.path).sorted().first,
            "model/ParaformerPreprocessor.mlmodelc/analytics/coremldata.bin"
        )
        // The same front end as SenseVoice: the preprocessor's graph
        // (`model.mil`) and weights are byte-identical, so their digests
        // are; only the two `coremldata.bin` metadata blobs (which carry
        // the bundle name) differ.
        func preprocessorDigests(_ files: [ModelFileDescriptor], bundle: String) -> [String] {
            files.filter { $0.path.hasPrefix("model/\(bundle)/") && !$0.path.hasSuffix("coremldata.bin") }
                .map { file -> String in
                    let inside = file.path.split(separator: "/").dropFirst(2).joined(separator: "/")
                    return inside + "=" + file.sha256
                }
                .sorted()
        }
        XCTAssertEqual(
            preprocessorDigests(senseVoiceAnchor.manifest.files, bundle: "SenseVoicePreprocessor.mlmodelc"),
            preprocessorDigests(paraformerAnchor.manifest.files, bundle: "ParaformerPreprocessor.mlmodelc")
        )
        XCTAssertEqual(preprocessorDigests(paraformerAnchor.manifest.files, bundle: "ParaformerPreprocessor.mlmodelc").count, 2)

        // ADR-019 amendment (2026-09-16, fourth model): Parakeet Realtime
        // EOU — English only, no punctuation, streaming and batch, the
        // `320ms/` tier, 16 files, the EOU signal never acted on.
        let eou = try XCTUnwrap(catalog.entry(id: KvoiceFluidAudioModels.parakeetEOUModelID))
        XCTAssertEqual(eou.runtime, .fluidAudioParakeetEOU)
        XCTAssertTrue(eou.supportsStreaming, "a cache-aware streaming RNNT: partials every 320 ms")
        XCTAssertEqual(eou.availableModes, [.batch, .streaming])
        XCTAssertEqual(eou.languageCodes, TranscriptionLanguage.parakeetEOULanguageCodes)
        XCTAssertEqual(eou.languageCodes, ["en"])
        XCTAssertTrue(eou.supportsLanguage("en"))
        for other in ["zh", "de", "ja", "yue"] {
            XCTAssertFalse(eou.supportsLanguage(other), other)
            XCTAssertNotNil(eou.languageCoverageWarning(forLanguageCode: other), "the picker must warn for \(other)")
        }
        XCTAssertNil(eou.languageCoverageWarning(forLanguageCode: "en"))
        XCTAssertNil(eou.promptTokenLimit, "no initial prompt (ADR-018 rule 3)")
        XCTAssertEqual(eou.punctuation, false, "NVIDIA's card: no punctuation or capitalisation")
        XCTAssertEqual(eou.punctuationSummary, "No punctuation")
        XCTAssertEqual(eou.license, "NVIDIA-Open-Model-License")
        XCTAssertTrue(eou.attribution?.contains("NVIDIA") == true)
        XCTAssertTrue(eou.attribution?.contains("FluidInference") == true)
        XCTAssertFalse(eou.isRecommended)
        XCTAssertEqual(eou.downloadBytes, 224_238_270)
        XCTAssertTrue(eou.summary.contains("never stops a recording"), "FR-AUD-007 stated on the card")
        let eouAnchor = loaded.anchors[eou.id]!
        XCTAssertEqual(eouAnchor.manifest.source.subdirectory, "320ms")
        XCTAssertEqual(eouAnchor.manifest.files.count, 16)
        for required in ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc"] {
            XCTAssertTrue(eouAnchor.manifest.files.contains { $0.path == "model/\(required)/weights/weight.bin" }, required)
        }
        for excluded in ["model/parakeet_eou_preprocessor.mlmodelc/", "model/streaming_encoder.mlpackage/", "model/streaming_encoder_metadata.json"] {
            XCTAssertFalse(eouAnchor.manifest.files.contains { $0.path.hasPrefix(excluded) }, "\(excluded) is not part of the package")
        }
        XCTAssertFalse(eouAnchor.manifest.files.contains { $0.path.hasSuffix(".py") || $0.path.hasSuffix(".DS_Store") })
        XCTAssertEqual(
            eouAnchor.manifest.files.filter { $0.role == .audioEncoder && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/streaming_encoder.mlmodelc/weights/weight.bin"]
        )
        XCTAssertEqual(
            eouAnchor.manifest.files.filter { $0.role == .textDecoder && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/decoder.mlmodelc/weights/weight.bin"],
            "a real decoder graph: the Runtime card's decoder row is the executing graph"
        )
        XCTAssertEqual(
            eouAnchor.manifest.files.filter { $0.role == .otherRequired && $0.path.hasSuffix("weight.bin") }.map(\.path),
            ["model/joint_decision.mlmodelc/weights/weight.bin"]
        )
        XCTAssertEqual(eouAnchor.manifest.files.filter { $0.role == .tokenizer }.map(\.path), ["model/vocab.json"])

        for entry in [tdt, unified, nemotron, senseVoice, paraformer, eou] {
            let anchor = loaded.anchors[entry.id]!
            XCTAssertEqual(anchor.manifest.format, KvoiceFluidAudioModels.format)
            XCTAssertEqual(anchor.manifest.runtimeCompatibility.swiftPackage, KvoiceFluidAudioModels.runtimePackage)
            XCTAssertEqual(anchor.manifest.runtimeCompatibility.exactVersion, KvoiceFluidAudioModels.runtimeVersion)
            XCTAssertEqual(anchor.manifest.tokenizer.relativeRoot, "model", "FluidAudio layout: vocabulary beside the graphs")
            let subdirectory: String
            switch entry.runtime {
            case .fluidAudioNemotronStreaming: subdirectory = "multilingual/2240ms"
            case .fluidAudioParakeetEOU: subdirectory = "320ms"
            default: subdirectory = ""
            }
            XCTAssertEqual(
                anchor.manifest.source.subdirectory, subdirectory,
                "the Parakeets, SenseVoice and Paraformer publish at the repository root; Nemotron and EOU in a tier folder"
            )
            XCTAssertTrue(anchor.manifest.files.allSatisfy { $0.path.hasPrefix("model/") })
            XCTAssertEqual(anchor.manifest.files.filter { $0.role == .tokenizer }.count, 1)
            XCTAssertEqual(anchor.manifest.files.filter { $0.role == .audioEncoder && $0.path.hasSuffix("weight.bin") }.count, 1)
            // SenseVoice decodes its CTC head on the host: no decoder graph.
            XCTAssertEqual(
                anchor.manifest.files.filter { $0.role == .textDecoder && $0.path.hasSuffix("weight.bin") }.count,
                entry.runtime == .fluidAudioSenseVoice ? 0 : 1,
                entry.id
            )
        }
    }

    func testOptionalCatalogFieldsDecodeAsAbsentWhenMissing() throws {
        let json = """
        {"id":"x","displayName":"X","variantName":"","family":"f","runtime":"whisperkit-coreml","hosting":"on-device",
         "supportsStreaming":false,"supportsBatch":true,"downloadBytes":1,"languageCodes":null,"languageSummary":"s",
         "summary":"s","isRecommended":false,"revision":"r","manifestResource":"m","manifestSHA256":"d"}
        """
        let entry = try JSONDecoder().decode(SpeechModelCatalogEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.promptTokenLimit)
        XCTAssertNil(entry.punctuation)
        XCTAssertNil(entry.license)
        XCTAssertNil(entry.attribution)
        XCTAssertNil(entry.punctuationSummary)
        XCTAssertEqual(
            SpeechModelCatalogEntry(
                id: "y", displayName: "Y", variantName: "", family: "f", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
                supportsStreaming: false, supportsBatch: true, downloadBytes: 1, languageSummary: "s", summary: "s",
                isRecommended: false, revision: "r", manifestResource: "m", manifestSHA256: "d", punctuation: false
            ).punctuationSummary,
            "No punctuation"
        )
    }

    func testUncompressedEntryIsByteIdenticalToTheAppBundledManifest() throws {
        let appManifest = try Data(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Apps/KvoiceApp/ModelManifest.json")
        )
        let packageManifest = try Data(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Packages/KvoiceModelManagement/Sources/KvoiceModelManagement/Resources/Manifests/whisper-large-v3-turbo-coreml-uncompressed.json")
        )
        XCTAssertEqual(appManifest, packageManifest, "the two copies must not drift")

        let loaded = try BundledSpeechModelCatalogLoader().load()
        let entry = try XCTUnwrap(loaded.catalog.entry(id: "whisper-large-v3-turbo-coreml-uncompressed"))
        let appDigest = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Apps/KvoiceApp/ModelManifest.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(entry.manifestSHA256, appDigest)
    }

    func testStandardManifestIsCanonicalAndDescribesTheQuantizedPackage() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("Packages/KvoiceModelManagement/Sources/KvoiceModelManagement/Resources/Manifests/whisper-large-v3-turbo-coreml-632mb.json")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        XCTAssertEqual(try WhisperModelReleaseTrustAnchor.canonicalData(for: manifest), data, "resource bytes are canonical")
        XCTAssertEqual(manifest.source.subdirectory, "openai_whisper-large-v3-v20240930_turbo_632MB")
        XCTAssertEqual(manifest.source.revision, KvoiceManagedModel.revision)
        XCTAssertEqual(manifest.files.count, 29)
        XCTAssertFalse(manifest.files.contains { $0.path.hasSuffix("model.mlmodel") }, "the quantized package ships no .mlmodel")
        XCTAssertTrue(WhisperModelPackageValidator.isKnownRelease(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            subdirectory: manifest.source.subdirectory
        ))
    }

    func testLoaderFailsClosedOnDigestIdentityAndUnknownRelease() throws {
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let entry = try XCTUnwrap(loaded.catalog.entries.first)
        let manifestBytes = try WhisperModelReleaseTrustAnchor.canonicalData(for: loaded.anchors[entry.id]!.manifest)

        func catalogData(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded.catalog)) as! [String: Any]
            var entries = object["entries"] as! [[String: Any]]
            entries = [entries[0]]
            var first = entries[0]
            var mutated = first
            mutate(&mutated)
            first = mutated
            object["entries"] = [first]
            return try JSONSerialization.data(withJSONObject: object)
        }

        // Tampered digest.
        let badDigest = try catalogData { $0["manifestSHA256"] = String(repeating: "0", count: 64) }
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(catalogData: badDigest, manifestData: { _ in manifestBytes })) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .manifestDigestMismatch(entry.id))
        }
        // Entry that names a different model than its manifest.
        let badIdentity = try catalogData { $0["id"] = "whisper-large-v3-turbo-coreml-uncompressed" }
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(catalogData: badIdentity, manifestData: { _ in manifestBytes })) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .manifestIdentityMismatch("whisper-large-v3-turbo-coreml-uncompressed"))
        }
        // Missing manifest resource.
        let good = try catalogData { _ in }
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(catalogData: good, manifestData: { _ in nil })) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .manifestMissing(entry.id))
        }
        // Unsupported schema and empty catalog.
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(
            catalogData: Data("{\"schemaVersion\":2,\"entries\":[]}".utf8),
            manifestData: { _ in nil }
        )) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(
            catalogData: Data("{\"schemaVersion\":1,\"entries\":[]}".utf8),
            manifestData: { _ in nil }
        )) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .emptyCatalog)
        }
        // A release the validator does not know is refused even with a
        // matching digest.
        var unknown = loaded.anchors[entry.id]!.manifest
        unknown = ModelManifest(
            schemaVersion: unknown.schemaVersion,
            modelID: unknown.modelID,
            family: unknown.family,
            format: unknown.format,
            workingSpaceBytes: unknown.workingSpaceBytes,
            source: ModelManifestSource(
                repository: unknown.source.repository,
                revision: unknown.source.revision,
                subdirectory: "openai_whisper-large-v3-v20240930_turbo_999MB"
            ),
            runtimeCompatibility: unknown.runtimeCompatibility,
            tokenizer: unknown.tokenizer,
            files: unknown.files
        )
        let unknownBytes = try WhisperModelReleaseTrustAnchor.canonicalData(for: unknown)
        let unknownDigest = SHA256.hash(data: unknownBytes).map { String(format: "%02x", $0) }.joined()
        let unknownCatalog = try catalogData { $0["manifestSHA256"] = unknownDigest }
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(catalogData: unknownCatalog, manifestData: { _ in unknownBytes })) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .unknownRelease(entry.id))
        }
    }

    func testASystemManagedEntryNeedsNoManifestButMustNotPretendToHaveOne() throws {
        let loaded = try BundledSpeechModelCatalogLoader().load()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded.catalog)) as! [String: Any]
        var entries = object["entries"] as! [[String: Any]]
        var appleSpeech = try XCTUnwrap(entries.first { ($0["id"] as? String) == "apple-speech" })
        // Alone in the catalog, with no manifest data available at all.
        object["entries"] = [appleSpeech]
        let alone = try BundledSpeechModelCatalogLoader.load(
            catalogData: JSONSerialization.data(withJSONObject: object),
            manifestData: { _ in nil }
        )
        XCTAssertEqual(alone.catalog.entries.map(\.id), ["apple-speech"])
        XCTAssertTrue(alone.anchors.isEmpty)
        // A digest on a system-managed entry is a contradiction and is refused.
        appleSpeech["manifestSHA256"] = String(repeating: "a", count: 64)
        object["entries"] = [appleSpeech]
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(
            catalogData: JSONSerialization.data(withJSONObject: object),
            manifestData: { _ in nil }
        )) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .manifestIdentityMismatch("apple-speech"))
        }
        // Listed twice is still a duplicate.
        appleSpeech["manifestSHA256"] = ""
        entries = [appleSpeech, appleSpeech]
        object["entries"] = entries
        XCTAssertThrowsError(try BundledSpeechModelCatalogLoader.load(
            catalogData: JSONSerialization.data(withJSONObject: object),
            manifestData: { _ in nil }
        )) { error in
            XCTAssertEqual(error as? SpeechModelCatalogError, .duplicateEntry("apple-speech"))
        }
    }
}
