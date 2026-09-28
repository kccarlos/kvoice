import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// ADR-019: a second runtime behind the one resident engine. Covers the
/// pinned-release table, the FluidAudio package layout through the verifier
/// and the generator, the URL mapping, the runtime-switching engine, and the
/// library switching runtimes when the default model changes.
final class RuntimeSwitchingEngineTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture: a FluidAudio-layout package

    /// Files under `model/` only, vocabulary beside the graphs.
    private struct ParakeetFixture {
        let sourceURL: URL
        let manifest: ModelManifest
        let anchor: WhisperModelReleaseTrustAnchor

        static let contents: [(String, Data, ModelArtifactRole)] = [
            ("model/Preprocessor.mlmodelc/coremldata.bin", Data("pre".utf8), .melSpectrogram),
            ("model/Encoder.mlmodelc/weights/weight.bin", Data("enc".utf8), .audioEncoder),
            ("model/Decoder.mlmodelc/weights/weight.bin", Data("dec".utf8), .textDecoder),
            ("model/JointDecisionv3.mlmodelc/weights/weight.bin", Data("joint".utf8), .otherRequired),
            ("model/parakeet_vocab.json", Data("{\"0\":\"a\"}".utf8), .tokenizer),
            ("model/config.json", Data("{}".utf8), .configuration)
        ]

        static func make(in tracker: inout [URL]) throws -> ParakeetFixture {
            let sourceURL = ModelLifecycleFixture.makeTemporaryDirectory(in: &tracker)
            for (path, data, _) in contents {
                let url = sourceURL.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            let release = PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.parakeetTDTv3ModelID)!
            let manifest = ModelManifest(
                schemaVersion: 1,
                modelID: release.modelID,
                family: release.family,
                format: release.format,
                workingSpaceBytes: 1,
                source: ModelManifestSource(repository: release.repository, revision: release.revision, subdirectory: ""),
                runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: release.runtimePackage, exactVersion: release.runtimeVersion),
                tokenizer: ModelTokenizer(relativeRoot: "model"),
                files: contents.map { path, data, role in
                    ModelFileDescriptor(path: path, bytes: Int64(data.count), sha256: ModelLifecycleFixture.digest(data), role: role)
                }
            )
            let bytes = try WhisperModelReleaseTrustAnchor.canonicalData(for: manifest)
            let anchor = try WhisperModelReleaseTrustAnchor(manifestData: bytes, manifestSHA256: ModelLifecycleFixture.digest(bytes))
            return ParakeetFixture(sourceURL: sourceURL, manifest: manifest, anchor: anchor)
        }

        var entry: SpeechModelCatalogEntry {
            SpeechModelCatalogEntry(
                id: manifest.modelID, displayName: "Parakeet TDT v3", variantName: "Multilingual",
                family: manifest.family, runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
                supportsStreaming: false, supportsBatch: true,
                downloadBytes: Self.contents.reduce(0) { $0 + Int64($1.1.count) },
                languageCodes: TranscriptionLanguage.parakeetTDTv3LanguageCodes, languageSummary: "25 languages",
                summary: "fixture", isRecommended: false, revision: manifest.source.revision,
                manifestResource: manifest.modelID, manifestSHA256: anchor.manifestSHA256, punctuation: true, license: "CC-BY-4.0"
            )
        }
    }

    private func whisperEntry(_ fixture: ModelLifecycleFixture) -> SpeechModelCatalogEntry {
        SpeechModelCatalogEntry(
            id: fixture.manifest.modelID, displayName: "Whisper v3 Turbo", variantName: "Standard",
            family: fixture.manifest.family, runtime: .whisperKitCoreML, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: ModelLifecycleFixture.totalBytes,
            languageSummary: "99 languages", summary: "fixture", isRecommended: true,
            revision: fixture.manifest.source.revision, manifestResource: fixture.manifest.modelID,
            manifestSHA256: fixture.anchor.manifestSHA256, promptTokenLimit: 224
        )
    }

    // MARK: - Pinned releases

    func testPinnedReleasesMatchExactlyAndEveryWhisperRowIsKnownToTheValidator() throws {
        XCTAssertEqual(PinnedModelReleases.all.count, 9)
        for release in PinnedModelReleases.all where release.runtime == .whisperKitCoreML {
            XCTAssertTrue(WhisperModelPackageValidator.isKnownRelease(
                modelID: release.modelID, revision: release.revision, subdirectory: release.subdirectory
            ), release.modelID)
            XCTAssertEqual(release.tokenizerRelativeRoot, "tokenizer")
            XCTAssertNotNil(release.tokenizerSource)
        }
        for release in PinnedModelReleases.all where release.format == KvoiceFluidAudioModels.format {
            XCTAssertEqual(release.tokenizerRelativeRoot, "model")
            XCTAssertNil(release.tokenizerSource)
            XCTAssertEqual(release.runtimeVersion, KvoiceFluidAudioModels.runtimeVersion)
            // The 0.6B Parakeets, SenseVoice and Paraformer publish at the
            // root; Nemotron publishes `<stack>/<tier>ms/` folders and EOU
            // `<tier>ms/` folders, and the folder is part of the pinned
            // identity.
            let subdirectory: String
            switch release.runtime {
            case .fluidAudioNemotronStreaming: subdirectory = "multilingual/2240ms"
            case .fluidAudioParakeetEOU: subdirectory = "320ms"
            default: subdirectory = ""
            }
            XCTAssertEqual(release.subdirectory, subdirectory, release.modelID)
        }
        let nemotron = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.nemotronMultilingualModelID))
        XCTAssertEqual(nemotron.runtime, .fluidAudioNemotronStreaming)
        XCTAssertEqual(nemotron.family, "nemotron-3.5-asr-streaming-multilingual-0.6b")
        XCTAssertEqual(nemotron.repository, "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML")
        XCTAssertEqual(nemotron.revision, "1a41b75758b0337ff67db7d5408280aaaf23074e")
        // ADR-019 amendment (2026-09-16, second model): SenseVoice at the
        // repository root, both encoders in one package.
        let senseVoice = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.senseVoiceSmallModelID))
        XCTAssertEqual(senseVoice.runtime, .fluidAudioSenseVoice)
        XCTAssertEqual(senseVoice.family, "sensevoice-small")
        XCTAssertEqual(senseVoice.repository, "FluidInference/sensevoice-small-coreml")
        XCTAssertEqual(senseVoice.revision, "cdea3526163035c19915d4a10268992d018ebd46")
        XCTAssertEqual(senseVoice.subdirectory, "")
        // ADR-019 amendment (2026-09-16, third model): Paraformer-large at
        // the repository root, the int8 pair only.
        let paraformer = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.paraformerLargeZhModelID))
        XCTAssertEqual(paraformer.runtime, .fluidAudioParaformer)
        XCTAssertEqual(paraformer.family, "paraformer-large-zh")
        XCTAssertEqual(paraformer.repository, "FluidInference/paraformer-large-zh-coreml")
        XCTAssertEqual(paraformer.revision, "5dd557bd06342a3cd07ceccb909d8a45e48b053a")
        XCTAssertEqual(paraformer.subdirectory, "")
        // ADR-019 amendment (2026-09-16, fourth model): Parakeet Realtime EOU
        // in its `320ms/` tier folder.
        let eou = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.parakeetEOUModelID))
        XCTAssertEqual(eou.runtime, .fluidAudioParakeetEOU)
        XCTAssertEqual(eou.family, "parakeet-realtime-eou-120m")
        XCTAssertEqual(eou.repository, "FluidInference/parakeet-realtime-eou-120m-coreml")
        XCTAssertEqual(eou.revision, "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355")
        XCTAssertEqual(eou.subdirectory, "320ms")

        let fixture = try ParakeetFixture.make(in: &temporaryURLs)
        XCTAssertEqual(PinnedModelReleases.release(matching: fixture.manifest)?.runtime, .fluidAudioParakeetTDT)
        // Same ID, different revision: a different release, refused.
        let drifted = ModelManifest(
            schemaVersion: 1, modelID: fixture.manifest.modelID, family: fixture.manifest.family, format: fixture.manifest.format,
            workingSpaceBytes: 1, source: ModelManifestSource(repository: fixture.manifest.source.repository, revision: "0000", subdirectory: ""),
            runtimeCompatibility: fixture.manifest.runtimeCompatibility, tokenizer: fixture.manifest.tokenizer, files: []
        )
        XCTAssertNil(PinnedModelReleases.release(matching: drifted))
        // A Whisper tokenizer root on a FluidAudio manifest is refused too.
        let wrongRoot = ModelManifest(
            schemaVersion: 1, modelID: fixture.manifest.modelID, family: fixture.manifest.family, format: fixture.manifest.format,
            workingSpaceBytes: 1, source: fixture.manifest.source, runtimeCompatibility: fixture.manifest.runtimeCompatibility,
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"), files: []
        )
        XCTAssertNil(PinnedModelReleases.release(matching: wrongRoot))
    }

    // MARK: - URL provider

    func testParakeetFilesResolveAtTheRepositoryRootOfThePinnedRevision() throws {
        let fixture = try ParakeetFixture.make(in: &temporaryURLs)
        let provider = PinnedHuggingFaceModelURLProvider()
        let url = try provider.url(
            for: ModelFileDescriptor(path: "model/Encoder.mlmodelc/weights/weight.bin", bytes: 1, sha256: String(repeating: "0", count: 64), role: .audioEncoder),
            manifest: fixture.manifest
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/"
                + "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/Encoder.mlmodelc/weights/weight.bin?download=true"
        )
        let vocabulary = try provider.url(
            for: ModelFileDescriptor(path: "model/parakeet_vocab.json", bytes: 1, sha256: String(repeating: "0", count: 64), role: .tokenizer),
            manifest: fixture.manifest
        )
        XCTAssertEqual(
            vocabulary.absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/"
                + "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/parakeet_vocab.json?download=true"
        )
        // The Nemotron folder sits between the revision and the file
        // (verified against the live host on 2026-09-16: 18 URLs, each 200
        // with the manifest's byte count).
        let nemotron = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.nemotronMultilingualModelID))
        let nemotronManifest = ModelManifest(
            schemaVersion: 1, modelID: nemotron.modelID, family: nemotron.family, format: nemotron.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(repository: nemotron.repository, revision: nemotron.revision, subdirectory: nemotron.subdirectory),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: nemotron.runtimePackage, exactVersion: nemotron.runtimeVersion),
            tokenizer: ModelTokenizer(relativeRoot: "model"), files: []
        )
        let nemotronEncoder = try provider.url(
            for: ModelFileDescriptor(path: "model/encoder.mlmodelc/weights/weight.bin", bytes: 1, sha256: String(repeating: "0", count: 64), role: .audioEncoder),
            manifest: nemotronManifest
        )
        XCTAssertEqual(
            nemotronEncoder.absoluteString,
            "https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/"
                + "1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/encoder.mlmodelc/weights/weight.bin?download=true"
        )
        // SenseVoice publishes at the root like the Parakeets (verified
        // against the live host on 2026-09-16: 13 files fetched at the
        // pinned revision, every LFS digest equal to the tree API's lfs.oid).
        let senseVoice = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.senseVoiceSmallModelID))
        let senseVoiceManifest = ModelManifest(
            schemaVersion: 1, modelID: senseVoice.modelID, family: senseVoice.family, format: senseVoice.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(repository: senseVoice.repository, revision: senseVoice.revision, subdirectory: senseVoice.subdirectory),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: senseVoice.runtimePackage, exactVersion: senseVoice.runtimeVersion),
            tokenizer: ModelTokenizer(relativeRoot: "model"), files: []
        )
        let senseVoiceEncoder = try provider.url(
            for: ModelFileDescriptor(path: "model/SenseVoiceSmall_int8.mlmodelc/weights/weight.bin", bytes: 1, sha256: String(repeating: "0", count: 64), role: .audioEncoder),
            manifest: senseVoiceManifest
        )
        XCTAssertEqual(
            senseVoiceEncoder.absoluteString,
            "https://huggingface.co/FluidInference/sensevoice-small-coreml/resolve/"
                + "cdea3526163035c19915d4a10268992d018ebd46/SenseVoiceSmall_int8.mlmodelc/weights/weight.bin?download=true"
        )
        // Paraformer publishes at the root too (verified against the live
        // host on 2026-09-16: 17 files fetched at the pinned revision, 12
        // LFS digests equal to the tree API's, 5 small files hashed locally).
        let paraformer = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.paraformerLargeZhModelID))
        let paraformerManifest = ModelManifest(
            schemaVersion: 1, modelID: paraformer.modelID, family: paraformer.family, format: paraformer.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(repository: paraformer.repository, revision: paraformer.revision, subdirectory: paraformer.subdirectory),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: paraformer.runtimePackage, exactVersion: paraformer.runtimeVersion),
            tokenizer: ModelTokenizer(relativeRoot: "model"), files: []
        )
        let paraformerDecoder = try provider.url(
            for: ModelFileDescriptor(path: "model/ParaformerDecoder_int8.mlmodelc/weights/weight.bin", bytes: 1, sha256: String(repeating: "0", count: 64), role: .textDecoder),
            manifest: paraformerManifest
        )
        XCTAssertEqual(
            paraformerDecoder.absoluteString,
            "https://huggingface.co/FluidInference/paraformer-large-zh-coreml/resolve/"
                + "5dd557bd06342a3cd07ceccb909d8a45e48b053a/ParaformerDecoder_int8.mlmodelc/weights/weight.bin?download=true"
        )
        // The EOU tier folder is the URL's subdirectory segment (verified
        // against the live host on 2026-09-16: 16 files fetched at the
        // pinned revision, 9 LFS digests equal to the tree API's, 7 small
        // files hashed locally).
        let eou = try XCTUnwrap(PinnedModelReleases.release(modelID: KvoiceFluidAudioModels.parakeetEOUModelID))
        let eouManifest = ModelManifest(
            schemaVersion: 1, modelID: eou.modelID, family: eou.family, format: eou.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(repository: eou.repository, revision: eou.revision, subdirectory: eou.subdirectory),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: eou.runtimePackage, exactVersion: eou.runtimeVersion),
            tokenizer: ModelTokenizer(relativeRoot: "model"), files: []
        )
        let eouEncoder = try provider.url(
            for: ModelFileDescriptor(path: "model/streaming_encoder.mlmodelc/weights/weight.bin", bytes: 1, sha256: String(repeating: "0", count: 64), role: .audioEncoder),
            manifest: eouManifest
        )
        XCTAssertEqual(
            eouEncoder.absoluteString,
            "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/"
                + "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355/320ms/streaming_encoder.mlmodelc/weights/weight.bin?download=true"
        )
        // No `tokenizer/` prefix exists for this layout.
        XCTAssertThrowsError(try provider.url(
            for: ModelFileDescriptor(path: "tokenizer/vocab.json", bytes: 1, sha256: String(repeating: "0", count: 64), role: .tokenizer),
            manifest: fixture.manifest
        ))
    }

    // MARK: - Verifier and generator with the FluidAudio layout

    func testVerifierAcceptsAModelOnlyPackageWhoseManifestSaysSo() throws {
        let fixture = try ParakeetFixture.make(in: &temporaryURLs)
        try WhisperModelReleaseTrustAnchor.canonicalData(for: fixture.manifest)
            .write(to: fixture.sourceURL.appendingPathComponent("ModelManifest.json"))
        let verifier = ModelPackageVerifier(trustedRelease: fixture.anchor)
        let package = try verifier.makePackage(at: fixture.sourceURL, ownership: .managedByKvoice)
        XCTAssertEqual(package.tokenizerFolderURL, package.modelFolderURL, "the vocabulary sits beside the graphs")
        XCTAssertNoThrow(try verifier.verify(package))

        // A Whisper-layout anchor still requires tokenizer/.
        let whisper = try ModelLifecycleFixture.make(in: &temporaryURLs)
        try WhisperModelReleaseTrustAnchor.canonicalData(for: whisper.manifest)
            .write(to: whisper.sourceURL.appendingPathComponent("ModelManifest.json"))
        try FileManager.default.removeItem(at: whisper.sourceURL.appendingPathComponent("tokenizer"))
        XCTAssertThrowsError(
            try ModelPackageVerifier(trustedRelease: whisper.anchor).makePackage(at: whisper.sourceURL, ownership: .managedByKvoice)
        )
    }

    func testGeneratorProducesTheParakeetManifestFromAFlatModelFolder() throws {
        let fixture = try ParakeetFixture.make(in: &temporaryURLs)
        let configuration = try XCTUnwrap(ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceFluidAudioModels.parakeetTDTv3ModelID))
        XCTAssertFalse(configuration.usesSeparateTokenizerDirectory)
        let generated = try ModelManifestGenerator().generate(packageURL: fixture.sourceURL, configuration: configuration)
        XCTAssertEqual(generated.tokenizer.relativeRoot, "model")
        XCTAssertEqual(generated.source.subdirectory, "")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: generated.files.map { ($0.path, $0.role) }),
            Dictionary(uniqueKeysWithValues: ParakeetFixture.contents.map { ($0.0, $0.2) }),
            "roles come from the release table, not from Whisper's file names"
        )
        XCTAssertNotNil(PinnedModelReleases.release(matching: generated), "the generated manifest is a pinned release")
        XCTAssertNil(ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceManagedModel.modelID), "Whisper keeps the original layout")

        // A stray tokenizer/ directory is an unexpected entry for this layout.
        try FileManager.default.createDirectory(at: fixture.sourceURL.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixture.sourceURL.appendingPathComponent("tokenizer/vocab.json"))
        XCTAssertThrowsError(try ModelManifestGenerator().generate(packageURL: fixture.sourceURL, configuration: configuration))
    }

    // MARK: - Runtime-switching engine

    func testSwitchingEngineRoutesByRuntimeAndUnloadsTheOtherEngine() async throws {
        let whisper = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let parakeet = try ParakeetFixture.make(in: &temporaryURLs)
        let catalog = SpeechModelCatalog(entries: [whisperEntry(whisper), parakeet.entry])
        let whisperEngine = RecordingRuntimeEngine(promptLimit: .tokens(111))
        let parakeetEngine = RecordingRuntimeEngine(promptLimit: .unsupported)
        let engine = RuntimeSwitchingTranscriptionEngine(
            catalog: catalog,
            factory: StaticSpeechRuntimeFactory(engines: [.whisperKitCoreML: whisperEngine, .fluidAudioParakeetTDT: parakeetEngine])
        )

        var limit = await engine.promptTokenLimit
        XCTAssertNil(limit)
        try await engine.setComputeUnits(.cpuOnly)
        var units = await whisperEngine.units
        XCTAssertEqual(units, .cpuOnly, "a choice made before anything is resident reaches every engine")
        units = await parakeetEngine.units
        XCTAssertEqual(units, .cpuOnly)

        var statistics = await engine.runtimeStatistics
        XCTAssertNil(statistics.lastWarmUpDuration, "nothing resident, nothing warmed up")
        try await engine.load(package(for: whisper.manifest, root: whisper.sourceURL, tokenizerRoot: "tokenizer"))
        var loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, whisper.manifest.modelID)
        var runtime = await engine.currentRuntime
        XCTAssertEqual(runtime, .whisperKitCoreML)
        statistics = await engine.runtimeStatistics
        XCTAssertEqual(statistics.lastWarmUpDuration, .milliseconds(420), "the resident engine's warm-up reaches the Runtime card")
        limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .tokens(111))

        try await engine.load(package(for: parakeet.manifest, root: parakeet.sourceURL, tokenizerRoot: "model"))
        loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, parakeet.manifest.modelID)
        runtime = await engine.currentRuntime
        XCTAssertEqual(runtime, .fluidAudioParakeetTDT)
        let whisperUnloads = await whisperEngine.unloadCount
        XCTAssertEqual(whisperUnloads, 1, "never two runtimes resident at once")
        limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported, "the Dictionary section sees the Parakeet answer")

        // A choice the resident engine refuses changes nothing anywhere.
        await parakeetEngine.setRefusedUnits(.gpuAndCPU)
        do {
            try await engine.setComputeUnits(.gpuAndCPU)
            XCTFail("expected the refusal to propagate")
        } catch {}
        let stored = await engine.currentComputeUnits
        XCTAssertEqual(stored, .cpuOnly)
        units = await whisperEngine.units
        XCTAssertEqual(units, .cpuOnly, "the other engine was not told either")

        // Streaming is refused for an engine that does not stream.
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: nil, initialPrompt: nil) { _ in }
            XCTFail("expected streamingUnsupported")
        } catch let error as RuntimeSwitchingError {
            XCTAssertEqual(error, .streamingUnsupported(parakeet.manifest.modelID))
        }

        // An unknown model or a runtime without an engine is refused before any engine is touched.
        let unknown = SpeechModelCatalogEntry(
            id: "qwen", displayName: "Q", variantName: "", family: "qwen3-asr", runtime: .mlxQwen3ASR, hosting: .onDevice,
            supportsStreaming: false, supportsBatch: true, downloadBytes: 1, languageSummary: "", summary: "",
            isRecommended: false, revision: "r", manifestResource: "m", manifestSHA256: "d"
        )
        let engine2 = RuntimeSwitchingTranscriptionEngine(
            catalog: SpeechModelCatalog(entries: [unknown]),
            factory: StaticSpeechRuntimeFactory(engines: [:])
        )
        let qwenManifest = ModelManifest(
            schemaVersion: 1, modelID: "qwen", family: "qwen3-asr", format: "mlx", workingSpaceBytes: 1,
            source: ModelManifestSource(repository: "a/b", revision: "r", subdirectory: ""),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: "p", exactVersion: "1"),
            tokenizer: ModelTokenizer(relativeRoot: "model"), files: []
        )
        do {
            try await engine2.load(package(for: qwenManifest, root: parakeet.sourceURL, tokenizerRoot: "model"))
            XCTFail("expected runtimeUnavailable")
        } catch let error as RuntimeSwitchingError {
            XCTAssertEqual(error, .runtimeUnavailable(.mlxQwen3ASR))
        }
        do {
            try await engine2.load(package(for: parakeet.manifest, root: parakeet.sourceURL, tokenizerRoot: "model"))
            XCTFail("expected unknownModel")
        } catch let error as RuntimeSwitchingError {
            XCTAssertEqual(error, .unknownModel(parakeet.manifest.modelID))
        }
    }

    /// Pins the accepted tradeoff: a cross-runtime load that fails leaves
    /// nothing resident (the previous engine was released first) rather than
    /// restoring the old model, and the engine is not left pointing at a
    /// runtime that holds nothing. The library releases the old default
    /// before loading the new one anyway, so a restore here would be moot.
    func testAFailedCrossRuntimeLoadLeavesNothingResidentAndReportsIt() async throws {
        let whisper = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let parakeet = try ParakeetFixture.make(in: &temporaryURLs)
        let catalog = SpeechModelCatalog(entries: [whisperEntry(whisper), parakeet.entry])
        let whisperEngine = RecordingRuntimeEngine(promptLimit: .tokens(111))
        let parakeetEngine = RecordingRuntimeEngine(promptLimit: .unsupported)
        await parakeetEngine.setLoadError(KVoiceError(code: .modelNotInstalled))
        let engine = RuntimeSwitchingTranscriptionEngine(
            catalog: catalog,
            factory: StaticSpeechRuntimeFactory(engines: [.whisperKitCoreML: whisperEngine, .fluidAudioParakeetTDT: parakeetEngine])
        )
        try await engine.load(package(for: whisper.manifest, root: whisper.sourceURL, tokenizerRoot: "tokenizer"))

        do {
            try await engine.load(package(for: parakeet.manifest, root: parakeet.sourceURL, tokenizerRoot: "model"))
            XCTFail("expected the Parakeet load to fail")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .modelNotInstalled, "the engine's own error is surfaced, not wrapped")
        }
        let loaded = await engine.loadedModelID
        XCTAssertNil(loaded, "the Whisper graphs were released before the failed load; nothing is restored")
        let runtime = await engine.currentRuntime
        XCTAssertNil(runtime)
        let whisperUnloads = await whisperEngine.unloadCount
        XCTAssertEqual(whisperUnloads, 1)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: AudioRecording(
                samples: [0], duration: .seconds(1), peakLevelDBFS: -10, clippedFrameCount: 0
            ))) { _ in }
            XCTFail("expected noModelLoaded")
        } catch let error as RuntimeSwitchingError {
            XCTAssertEqual(error, .noModelLoaded)
        }

        // The next load (the library retrying, or the default going back to
        // Whisper) works from the clean state.
        try await engine.load(package(for: whisper.manifest, root: whisper.sourceURL, tokenizerRoot: "tokenizer"))
        let restored = await engine.loadedModelID
        XCTAssertEqual(restored, whisper.manifest.modelID)
    }

    // MARK: - Library switching runtimes

    func testLibrarySwitchesRuntimesWhenTheDefaultModelChanges() async throws {
        let storageURL = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let whisper = try ModelLifecycleFixture.make(in: &temporaryURLs, storageURL: storageURL)
        let parakeet = try ParakeetFixture.make(in: &temporaryURLs)
        let catalog = SpeechModelCatalog(entries: [whisperEntry(whisper), parakeet.entry])
        let loaded = LoadedSpeechModelCatalog(
            catalog: catalog,
            anchors: [whisper.manifest.modelID: whisper.anchor, parakeet.manifest.modelID: parakeet.anchor]
        )
        let whisperEngine = RecordingRuntimeEngine(promptLimit: .tokens(111))
        let parakeetEngine = RecordingRuntimeEngine(promptLimit: .unsupported)
        let engine = RuntimeSwitchingTranscriptionEngine(
            catalog: catalog,
            factory: StaticSpeechRuntimeFactory(engines: [.whisperKitCoreML: whisperEngine, .fluidAudioParakeetTDT: parakeetEngine])
        )
        let library = try SpeechModelLibrary(
            loaded: loaded,
            storageDirectoryURL: storageURL,
            engine: engine,
            makeDownloader: { LifecycleFixtureDownloader() },
            urlProvider: SourceTreeURLProvider(roots: [whisper.manifest.modelID: whisper.sourceURL, parakeet.manifest.modelID: parakeet.sourceURL]),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build"
        )
        XCTAssertEqual(library.modelIDs, [whisper.manifest.modelID, parakeet.manifest.modelID])

        try await library.installRecommendedModel()
        var resident = await engine.loadedModelID
        XCTAssertEqual(resident, whisper.manifest.modelID)

        // The Parakeet package downloads and verifies through the same
        // manager path (FluidAudio layout), without touching the engine.
        try await library.install(parakeet.manifest.modelID)
        let parakeetState = await library.state(of: parakeet.manifest.modelID)
        XCTAssertEqual(parakeetState, .ready(InstalledModelSummary(
            modelID: parakeet.manifest.modelID, revision: parakeet.manifest.source.revision, ownership: .managedByKvoice
        )))
        resident = await engine.loadedModelID
        XCTAssertEqual(resident, whisper.manifest.modelID, "a non-default install is verified, not loaded")
        var parakeetLoads = await parakeetEngine.loadedIDs
        XCTAssertTrue(parakeetLoads.isEmpty)

        try await library.setDefaultModel(parakeet.manifest.modelID)
        resident = await engine.loadedModelID
        XCTAssertEqual(resident, parakeet.manifest.modelID)
        let runtime = await engine.currentRuntime
        XCTAssertEqual(runtime, .fluidAudioParakeetTDT)
        parakeetLoads = await parakeetEngine.loadedIDs
        XCTAssertEqual(parakeetLoads, [parakeet.manifest.modelID])
        let whisperLoaded = await whisperEngine.loadedModelID
        XCTAssertNil(whisperLoaded, "the Whisper engine released its package")
        let isResident = await library.isDefaultModelResident()
        XCTAssertTrue(isResident)
        let residentPackage = await library.residentPackage()
        let package = try XCTUnwrap(residentPackage)
        XCTAssertEqual(package.tokenizerFolderURL, package.modelFolderURL)
    }

    // MARK: - Helpers

    private func package(for manifest: ModelManifest, root: URL, tokenizerRoot: String) -> InstalledModelPackage {
        InstalledModelPackage(
            manifest: manifest,
            packageURL: root,
            modelFolderURL: root.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: root.appendingPathComponent(tokenizerRoot, isDirectory: true),
            ownership: .managedByKvoice
        )
    }
}

/// An engine that records loads and the compute units it was told about.
private actor RecordingRuntimeEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true, supportsStreaming: false, supportsCancellation: true,
        supportedSampleRate: 16_000, supportedChannelCount: 1
    )
    private let promptLimit: PromptTokenLimit
    private(set) var loadedModelID: ModelID?
    private(set) var loadedIDs: [ModelID] = []
    private(set) var unloadCount = 0
    private(set) var units: SpeechComputeUnits = .default

    init(promptLimit: PromptTokenLimit) {
        self.promptLimit = promptLimit
    }

    func load(_ package: InstalledModelPackage) async throws {
        if let loadError { throw loadError }
        loadedModelID = package.manifest.modelID
        loadedIDs.append(package.manifest.modelID)
    }

    func unload() async {
        loadedModelID = nil
        unloadCount += 1
    }

    private var refusedUnits: SpeechComputeUnits?
    private var loadError: Error?

    func setRefusedUnits(_ units: SpeechComputeUnits?) {
        refusedUnits = units
    }

    func setLoadError(_ error: Error?) {
        loadError = error
    }

    func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        if units == refusedUnits { throw KVoiceError(code: .sttFailed) }
        self.units = units
    }

    var promptTokenLimit: PromptTokenLimit? {
        loadedModelID == nil ? nil : promptLimit
    }

    /// ADR-022 item 8: the resident engine's warm-up figure is what the
    /// switching engine must report to the Runtime card.
    var runtimeStatistics: TranscriptionRuntimeStatistics {
        loadedModelID == nil ? TranscriptionRuntimeStatistics() : TranscriptionRuntimeStatistics(lastWarmUpDuration: .milliseconds(420))
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }
}

private struct SourceTreeURLProvider: ModelDownloadURLProviding {
    let roots: [ModelID: URL]

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        guard let root = roots[manifest.modelID] else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
        return try ModelRelativePath.url(for: descriptor.path, under: root)
    }
}
