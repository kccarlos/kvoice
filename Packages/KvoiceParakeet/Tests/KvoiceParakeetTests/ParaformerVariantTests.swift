import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019 amendment (2026-09-16, third model): the Paraformer-large zh
/// variant against the fake runtime and a fake-but-verifiable package, plus
/// the pure pieces the FluidAudio pipeline calls (the CIF integrate-and-fire
/// port, the text assembly with BPE rejoin, the graph constants, the
/// compute-unit refusal). Nothing here loads Core ML or touches the
/// network; the live checks are `LiveParaformerMatrixTests` and
/// `LiveParakeetModelTests`.
final class ParaformerVariantTests: XCTestCase {
    private var fixtures: [FakeParakeetPackage] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func fixture() throws -> FakeParakeetPackage {
        let fixture = try FakeParakeetPackage.make(variant: .paraformerLargeZh)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: Variant table

    func testVariantIsResolvedFromTheManifestAndDescribesThePackage() throws {
        let fixture = try fixture()
        XCTAssertEqual(ParakeetModelVariant(manifest: fixture.package.manifest), .paraformerLargeZh)
        XCTAssertEqual(fixture.package.manifest.family, "paraformer-large-zh")
        XCTAssertEqual(fixture.package.manifest.source.subdirectory, "", "published at the repository root")
        XCTAssertEqual(ParakeetModelVariant.paraformerLargeZh.requiredArtifactRoots, [
            "model/ParaformerPreprocessor.mlmodelc",
            "model/ParaformerEncoder_int8.mlmodelc",
            "model/ParaformerCifAlphas.mlmodelc",
            "model/ParaformerDecoder_int8.mlmodelc",
            "model/vocab.json"
        ])
        for fp16 in [ParaformerGraph.Precision.fp16.encoderBundle, ParaformerGraph.Precision.fp16.decoderBundle] {
            XCTAssertFalse(
                ParakeetModelVariant.paraformerLargeZh.requiredArtifactRoots.contains("model/" + fp16),
                "the fp16 export is not part of the package"
            )
        }
        XCTAssertEqual(ParaformerGraph.shippedPrecision, .int8)
        XCTAssertFalse(ParakeetModelVariant.paraformerLargeZh.supportsStreaming, "non-autoregressive: one pass, no partials")
        XCTAssertFalse(ParakeetModelVariant.paraformerLargeZh.emitsPunctuation, "the plain checkpoint; measured 2026-09-16")
        XCTAssertEqual(ParakeetModelVariant.paraformerLargeZh.languageCodes, ["zh"])
        // The generator preset and the variant name the same bundles; a
        // real decoder graph this time, so the Runtime card's decoder row
        // plans the executing graph.
        let configuration = try XCTUnwrap(
            ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceFluidAudioModels.paraformerLargeZhModelID)
        )
        XCTAssertEqual(
            Set(configuration.modelRoles.keys),
            Set(ParakeetModelVariant.paraformerLargeZh.requiredArtifactRoots.map { String($0.dropFirst("model/".count)) })
        )
        XCTAssertEqual(configuration.modelRoles["ParaformerPreprocessor.mlmodelc"], .melSpectrogram)
        XCTAssertEqual(configuration.modelRoles["ParaformerEncoder_int8.mlmodelc"], .audioEncoder)
        XCTAssertEqual(configuration.modelRoles["ParaformerCifAlphas.mlmodelc"], .otherRequired)
        XCTAssertEqual(configuration.modelRoles["ParaformerDecoder_int8.mlmodelc"], .textDecoder)
        XCTAssertEqual(configuration.modelRoles["vocab.json"], .tokenizer)
        XCTAssertEqual(configuration.source.subdirectory, "")
        XCTAssertEqual(configuration.tokenizer.relativeRoot, "model")
    }

    func testGraphConstantsMatchTheExportsAndTheSharedFrontEnd() {
        XCTAssertEqual(ParaformerGraph.preprocessorBundle, "ParaformerPreprocessor.mlmodelc")
        XCTAssertEqual(ParaformerGraph.cifAlphasBundle, "ParaformerCifAlphas.mlmodelc")
        XCTAssertEqual(ParaformerGraph.Precision.int8.encoderBundle, "ParaformerEncoder_int8.mlmodelc")
        XCTAssertEqual(ParaformerGraph.Precision.int8.decoderBundle, "ParaformerDecoder_int8.mlmodelc")
        XCTAssertEqual(ParaformerGraph.Precision.fp16.encoderBundle, "ParaformerEncoder.mlmodelc")
        XCTAssertEqual(ParaformerGraph.Precision.fp16.decoderBundle, "ParaformerDecoder.mlmodelc")
        XCTAssertEqual(ParaformerGraph.vocabularyFile, "vocab.json")
        XCTAssertEqual(ParaformerGraph.featureDim, 560)
        XCTAssertEqual(ParaformerGraph.encoderDim, 512)
        XCTAssertEqual(ParaformerGraph.decoderEncoderFrames, 512)
        XCTAssertEqual(ParaformerGraph.decoderMaxTokens, 128)
        XCTAssertEqual(ParaformerGraph.bucket(forFrames: 1), 128)
        XCTAssertEqual(ParaformerGraph.bucket(forFrames: 250), 256, "a 15 s window")
        XCTAssertEqual(ParaformerGraph.bucket(forFrames: 257), 512)
        XCTAssertEqual(ParaformerGraph.bucket(forFrames: 5_000), 1_800, "clamped; the chunker keeps windows far below it")
        // The preprocessor is the same graph as SenseVoice's, so its input
        // range and frame rate are the same constants.
        XCTAssertEqual(ParaformerGraph.minimumWaveformSamples, SenseVoiceEncoderGraph.minimumWaveformSamples)
        XCTAssertEqual(ParaformerGraph.maximumWaveformSamples, SenseVoiceEncoderGraph.maximumWaveformSamples)
        XCTAssertEqual(ParaformerGraph.secondsPerFrame, SenseVoiceEncoderGraph.secondsPerFrame)
        XCTAssertEqual(ParaformerGraph.waveformScale, 32_768)
        // The window stays inside every bound: the preprocessor's 30 s,
        // the decoder's 512 frames, and the 128-token budget at ~6 chars/s.
        let windowSamples = Int(ParaformerGraph.maxWindowSeconds * 16_000)
        XCTAssertLessThanOrEqual(windowSamples, ParaformerGraph.maximumWaveformSamples)
        XCTAssertLessThanOrEqual(Int(ParaformerGraph.maxWindowSeconds / ParaformerGraph.secondsPerFrame), ParaformerGraph.decoderEncoderFrames / 2)
        XCTAssertLessThanOrEqual(Int(ParaformerGraph.maxWindowSeconds * 6), ParaformerGraph.decoderMaxTokens)
        let windows = SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.2, count: 40 * 16_000), maxSeconds: ParaformerGraph.maxWindowSeconds)
        // Constant-amplitude audio ties on energy, so every cut lands at the
        // start of the 10–15 s search range: four 10 s windows.
        XCTAssertEqual(windows.count, 4)
        XCTAssertTrue(windows.allSatisfy { $0.count <= windowSamples })
        XCTAssertEqual(windows.map(\.count).reduce(0, +), 40 * 16_000)
    }

    // MARK: Compute units

    func testOffNeuralEngineChoicesAreRefusedBeforeAnyRuntimeCall() async throws {
        let variant = ParakeetModelVariant.paraformerLargeZh
        XCTAssertTrue(variant.supportsComputeUnits(.neuralEngineAndCPU))
        XCTAssertTrue(variant.supportsComputeUnits(.all), "Core ML places the encoder on the ANE under .all; measured correct")
        XCTAssertFalse(variant.supportsComputeUnits(.gpuAndCPU), "the encoder is NaN off the Neural Engine")
        XCTAssertFalse(variant.supportsComputeUnits(.cpuOnly))
        let message = ParakeetTranscriptionError.computeUnitsUnsupported(variant, .cpuOnly).errorDescription ?? ""
        XCTAssertTrue(message.hasPrefix("paraformer-large-zh cannot run under CPU only"), message)
        XCTAssertTrue(message.contains("NaN off the Neural Engine"), message)
        XCTAssertTrue(message.hasSuffix("Choose Neural Engine + CPU, All in Speech Models › Runtime."), message)

        let fixture = try fixture()
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        for refused in [SpeechComputeUnits.gpuAndCPU, .cpuOnly] {
            do {
                try await engine.setComputeUnits(refused)
                XCTFail("expected computeUnitsUnsupported for \(refused.rawValue)")
            } catch let error as ParakeetTranscriptionError {
                XCTAssertEqual(error, .computeUnitsUnsupported(.paraformerLargeZh, refused))
            }
        }
        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .neuralEngineAndCPU, "the stored choice is unchanged")
        XCTAssertEqual(runtime.batchConfigurations.count, 1, "no reload was attempted")
        // The allowed alternative reloads.
        try await engine.setComputeUnits(.all)
        XCTAssertEqual(runtime.batchConfigurations.last?.computeUnits, .all)
        XCTAssertEqual(runtime.batchConfigurations.count, 2)

        // A persisted refused choice refuses the load with the same message.
        let cold = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await cold.setComputeUnits(.cpuOnly)
        do {
            try await cold.load(fixture.package)
            XCTFail("expected computeUnitsUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .computeUnitsUnsupported(.paraformerLargeZh, .cpuOnly))
        }
        if case .error = await cold.state {} else { XCTFail("expected an error state") }
        XCTAssertEqual(runtime.batchConfigurations.count, 2)
    }

    // MARK: CIF integrate-and-fire

    func testCIFFiresWhenTheIntegralCrossesTheThresholdAndSeedsTheNextTokenWithTheLeftover() {
        // Frame 0 (α 0.6) accumulates 0.6·[1, 0]; frame 1 (α 0.6) crosses at
        // 1.2, so only 0.4 of it is used (0.4·[0, 1]), the token fires on
        // frame 1, and the leftover 0.2 seeds the next token; frame 2 (α 0.3)
        // and the 0.45 tail reach 0.95 — no second fire.
        let fired = ParaformerCIF.integrateAndFire(
            encoderRows: [[1, 0], [0, 1], [2, 2]], alphas: [0.6, 0.6, 0.3]
        )
        XCTAssertEqual(fired.fireFrames, [1])
        XCTAssertEqual(fired.embeddings.count, 1)
        XCTAssertEqual(fired.embeddings[0][0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(fired.embeddings[0][1], 0.4, accuracy: 1e-6)

        // Alphas of exactly 1 fire every frame with nothing left over.
        let exact = ParaformerCIF.integrateAndFire(encoderRows: [[1, 1], [2, 2]], alphas: [1, 1])
        XCTAssertEqual(exact.fireFrames, [0, 1])
        XCTAssertEqual(exact.embeddings, [[1, 1], [2, 2]])

        // The tail alpha fires a partially integrated last character on the
        // tail frame (index T), contributing a zero row.
        let tail = ParaformerCIF.integrateAndFire(encoderRows: [[1, 1]], alphas: [0.7])
        XCTAssertEqual(tail.fireFrames, [1])
        XCTAssertEqual(tail.embeddings.count, 1)
        XCTAssertEqual(tail.embeddings[0][0], 0.7, accuracy: 1e-6)

        // Silence (alphas ≈ 0) fires nothing; empty input fires nothing.
        XCTAssertTrue(ParaformerCIF.integrateAndFire(encoderRows: [[1, 1], [1, 1]], alphas: [0.1, 0.1]).embeddings.isEmpty)
        XCTAssertEqual(ParaformerCIF.integrateAndFire(encoderRows: [], alphas: []), .init(embeddings: [], fireFrames: []))
        // Mismatched lengths: the shorter wins, nothing is read past it.
        XCTAssertEqual(ParaformerCIF.integrateAndFire(encoderRows: [[1]], alphas: [1, 1, 1]).fireFrames, [0])
        XCTAssertEqual(ParaformerGraph.cifThreshold, 1)
        XCTAssertEqual(ParaformerGraph.cifTailThreshold, 0.45)
    }

    // MARK: Text assembly

    func testTextAssemblyDropsSpecialsRejoinsBPEAndSpacesLatinWordsOnly() {
        let vocabulary: [Int: String] = [
            0: "<blank>", 1: "<s>", 2: "</s>", 3: "今", 4: "天", 5: "sa@@", 6: "f@@", 7: "ar@@", 8: "i",
            9: "浏", 10: "price", 11: "these", 12: ".", 13: "<unk>"
        ]
        XCTAssertEqual(ParaformerTextAssembler.text([1, 3, 4, 2], vocabulary: vocabulary), "今天")
        XCTAssertEqual(ParaformerTextAssembler.text([13, 3, 0, 4, 13], vocabulary: vocabulary), "今天", "<unk> and blank reach nothing")
        // English inside Mandarin: the BPE pieces become one word with a
        // space on each side (the library's own decode would leave
        // `sa@@f@@ar@@i` — measured 2026-09-16).
        XCTAssertEqual(ParaformerTextAssembler.text([3, 5, 6, 7, 8, 9], vocabulary: vocabulary), "今 safari 浏")
        XCTAssertEqual(ParaformerTextAssembler.text([10, 11], vocabulary: vocabulary), "price these")
        XCTAssertEqual(ParaformerTextAssembler.text([10, 12, 11], vocabulary: vocabulary), "price. these", "punctuation glues to the word before it")
        XCTAssertEqual(ParaformerTextAssembler.text([3, 12], vocabulary: vocabulary), "今.")
        XCTAssertEqual(ParaformerTextAssembler.text([5], vocabulary: vocabulary), "sa", "a dangling continuation is kept, not lost")
        XCTAssertEqual(ParaformerTextAssembler.text([], vocabulary: vocabulary), "")
        XCTAssertEqual(ParaformerTextAssembler.text([0, 1, 2], vocabulary: vocabulary), "")
        XCTAssertEqual(ParaformerTextAssembler.text([42], vocabulary: vocabulary), "", "an unknown id decodes to nothing")

        // Word positions carry the decoder positions for the token spans:
        // a merged word spans its first and last piece.
        let words = ParaformerTextAssembler.words([1, 3, 5, 6, 7, 8, 0, 9, 2], vocabulary: vocabulary)
        XCTAssertEqual(words, [
            .init(text: "今", firstPosition: 1, lastPosition: 1),
            .init(text: "safari", firstPosition: 2, lastPosition: 5),
            .init(text: "浏", firstPosition: 7, lastPosition: 7)
        ])
        XCTAssertEqual(ParaformerTextAssembler.words([5], vocabulary: vocabulary), [.init(text: "sa", firstPosition: 0, lastPosition: 0)])
    }

    // MARK: Language

    func testMandarinOnlyTakesNoHintAndAlwaysReportsChinese() async throws {
        let variant = ParakeetModelVariant.paraformerLargeZh
        XCTAssertEqual(TranscriptionLanguage.paraformerLargeZhLanguageCodes, ["zh"])
        XCTAssertTrue(TranscriptionLanguage.whisperLanguages.contains { $0.code == "zh" })
        for hint in ["zh", "en", "yue", nil] {
            XCTAssertNil(variant.runtimeLanguageHint(for: hint), "monolingual: no hint is ever sent (\(hint ?? "auto"))")
            XCTAssertEqual(variant.reportedLanguage(forHint: hint), "zh")
        }

        let fixture = try fixture()
        let runtime = FakeParakeetRuntime()
        runtime.transcript = ParakeetTranscript(
            text: "今天天气很好我们去公园散步吧",
            tokens: [ParakeetTokenSpan(text: "今", start: 0, end: 0.06), ParakeetTokenSpan(text: "吧", start: 3.0, end: 3.06)],
            runtimeReportedRealTimeFactor: nil,
            detectedLanguage: "zh"
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        XCTAssertEqual(runtime.batchConfigurations, [
            ParakeetRuntimeConfiguration(
                variant: .paraformerLargeZh, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .neuralEngineAndCPU
            )
        ])
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "en")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some(nil), "an English hint is dropped, not sent")
        XCTAssertEqual(result.text, "今天天气很好我们去公园散步吧")
        XCTAssertEqual(result.detectedLanguage, "zh")
        XCTAssertEqual(result.segments, [TranscriptSegment(start: .zero, end: .seconds(3.06), text: "今天天气很好我们去公园散步吧")])
        XCTAssertEqual(result.modelID, KvoiceFluidAudioModels.paraformerLargeZhModelID)

        // Without a runtime-reported language the variant's answer stands.
        runtime.transcript = ParakeetTranscript(text: "你好", detectedLanguage: nil)
        let auto = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: nil)) { _ in }
        XCTAssertEqual(auto.detectedLanguage, "zh")

        // No prompt (ADR-018 rule 3).
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)
    }

    func testStreamingIsRefusedAsBatchOnly() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime(decoderStreams: false)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: "zh", initialPrompt: nil) { _ in }
            XCTFail("expected streamingUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .streamingUnsupported(.paraformerLargeZh))
        }
        XCTAssertTrue(runtime.streamingConfigurations.isEmpty)
        XCTAssertEqual(runtime.sharedSessionHints, [])
    }

    func testLoadRefusesAPackageMissingAnyOfTheFourGraphs() async throws {
        for missing in [
            "model/ParaformerPreprocessor.mlmodelc", "model/ParaformerEncoder_int8.mlmodelc",
            "model/ParaformerCifAlphas.mlmodelc", "model/ParaformerDecoder_int8.mlmodelc"
        ] {
            let fixture = try fixture()
            let runtime = FakeParakeetRuntime()
            let manifest = fixture.package.manifest
            let trimmed = ModelManifest(
                schemaVersion: 1, modelID: manifest.modelID, family: manifest.family, format: manifest.format,
                workingSpaceBytes: manifest.workingSpaceBytes, source: manifest.source,
                runtimeCompatibility: manifest.runtimeCompatibility, tokenizer: manifest.tokenizer,
                files: manifest.files.filter { !$0.path.hasPrefix(missing) }
            )
            let canonical = try WhisperModelReleaseTrustAnchor.canonicalData(for: trimmed)
            try canonical.write(to: fixture.root.appendingPathComponent("ModelManifest.json"))
            let anchor = try WhisperModelReleaseTrustAnchor(
                manifestData: canonical, manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: trimmed)
            )
            let trimmedEngine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [anchor])
            let package = InstalledModelPackage(
                manifest: trimmed, packageURL: fixture.root,
                modelFolderURL: fixture.package.modelFolderURL, tokenizerFolderURL: fixture.package.tokenizerFolderURL,
                ownership: .managedByKvoice
            )
            do {
                try await trimmedEngine.load(package)
                XCTFail("expected a validation failure for \(missing)")
            } catch let error as ParakeetTranscriptionError {
                if case .invalidModelPackage = error {} else { XCTFail("\(error)") }
            }
            XCTAssertTrue(runtime.batchConfigurations.isEmpty, "refused before the runtime is asked (\(missing))")
        }
    }
}
