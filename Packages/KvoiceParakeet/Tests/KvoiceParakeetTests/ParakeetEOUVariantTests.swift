import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019 amendment (2026-09-16, fourth model): the Parakeet Realtime EOU
/// variant against the fake runtime and a fake-but-verifiable package, and
/// the pure support types. Nothing here loads Core ML or touches the
/// network; the live checks are in `LiveParakeetModelTests`.
final class ParakeetEOUVariantTests: XCTestCase {
    private var fixtures: [FakeParakeetPackage] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func fixture() throws -> FakeParakeetPackage {
        let fixture = try FakeParakeetPackage.make(variant: .parakeetEOU)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: Variant table

    func testVariantIsResolvedFromTheManifestAndDescribesThePackage() throws {
        let fixture = try fixture()
        XCTAssertEqual(ParakeetModelVariant(manifest: fixture.package.manifest), .parakeetEOU)
        XCTAssertEqual(fixture.package.manifest.family, "parakeet-realtime-eou-120m")
        XCTAssertEqual(fixture.package.manifest.source.subdirectory, "320ms")
        XCTAssertEqual(ParakeetModelVariant.parakeetEOU.requiredArtifactRoots, [
            "model/streaming_encoder.mlmodelc",
            "model/decoder.mlmodelc",
            "model/joint_decision.mlmodelc",
            "model/vocab.json"
        ])
        XCTAssertTrue(ParakeetModelVariant.parakeetEOU.supportsStreaming)
        XCTAssertFalse(ParakeetModelVariant.parakeetEOU.emitsPunctuation, "NVIDIA's card: no punctuation or capitalisation")
        XCTAssertEqual(ParakeetModelVariant.parakeetEOU.languageCodes, ["en"])
        // English only, so no hint is ever sent and `en` is always reported.
        XCTAssertNil(ParakeetModelVariant.parakeetEOU.runtimeLanguageHint(for: "en"))
        XCTAssertNil(ParakeetModelVariant.parakeetEOU.runtimeLanguageHint(for: "zh"))
        XCTAssertEqual(ParakeetModelVariant.parakeetEOU.reportedLanguage(forHint: nil), "en")
        XCTAssertEqual(ParakeetModelVariant.parakeetEOU.reportedLanguage(forHint: "de"), "en")
        // Checked for real on 2026-09-16, one process per choice: no abort,
        // no non-finite output, identical text.
        for units in SpeechComputeUnits.allCases {
            XCTAssertTrue(ParakeetModelVariant.parakeetEOU.supportsComputeUnits(units), units.rawValue)
        }
        // The generator preset and the variant name the same bundles.
        let configuration = try XCTUnwrap(
            ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceFluidAudioModels.parakeetEOUModelID)
        )
        XCTAssertEqual(
            Set(configuration.modelRoles.keys),
            Set(ParakeetModelVariant.parakeetEOU.requiredArtifactRoots.map { String($0.dropFirst("model/".count)) })
        )
        XCTAssertEqual(configuration.modelRoles["streaming_encoder.mlmodelc"], .audioEncoder)
        XCTAssertEqual(configuration.modelRoles["decoder.mlmodelc"], .textDecoder)
        XCTAssertEqual(configuration.modelRoles["joint_decision.mlmodelc"], .otherRequired)
        XCTAssertEqual(configuration.modelRoles["vocab.json"], .tokenizer)
        XCTAssertEqual(configuration.source.subdirectory, "320ms")
        XCTAssertEqual(configuration.tokenizer.relativeRoot, "model")
        XCTAssertNil(configuration.modelRoles[ParakeetEOUGraph.preprocessorBundleNotDownloaded], "0.15.7 never loads it")
    }

    // MARK: Pure support

    func testChunkGeometryMatchesThePinnedTier() {
        // `StreamingChunkSize.ms320` in the pinned source: 64 mel frames →
        // (64 − 1) × 160 samples per chunk, 32 × 160 per shift, 4 valid
        // encoder frames, one frame per 80 ms.
        XCTAssertEqual(ParakeetEOUGraph.chunkSamples, 10_080)
        XCTAssertEqual(ParakeetEOUGraph.shiftSamples, 5_120)
        XCTAssertEqual(ParakeetEOUGraph.validOutputFrames, 4)
        XCTAssertEqual(ParakeetEOUGraph.secondsPerFrame, 0.08)
        XCTAssertEqual(ParakeetEOUGraph.chunkTierMilliseconds, 320)
        XCTAssertEqual(ParakeetEOUGraph.shiftSamples * 1_000 / ParakeetEOUGraph.sampleRate, 320)
        XCTAssertEqual(ParakeetEOUGraph.endOfUtteranceTokenID, 1024)
        XCTAssertEqual(ParakeetEOUGraph.endOfBackchannelTokenID, 1025)
        XCTAssertEqual(ParakeetEOUGraph.blankTokenID, 1026)
    }

    func testTailPaddingReproducesTheManagersFinishPadding() {
        let chunk = ParakeetEOUGraph.chunkSamples
        let shift = ParakeetEOUGraph.shiftSamples
        // Nothing appended: nothing buffered, nothing to pad.
        XCTAssertEqual(ParakeetEOUChunking.bufferedSamples(afterAppending: 0), 0)
        XCTAssertEqual(ParakeetEOUChunking.tailPaddingSamples(afterAppending: 0), 0)
        // Shorter than a chunk: everything is buffered, padded up to one chunk.
        XCTAssertEqual(ParakeetEOUChunking.bufferedSamples(afterAppending: 1_000), 1_000)
        XCTAssertEqual(ParakeetEOUChunking.tailPaddingSamples(afterAppending: 1_000), chunk - 1_000)
        // Exactly one chunk: one pass, the overlap stays buffered.
        XCTAssertEqual(ParakeetEOUChunking.bufferedSamples(afterAppending: chunk), chunk - shift)
        XCTAssertEqual(ParakeetEOUChunking.tailPaddingSamples(afterAppending: chunk), shift)
        // The 11.6 s bundled sample and a 2 s recording, against a
        // simulation of the manager's loop.
        for appended in [185_600, 32_000, chunk + 1, chunk + shift - 1, chunk + shift, 3 * chunk] {
            var buffer = appended
            while buffer >= chunk { buffer -= shift }
            XCTAssertEqual(ParakeetEOUChunking.bufferedSamples(afterAppending: appended), buffer, "\(appended)")
            let padding = ParakeetEOUChunking.tailPaddingSamples(afterAppending: appended)
            XCTAssertEqual(buffer + padding, chunk, "\(appended): the padded tail is exactly one chunk")
            XCTAssertGreaterThan(padding, 0)
            XCTAssertLessThanOrEqual(padding, chunk)
        }
    }

    func testTokenSpansAndTheCleanedText() {
        let spans = ParakeetEOUTokens.spans(timestampsMilliseconds: [80, 240, 1_200], pieces: ["\u{2581}hello", "\u{2581}wor", "ld"])
        XCTAssertEqual(spans, [
            ParakeetTokenSpan(text: " hello", start: 0.08, end: 0.16),
            ParakeetTokenSpan(text: " wor", start: 0.24, end: 0.32),
            ParakeetTokenSpan(text: "ld", start: 1.2, end: 1.28)
        ])
        XCTAssertEqual(ParakeetEOUTokens.spans(timestampsMilliseconds: [80, 160], pieces: ["a"]).count, 1, "truncated, not padded")
        XCTAssertEqual(ParakeetEOUTokens.spans(timestampsMilliseconds: [], pieces: []), [])

        XCTAssertEqual(ParakeetEOUTokens.cleaned("hello world"), "hello world")
        XCTAssertEqual(ParakeetEOUTokens.cleaned("  hello   world \n"), "hello world")
        XCTAssertEqual(ParakeetEOUTokens.cleaned("uh huh<EOB> yes<EOU>"), "uh huh yes")
        XCTAssertEqual(ParakeetEOUTokens.cleaned("<unk>what is<unk> your name<EOU>"), "what is your name")
        XCTAssertEqual(ParakeetEOUTokens.cleaned("<EOU>"), "")
        XCTAssertEqual(ParakeetEOUTokens.cleaned(""), "")
    }

    // MARK: Engine

    func testTranscribeSendsNoHintReportsEnglishAndTakesNoPrompt() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime(decoderStreams: true)
        runtime.transcript = ParakeetTranscript(
            text: "what is your name",
            tokens: [ParakeetTokenSpan(text: " what", start: 0.32, end: 0.4), ParakeetTokenSpan(text: " name", start: 1.2, end: 1.28)]
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        XCTAssertEqual(runtime.batchConfigurations, [
            ParakeetRuntimeConfiguration(
                variant: .parakeetEOU, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .neuralEngineAndCPU
            )
        ])
        let result = try await engine.transcribe(
            TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "zh", initialPrompt: "Dictionary words")
        ) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some(nil), "English only: no hint, whatever the setting")
        XCTAssertEqual(result.text, "what is your name")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments, [TranscriptSegment(start: .seconds(0.32), end: .seconds(1.28), text: "what is your name")])
        XCTAssertEqual(result.modelID, KvoiceFluidAudioModels.parakeetEOUModelID)
        let factor = await engine.runtimeStatistics.lastRealTimeFactor
        XCTAssertNotNil(factor, "measured by the engine; the manager reports none")
        // No prompt (ADR-018 rule 3): the Dictionary section shows "no dictionary".
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)
        let count = await engine.promptTokenCount(of: "Dictionary words")
        XCTAssertNil(count)
    }

    func testStreamingRunsOverTheResidentGraphsAndSurfacesTheEndOfUtteranceScalarOnce() async throws {
        let fixture = try fixture()
        // The flag turns on after two seconds of audio and stays on, as the
        // manager's debounced `eouDetected` does in 0.15.7.
        let runtime = FakeParakeetRuntime(
            streamingPartials: ["what", "what is", "what is your name"],
            decoderStreams: true,
            endOfUtteranceAfterSamples: 32_000
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)

        let collector = EventCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { event in
            await collector.add(event)
        }
        XCTAssertEqual(runtime.streamingConfigurations, [], "the runtime is not asked for a streaming graph set")
        XCTAssertEqual(runtime.sharedSessionHints, [nil], "the session is opened without a hint")

        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0.1, count: 16_000))
        for _ in 0..<3 {
            await engine.appendStreamingAudio(chunk, jobID: jobID)
            await engine.awaitStreamingPasses()
        }
        await engine.endStreaming(jobID: jobID)
        let events = await collector.events
        // Partials as before; the scalar exactly once, after the partial of
        // the pass that flipped it, and never again while it stays true.
        XCTAssertEqual(events, [
            .partialText("what"),
            .partialText("what is"),
            .endOfUtteranceDetected(true),
            .partialText("what is your name")
        ])
        XCTAssertEqual(runtime.unloadedSessions, 1, "the session is reset, the pipeline stays")
        XCTAssertEqual(runtime.unloadedDecoders, 0)

        // The batch pass still follows on the same pipeline (ADR-017): the
        // inserted text never comes from the partials or the EOU signal.
        let result = try await engine.transcribe(TranscriptionRequest(jobID: jobID, audio: makeRecording(), languageHint: "en")) { _ in }
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(runtime.batchConfigurations.count, 1, "no second decoder was built")
    }

    func testAModelWithoutTheSignalNeverPublishesIt() async throws {
        // Nemotron's session takes the protocol default (false): no event.
        let nemotron = try FakeParakeetPackage.make(variant: .nemotronMultilingual)
        fixtures.append(nemotron)
        let runtime = FakeParakeetRuntime(streamingPartials: ["你", "你好"], decoderStreams: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [nemotron.anchor])
        try await engine.load(nemotron.package)
        let collector = EventCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "zh", initialPrompt: nil) { event in
            await collector.add(event)
        }
        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0.1, count: 16_000))
        for _ in 0..<2 {
            await engine.appendStreamingAudio(chunk, jobID: jobID)
            await engine.awaitStreamingPasses()
        }
        await engine.endStreaming(jobID: jobID)
        let events = await collector.events
        XCTAssertEqual(events, [.partialText("你"), .partialText("你好")])
    }

    func testTheEndOfUtteranceScalarIsIgnoredByTheJobRunnerSeam() {
        // The runner keeps partial text and nothing else from the stream
        // (`DictationJobRunner.receiveTranscriptionEvent`); the domain event
        // is Equatable and scalar so it can be matched and logged, and it
        // carries no text.
        let event = TranscriptionEvent.endOfUtteranceDetected(true)
        XCTAssertNotEqual(event, .endOfUtteranceDetected(false))
        if case .partialText = event { XCTFail("the scalar must not look like partial text") }
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

    func testLoadRefusesAPackageMissingTheJointOrTheVocabulary() async throws {
        for missing in ["model/joint_decision.mlmodelc", "model/vocab.json"] {
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
            XCTAssertTrue(runtime.batchConfigurations.isEmpty)
        }
    }
}

private actor EventCollector {
    var events: [TranscriptionEvent] = []
    func add(_ event: TranscriptionEvent) { events.append(event) }
}
