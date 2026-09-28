import CryptoKit
import Foundation
import XCTest
@testable import KvoiceTranscription
import KvoiceDomain

final class WhisperTranscriptionEngineTests: XCTestCase {
    private var temporaryPackageURLs: [URL] = []

    override func tearDown() {
        for url in temporaryPackageURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryPackageURLs.removeAll()
        super.tearDown()
    }

    func testLoadUsesExplicitOfflinePathsAndKeepsRuntimeResident() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])

        try await engine.load(package)
        try await engine.load(package)

        let configurations = await factory.configurations
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(configurations[0].modelFolderURL, package.modelFolderURL.standardizedFileURL)
        XCTAssertEqual(configurations[0].tokenizerFolderURL, package.tokenizerFolderURL.standardizedFileURL)
        XCTAssertFalse(configurations[0].download)
        XCTAssertFalse(configurations[0].prewarm)
        XCTAssertTrue(configurations[0].load)
        let loadedModelID = await engine.loadedModelID
        let state = await engine.state
        XCTAssertEqual(loadedModelID, package.manifest.modelID)
        XCTAssertEqual(state, .ready(summary(for: package)))
    }

    func testInvalidPackageIsRejectedBeforeRuntimeFactory() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "should not load"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try FileManager.default.removeItem(
            at: package.modelFolderURL.appendingPathComponent("config.json")
        )

        do {
            try await engine.load(package)
            XCTFail("An incomplete package must fail before runtime construction")
        } catch let error as WhisperTranscriptionError {
            guard case let .invalidModelPackage(validationError) = error else {
                return XCTFail("Unexpected transcription error: \(error)")
            }
            XCTAssertEqual(validationError, .requiredFileMissing("model/config.json"))
        }
        let configurations = await factory.configurations
        XCTAssertTrue(configurations.isEmpty)
        let state = await engine.state
        guard case .error = state else {
            return XCTFail("Invalid package should leave the engine in an error state")
        }
    }

    func testSemanticallyInvalidTokenizerIsRejectedBeforeRuntimeFactory() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "should not load"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: [anchor(for: package)],
            tokenizerPreflight: WhisperKitLocalTokenizerPreflight()
        )

        do {
            try await engine.load(package)
            XCTFail("A JSON-valid but semantically invalid tokenizer must fail before runtime construction")
        } catch let error as WhisperTranscriptionError {
            guard case let .invalidModelPackage(validationError) = error else {
                return XCTFail("Unexpected transcription error: \(error)")
            }
            XCTAssertEqual(validationError, .tokenizerSemanticsInvalid)
        }
        let configurations = await factory.configurations
        XCTAssertTrue(configurations.isEmpty)
    }

    func testTranscriptionUsesTranscribeTaskBoundaryNormalizesTextAndReportsTimings() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "Cafe\u{301}"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let sink = EventSink()
        let request = makeRequest(jobID: UUID())
        let result = try await engine.transcribe(request) { event in
            await sink.append(event)
        }

        XCTAssertEqual(result.text, "Café")
        XCTAssertEqual(result.segments.first?.text, "Café")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.modelID, package.manifest.modelID)
        XCTAssertEqual(result.timings.runtimeReportedRealTimeFactor, 0.42)
        XCTAssertGreaterThanOrEqual(result.timings.inferenceEnd, result.timings.inferenceStart)

        let events = await sink.events
        XCTAssertEqual(
            events,
            [.phase(.preparingAudio), .phase(.encoding), .phase(.decoding), .phase(.finalizing)]
        )
        XCTAssertFalse(events.contains { event in
            if case .partialText = event { return true }
            return false
        })
        let transcriptionCallCount = await runtime.transcriptionCallCount
        let state = await engine.state
        XCTAssertEqual(transcriptionCallCount, 1)
        XCTAssertEqual(state, .ready(summary(for: package)))
    }

    // MARK: Short-clip padding (WhisperKit `windowClipTime`, `sttEmpty`)

    /// WhisperKit 1.1.0's seek loop (`TranscribeTask.run`) is `while seek <
    /// seekClipEnd - windowPadding`, where `windowPadding = Int(windowClipTime
    /// * WhisperKit.sampleRate)` and `windowClipTime` defaults to `1.0`
    /// (16,000 samples at 16 kHz). A clip at or under that count makes
    /// `seekClipEnd - windowPadding <= 0`, so the loop — the only place that
    /// calls the encoder — never runs, and WhisperKit returns an empty
    /// result. `SpeechGate.trailingSilenceMinimumSeconds` keeps at least
    /// 1.0 s, so a short utterance ("yes", "okay") trimmed to exactly that
    /// floor hits this every time. `ShortClipPadding` pads the batch path's
    /// input to 1.5 s (24,000 samples) so the loop always runs at least
    /// once; a clip already past the floor is untouched.
    func testShortClipsArePaddedToTheWhisperKitWindowClipTimeFloorAndLongerClipsAreUnchanged() async throws {
        func transcribedSampleCount(seconds: Double) async throws -> Int {
            let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "yes"))
            let factory = ScriptedFactory(steps: [.runtime(runtime)])
            let package = makePackage(id: "primary")
            let engine = makeEngine(factory: factory, trustedPackages: [package])
            try await engine.load(package)

            let audio = AudioRecording(
                samples: ContiguousArray(repeating: 0.05, count: Int(seconds * 16_000)),
                duration: .seconds(seconds),
                peakLevelDBFS: -20,
                clippedFrameCount: 0
            )
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: audio)) { _ in }
            return await runtime.lastTranscribeSamples?.count ?? -1
        }

        let short = try await transcribedSampleCount(seconds: 0.6)
        XCTAssertEqual(short, ShortClipPadding.minimumSampleCount, "0.6 s is padded up to the 1.5 s floor")

        // Exactly SpeechGate's 1.0 s minimum: at 1.0 s, WhisperKit's own seek
        // loop condition (`0 < contentFrames - windowPadding`, i.e. `0 < 0`)
        // is already false, so this is still padded.
        let atSpeechGateFloor = try await transcribedSampleCount(seconds: 1.0)
        XCTAssertEqual(atSpeechGateFloor, ShortClipPadding.minimumSampleCount)

        let longer = try await transcribedSampleCount(seconds: 2.0)
        XCTAssertEqual(longer, 32_000, "a clip already past the floor is passed through unchanged")
    }

    func testShortClipPaddingIsTrailingDigitalSilence() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "yes"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let spokenSampleCount = Int(0.6 * 16_000)
        let audio = AudioRecording(
            samples: ContiguousArray(repeating: 0.05, count: spokenSampleCount),
            duration: .seconds(0.6),
            peakLevelDBFS: -20,
            clippedFrameCount: 0
        )
        _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: audio)) { _ in }

        let padded = await runtime.lastTranscribeSamples
        XCTAssertEqual(padded?.count, ShortClipPadding.minimumSampleCount)
        XCTAssertEqual(Array(padded!.prefix(spokenSampleCount)), Array(repeating: Float(0.05), count: spokenSampleCount))
        XCTAssertEqual(Array(padded!.suffix(from: spokenSampleCount)), Array(repeating: Float(0), count: padded!.count - spokenSampleCount))
    }

    /// The warm-up pass (ADR-022 item 8) never goes through the batch
    /// `transcribe(_:events:)` path that applies `ShortClipPadding` — it
    /// calls `runtime.warmUp` directly with `WarmUpAudio.samples()`
    /// (exactly 16,000 samples) — so it must never be padded either.
    /// `testLoadWarmsUpTheRuntimeOnceAndRecordsNothingAsAPass` already pins
    /// the warm-up sample count at exactly 16,000, which this note exists to
    /// explain.
    func testWarmUpIsNeverPadded() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])

        try await engine.load(package)

        let warmUpSampleCount = await runtime.warmUpSampleCount
        let transcriptionCallCount = await runtime.transcriptionCallCount
        XCTAssertEqual(warmUpSampleCount, 16_000, "unpadded: the warm-up never reaches ShortClipPadding")
        XCTAssertEqual(transcriptionCallCount, 0, "the warm-up goes through `warmUp`, never `transcribe`")
    }

    // MARK: Dictionary (ADR-018)

    func testInitialPromptIsEncodedWithTheRuntimeTokenizerAndHandedToThePass() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "kvoice"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let audio = makeRequest(jobID: UUID()).audio
        _ = try await engine.transcribe(
            TranscriptionRequest(jobID: UUID(), audio: audio, initialPrompt: "Glossary: kvoice, WhisperKit.")
        ) { _ in }
        _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: audio)) { _ in }

        let received = await runtime.promptTokensReceived
        XCTAssertEqual(received, [[0, 1, 2], nil], "three words → three fake tokens; no prompt → nil")
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .tokens(111))
        let count = await engine.promptTokenCount(of: "a b c d")
        XCTAssertEqual(count, 4)
    }

    func testPromptOverTheRuntimeCapIsCutToThePrefixAndLoggedAsAScalar() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "x"), promptLimit: 3)
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let diagnostics = RecordingDiagnostics()
        let engine = WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: [anchor(for: package)],
            tokenizerPreflight: FixtureTokenizerPreflight(),
            diagnostics: diagnostics
        )
        try await engine.load(package)

        let jobID = UUID()
        _ = try await engine.transcribe(
            TranscriptionRequest(jobID: jobID, audio: makeRequest(jobID: jobID).audio, initialPrompt: "Glossary: a, b, c, d.")
        ) { _ in }

        let received = await runtime.promptTokensReceived
        XCTAssertEqual(received, [[0, 1, 2]], "the first `limit` tokens are kept, never more than the cap")
        // The load's warm-up event is the only other line; filter it out.
        let events = await diagnostics.events.filter { $0.name != .modelWarmUpCompleted }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, .sttPromptTruncated)
        XCTAssertEqual(events.first?.jobID, jobID)
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "dictionaryPromptTruncated")
        XCTAssertEqual(events.first?.attributes.tokenCount, 5)
        let encoded = try JSONEncoder().encode(events.first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Glossary"), "never the terms")
    }

    func testRuntimeWithoutAPromptReportsUnsupportedAndSendsNone() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "x"), promptLimit: nil)
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])

        let before = await engine.promptTokenLimit
        XCTAssertNil(before, "nothing loaded yet")
        try await engine.load(package)
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)

        _ = try await engine.transcribe(
            TranscriptionRequest(jobID: UUID(), audio: makeRequest(jobID: UUID()).audio, initialPrompt: "Glossary: kvoice.")
        ) { _ in }
        let received = await runtime.promptTokensReceived
        XCTAssertEqual(received, [nil])
    }

    func testTranslationTaskIsRejectedBeforeCallingWhisperRuntime() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "not called"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        do {
            _ = try await engine.transcribe(
                makeRequest(jobID: UUID(), task: .translate),
                events: { _ in }
            )
            XCTFail("Translation should be rejected")
        } catch {
            XCTAssertEqual(error as? WhisperTranscriptionError, .unsupportedTask)
        }
        let transcriptionCallCount = await runtime.transcriptionCallCount
        XCTAssertEqual(transcriptionCallCount, 0)
    }

    func testCancelledJobCannotPublishLateRuntimeResultAndNextJobCanRun() async throws {
        // The runtime ignores cancellation: it parks on a gate that is not
        // cancellation-aware, like a Core ML pass that runs to the end.
        let gate = WarmUpGate()
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "late"))
        await runtime.setTranscribeGate(gate)
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let firstJob = UUID()
        let firstRequest = makeRequest(jobID: firstJob)
        let firstTask = Task {
            try await engine.transcribe(firstRequest, events: { _ in })
        }
        // Cancel only once the pass is provably in the runtime (a fixed
        // sleep here raced the engine's own bookkeeping under load: a
        // cancel that arrives before the job is active is ignored).
        await runtime.waitUntilTranscribing(count: 1)
        await engine.cancel(jobID: firstJob)
        await gate.open()

        do {
            _ = try await firstTask.value
            XCTFail("A cancelled job must not return a late runtime result")
        } catch is CancellationError {
            // Expected: the runtime intentionally ignored cancellation in this test.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let next = try await engine.transcribe(makeRequest(jobID: UUID())) { _ in }
        XCTAssertEqual(next.text, "late")
        let transcriptionCallCount = await runtime.transcriptionCallCount
        XCTAssertEqual(transcriptionCallCount, 2)
        let cancellationObserved = await runtime.cancellationObserved
        XCTAssertTrue(cancellationObserved)
    }

    func testFailedReplacementRestoresPreviousResidentPackage() async throws {
        let firstRuntime = ScriptedRuntime(result: makeRuntimeResult(text: "old"))
        let restoredRuntime = ScriptedRuntime(result: makeRuntimeResult(text: "restored"))
        let factory = ScriptedFactory(steps: [.runtime(firstRuntime), .failure, .runtime(restoredRuntime)])
        let firstPackage = makePackage(id: "primary")
        let replacement = makePackage(id: "replacement")
        let engine = makeEngine(factory: factory, trustedPackages: [firstPackage, replacement])
        try await engine.load(firstPackage)

        do {
            try await engine.load(replacement)
            XCTFail("The scripted replacement must fail")
        } catch is TestFactoryError {
            // Expected; the old package remains active.
        }

        let loadedModelID = await engine.loadedModelID
        let state = await engine.state
        let configurationCount = await factory.configurations.count
        XCTAssertEqual(loadedModelID, firstPackage.manifest.modelID)
        XCTAssertEqual(state, .ready(summary(for: firstPackage)))
        XCTAssertEqual(configurationCount, 3)
    }

    func testInvalidAudioIsRejectedBeforeRuntimeCall() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "not called"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let invalid = AudioRecording(
            samples: [0, 1],
            sampleRate: 48_000,
            channelCount: 2,
            duration: .seconds(0.01),
            peakLevelDBFS: 0,
            clippedFrameCount: 0
        )
        let request = TranscriptionRequest(jobID: UUID(), audio: invalid)
        do {
            _ = try await engine.transcribe(request, events: { _ in })
            XCTFail("Invalid audio should be rejected")
        } catch {
            XCTAssertEqual(
                error as? WhisperTranscriptionError,
                .invalidAudio(sampleRate: 48_000, channelCount: 2)
            )
        }
        let transcriptionCallCount = await runtime.transcriptionCallCount
        XCTAssertEqual(transcriptionCallCount, 0)
    }

    // MARK: Runtime (compute units and statistics)

    func testComputeUnitsChosenBeforeLoadReachTheFactoryAndDefaultIsNeuralEngine() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])

        XCTAssertEqual(WhisperRuntimeConfiguration(
            modelFolderURL: package.modelFolderURL,
            tokenizerFolderURL: package.tokenizerFolderURL
        ).computeUnits, .neuralEngineAndCPU)

        // Nothing is loaded yet: the choice is stored and no runtime is made.
        try await engine.setComputeUnits(.cpuOnly)
        var configurations = await factory.configurations
        XCTAssertTrue(configurations.isEmpty)

        try await engine.load(package)
        configurations = await factory.configurations
        XCTAssertEqual(configurations.map(\.computeUnits), [.cpuOnly])
        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .cpuOnly)
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastLoadDuration, "a successful load is timed")
        XCTAssertNil(statistics.lastRealTimeFactor, "no pass has run yet")
    }

    func testChangingComputeUnitsReloadsTheResidentPackageAndUnloadsTheOldRuntime() async throws {
        let first = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let second = ScriptedRuntime(result: makeRuntimeResult(text: "second"))
        let factory = ScriptedFactory(steps: [.runtime(first), .runtime(second)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        try await engine.setComputeUnits(.gpuAndCPU)
        // The same choice again is a no-op: no third runtime.
        try await engine.setComputeUnits(.gpuAndCPU)

        let configurations = await factory.configurations
        XCTAssertEqual(configurations.map(\.computeUnits), [.neuralEngineAndCPU, .gpuAndCPU])
        let unloaded = await first.unloadCallCount
        XCTAssertEqual(unloaded, 1, "the previous runtime is released before the new one loads")
        let state = await engine.state
        XCTAssertEqual(state, .ready(summary(for: package)))
        let loadedModelID = await engine.loadedModelID
        XCTAssertEqual(loadedModelID, package.manifest.modelID)
        let result = try await engine.transcribe(makeRequest(jobID: UUID()), events: { _ in })
        XCTAssertEqual(result.text, "second")
    }

    func testFailedReloadFallsBackToThePreviousComputeUnits() async throws {
        let first = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let restored = ScriptedRuntime(result: makeRuntimeResult(text: "restored"))
        // Load under the default, fail twice under GPU (the reload and the
        // engine's own restore attempt), then succeed under the old units.
        let factory = ScriptedFactory(steps: [.runtime(first), .failure, .failure, .runtime(restored)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        do {
            try await engine.setComputeUnits(.gpuAndCPU)
            XCTFail("A failed reload must surface")
        } catch {
            // expected
        }

        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .neuralEngineAndCPU)
        let configurations = await factory.configurations
        XCTAssertEqual(
            configurations.map(\.computeUnits),
            [.neuralEngineAndCPU, .gpuAndCPU, .gpuAndCPU, .neuralEngineAndCPU]
        )
        let state = await engine.state
        XCTAssertEqual(state, .ready(summary(for: package)), "the model is back under the old units")
        let result = try await engine.transcribe(makeRequest(jobID: UUID()), events: { _ in })
        XCTAssertEqual(result.text, "restored")
    }

    func testComputeUnitsChangeIsRefusedWhileAPassIsRunning() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "slow"), detachedDelay: .milliseconds(300))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        let jobID = UUID()
        let request = makeRequest(jobID: jobID)
        let pass = Task {
            try await engine.transcribe(request, events: { _ in })
        }
        // Wait for the pass to own the runtime rather than sleeping a fixed
        // time, so a loaded machine cannot let the change in first.
        for _ in 0..<2_000 {
            if case .inference = await engine.state { break }
            await Task.yield()
        }
        do {
            try await engine.setComputeUnits(.cpuOnly)
            XCTFail("A change during inference must be refused")
        } catch {
            XCTAssertEqual(error as? WhisperTranscriptionError, .inferenceInProgress(jobID))
        }
        _ = try await pass.value
        let configurations = await factory.configurations
        XCTAssertEqual(configurations.count, 1)
        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .neuralEngineAndCPU, "a refused change is not stored either")
    }

    func testComputeUnitsChangedDuringALoadReloadUnderTheNewUnits() async throws {
        let first = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let second = ScriptedRuntime(result: makeRuntimeResult(text: "second"))
        let factory = ReentrantFactory(runtimes: [first, second])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        // While the first runtime is being made, the factory changes the
        // engine's units (the actor is reentrant across the await).
        await factory.setSideEffect { try? await engine.setComputeUnits(.gpuAndCPU) }

        try await engine.load(package)

        let configurations = await factory.configurations
        XCTAssertEqual(configurations.map(\.computeUnits), [.neuralEngineAndCPU, .gpuAndCPU])
        let unloaded = await first.unloadCallCount
        XCTAssertEqual(unloaded, 1, "the runtime built under the stale units is released")
        let result = try await engine.transcribe(makeRequest(jobID: UUID()), events: { _ in })
        XCTAssertEqual(result.text, "second")
        let units = await engine.currentComputeUnits
        XCTAssertEqual(units, .gpuAndCPU)
    }

    func testRuntimeStatisticsRecordTheLastPass() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        _ = try await engine.transcribe(makeRequest(jobID: UUID()), events: { _ in })

        let statistics = await engine.runtimeStatistics
        XCTAssertEqual(statistics.lastRealTimeFactor, 0.42, "the runtime's own figure wins when it reports one")
        XCTAssertNotNil(statistics.lastInferenceDuration)
        XCTAssertEqual(
            WhisperTranscriptionEngine.realTimeFactor(inference: .seconds(2), audio: .seconds(10)),
            0.2
        )
        XCTAssertNil(WhisperTranscriptionEngine.realTimeFactor(inference: .seconds(2), audio: .zero))
    }

    // MARK: - Warm-up after load (ADR-022 item 8)

    func testLoadWarmsUpTheRuntimeOnceAndRecordsNothingAsAPass() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let diagnostics = RecordingDiagnostics()
        let engine = WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: [anchor(for: package)],
            tokenizerPreflight: FixtureTokenizerPreflight(),
            diagnostics: diagnostics
        )

        try await engine.load(package)
        try await engine.load(package) // already resident: no reload, no second warm-up

        let warmUps = await runtime.warmUpCallCount
        let passes = await runtime.transcriptionCallCount
        let sampleCount = await runtime.warmUpSampleCount
        XCTAssertEqual(warmUps, 1, "exactly one warm-up per load")
        XCTAssertEqual(passes, 0, "the warm-up goes straight to the runtime, never through `transcribe`")
        XCTAssertEqual(sampleCount, 16_000, "one second at 16 kHz")
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastWarmUpDuration)
        XCTAssertNil(statistics.lastRealTimeFactor, "a warm-up is not a pass")
        XCTAssertNil(statistics.lastInferenceDuration)
        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, package.manifest.modelID)
        let events = await diagnostics.events.filter { $0.name == .modelWarmUpCompleted }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.result, .success)
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "warmUp")
        XCTAssertNotNil(events.first?.durationMilliseconds)
    }

    func testWarmUpAudioIsNearSilentDeterministicAndOneSecond() {
        let samples = WarmUpAudio.samples()
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples, WarmUpAudio.samples(), "deterministic: two warm-ups feed identical audio")
        let peak = samples.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, WarmUpAudio.peakAmplitude)
        XCTAssertGreaterThan(peak, 0, "near-silent rather than all zeros so the mel is not degenerate")
    }

    func testComputeUnitsReloadAndRestoreWarmUpAgain() async throws {
        let first = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let reloaded = ScriptedRuntime(result: makeRuntimeResult(text: "reloaded"))
        let factory = ScriptedFactory(steps: [.runtime(first), .runtime(reloaded)])
        let package = makePackage(id: "primary")
        let engine = makeEngine(factory: factory, trustedPackages: [package])
        try await engine.load(package)

        try await engine.setComputeUnits(.cpuOnly)

        let firstWarmUps = await first.warmUpCallCount
        let reloadedWarmUps = await reloaded.warmUpCallCount
        XCTAssertEqual(firstWarmUps, 1)
        XCTAssertEqual(reloadedWarmUps, 1, "a compute-unit reload is a fresh Core ML load and warms up again")
    }

    func testWarmUpFailureIsSwallowedWithOneScalarEventAndTheLoadStands() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        await runtime.setWarmUpError(TestFactoryError.unavailable)
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let diagnostics = RecordingDiagnostics()
        let engine = WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: [anchor(for: package)],
            tokenizerPreflight: FixtureTokenizerPreflight(),
            diagnostics: diagnostics
        )

        try await engine.load(package)

        let loaded = await engine.loadedModelID
        let state = await engine.state
        XCTAssertEqual(loaded, package.manifest.modelID, "a failed warm-up never fails the load")
        XCTAssertEqual(state, .ready(summary(for: package)))
        let statistics = await engine.runtimeStatistics
        XCTAssertNil(statistics.lastWarmUpDuration)
        let events = await diagnostics.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, .modelWarmUpCompleted)
        XCTAssertEqual(events.first?.result, .warning)
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "warmupFailed")
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "warmUp")
        // The runtime still transcribes normally afterwards.
        _ = try await engine.transcribe(makeRequest(jobID: UUID()), events: { _ in })
        let passes = await runtime.transcriptionCallCount
        XCTAssertEqual(passes, 1)
    }

    func testLoadCancelledDuringWarmUpReleasesTheRuntimeAndReportsNoModel() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        await runtime.setWarmUpWaitsForCancellation(true)
        let factory = ScriptedFactory(steps: [.runtime(runtime)])
        let package = makePackage(id: "primary")
        let diagnostics = RecordingDiagnostics()
        let engine = WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: [anchor(for: package)],
            tokenizerPreflight: FixtureTokenizerPreflight(),
            diagnostics: diagnostics
        )

        let load = Task { try await engine.load(package) }
        // The model is not resident while the warm-up runs: the start gate
        // keeps reporting "loading" until the first-inference compile is done.
        while await runtime.warmUpCallCount == 0 { await Task.yield() }
        let midLoad = await engine.loadedModelID
        let midState = await engine.state
        XCTAssertNil(midLoad)
        XCTAssertEqual(midState, .loading)

        load.cancel()
        do {
            _ = try await load.value
            XCTFail("a load cancelled during its warm-up must not succeed")
        } catch is CancellationError {
            // Expected.
        }

        let unloads = await runtime.unloadCallCount
        let loaded = await engine.loadedModelID
        XCTAssertEqual(unloads, 1, "the runtime built for the cancelled load is released, not leaked")
        XCTAssertNil(loaded)
        let warmUpEvents = await diagnostics.events.filter { $0.name == .modelWarmUpCompleted }
        XCTAssertTrue(warmUpEvents.isEmpty, "a cancelled warm-up is not a warm-up failure")
    }

    /// 2026-09-14 slice-2 review: the actor is reentrant across the load's
    /// awaits and the warm-up widened that window; a second `load` in it
    /// must be refused, never interleaved.
    func testASecondLoadDuringTheWarmUpIsRefusedAndTheFirstCompletes() async throws {
        let runtime = ScriptedRuntime(result: makeRuntimeResult(text: "first"))
        let gate = WarmUpGate()
        await runtime.setWarmUpGate(gate)
        let factory = ScriptedFactory(steps: [.runtime(runtime), .runtime(ScriptedRuntime(result: makeRuntimeResult(text: "never")))])
        let package = makePackage(id: "primary")
        let replacement = makePackage(id: "replacement")
        let engine = makeEngine(factory: factory, trustedPackages: [package, replacement])

        let first = Task { try await engine.load(package) }
        while await runtime.warmUpCallCount == 0 { await Task.yield() }

        do {
            try await engine.load(replacement)
            XCTFail("a load during another load's warm-up must be refused")
        } catch WhisperTranscriptionError.loadInProgress {
            // Expected.
        }
        let midState = await engine.state
        XCTAssertEqual(midState, .loading, "the refusal changes nothing about the load in flight")

        await gate.open()
        try await first.value

        let loaded = await engine.loadedModelID
        XCTAssertEqual(loaded, package.manifest.modelID, "the first load completes normally")
        let configurations = await factory.configurations
        XCTAssertEqual(configurations.count, 1, "the second load never reached the factory")
        let warmUps = await runtime.warmUpCallCount
        XCTAssertEqual(warmUps, 1)
        // The guard does not wedge shut: the next load goes through.
        try await engine.load(replacement)
        let afterwards = await engine.loadedModelID
        XCTAssertEqual(afterwards, replacement.manifest.modelID)
    }

    // MARK: - Load-failure diagnostics (ADR-022 item 9)

    func testEveryLoadFailureEmitsOneScalarEventNamingItsSite() async throws {
        let package = makePackage(id: "primary")
        // 1. Runtime construction fails.
        do {
            let diagnostics = RecordingDiagnostics()
            let engine = WhisperTranscriptionEngine(
                factory: ScriptedFactory(steps: [.failure]),
                trustedReleases: [anchor(for: package)],
                tokenizerPreflight: FixtureTokenizerPreflight(),
                diagnostics: diagnostics
            )
            await XCTAssertThrowsErrorAsync(try await engine.load(package))
            let events = await diagnostics.events
            XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
            XCTAssertEqual(events.first?.result, .failure)
            XCTAssertEqual(events.first?.errorCode, .modelLoadFailed)
            XCTAssertEqual(events.first?.attributes.site?.rawValue, "runtimeMake")
            XCTAssertEqual(events.first?.attributes.reason?.rawValue, "runtimeLoadFailed")
        }
        // 2. The package fails validation before the factory is asked.
        do {
            let diagnostics = RecordingDiagnostics()
            let engine = WhisperTranscriptionEngine(
                factory: ScriptedFactory(steps: []),
                trustedReleases: [anchor(for: package)],
                tokenizerPreflight: FixtureTokenizerPreflight(),
                diagnostics: diagnostics
            )
            try FileManager.default.removeItem(at: package.modelFolderURL.appendingPathComponent("config.json"))
            await XCTAssertThrowsErrorAsync(try await engine.load(package))
            let events = await diagnostics.events
            XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
            XCTAssertEqual(events.first?.attributes.site?.rawValue, "validatePackage")
            XCTAssertEqual(events.first?.attributes.reason?.rawValue, "invalidModelPackage")
            let encoded = try JSONEncoder().encode(events.first)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(package.modelFolderURL.path), "never a path")
        }
    }

    private func makeRequest(jobID: JobID, task: TranscriptionTask = .transcribe) -> TranscriptionRequest {
        let audio = AudioRecording(
            samples: ContiguousArray(repeating: 0, count: 16_000),
            duration: .seconds(1),
            peakLevelDBFS: -60,
            clippedFrameCount: 0
        )
        return TranscriptionRequest(jobID: jobID, audio: audio, task: task)
    }

    private func makePackage(id: String) -> InstalledModelPackage {
        let isComparator = id == "replacement"
        let modelID = isComparator
            ? "whisper-large-v3-turbo-coreml-626mb"
            : "whisper-large-v3-turbo-coreml-uncompressed"
        let revision = isComparator
            ? "7235bbd38ae9ab5476bee007313c0bb327387b84"
            : "04e5c42d80a522518023727e8c7e68d4bb391b28"
        let subdirectory = isComparator
            ? "openai_whisper-large-v3-v20240930_626MB"
            : "openai_whisper-large-v3-v20240930_turbo"
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-transcription-test-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try! fileManager.createDirectory(
            at: root.appendingPathComponent("model", isDirectory: true),
            withIntermediateDirectories: true
        )
        try! fileManager.createDirectory(
            at: root.appendingPathComponent("tokenizer/models/openai/whisper-large-v3", isDirectory: true),
            withIntermediateDirectories: true
        )

        let paths: [(String, ModelArtifactRole)] = [
            ("model/AudioEncoder.mlmodelc/model.bin", .audioEncoder),
            ("model/MelSpectrogram.mlmodelc/model.bin", .melSpectrogram),
            ("model/TextDecoder.mlmodelc/model.bin", .textDecoder),
            ("model/TextDecoderContextPrefill.mlmodelc/model.bin", .decoderPrefill),
            ("model/config.json", .configuration),
            ("model/generation_config.json", .configuration),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer.json", .tokenizer),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer_config.json", .tokenizer)
        ]
        let descriptors = paths.map { relativePath, role in
            let data = relativePath.hasSuffix(".json")
                ? Data("{\"fixture\":\"\(relativePath)\"}".utf8)
                : Data("fixture-\(relativePath)".utf8)
            let url = root.appendingPathComponent(relativePath)
            try! fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try! data.write(to: url, options: .atomic)
            return ModelFileDescriptor(
                path: relativePath,
                bytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                role: role
            )
        }
        let manifest = ModelManifest(
            schemaVersion: 1,
            modelID: modelID,
            family: "whisper-large-v3-turbo",
            format: "whisperkit-coreml",
            workingSpaceBytes: 1_073_741_824,
            source: ModelManifestSource(
                repository: "argmaxinc/whisperkit-coreml",
                revision: revision,
                subdirectory: subdirectory
            ),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: "argmaxinc/argmax-oss-swift/WhisperKit",
                exactVersion: "1.1.0"
            ),
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
            files: descriptors
        )
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try! encoder.encode(manifest).write(
            to: root.appendingPathComponent("ModelManifest.json"),
            options: .atomic
        )
        temporaryPackageURLs.append(root)
        return InstalledModelPackage(
            manifest: manifest,
            packageURL: root,
            modelFolderURL: root.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: root.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .managedByKvoice
        )
    }

    private func summary(for package: InstalledModelPackage) -> InstalledModelSummary {
        InstalledModelSummary(
            modelID: package.manifest.modelID,
            revision: package.manifest.source.revision,
            ownership: package.ownership
        )
    }

    private func makeEngine(
        factory: any WhisperRuntimeFactory,
        trustedPackages: [InstalledModelPackage]
    ) -> WhisperTranscriptionEngine {
        WhisperTranscriptionEngine(
            factory: factory,
            trustedReleases: trustedPackages.map(anchor(for:)),
            tokenizerPreflight: FixtureTokenizerPreflight()
        )
    }

    private func anchor(for package: InstalledModelPackage) -> WhisperModelReleaseTrustAnchor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(package.manifest)
        return try! WhisperModelReleaseTrustAnchor(
            manifestData: data,
            manifestSHA256: try! WhisperModelReleaseTrustAnchor.digest(for: package.manifest)
        )
    }

    private func makeRuntimeResult(text: String) -> WhisperRuntimeResult {
        WhisperRuntimeResult(
            text: text,
            detectedLanguage: "en",
            segments: [
                WhisperRuntimeSegment(
                    start: .zero,
                    end: .seconds(1),
                    text: text
                )
            ],
            runtimeReportedRealTimeFactor: 0.42
        )
    }
}

private struct FixtureTokenizerPreflight: WhisperLocalTokenizerPreflight {
    func validate(tokenizerFolderURL: URL) async throws {}
}

private actor RecordingDiagnostics: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

private actor EventSink {
    private(set) var events: [TranscriptionEvent] = []

    func append(_ event: TranscriptionEvent) {
        events.append(event)
    }
}

private enum TestFactoryError: Error, Sendable {
    case unavailable
}

private actor ScriptedFactory: WhisperRuntimeFactory {
    enum Step: Sendable {
        case runtime(any WhisperRuntime)
        case failure
    }

    private var steps: [Step]
    private(set) var configurations: [WhisperRuntimeConfiguration] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func make(configuration: WhisperRuntimeConfiguration) async throws -> any WhisperRuntime {
        configurations.append(configuration)
        guard !steps.isEmpty else { throw TestFactoryError.unavailable }
        switch steps.removeFirst() {
        case let .runtime(runtime): return runtime
        case .failure: throw TestFactoryError.unavailable
        }
    }
}

/// A factory whose first `make` runs a side effect before returning, to
/// exercise actor reentrancy during a load.
private actor ReentrantFactory: WhisperRuntimeFactory {
    private var runtimes: [any WhisperRuntime]
    private var sideEffect: (@Sendable () async -> Void)?
    private(set) var configurations: [WhisperRuntimeConfiguration] = []

    init(runtimes: [any WhisperRuntime]) {
        self.runtimes = runtimes
    }

    func setSideEffect(_ effect: @escaping @Sendable () async -> Void) {
        sideEffect = effect
    }

    func make(configuration: WhisperRuntimeConfiguration) async throws -> any WhisperRuntime {
        configurations.append(configuration)
        if let effect = sideEffect {
            sideEffect = nil
            await effect()
        }
        guard !runtimes.isEmpty else { throw TestFactoryError.unavailable }
        return runtimes.removeFirst()
    }
}

private actor ScriptedRuntime: WhisperRuntime {
    let result: WhisperRuntimeResult
    let detachedDelay: Duration?
    private(set) var transcriptionCallCount = 0
    private(set) var cancellationObserved = false
    private(set) var unloadCallCount = 0
    /// ADR-022 item 8: warm-up passes, kept apart from `transcriptionCallCount`
    /// so the existing pass-count assertions stay exact.
    private(set) var warmUpCallCount = 0
    private(set) var warmUpSampleCount: Int?
    /// Thrown by `warmUp` when set (the load must still succeed).
    var warmUpError: Error?
    /// When set, `warmUp` parks until the task is cancelled, so a test can
    /// cancel a load mid-warm-up without waiting on real time.
    var warmUpWaitsForCancellation = false
    /// When set, `warmUp` parks until the gate opens, so a test can act
    /// while a load is provably mid-warm-up.
    var warmUpGate: WarmUpGate?
    /// When set, `transcribe` parks until the gate opens — ignoring task
    /// cancellation meanwhile, like a runtime pass that runs to the end.
    var transcribeGate: WarmUpGate?

    func setWarmUpError(_ error: Error?) { warmUpError = error }
    func setWarmUpWaitsForCancellation(_ waits: Bool) { warmUpWaitsForCancellation = waits }
    func setWarmUpGate(_ gate: WarmUpGate?) { warmUpGate = gate }
    func setTranscribeGate(_ gate: WarmUpGate?) { transcribeGate = gate }

    /// Returns once `count` passes have entered `transcribe` (never real
    /// time; fails after `testYieldBudget` yields).
    func waitUntilTranscribing(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while transcriptionCallCount < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilTranscribing: `transcriptionCallCount < count` still held after \(testYieldBudget) yields; transcriptionCallCount = \(transcriptionCallCount)", file: file, line: line)
            }
            await Task.yield()
        }
    }
    /// ADR-018: the prompt tokens of each pass, in order.
    private(set) var promptTokensReceived: [[Int]?] = []
    /// The samples of the most recent `transcribe` call, so a test can check
    /// short-clip padding (`ShortClipPadding`) without loading Core ML.
    private(set) var lastTranscribeSamples: [Float]?
    /// Simulated runtime cap; nil models a runtime without a prompt.
    let promptLimit: Int?

    init(result: WhisperRuntimeResult, detachedDelay: Duration? = nil, promptLimit: Int? = 111) {
        self.result = result
        self.detachedDelay = detachedDelay
        self.promptLimit = promptLimit
    }

    func promptTokenLimit() async -> Int? { promptLimit }

    /// One token per whitespace-separated word, so a test can predict counts.
    func encodePrompt(_ text: String) async -> [Int] {
        text.split(separator: " ").enumerated().map { $0.offset }
    }

    func transcribe(samples: [Float], languageHint: String?, promptTokens: [Int]?) async throws -> WhisperRuntimeResult {
        transcriptionCallCount += 1
        promptTokensReceived.append(promptTokens)
        lastTranscribeSamples = samples
        if let transcribeGate {
            await transcribeGate.waitUntilOpen()
        }
        if let detachedDelay {
            let sleeper = Task.detached {
                try? await Task.sleep(for: detachedDelay)
            }
            _ = await sleeper.value
        }
        cancellationObserved = cancellationObserved || Task.isCancelled
        return result
    }

    func warmUp(samples: [Float]) async throws {
        warmUpCallCount += 1
        warmUpSampleCount = samples.count
        if let warmUpError { throw warmUpError }
        if warmUpWaitsForCancellation {
            try await CancellationGate.waitUntilCancelled()
        }
        if let warmUpGate {
            await warmUpGate.waitUntilOpen()
        }
    }

    func unload() async {
        unloadCallCount += 1
    }
}

/// A gate a fake warm-up (or transcription pass) parks on until the test
/// opens it (never real time).
private actor WarmUpGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Suspends until the current task is cancelled, then throws — a clock-free
/// way to hold a fake runtime "busy" for exactly as long as a test needs.
private enum CancellationGate {
    static func waitUntilCancelled() async throws {
        let box = ContinuationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.store(continuation)
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancelled = false

        func store(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// XCTest has no async `XCTAssertThrowsError`; this one only checks that the
/// expression threw.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
