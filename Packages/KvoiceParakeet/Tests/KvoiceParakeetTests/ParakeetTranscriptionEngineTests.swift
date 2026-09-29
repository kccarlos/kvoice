import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019: the engine against a fake runtime and a fake-but-verifiable
/// package. Nothing here loads Core ML or touches the network.
final class ParakeetTranscriptionEngineTests: XCTestCase {
    private var fixtures: [FakeParakeetPackage] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func fixture(_ variant: ParakeetModelVariant, extraFiles: [String: Data] = [:]) throws -> FakeParakeetPackage {
        let fixture = try FakeParakeetPackage.make(variant: variant, extraFiles: extraFiles)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: Variant

    func testVariantIsResolvedFromTheManifestFamilyAndFormat() throws {
        let tdt = try fixture(.tdtV3)
        XCTAssertEqual(ParakeetModelVariant(manifest: tdt.package.manifest), .tdtV3)
        let unified = try fixture(.unifiedEN)
        XCTAssertEqual(ParakeetModelVariant(manifest: unified.package.manifest), .unifiedEN)
        XCTAssertEqual(ParakeetModelVariant.allCases, [.tdtV3, .unifiedEN, .nemotronMultilingual, .senseVoiceSmall, .paraformerLargeZh, .parakeetEOU])

        let whisper = ModelManifest(
            schemaVersion: 1, modelID: "x", family: "whisper-large-v3-turbo", format: "whisperkit-coreml",
            workingSpaceBytes: 1, source: ModelManifestSource(repository: "a/b", revision: "c", subdirectory: ""),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: "p", exactVersion: "1"),
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"), files: []
        )
        XCTAssertNil(ParakeetModelVariant(manifest: whisper))
    }

    func testLanguageHintsFollowTheModelCoverage() {
        XCTAssertEqual(ParakeetModelVariant.tdtV3.runtimeLanguageHint(for: "de"), "de")
        XCTAssertNil(ParakeetModelVariant.tdtV3.runtimeLanguageHint(for: "zh"), "outside coverage → auto")
        XCTAssertNil(ParakeetModelVariant.tdtV3.runtimeLanguageHint(for: nil))
        XCTAssertNil(ParakeetModelVariant.unifiedEN.runtimeLanguageHint(for: "en"), "English-only, takes no hint")
        XCTAssertEqual(ParakeetModelVariant.unifiedEN.reportedLanguage(forHint: nil), "en")
        XCTAssertNil(ParakeetModelVariant.tdtV3.reportedLanguage(forHint: "zh"))
        XCTAssertEqual(ParakeetModelVariant.tdtV3.languageCodes.count, 25)
        XCTAssertFalse(ParakeetModelVariant.tdtV3.supportsStreaming)
        XCTAssertTrue(ParakeetModelVariant.unifiedEN.supportsStreaming)
        XCTAssertTrue(ParakeetModelVariant.tdtV3.emitsPunctuation, "NVIDIA lists punctuation for v3 and the live sample confirmed it")
        XCTAssertTrue(ParakeetModelVariant.unifiedEN.emitsPunctuation)
    }

    // MARK: Load

    func testLoadValidatesThenBuildsTheDecoderFromTheModelFolderUnderTheChosenUnits() async throws {
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.setComputeUnits(.cpuOnly)

        try await engine.load(fixture.package)

        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
        let variant = await engine.loadedVariant
        XCTAssertEqual(variant, .tdtV3)
        XCTAssertEqual(runtime.batchConfigurations, [
            ParakeetRuntimeConfiguration(variant: .tdtV3, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .cpuOnly)
        ])
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastLoadDuration)
        if case .ready = await engine.state {} else { XCTFail("expected ready") }
    }

    // MARK: Warm-up after load (ADR-022 item 8)

    func testLoadWarmsUpTheDecoderOnceWithSilentAudioAndDiscardsTheResult() async throws {
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        let diagnostics = RecordingDiagnostics()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)

        try await engine.load(fixture.package)
        try await engine.load(fixture.package) // resident: no second warm-up

        XCTAssertEqual(runtime.decodedPasses.count, 1, "exactly one warm-up per load")
        XCTAssertEqual(runtime.decodedPasses.first?.sampleCount, 16_000, "one second at 16 kHz")
        XCTAssertLessThanOrEqual(runtime.decodedPasses.first?.peak ?? 1, WarmUpAudio.peakAmplitude, "near-silent")
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastWarmUpDuration)
        XCTAssertNil(statistics.lastRealTimeFactor, "the warm-up is not counted as a pass")
        XCTAssertNil(statistics.lastInferenceDuration)
        let events = await diagnostics.events
        XCTAssertEqual(events.map(\.name), [.modelWarmUpCompleted])
        XCTAssertEqual(events.first?.result, .success)
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "warmUp")

        // A compute-unit reload is a fresh Core ML load and warms up again.
        try await engine.setComputeUnits(.cpuOnly)
        XCTAssertEqual(runtime.decodedPasses.count, 2)
        // A real pass afterwards is the first thing the statistics count.
        _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording()), events: { _ in })
        let after = await engine.runtimeStatistics
        XCTAssertEqual(after.lastRealTimeFactor, 0.05)
        XCTAssertNotNil(after.lastWarmUpDuration)
    }

    func testWarmUpFailureIsSwallowedWithOneScalarEventAndTheLoadStands() async throws {
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        runtime.decodeError = CocoaError(.fileReadCorruptFile)
        let diagnostics = RecordingDiagnostics()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)

        try await engine.load(fixture.package)

        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetTDTv3ModelID, "a failed warm-up never fails the load")
        if case .ready = await engine.state {} else { XCTFail("expected ready") }
        let statistics = await engine.runtimeStatistics
        XCTAssertNil(statistics.lastWarmUpDuration)
        let events = await diagnostics.events
        XCTAssertEqual(events.map(\.name), [.modelWarmUpCompleted])
        XCTAssertEqual(events.first?.result, .warning)
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "warmupFailed")
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "warmUp")
    }

    /// 2026-09-29: a decoder that was built is finished Core ML work; a
    /// cancellation that lands during its warm-up no longer throws it away.
    func testLoadCancelledDuringWarmUpKeepsTheBuiltDecoderResident() async throws {
        let fixture = try fixture(.tdtV3)
        let gate = LoadGate()
        let runtime = FakeParakeetRuntime(warmUpGate: gate)
        let diagnostics = RecordingDiagnostics()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)

        let load = Task { try await engine.load(fixture.package) }
        while runtime.decodedPasses.isEmpty { await Task.yield() }
        // Still loading while the warm-up runs: the start gate must not see
        // a resident model yet.
        let midLoad = await engine.loadedModelID
        XCTAssertNil(midLoad)
        if case .loading = await engine.state {} else { XCTFail("expected loading during the warm-up") }

        load.cancel()
        await gate.open()
        try await load.value

        XCTAssertEqual(runtime.unloadedDecoders, 0, "the built decoder is not released")
        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
        if case .ready = await engine.state {} else { XCTFail("expected ready") }
        let events = await diagnostics.events
        XCTAssertFalse(events.contains { $0.attributes.reason?.rawValue == "loadCancelled" })
    }

    /// The owner's `loadCancelled` case: the task is cancelled while Core ML
    /// is still building (the build cannot be interrupted); the finished
    /// decoder becomes resident instead of being discarded.
    func testLoadCancelledWhileTheDecoderIsBuildingKeepsItResident() async throws {
        let fixture = try fixture(.tdtV3)
        let gate = LoadGate()
        let runtime = FakeParakeetRuntime(gate: gate)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])

        let load = Task { try await engine.load(fixture.package) }
        while runtime.batchConfigurations.isEmpty { await Task.yield() }
        load.cancel()
        await gate.open()
        try await load.value

        XCTAssertEqual(runtime.unloadedDecoders, 0)
        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
    }

    /// A replacement cancelled before it starts leaves the resident decoder.
    func testACancelledReplacementLeavesTheResidentDecoderUntouched() async throws {
        let fixture = try fixture(.tdtV3)
        let other = try self.fixture(.unifiedEN)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor, other.anchor])
        try await engine.load(fixture.package)

        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.load(other.package)
        }
        do {
            try await load.value
            XCTFail("a cancelled replacement must not succeed")
        } catch is CancellationError {}
        XCTAssertEqual(runtime.unloadedDecoders, 0)
        XCTAssertEqual(runtime.batchConfigurations.count, 1)
        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
        if case .ready = await engine.state {} else { XCTFail("expected ready") }
    }

    /// Cancellation before Core ML starts is still honoured: nothing built.
    func testLoadCancelledBeforeTheBuildStartsBuildsNothing() async throws {
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])

        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.load(fixture.package)
        }
        do {
            try await load.value
            XCTFail("a load cancelled before its build must not succeed")
        } catch is CancellationError {}
        XCTAssertTrue(runtime.batchConfigurations.isEmpty)
        let loaded = await engine.loadedModelID
        XCTAssertNil(loaded)
    }

    /// 2026-09-14 slice-2 review: a second `load` during a load's warm-up is
    /// refused, never interleaved with the build in flight.
    func testASecondLoadDuringTheWarmUpIsRefusedAndTheFirstCompletes() async throws {
        let fixture = try fixture(.tdtV3)
        let other = try self.fixture(.unifiedEN)
        let gate = LoadGate()
        let runtime = FakeParakeetRuntime(warmUpGate: gate)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor, other.anchor])

        let first = Task { try await engine.load(fixture.package) }
        while runtime.decodedPasses.isEmpty { await Task.yield() }

        do {
            try await engine.load(other.package)
            XCTFail("a load during another load's warm-up must be refused")
        } catch ParakeetTranscriptionError.loadInProgress {}
        if case .loading = await engine.state {} else { XCTFail("the refusal changes nothing about the load in flight") }

        await gate.open()
        try await first.value

        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
        XCTAssertEqual(runtime.batchConfigurations.count, 1, "the second load never reached the runtime")
        XCTAssertEqual(runtime.unloadedDecoders, 0)
        // Not wedged: the next load goes through (its warm-up passes the open gate).
        try await engine.load(other.package)
        let afterwards = await engine.loadedVariant
        XCTAssertEqual(afterwards, .unifiedEN)
    }

    // MARK: Load-failure diagnostics (ADR-022 item 9)

    func testEveryLoadFailureEmitsOneScalarEventNamingItsSite() async throws {
        // Runtime construction fails.
        do {
            let fixture = try fixture(.tdtV3)
            let runtime = FakeParakeetRuntime()
            runtime.loadError = CocoaError(.fileReadCorruptFile)
            let diagnostics = RecordingDiagnostics()
            let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)
            do { try await engine.load(fixture.package); XCTFail("expected a failure") } catch {}
            let events = await diagnostics.events
            XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
            XCTAssertEqual(events.first?.result, .failure)
            XCTAssertEqual(events.first?.errorCode, .modelLoadFailed)
            XCTAssertEqual(events.first?.attributes.site?.rawValue, "runtimeMake")
            XCTAssertEqual(events.first?.attributes.reason?.rawValue, "runtimeLoadFailed")
            let encoded = try JSONEncoder().encode(events.first)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(fixture.package.modelFolderURL.path), "never a path")
        }
        // The Unified encoder refuses the GPU before any runtime call.
        do {
            let fixture = try fixture(.unifiedEN)
            let runtime = FakeParakeetRuntime()
            let diagnostics = RecordingDiagnostics()
            let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)
            try await engine.setComputeUnits(.gpuAndCPU)
            do { try await engine.load(fixture.package); XCTFail("expected a refusal") } catch {}
            let events = await diagnostics.events
            XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
            XCTAssertEqual(events.first?.attributes.site?.rawValue, "computeUnits")
            XCTAssertEqual(events.first?.attributes.reason?.rawValue, "computeUnitsUnsupported")
            XCTAssertTrue(runtime.batchConfigurations.isEmpty)
        }
        // The package fails validation.
        do {
            let fixture = try fixture(.tdtV3)
            try Data("stray".utf8).write(to: fixture.root.appendingPathComponent("model/stray.bin"))
            let runtime = FakeParakeetRuntime()
            let diagnostics = RecordingDiagnostics()
            let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor], diagnostics: diagnostics)
            do { try await engine.load(fixture.package); XCTFail("expected a refusal") } catch {}
            let events = await diagnostics.events
            XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
            XCTAssertEqual(events.first?.attributes.site?.rawValue, "validatePackage")
            XCTAssertEqual(events.first?.attributes.reason?.rawValue, "invalidModelPackage")
        }
    }

    func testLoadRefusesAPackageWhoseManifestIsNotATrustedAnchor() async throws {
        let fixture = try fixture(.tdtV3)
        let other = try self.fixture(.unifiedEN)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [other.anchor])

        do {
            try await engine.load(fixture.package)
            XCTFail("expected a validation failure")
        } catch let ParakeetTranscriptionError.invalidModelPackage(error) {
            XCTAssertEqual(error, .untrustedReleaseManifest)
        }
        XCTAssertTrue(runtime.batchConfigurations.isEmpty, "nothing reaches the runtime")
        let loaded = await engine.loadedModelID
        XCTAssertNil(loaded)
    }

    func testLoadRefusesATamperedFileAndAnUnallowlistedExtraFile() async throws {
        let tampered = try fixture(.tdtV3)
        try Data("changed".utf8).write(to: tampered.root.appendingPathComponent("model/Decoder.mlmodelc/coremldata.bin"))
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [tampered.anchor])
        do {
            try await engine.load(tampered.package)
            XCTFail("expected a hash failure")
        } catch let ParakeetTranscriptionError.invalidModelPackage(error) {
            if case .byteCountMismatch = error {} else if case .hashMismatch = error {} else {
                XCTFail("unexpected \(error)")
            }
        }

        let extra = try fixture(.unifiedEN)
        try Data("stray".utf8).write(to: extra.root.appendingPathComponent("model/stray.bin"))
        let engine2 = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [extra.anchor])
        do {
            try await engine2.load(extra.package)
            XCTFail("expected an unexpected-file failure")
        } catch let ParakeetTranscriptionError.invalidModelPackage(error) {
            XCTAssertEqual(error, .unexpectedFile("model/stray.bin"))
        }
    }

    func testLoadRefusesAManifestMissingARequiredArtifact() async throws {
        let fixture = try fixture(.tdtV3)
        // Drop the joint from the manifest and the disk, re-anchor: still a
        // consistent package, but not a runnable one.
        var files = fixture.package.manifest.files
        files.removeAll { $0.path.hasPrefix("model/JointDecisionv3.mlmodelc") }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("model/JointDecisionv3.mlmodelc"))
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: fixture.package.manifest.modelID, family: fixture.package.manifest.family,
            format: fixture.package.manifest.format, workingSpaceBytes: 1, source: fixture.package.manifest.source,
            runtimeCompatibility: fixture.package.manifest.runtimeCompatibility,
            tokenizer: fixture.package.manifest.tokenizer, files: files
        )
        let canonical = try WhisperModelReleaseTrustAnchor.canonicalData(for: manifest)
        try canonical.write(to: fixture.root.appendingPathComponent("ModelManifest.json"))
        let anchor = try WhisperModelReleaseTrustAnchor(manifestData: canonical, manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: manifest))
        let package = InstalledModelPackage(
            manifest: manifest, packageURL: fixture.root, modelFolderURL: fixture.package.modelFolderURL,
            tokenizerFolderURL: fixture.package.tokenizerFolderURL, ownership: .managedByKvoice
        )
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [anchor])
        do {
            try await engine.load(package)
            XCTFail("expected a missing-artifact failure")
        } catch let ParakeetTranscriptionError.invalidModelPackage(error) {
            XCTAssertEqual(error, .requiredArtifactMissing("model/JointDecisionv3.mlmodelc"))
        }
    }

    // MARK: Transcribe

    func testTranscribeMapsTheRuntimeTranscriptAndFiltersTheLanguageHint() async throws {
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)

        var phases: [TranscriptionPhase] = []
        let collector = PhaseCollector()
        let request = TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "zh")
        let result = try await engine.transcribe(request) { event in
            if case let .phase(phase) = event { await collector.add(phase) }
        }
        phases = await collector.phases

        XCTAssertEqual(result.text, "hello world")
        XCTAssertNil(result.detectedLanguage, "TDT with an uncovered hint reports no language")
        XCTAssertEqual(result.segments, [TranscriptSegment(start: .seconds(0.2), end: .seconds(1.0), text: "hello world")])
        XCTAssertEqual(result.timings.runtimeReportedRealTimeFactor, 0.05)
        XCTAssertEqual(result.modelID, KvoiceFluidAudioModels.parakeetTDTv3ModelID)
        XCTAssertEqual(runtime.lastLanguageHint, .some(nil), "zh is outside TDT coverage → auto")
        XCTAssertEqual(phases, [.preparingAudio, .encoding, .decoding, .finalizing])
        let statistics = await engine.runtimeStatistics
        XCTAssertEqual(statistics.lastRealTimeFactor, 0.05)
        XCTAssertNotNil(statistics.lastInferenceDuration)

        _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "de")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some("de"))
    }

    func testTranscribeWithoutAModelOrWithBadAudioIsRefused() async throws {
        let fixture = try fixture(.unifiedEN)
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [fixture.anchor])
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording())) { _ in }
            XCTFail("expected noModelLoaded")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .noModelLoaded)
        }
        try await engine.load(fixture.package)
        let stereo = AudioRecording(samples: [0, 0], sampleRate: 44_100, channelCount: 2, duration: .seconds(1), peakLevelDBFS: -10, clippedFrameCount: 0)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: stereo)) { _ in }
            XCTFail("expected invalidAudio")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .invalidAudio(sampleRate: 44_100, channelCount: 2))
        }
    }

    func testAnEmptyTranscriptIsAResultNotAFailure() async throws {
        let fixture = try fixture(.unifiedEN)
        let runtime = FakeParakeetRuntime()
        runtime.transcript = ParakeetTranscript(text: "  ")
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording())) { _ in }
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.segments, [])
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertNotNil(result.timings.inferenceEnd)
    }

    // MARK: Dictionary (ADR-018)

    func testPromptLimitIsUnsupportedWhileLoadedAndNilOtherwise() async throws {
        let fixture = try fixture(.tdtV3)
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [fixture.anchor])
        var limit = await engine.promptTokenLimit
        XCTAssertNil(limit)
        try await engine.load(fixture.package)
        limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)
        let count = await engine.promptTokenCount(of: "Glossary: kvoice.")
        XCTAssertNil(count)
    }

    // MARK: Compute units

    func testSetComputeUnitsReloadsUnderTheNewUnitsAndFallsBackOnFailure() async throws {
        // TDT: every choice is allowed (Unified refuses the GPU, tested below).
        let fixture = try fixture(.tdtV3)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        XCTAssertEqual(runtime.batchConfigurations.map(\.computeUnits), [.neuralEngineAndCPU])

        try await engine.setComputeUnits(.gpuAndCPU)
        XCTAssertEqual(runtime.batchConfigurations.map(\.computeUnits), [.neuralEngineAndCPU, .gpuAndCPU])
        XCTAssertEqual(runtime.unloadedDecoders, 1, "the previous pipeline is released before the new one loads")
        var units = await engine.currentComputeUnits
        XCTAssertEqual(units, .gpuAndCPU)

        runtime.loadError = CocoaError(.fileReadCorruptFile)
        do {
            try await engine.setComputeUnits(.cpuOnly)
            XCTFail("expected the reload to fail")
        } catch {}
        units = await engine.currentComputeUnits
        XCTAssertEqual(units, .gpuAndCPU, "a failed reload keeps the previous units")

        // Unchanged choice: no reload.
        runtime.loadError = nil
        let before = runtime.batchConfigurations.count
        try await engine.setComputeUnits(.gpuAndCPU)
        XCTAssertEqual(runtime.batchConfigurations.count, before)
    }

    func testUnifiedRefusesTheGPUChoiceBeforeAnyRuntimeCall() async throws {
        XCTAssertFalse(ParakeetModelVariant.unifiedEN.supportsComputeUnits(.gpuAndCPU))
        XCTAssertTrue(ParakeetModelVariant.unifiedEN.supportsComputeUnits(.all))
        XCTAssertTrue(ParakeetModelVariant.tdtV3.supportsComputeUnits(.gpuAndCPU))

        let fixture = try fixture(.unifiedEN)
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        do {
            try await engine.setComputeUnits(.gpuAndCPU)
            XCTFail("expected computeUnitsUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .computeUnitsUnsupported(.unifiedEN, .gpuAndCPU))
        }
        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .neuralEngineAndCPU, "the stored choice is unchanged")
        XCTAssertEqual(runtime.batchConfigurations.count, 1, "no reload was attempted")
        let loaded = await engine.loadedModelID
        XCTAssertNotNil(loaded, "the resident model stays")

        // A persisted GPU choice refuses the load with the same message and
        // leaves the engine in an error state the card can show.
        let cold = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await cold.setComputeUnits(.gpuAndCPU)
        do {
            try await cold.load(fixture.package)
            XCTFail("expected computeUnitsUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .computeUnitsUnsupported(.unifiedEN, .gpuAndCPU))
        }
        if case .error = await cold.state {} else { XCTFail("expected an error state") }
        XCTAssertEqual(runtime.batchConfigurations.count, 1)
    }

    /// The refusal must hold while the model is *loading*: `currentVariant`
    /// is nil for the duration, so a click that lands mid-load used to skip
    /// the check, store GPU + CPU, and the reload loop then built the Unified
    /// encoder under it — the abort the refusal exists to prevent.
    func testUnifiedRefusesTheGPUChoiceWhileItIsStillLoading() async throws {
        let fixture = try fixture(.unifiedEN)
        let gate = LoadGate()
        let runtime = FakeParakeetRuntime(gate: gate)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])

        let load = Task { try await engine.load(fixture.package) }
        await gate.waitUntilEntered()

        // Mid-flight: the engine is suspended inside makeBatchDecoder.
        do {
            try await engine.setComputeUnits(.gpuAndCPU)
            XCTFail("expected computeUnitsUnsupported while loading")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .computeUnitsUnsupported(.unifiedEN, .gpuAndCPU))
        }
        // A supported change mid-flight is still honoured by the loop.
        try await engine.setComputeUnits(.cpuOnly)

        await gate.open()
        try await load.value

        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .cpuOnly)
        XCTAssertEqual(runtime.batchConfigurations.map(\.computeUnits), [.neuralEngineAndCPU, .cpuOnly])
        XCTAssertFalse(runtime.batchConfigurations.contains { $0.computeUnits == .gpuAndCPU },
                       "the runtime is never asked to build the Unified encoder under GPU + CPU")
        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, KvoiceFluidAudioModels.parakeetUnifiedENModelID)
        if case .ready = await engine.state {} else { XCTFail("expected ready") }
    }

    // MARK: Streaming

    func testTDTRefusesStreaming() async throws {
        let fixture = try fixture(.tdtV3)
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime(), trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: nil, initialPrompt: nil) { _ in }
            XCTFail("expected streamingUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .streamingUnsupported(.tdtV3))
        }
    }

    func testUnifiedStreamingPublishesChangedPartialsAndStopsAfterEnd() async throws {
        let fixture = try fixture(.unifiedEN)
        let runtime = FakeParakeetRuntime(streamingPartials: ["hello", "hello", "hello world"])
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)

        let collector = PartialCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: "Glossary: kvoice.") { event in
            if case let .partialText(text) = event { await collector.add(text) }
        }
        XCTAssertEqual(runtime.streamingConfigurations, [
            ParakeetRuntimeConfiguration(variant: .unifiedEN, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .neuralEngineAndCPU)
        ])
        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0.1, count: 16_000))
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        await engine.awaitStreamingPasses()
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        await engine.awaitStreamingPasses()
        await engine.appendStreamingAudio(chunk, jobID: UUID()) // another job: dropped
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        await engine.awaitStreamingPasses()
        await engine.endStreaming(jobID: jobID)
        await engine.appendStreamingAudio(chunk, jobID: jobID) // after end: dropped

        let partials = await collector.partials
        XCTAssertEqual(partials, ["hello", "hello world"], "unchanged text is not re-published")
        XCTAssertEqual(runtime.unloadedSessions, 1)

        // The batch pass still runs after streaming (ADR-017: the inserted
        // text is the batch pass).
        let result = try await engine.transcribe(TranscriptionRequest(jobID: jobID, audio: makeRecording())) { _ in }
        XCTAssertEqual(result.text, "hello world")
    }

    func testSegmentsSpanTheTokensOrTheWholeAudioWhenTheRuntimeGivesNone() {
        XCTAssertEqual(
            ParakeetTranscriptionEngine.segments(for: "hi", tokens: [], audioDuration: .seconds(3)),
            [TranscriptSegment(start: .zero, end: .seconds(3), text: "hi")]
        )
        XCTAssertEqual(ParakeetTranscriptionEngine.segments(for: "", tokens: [], audioDuration: .seconds(3)), [])
    }
}

private actor PhaseCollector {
    var phases: [TranscriptionPhase] = []
    func add(_ phase: TranscriptionPhase) { phases.append(phase) }
}

private actor PartialCollector {
    var partials: [String] = []
    func add(_ text: String) { partials.append(text) }
}

private actor RecordingDiagnostics: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}
