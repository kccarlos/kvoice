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

    /// The pass in flight at Escape is held until after the cancel, then
    /// allowed to *return a result* — the worst case: a runtime that
    /// finishes anyway. The engine must discard it.
    func testCancelDropsTheSessionAndNothingIsPublishedAfterwards() async throws {
        let gate = RuntimeGate()
        let runtime = QueuedRuntime(
            results: [makeResult(segments: [(0, 1, "late")])],
            gate: gate
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
        await gate.entered()

        // Escape while the pass is in flight.
        await engine.cancel(jobID: jobID)
        let live = await engine.streamingPartialText
        XCTAssertNil(live)
        XCTAssertTrue(gate.sawCancellation, "the runtime pass saw task cancellation")
        gate.release()
        await engine.cancelledStreamingWorker?.value
        let partials = await sink.partials
        XCTAssertTrue(partials.isEmpty, "a pass that finishes after Escape must not publish")
        let calls = await runtime.callCount
        XCTAssertEqual(calls, 1, "the cancelled worker starts no further pass")
    }

    /// The runtime ignores cancellation (it returns only when the test
    /// releases it), and is released only once `endStreaming` has cancelled
    /// the worker — so `endStreaming` can return with the pass unwound only
    /// if it waited for it.
    func testEndStreamingWaitsForTheInFlightPassBeforeReturning() async throws {
        let gate = RuntimeGate()
        let runtime = QueuedRuntime(
            results: [makeResult(segments: [(0, 1, "slow")])],
            gate: gate
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
        await gate.entered()
        let inFlightAtStart = await runtime.inFlight
        XCTAssertTrue(inFlightAtStart)

        let ending = Task {
            await engine.endStreaming(jobID: jobID)
            return await runtime.inFlight
        }
        await gate.cancellationSeen()
        gate.release()
        let stillInFlight = await ending.value
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
        // A positive witness instead of waiting and seeing nothing: once a
        // valid chunk for this job produces a pass, that pass must contain
        // exactly the valid chunk's samples — the rejected audio never
        // reached the session, so it can never reach the runtime.
        await engine.appendStreamingAudio(chunk(seconds: 2), jobID: jobID)
        try await waitUntil { await runtime.callCount == 1 }
        let windows = await runtime.sampleCounts
        XCTAssertEqual(windows, [32_000], "audio for another job or in the wrong format never reaches the runtime")
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

    /// Polls the condition (the engine's worker checks for audio on its own
    /// 50 ms cadence, so there is no event to await). The deadline is a hang
    /// guard, not a timing assumption: a passing condition returns at once.
    private func waitUntil(
        timeout: Duration = .seconds(30),
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
    private let gate: RuntimeGate?
    private(set) var callCount = 0
    private(set) var inFlight = false
    /// The window length of each pass, in order.
    private(set) var sampleCounts: [Int] = []
    private(set) var languageHints: [String?] = []
    /// ADR-018: the prompt tokens of each pass, in order.
    private(set) var promptTokensReceived: [[Int]?] = []

    init(results: [WhisperRuntimeResult], gate: RuntimeGate? = nil) {
        self.results = results
        self.gate = gate
    }

    func promptTokenLimit() async -> Int? { 111 }

    func encodePrompt(_ text: String) async -> [Int] {
        text.split(separator: " ").enumerated().map { $0.offset }
    }

    func transcribe(samples: [Float], languageHint: String?, promptTokens: [Int]?) async throws -> WhisperRuntimeResult {
        callCount += 1
        inFlight = true
        defer { inFlight = false }
        sampleCounts.append(samples.count)
        languageHints.append(languageHint)
        promptTokensReceived.append(promptTokens)
        await gate?.hold()
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

/// Holds a runtime pass until the test releases it — a non-cooperative
/// runtime that notices cancellation but finishes anyway, as WhisperKit may
/// between checkpoints. Replaces fixed delays: the test decides when the
/// pass ends, and can wait for the moment the pass was cancelled.
final class RuntimeGate: @unchecked Sendable {
    private enum Condition { case entered, cancelled }

    private let lock = NSLock()
    private var released = false
    private var cancelled = false
    private var entries = 0
    private var held: CheckedContinuation<Void, Never>?
    private var nextWaiterID: UInt64 = 0
    /// Test waits, each resumed exactly once: `true` by the gate when its
    /// condition holds, `false` by its hang guard. Whoever removes it resumes it.
    private var waiters: [(id: UInt64, condition: Condition, continuation: CheckedContinuation<Bool, Never>)] = []

    var sawCancellation: Bool {
        lock.withLock { cancelled }
    }

    /// Called by the runtime inside a pass.
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                entries += 1
                let ready = takeWaiters(.entered)
                if released {
                    lock.unlock()
                    ready.forEach { $0.resume(returning: true) }
                    continuation.resume()
                    return
                }
                held = continuation
                lock.unlock()
                ready.forEach { $0.resume(returning: true) }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let ready = takeWaiters(.cancelled)
            lock.unlock()
            ready.forEach { $0.resume(returning: true) }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = held
        held = nil
        lock.unlock()
        continuation?.resume()
    }

    /// Resumes once a pass is being held.
    func entered(file: StaticString = #filePath, line: UInt = #line) async {
        await wait(for: .entered, "a runtime pass was never held", file: file, line: line)
    }

    /// Resumes once the held pass's task was cancelled.
    func cancellationSeen(file: StaticString = #filePath, line: UInt = #line) async {
        await wait(for: .cancelled, "the held pass never saw cancellation", file: file, line: line)
    }

    /// The 30 s bound is a hang guard, never reached on a pass: a
    /// regression fails with `message` instead of hanging the suite.
    private func wait(for condition: Condition, _ message: String, file: StaticString, line: UInt) async {
        let id = lock.withLock { () -> UInt64 in
            nextWaiterID &+= 1
            return nextWaiterID
        }
        let hangGuard = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.abandonWaiter(id)
        }
        let satisfied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            let holds = condition == .entered ? entries > 0 : cancelled
            if holds {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters.append((id, condition, continuation))
            lock.unlock()
        }
        hangGuard.cancel()
        if !satisfied {
            XCTFail(message, file: file, line: line)
        }
    }

    /// Called with the lock held.
    private func takeWaiters(_ condition: Condition) -> [CheckedContinuation<Bool, Never>] {
        let ready = waiters.filter { $0.condition == condition }.map(\.continuation)
        waiters.removeAll { $0.condition == condition }
        return ready
    }

    private func abandonWaiter(_ id: UInt64) {
        lock.lock()
        let index = waiters.firstIndex { $0.id == id }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }
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
