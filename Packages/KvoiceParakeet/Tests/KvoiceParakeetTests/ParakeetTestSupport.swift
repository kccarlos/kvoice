import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
@testable import KvoiceParakeet

/// A verified-looking package on disk: one small regular file per required
/// artifact root, a manifest that hashes them, and the canonical
/// `ModelManifest.json` beside `model/` — everything the validator needs,
/// nothing Core ML would load. Built in a temp folder per test.
struct FakeParakeetPackage {
    let root: URL
    let package: InstalledModelPackage
    let anchor: WhisperModelReleaseTrustAnchor

    static func make(variant: ParakeetModelVariant, extraFiles: [String: Data] = [:]) throws -> FakeParakeetPackage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-parakeet-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)

        var files: [ModelFileDescriptor] = []
        func write(_ relative: String, _ data: Data, role: ModelArtifactRole) throws {
            let url = root.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            files.append(ModelFileDescriptor(
                path: relative,
                bytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                role: role
            ))
        }
        for rootPath in variant.requiredArtifactRoots {
            if rootPath.hasSuffix(".json") {
                try write(rootPath, Data("{\"0\": \"<blk>\", \"1\": \"▁hello\"}".utf8), role: .tokenizer)
            } else {
                let role: ModelArtifactRole
                if rootPath.contains("Preprocessor") {
                    role = .melSpectrogram
                } else if rootPath.contains("SenseVoiceSmall_int8") {
                    role = .audioEncoder
                } else if rootPath.contains("SenseVoiceSmall_fp32") || rootPath.contains("CifAlphas") {
                    role = .otherRequired
                } else if rootPath.lowercased().contains("encoder") && (!rootPath.contains("streaming") || rootPath.contains("streaming_encoder")) {
                    role = .audioEncoder
                } else if rootPath.lowercased().contains("decoder") && !rootPath.contains("joint") {
                    role = .textDecoder
                } else {
                    role = .otherRequired
                }
                try write(rootPath + "/coremldata.bin", Data(rootPath.utf8), role: role)
                try write(rootPath + "/weights/weight.bin", Data(repeating: 7, count: 64), role: role)
            }
        }
        for (relative, data) in extraFiles {
            try write(relative, data, role: .otherRequired)
        }

        let modelID: String
        switch variant {
        case .tdtV3: modelID = KvoiceFluidAudioModels.parakeetTDTv3ModelID
        case .unifiedEN: modelID = KvoiceFluidAudioModels.parakeetUnifiedENModelID
        case .nemotronMultilingual: modelID = KvoiceFluidAudioModels.nemotronMultilingualModelID
        case .senseVoiceSmall: modelID = KvoiceFluidAudioModels.senseVoiceSmallModelID
        case .paraformerLargeZh: modelID = KvoiceFluidAudioModels.paraformerLargeZhModelID
        case .parakeetEOU: modelID = KvoiceFluidAudioModels.parakeetEOUModelID
        }
        let release = PinnedModelReleases.release(modelID: modelID)!
        let manifest = ModelManifest(
            schemaVersion: 1,
            modelID: release.modelID,
            family: release.family,
            format: release.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(repository: release.repository, revision: release.revision, subdirectory: release.subdirectory),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: release.runtimePackage,
                exactVersion: release.runtimeVersion
            ),
            tokenizer: ModelTokenizer(relativeRoot: "model"),
            files: files.sorted { $0.path < $1.path }
        )
        let canonical = try WhisperModelReleaseTrustAnchor.canonicalData(for: manifest)
        try canonical.write(to: root.appendingPathComponent("ModelManifest.json"))
        let anchor = try WhisperModelReleaseTrustAnchor(
            manifestData: canonical,
            manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: manifest)
        )
        return FakeParakeetPackage(
            root: root,
            package: InstalledModelPackage(
                manifest: manifest,
                packageURL: root,
                modelFolderURL: model,
                tokenizerFolderURL: model,
                ownership: .managedByKvoice
            ),
            anchor: anchor
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Fake runtime

final class FakeParakeetRuntime: ParakeetRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var _batchConfigurations: [ParakeetRuntimeConfiguration] = []
    private var _streamingConfigurations: [ParakeetRuntimeConfiguration] = []
    var transcript = ParakeetTranscript(text: "hello world", tokens: [
        ParakeetTokenSpan(text: "▁hello", start: 0.2, end: 0.5),
        ParakeetTokenSpan(text: "▁world", start: 0.6, end: 1.0)
    ], runtimeReportedRealTimeFactor: 0.05)
    var loadError: Error?
    /// Thrown by every decoder pass while set (the warm-up included).
    var decodeError: Error?
    /// When set, `makeBatchDecoder` records its configuration and then waits
    /// until the gate opens, so a test can act while a load is in flight.
    let gate: LoadGate?
    /// When set, every decoder pass (the warm-up included) records itself
    /// and then waits until the gate opens, throwing `CancellationError` if
    /// the task was cancelled meanwhile — so a test can cancel a load during
    /// its warm-up without real time.
    let warmUpGate: LoadGate?
    var lastLanguageHint: String??
    /// Every decoder pass, warm-up passes included, as (sample count, peak).
    private var _decodedPasses: [(sampleCount: Int, peak: Float)] = []
    var decodedPasses: [(sampleCount: Int, peak: Float)] { lock.withLock { _decodedPasses } }
    let streamingPartials: [String]
    /// When set, the decoder offers a streaming session over its own
    /// graphs (the Nemotron shape) and records the hint it was given; the
    /// engine must then never ask the runtime for one.
    let decoderStreams: Bool
    /// When set, a session answers `endOfUtteranceDetected` true once it
    /// has received this many samples (the Parakeet EOU shape: the flag
    /// turns on after a pause and stays on); nil answers false forever.
    let endOfUtteranceAfterSamples: Int?
    private(set) var unloadedDecoders = 0
    private(set) var unloadedSessions = 0
    private(set) var sharedSessionHints: [String?] = []

    init(
        streamingPartials: [String] = ["hello", "hello world"],
        gate: LoadGate? = nil,
        warmUpGate: LoadGate? = nil,
        decoderStreams: Bool = false,
        endOfUtteranceAfterSamples: Int? = nil
    ) {
        self.streamingPartials = streamingPartials
        self.gate = gate
        self.warmUpGate = warmUpGate
        self.decoderStreams = decoderStreams
        self.endOfUtteranceAfterSamples = endOfUtteranceAfterSamples
    }

    var batchConfigurations: [ParakeetRuntimeConfiguration] { lock.withLock { _batchConfigurations } }
    var streamingConfigurations: [ParakeetRuntimeConfiguration] { lock.withLock { _streamingConfigurations } }

    func makeBatchDecoder(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetBatchDecoder {
        lock.withLock { _batchConfigurations.append(configuration) }
        if let gate { await gate.waitUntilOpen() }
        if let loadError { throw loadError }
        return FakeDecoder(runtime: self)
    }

    func makeStreamingSession(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetStreamingSession {
        lock.withLock { _streamingConfigurations.append(configuration) }
        return FakeSession(runtime: self)
    }

    fileprivate func recordHint(_ hint: String?) { lock.withLock { lastLanguageHint = .some(hint) } }
    fileprivate func recordPass(samples: [Float]) {
        lock.withLock { _decodedPasses.append((samples.count, samples.map(abs).max() ?? 0)) }
    }
    fileprivate func decoderUnloaded() { lock.withLock { unloadedDecoders += 1 } }
    fileprivate func sessionUnloaded() { lock.withLock { unloadedSessions += 1 } }
    fileprivate func recordSharedSession(hint: String?) { lock.withLock { sharedSessionHints.append(hint) } }

    private final class FakeDecoder: ParakeetBatchDecoder, @unchecked Sendable {
        let runtime: FakeParakeetRuntime
        init(runtime: FakeParakeetRuntime) { self.runtime = runtime }
        func transcribe(samples: [Float], languageHint: String?) async throws -> ParakeetTranscript {
            runtime.recordPass(samples: samples)
            if let gate = runtime.warmUpGate {
                await gate.waitUntilOpen()
                try Task.checkCancellation()
            }
            if let error = runtime.decodeError { throw error }
            runtime.recordHint(languageHint)
            return runtime.transcript
        }
        func unload() async { runtime.decoderUnloaded() }
        func makeStreamingSession(languageHint: String?) async throws -> (any ParakeetStreamingSession)? {
            guard runtime.decoderStreams else { return nil }
            runtime.recordSharedSession(hint: languageHint)
            return FakeSession(runtime: runtime)
        }
    }

    private final class FakeSession: ParakeetStreamingSession, @unchecked Sendable {
        let runtime: FakeParakeetRuntime
        private let lock = NSLock()
        private var appendedSamples = 0
        init(runtime: FakeParakeetRuntime) { self.runtime = runtime }
        /// One partial per second of audio received, so coalesced appends
        /// (several chunks in one pass) still land on the expected text.
        func append(samples: [Float]) async throws -> String {
            lock.withLock {
                appendedSamples += samples.count
                let partials = runtime.streamingPartials
                let seconds = max(1, appendedSamples / 16_000)
                return partials[min(seconds, partials.count) - 1]
            }
        }
        func finish() async throws -> String { runtime.streamingPartials.last ?? "" }
        func unload() async { runtime.sessionUnloaded() }
        func endOfUtteranceDetected() async -> Bool {
            guard let threshold = runtime.endOfUtteranceAfterSamples else { return false }
            return lock.withLock { appendedSamples >= threshold }
        }
    }
}

func makeRecording(seconds: Double = 2) -> AudioRecording {
    AudioRecording(
        samples: ContiguousArray(repeating: 0.1, count: Int(16_000 * seconds)),
        duration: .seconds(seconds),
        peakLevelDBFS: -12,
        clippedFrameCount: 0
    )
}

/// A load that blocks until the test says so. `entered` completes when the
/// runtime is inside `makeBatchDecoder`, i.e. the engine is suspended
/// mid-`replaceRuntime`.
actor LoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        enteredCount += 1
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Suspends until a load has entered the gate.
    func waitUntilEntered() async {
        guard enteredCount == 0 else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
