import CryptoKit
import Foundation
import XCTest
@testable import KvoiceTranscription
import KvoiceDomain

/// ADR-017: the Whisper adapter runs a streaming session against the same
/// runtime seam as the batch pass. Partials arrive while audio is appended,
/// the batch pass tears the session down first so the runtime is never used
/// concurrently, and a cancelled or ended session publishes nothing more.
final class WhisperTranscriptionEngineStreamingTests: XCTestCase {
    private var temporaryPackageURLs: [URL] = []

    override func tearDown() {
        for url in temporaryPackageURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryPackageURLs.removeAll()
        super.tearDown()
    }

    func testPartialsAreEmittedWhileStreamingAndTheBatchPassStillProducesTheFinal() async throws {
        let runtime = QueuedRuntime(results: [
            makeResult(segments: [(0, 1, "hello")]),
            makeResult(segments: [(0, 1, "hello"), (1, 2, "world")]),
            makeResult(segments: [(0, 3, "hello world final")])
        ])
        let package = StreamingTestFixtures.makePackage(tracker: &temporaryPackageURLs)
        let engine = makeEngine(runtime: runtime, package: package)
        try await engine.load(package)

        let sink = StreamingEventSink()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "zh", initialPrompt: "Glossary: kvoice.") { event in
            await sink.append(event)
        }
        await engine.appendStreamingAudio(chunk(seconds: 1.5), jobID: jobID)
        try await waitUntil { await sink.partials == ["hello"] }
        await engine.appendStreamingAudio(chunk(seconds: 1.5), jobID: jobID)
        try await waitUntil { await sink.partials == ["hello", "hello world"] }
        let livePartial = await engine.streamingPartialText
        XCTAssertEqual(livePartial, "hello world")
        let hints = await runtime.languageHints
        XCTAssertEqual(hints, ["zh", "zh"], "the language setting reaches every streaming pass")
        let prompts = await runtime.promptTokensReceived
        XCTAssertEqual(prompts, [[0, 1], [0, 1]], "ADR-018: the dictionary prompt reaches every streaming pass")
        let sessionPrompt = await engine.streamingPromptTokens
        XCTAssertEqual(sessionPrompt, [0, 1])

        // The batch pass ends the session first, then runs exactly one more
        // runtime call over the whole recording.
        let request = TranscriptionRequest(
            jobID: jobID,
            audio: AudioRecording(
                samples: ContiguousArray(repeating: 0, count: 48_000),
                duration: .seconds(3),
                peakLevelDBFS: -20,
                clippedFrameCount: 0
            ),
            languageHint: "zh"
        )
        let final = try await engine.transcribe(request) { _ in }
        XCTAssertEqual(final.text, "hello world final")
        let calls = await runtime.callCount
        XCTAssertEqual(calls, 3)
        let afterFinal = await engine.streamingPartialText
        XCTAssertNil(afterFinal)
        let partials = await sink.partials
        XCTAssertEqual(partials, ["hello", "hello world"], "no partial after the batch pass")
    }

    func testCancelDropsTheSessionAndNothingIsPublishedAfterwards() async throws {
        let runtime = QueuedRuntime(
            results: [makeResult(segments: [(0, 1, "late")])],
            delay: .milliseconds(150)
        )
        let package = StreamingTestFixtures.makePackage(tracker: &temporaryPackageURLs)
        let engine = makeEngine(runtime: runtime, package: package)
        try await engine.load(package)

        let sink = StreamingEventSink()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: nil, initialPrompt: nil) { event in
            await sink.append(event)
        }
        await engine.appendStreamingAudio(chunk(seconds: 1.5), jobID: jobID)
        try await waitUntil { await runtime.callCount == 1 }

        // Escape while the pass is in flight.
        await engine.cancel(jobID: jobID)
        let live = await engine.streamingPartialText
        XCTAssertNil(live)
        try await Task.sleep(for: .milliseconds(300))
        let partials = await sink.partials
        XCTAssertTrue(partials.isEmpty, "a pass that finishes after Escape must not publish")
        let observed = await runtime.cancellationObserved
        XCTAssertTrue(observed, "the runtime pass saw task cancellation")
    }

    func testEndStreamingWaitsForTheInFlightPassBeforeReturning() async throws {
        let runtime = QueuedRuntime(
            results: [makeResult(segments: [(0, 1, "slow")])],
            delay: .milliseconds(150),
            ignoresCancellation: true
        )
        let package = StreamingTestFixtures.makePackage(tracker: &temporaryPackageURLs)
        let engine = makeEngine(runtime: runtime, package: package)
        try await engine.load(package)

        let sink = StreamingEventSink()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: nil, initialPrompt: nil) { event in
            await sink.append(event)
        }
        await engine.appendStreamingAudio(chunk(seconds: 2), jobID: jobID)
        try await waitUntil { await runtime.inFlight }

        await engine.endStreaming(jobID: jobID)
        let stillInFlight = await runtime.inFlight
        XCTAssertFalse(stillInFlight, "endStreaming returns only after the runtime pass unwound")
        let partials = await sink.partials
        XCTAssertTrue(partials.isEmpty)
        // Idempotent, and a second session for a new job starts cleanly.
        await engine.endStreaming(jobID: jobID)
        try await engine.beginStreaming(jobID: UUID(), languageHint: nil, initialPrompt: nil) { _ in }
        await engine.unload()
        let afterUnload = await engine.streamingPartialText
        XCTAssertNil(afterUnload)
    }

    func testStreamingRequiresALoadedModelAndIgnoresOtherJobsAndBadChunks() async throws {
        let runtime = QueuedRuntime(results: [makeResult(segments: [(0, 1, "x")])])
        let package = StreamingTestFixtures.makePackage(tracker: &temporaryPackageURLs)
        let engine = makeEngine(runtime: runtime, package: package)

        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: nil, initialPrompt: nil) { _ in }
            XCTFail("no model loaded")
        } catch {
            XCTAssertEqual(error as? WhisperTranscriptionError, .noModelLoaded)
        }

        try await engine.load(package)
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: nil, initialPrompt: nil) { _ in }
        await engine.appendStreamingAudio(chunk(seconds: 2), jobID: UUID())
        await engine.appendStreamingAudio(
            AudioSampleChunk(samples: ContiguousArray(repeating: 0, count: 48_000), sampleRate: 48_000),
            jobID: jobID
        )
        try await Task.sleep(for: .milliseconds(150))
        let calls = await runtime.callCount
        XCTAssertEqual(calls, 0, "audio for another job or in the wrong format never reaches the runtime")
        await engine.endStreaming(jobID: jobID)
    }

    // MARK: Helpers

    private func makeEngine(runtime: QueuedRuntime, package: InstalledModelPackage) -> WhisperTranscriptionEngine {
        WhisperTranscriptionEngine(
            factory: SingleRuntimeFactory(runtime: runtime),
            trustedReleases: [StreamingTestFixtures.anchor(for: package)],
            tokenizerPreflight: NoopTokenizerPreflight(),
            streamingPolicy: WhisperStreamingPolicy(minimumNewAudioSeconds: 1)
        )
    }

    private func chunk(seconds: Double) -> AudioSampleChunk {
        AudioSampleChunk(samples: ContiguousArray(repeating: 0.01, count: Int(seconds * 16_000)))
    }

    private func makeResult(segments: [(Double, Double, String)]) -> WhisperRuntimeResult {
        WhisperRuntimeResult(
            text: segments.map(\.2).joined(separator: " "),
            detectedLanguage: "en",
            segments: segments.map { WhisperRuntimeSegment(start: .seconds($0.0), end: .seconds($0.1), text: $0.2) },
            runtimeReportedRealTimeFactor: 0.3
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true within \(timeout)")
    }
}

private actor StreamingEventSink {
    private(set) var events: [TranscriptionEvent] = []

    var partials: [String] {
        events.compactMap { event in
            if case .partialText(let text) = event { return text }
            return nil
        }
    }

    func append(_ event: TranscriptionEvent) {
        events.append(event)
    }
}

private struct NoopTokenizerPreflight: WhisperLocalTokenizerPreflight {
    func validate(tokenizerFolderURL: URL) async throws {}
}

private struct SingleRuntimeFactory: WhisperRuntimeFactory {
    let runtime: QueuedRuntime

    func make(configuration: WhisperRuntimeConfiguration) async throws -> any WhisperRuntime {
        runtime
    }
}

/// Returns scripted results in call order; the last result repeats.
private actor QueuedRuntime: WhisperRuntime {
    private var results: [WhisperRuntimeResult]
    private let delay: Duration?
    private let ignoresCancellation: Bool
    private(set) var callCount = 0
    private(set) var inFlight = false
    private(set) var cancellationObserved = false
    private(set) var languageHints: [String?] = []
    /// ADR-018: the prompt tokens of each pass, in order.
    private(set) var promptTokensReceived: [[Int]?] = []

    init(results: [WhisperRuntimeResult], delay: Duration? = nil, ignoresCancellation: Bool = false) {
        self.results = results
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func promptTokenLimit() async -> Int? { 111 }

    func encodePrompt(_ text: String) async -> [Int] {
        text.split(separator: " ").enumerated().map { $0.offset }
    }

    func transcribe(samples: [Float], languageHint: String?, promptTokens: [Int]?) async throws -> WhisperRuntimeResult {
        callCount += 1
        inFlight = true
        defer { inFlight = false }
        languageHints.append(languageHint)
        promptTokensReceived.append(promptTokens)
        if let delay {
            if ignoresCancellation {
                // A non-cooperative runtime: sleeps on a detached clock.
                let sleeper = Task.detached { try? await Task.sleep(for: delay) }
                _ = await sleeper.value
            } else {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    cancellationObserved = true
                    throw CancellationError()
                }
            }
        }
        cancellationObserved = cancellationObserved || Task.isCancelled
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return result
    }

    /// ADR-022 item 8: the engine warms up on load; counted apart from
    /// `callCount`, which these tests use as the number of real passes.
    private(set) var warmUpCallCount = 0

    func warmUp(samples: [Float]) async throws {
        warmUpCallCount += 1
    }

    func unload() async {}
}

enum StreamingTestFixtures {
    static func makePackage(tracker: inout [URL]) -> InstalledModelPackage {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-streaming-test-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
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
            try! fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            family: "whisper-large-v3-turbo",
            format: "whisperkit-coreml",
            workingSpaceBytes: 1_073_741_824,
            source: ModelManifestSource(
                repository: "argmaxinc/whisperkit-coreml",
                revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
                subdirectory: "openai_whisper-large-v3-v20240930_turbo"
            ),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: "argmaxinc/argmax-oss-swift/WhisperKit",
                exactVersion: "1.1.0"
            ),
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
            files: descriptors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try! encoder.encode(manifest).write(to: root.appendingPathComponent("ModelManifest.json"), options: .atomic)
        tracker.append(root)
        return InstalledModelPackage(
            manifest: manifest,
            packageURL: root,
            modelFolderURL: root.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: root.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .managedByKvoice
        )
    }

    static func anchor(for package: InstalledModelPackage) -> WhisperModelReleaseTrustAnchor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(package.manifest)
        return try! WhisperModelReleaseTrustAnchor(
            manifestData: data,
            manifestSHA256: try! WhisperModelReleaseTrustAnchor.digest(for: package.manifest)
        )
    }
}
