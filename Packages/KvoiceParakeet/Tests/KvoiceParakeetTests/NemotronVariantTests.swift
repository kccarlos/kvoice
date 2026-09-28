import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019 amendment (2026-09-16): the Nemotron 3.5 ASR Streaming
/// Multilingual variant against the fake runtime and a fake-but-verifiable
/// package. Nothing here loads Core ML or touches the network; the live
/// checks are in `LiveParakeetModelTests`.
final class NemotronVariantTests: XCTestCase {
    private var fixtures: [FakeParakeetPackage] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func fixture() throws -> FakeParakeetPackage {
        let fixture = try FakeParakeetPackage.make(variant: .nemotronMultilingual)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: Variant table

    func testVariantIsResolvedFromTheManifestAndDescribesThePackage() throws {
        let fixture = try fixture()
        XCTAssertEqual(ParakeetModelVariant(manifest: fixture.package.manifest), .nemotronMultilingual)
        XCTAssertEqual(fixture.package.manifest.family, "nemotron-3.5-asr-streaming-multilingual-0.6b")
        XCTAssertEqual(fixture.package.manifest.source.subdirectory, "multilingual/2240ms")
        XCTAssertEqual(ParakeetModelVariant.nemotronMultilingual.requiredArtifactRoots, [
            "model/encoder.mlmodelc",
            "model/decoder.mlmodelc",
            "model/joint.mlmodelc",
            "model/decoder_joint.mlmodelc",
            "model/metadata.json",
            "model/tokenizer.json"
        ])
        XCTAssertTrue(ParakeetModelVariant.nemotronMultilingual.supportsStreaming)
        XCTAssertTrue(ParakeetModelVariant.nemotronMultilingual.emitsPunctuation)
        XCTAssertEqual(ParakeetModelVariant.nemotronMultilingual.languageCodes.count, 64)
        // Checked for real on 2026-09-16, one process per choice: no abort.
        for units in SpeechComputeUnits.allCases {
            XCTAssertTrue(ParakeetModelVariant.nemotronMultilingual.supportsComputeUnits(units), units.rawValue)
        }
        // The generator preset and the variant name the same bundles.
        let configuration = try XCTUnwrap(
            ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceFluidAudioModels.nemotronMultilingualModelID)
        )
        XCTAssertEqual(
            Set(configuration.modelRoles.keys),
            Set(ParakeetModelVariant.nemotronMultilingual.requiredArtifactRoots.map { String($0.dropFirst("model/".count)) })
        )
        XCTAssertEqual(configuration.modelRoles["encoder.mlmodelc"], .audioEncoder)
        XCTAssertEqual(configuration.modelRoles["decoder.mlmodelc"], .textDecoder)
        XCTAssertEqual(configuration.modelRoles["tokenizer.json"], .tokenizer)
        XCTAssertEqual(configuration.source.subdirectory, "multilingual/2240ms")
        XCTAssertEqual(configuration.tokenizer.relativeRoot, "model")
    }

    // MARK: Language coverage and prompt keys

    func testEveryCoveredCodeIsAWhisperCodeWithAPromptKey() {
        let whisper = Set(TranscriptionLanguage.whisperLanguages.map(\.code))
        let codes = TranscriptionLanguage.nemotronMultilingualLanguageCodes
        XCTAssertEqual(Set(codes).count, codes.count, "no duplicates")
        for code in codes {
            XCTAssertTrue(whisper.contains(code), "\(code) is not a Whisper code")
            let key = ParakeetModelVariant.nemotronPromptKey(forLanguageCode: code)
            XCTAssertNotNil(key, code)
            XCTAssertTrue(key!.hasPrefix(code), "\(code) → \(key!)")
        }
        for code in ["zh", "ja", "ko", "en", "de"] {
            XCTAssertTrue(codes.contains(code), "the target languages and the Latin six are covered")
        }
        XCTAssertNil(ParakeetModelVariant.nemotronPromptKey(forLanguageCode: "yue"))
        XCTAssertNil(ParakeetModelVariant.nemotronPromptKey(forLanguageCode: "sq"))
    }

    func testLanguageHintsMapToPromptKeysAndTagsMapBack() {
        let variant = ParakeetModelVariant.nemotronMultilingual
        XCTAssertEqual(variant.runtimeLanguageHint(for: "zh"), "zh-CN", "Simplified Chinese by default")
        XCTAssertEqual(variant.runtimeLanguageHint(for: "ja"), "ja-JP")
        XCTAssertEqual(variant.runtimeLanguageHint(for: "ko"), "ko-KR")
        XCTAssertEqual(variant.runtimeLanguageHint(for: "de"), "de", "a bare key where the dictionary has one")
        XCTAssertEqual(variant.runtimeLanguageHint(for: "en"), "en")
        XCTAssertNil(variant.runtimeLanguageHint(for: "yue"), "outside coverage → auto")
        XCTAssertNil(variant.runtimeLanguageHint(for: nil))
        // Every offered code round-trips: hint → prompt key → (as a tag the
        // model could emit) → the same Whisper code, and the fallback
        // reported language is the code itself.
        for code in TranscriptionLanguage.nemotronMultilingualLanguageCodes {
            let hint = variant.runtimeLanguageHint(for: code)
            XCTAssertEqual(hint, ParakeetModelVariant.nemotronPromptKey(forLanguageCode: code), code)
            XCTAssertEqual(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: hint!), code, "\(code) → \(hint!)")
            XCTAssertEqual(variant.reportedLanguage(forHint: code), code)
        }

        XCTAssertEqual(variant.reportedLanguage(forHint: "zh"), "zh", "fallback when the model emits no tag")
        XCTAssertNil(variant.reportedLanguage(forHint: "yue"))
        XCTAssertNil(variant.reportedLanguage(forHint: nil))

        XCTAssertEqual(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: "es-419"), "es")
        XCTAssertEqual(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: "zh-CN"), "zh")
        XCTAssertEqual(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: "en"), "en")
        XCTAssertEqual(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: "nb-NO"), "no", "Bokmål is Whisper's Norwegian")
        XCTAssertNil(ParakeetModelVariant.nemotronLanguageCode(forReportedTag: "xx-YY"))
    }

    // MARK: Engine

    func testTranscribePassesThePromptKeyAndPrefersTheRuntimeReportedLanguage() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime(decoderStreams: true)
        runtime.transcript = ParakeetTranscript(
            text: "你好世界",
            tokens: [ParakeetTokenSpan(text: "你好", start: 0.1, end: 0.6), ParakeetTokenSpan(text: "世界", start: 0.7, end: 1.2)],
            runtimeReportedRealTimeFactor: nil,
            detectedLanguage: "zh"
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        XCTAssertEqual(runtime.batchConfigurations, [
            ParakeetRuntimeConfiguration(
                variant: .nemotronMultilingual, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .neuralEngineAndCPU
            )
        ])

        // The hint is the model's own key; the language comes from the tag.
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "ja")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some("ja-JP"))
        XCTAssertEqual(result.text, "你好世界")
        XCTAssertEqual(result.detectedLanguage, "zh", "the tag the model emitted wins over the hint")
        XCTAssertEqual(result.segments, [TranscriptSegment(start: .seconds(0.1), end: .seconds(1.2), text: "你好世界")])
        XCTAssertEqual(result.modelID, KvoiceFluidAudioModels.nemotronMultilingualModelID)
        let factor = await engine.runtimeStatistics.lastRealTimeFactor
        XCTAssertNotNil(factor, "measured by the engine when the runtime reports none")

        // No tag: the accepted hint is reported; an uncovered hint is auto.
        runtime.transcript = ParakeetTranscript(text: "hallo", detectedLanguage: nil)
        let german = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "de")) { _ in }
        XCTAssertEqual(german.detectedLanguage, "de")
        let auto = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "yue")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some(nil))
        XCTAssertNil(auto.detectedLanguage)

        // No prompt (ADR-018 rule 3).
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)
    }

    func testStreamingRunsOverTheResidentGraphsAndNeverAsksTheRuntimeForASecondSet() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime(streamingPartials: ["你", "你好", "你好世界"], decoderStreams: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)

        let collector = PartialCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "zh", initialPrompt: nil) { event in
            if case let .partialText(text) = event { await collector.add(text) }
        }
        XCTAssertEqual(runtime.streamingConfigurations, [], "the runtime is not asked for a streaming graph set")
        XCTAssertEqual(runtime.sharedSessionHints, ["zh-CN"], "the session is opened with the prompt key")

        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0.1, count: 16_000))
        for _ in 0..<3 {
            await engine.appendStreamingAudio(chunk, jobID: jobID)
            await engine.awaitStreamingPasses()
        }
        await engine.endStreaming(jobID: jobID)
        let partials = await collector.partials
        XCTAssertEqual(partials, ["你", "你好", "你好世界"])
        XCTAssertEqual(runtime.unloadedSessions, 1, "the session is reset, the pipeline stays")
        XCTAssertEqual(runtime.unloadedDecoders, 0)

        // The batch pass still follows on the same pipeline (ADR-017).
        let result = try await engine.transcribe(TranscriptionRequest(jobID: jobID, audio: makeRecording(), languageHint: "zh")) { _ in }
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(runtime.batchConfigurations.count, 1, "no second decoder was built")
    }

    func testAVariantWhoseDecoderOffersNoSessionStillStreamsThroughTheRuntime() async throws {
        // Unified keeps its own streaming export: the runtime is asked.
        let unified = try FakeParakeetPackage.make(variant: .unifiedEN)
        fixtures.append(unified)
        let runtime = FakeParakeetRuntime(decoderStreams: false)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [unified.anchor])
        try await engine.load(unified.package)
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { _ in }
        XCTAssertEqual(runtime.streamingConfigurations.count, 1)
        XCTAssertEqual(runtime.sharedSessionHints, [])
        await engine.endStreaming(jobID: jobID)
    }

    func testTheRefusalMessageNamesTheChoicesTheVariantAccepts() {
        let unified = ParakeetTranscriptionError.computeUnitsUnsupported(.unifiedEN, .gpuAndCPU).errorDescription ?? ""
        XCTAssertTrue(unified.hasSuffix("Choose Neural Engine + CPU, All, CPU only in Speech Models › Runtime."), unified)
        XCTAssertTrue(unified.hasPrefix("parakeet-unified-en-0.6b cannot run under GPU + CPU"), unified)
        // The runtime's invariant error is not the user-facing "batch only".
        let invariant = ParakeetTranscriptionError.streamingSessionUnavailable(.nemotronMultilingual).errorDescription ?? ""
        XCTAssertTrue(invariant.contains("resident pipeline"), invariant)
        XCTAssertNotEqual(invariant, ParakeetTranscriptionError.streamingUnsupported(.nemotronMultilingual).errorDescription)
    }

    func testEveryComputeUnitChoiceReloadsRatherThanRefuses() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        for units in [SpeechComputeUnits.gpuAndCPU, .all, .cpuOnly, .neuralEngineAndCPU] {
            try await engine.setComputeUnits(units)
            XCTAssertEqual(runtime.batchConfigurations.last?.computeUnits, units)
        }
        XCTAssertEqual(runtime.batchConfigurations.count, 5, "one load plus four reloads")
    }

    func testLoadRefusesAPackageMissingTheFusedDecoderOrTheMetadata() async throws {
        for missing in ["model/decoder_joint.mlmodelc", "model/metadata.json"] {
            let fixture = try fixture()
            let runtime = FakeParakeetRuntime()
            // Drop the entry from the manifest and rebuild the anchor: the
            // validator must miss the required artifact before Core ML.
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
                // The file is still on disk, so it is an unexpected entry or
                // a missing required artifact — either way, refused before
                // the runtime is asked.
                if case .invalidModelPackage = error {} else { XCTFail("\(error)") }
            }
            XCTAssertTrue(runtime.batchConfigurations.isEmpty)
        }
    }
}

private actor PartialCollector {
    var partials: [String] = []
    func add(_ text: String) { partials.append(text) }
}
