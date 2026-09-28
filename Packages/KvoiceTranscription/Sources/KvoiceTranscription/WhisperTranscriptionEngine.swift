import Foundation
import KvoiceDomain
import WhisperKit

/// The local runtime configuration passed to WhisperKit.
///
/// Model acquisition is deliberately not part of this module. A model manager
/// must hand the adapter a verified package, and the adapter receives explicit
/// model and tokenizer folders from that package. The `download` property is
/// kept in this value as an auditable invariant rather than inferred from the
/// presence of a path.
public struct WhisperRuntimeConfiguration: Sendable, Equatable {
    public let modelFolderURL: URL
    public let tokenizerFolderURL: URL
    public let download: Bool
    public let prewarm: Bool
    public let load: Bool
    /// Domain compute-unit choice; the factory maps it to WhisperKit's
    /// `ModelComputeOptions` so `MLComputeUnits` never leaves this file.
    public let computeUnits: SpeechComputeUnits

    public init(
        modelFolderURL: URL,
        tokenizerFolderURL: URL,
        download: Bool = false,
        prewarm: Bool = false,
        load: Bool = true,
        computeUnits: SpeechComputeUnits = .default
    ) {
        self.modelFolderURL = modelFolderURL.standardizedFileURL
        self.tokenizerFolderURL = tokenizerFolderURL.standardizedFileURL
        self.download = download
        self.prewarm = prewarm
        self.load = load
        self.computeUnits = computeUnits
    }
}

/// Runtime-owned segment data. WhisperKit types stop at this adapter boundary.
public struct WhisperRuntimeSegment: Sendable, Equatable {
    public let start: Duration
    public let end: Duration
    public let text: String

    public init(start: Duration, end: Duration, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// The output of one runtime inference before it is normalized to the domain
/// `TranscriptionResult`.
public struct WhisperRuntimeResult: Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let segments: [WhisperRuntimeSegment]
    public let runtimeReportedRealTimeFactor: Double?

    public init(
        text: String,
        detectedLanguage: String?,
        segments: [WhisperRuntimeSegment],
        runtimeReportedRealTimeFactor: Double?
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
        self.runtimeReportedRealTimeFactor = runtimeReportedRealTimeFactor
    }
}

/// The narrow runtime seam makes deterministic tests possible without loading
/// Core ML. No WhisperKit type crosses this protocol.
public protocol WhisperRuntime: Sendable {
    /// `promptTokens` are the encoded initial prompt (ADR-018), already
    /// capped by the engine at `promptTokenLimit`; `nil` sends none.
    func transcribe(
        samples: [Float],
        languageHint: String?,
        promptTokens: [Int]?
    ) async throws -> WhisperRuntimeResult

    /// The prompt-token cap this runtime enforces, or `nil` for a runtime
    /// that takes no prompt.
    func promptTokenLimit() async -> Int?

    /// Encodes prompt text the way this runtime expects prompt tokens: no
    /// special tokens (the runtime adds its own framing).
    func encodePrompt(_ text: String) async -> [Int]

    /// ADR-022 item 8: one throw-away pass over `samples` (near-silent,
    /// 16 kHz mono) whose only purpose is to make Core ML compile and
    /// specialise the graphs. Runtimes may bound the decode (a handful of
    /// tokens, no temperature fallback) — the kernels are what matter, not
    /// the text. The engine discards the result and never records it as a
    /// pass. The default forwards to `transcribe`.
    func warmUp(samples: [Float]) async throws

    func unload() async
}

public extension WhisperRuntime {
    func warmUp(samples: [Float]) async throws {
        _ = try await transcribe(samples: samples, languageHint: nil, promptTokens: nil)
    }
}

public protocol WhisperRuntimeFactory: Sendable {
    func make(configuration: WhisperRuntimeConfiguration) async throws -> any WhisperRuntime
}

public enum WhisperTranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case invalidModelPaths
    case invalidModelPackage(WhisperPackageValidationError)
    case noModelLoaded
    case invalidAudio(sampleRate: Double, channelCount: Int)
    case unsupportedTask
    case emptyTranscript
    case inferenceInProgress(JobID)
    /// A second `load` arrived while a load (Core ML build plus the
    /// ADR-022 warm-up) was still in flight on this actor.
    case loadInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidModelPaths:
            return "The verified model package did not provide explicit model and tokenizer paths."
        case let .invalidModelPackage(error):
            return "The model package failed runtime validation: \(error.localizedDescription)"
        case .noModelLoaded:
            return "A verified local Whisper model is not loaded."
        case let .invalidAudio(sampleRate, channelCount):
            return "Audio must be mono 16 kHz Float32 (received \(sampleRate) Hz, \(channelCount) channels)."
        case .unsupportedTask:
            return "Whisper v1 supports transcription only; translation belongs to the optional text API."
        case .emptyTranscript:
            return "The local transcription runtime returned an empty transcript."
        case let .inferenceInProgress(jobID):
            return "A transcription job is already running (\(jobID.uuidString))."
        case .loadInProgress:
            return "A model load is already in progress."
        }
    }
}

/// Pads a batch clip that is too short for WhisperKit 1.1.0's seek loop to
/// ever reach the encoder.
///
/// Confirmed against the WhisperKit 1.1.0 source (`TranscribeTask.run`):
/// `windowPadding = Int(options.windowClipTime * WhisperKit.sampleRate)`,
/// then the seek loop is `while seek < seekClipEnd - windowPadding` (a
/// single, non-VAD clip has `seekClipStart == 0`, `seekClipEnd ==
/// contentFrames`, so this is `while seek < contentFrames - windowPadding`).
/// `windowClipTime` defaults to `1.0` (seconds) and exists so WhisperKit
/// stops seeking one second before the clip's real end, which is what
/// keeps it from hallucinating a "Thank you."-style closing phrase over a
/// clip's final second (see `WhisperKitRuntimeAdapter.warmUp`, which sets
/// `windowClipTime: 0` for the same reason, deliberately, for warm-up only).
/// When `contentFrames <= windowPadding` — audio at or under
/// `windowClipTime` — `contentFrames - windowPadding <= 0`, so `seek` (which
/// starts at `0`) never satisfies the condition: the loop body, which is
/// the only place that calls the encoder, never runs, and WhisperKit
/// returns an empty result (`sttEmpty`). `SpeechGate.trailingSilenceMinimumSeconds`
/// keeps at least 1.0 s of trailing audio, so a short utterance ("yes",
/// "okay") trimmed to exactly that floor reproduces this on every batch
/// pass.
///
/// `windowClipTime` itself must not change for a real clip — its tail
/// protection is load-bearing — so the fix pads the *input* instead, with
/// enough margin that `contentFrames - windowPadding` is safely positive
/// rather than exactly zero. The padding is trailing digital silence, which
/// `SpeechGate.strippingTrailingHallucinations` already drops if the model
/// hallucinates a closing phrase over it (same mechanism it already uses
/// for WhisperKit's own 30 s window padding).
enum ShortClipPadding {
    /// `DecodingOptions.windowClipTime`'s default (WhisperKit 1.1.0); real
    /// clips never override it, so this mirrors the value rather than reads
    /// it back from WhisperKit.
    static let windowClipTimeSeconds: Double = 1.0
    /// Headroom past `windowClipTimeSeconds` so the seek loop's first check
    /// is unambiguously true instead of landing on the `== 0` edge.
    static let marginSeconds: Double = 0.5
    static let sampleRate: Double = 16_000
    /// 24,000 samples (1.5 s at 16 kHz).
    static let minimumSampleCount = Int((windowClipTimeSeconds + marginSeconds) * sampleRate)

    /// `samples` padded with trailing zeros up to `minimumSampleCount`, or
    /// unchanged when it already meets the floor.
    static func applied(to samples: [Float]) -> [Float] {
        guard samples.count < minimumSampleCount else { return samples }
        return samples + [Float](repeating: 0, count: minimumSampleCount - samples.count)
    }
}

/// Actor-isolated resident WhisperKit adapter.
///
/// A single instance stays loaded for the process lifetime or until the model
/// package is replaced/unloaded. The actor serializes calls and owns all
/// WhisperKit-specific state. In particular, it never asks WhisperKit to pick
/// a model or to download one implicitly.
public actor WhisperTranscriptionEngine: StreamingTranscriptionEngine {
    public let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: true,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )

    private let factory: any WhisperRuntimeFactory
    private let packageValidator: WhisperModelPackageValidator
    private let tokenizerPreflight: any WhisperLocalTokenizerPreflight
    private let streamingPolicy: WhisperStreamingPolicy
    /// Scalar-only sink for the prompt-truncation event; nil logs nothing.
    private let diagnostics: (any DiagnosticLogging)?
    private var runtime: (any WhisperRuntime)?
    private var currentPackage: InstalledModelPackage?
    private var lifecycle: ModelLifecycleState = .absent
    private var activeJobID: JobID?
    private var activeInference: ActiveInference?
    private var cancelledJobIDs: Set<JobID> = []
    private var streaming: StreamingState?
    /// True for the whole of `replaceRuntime` — the factory build, the
    /// warm-up, and the reload-on-units-change loop. The actor is reentrant
    /// across those awaits, and `runtime`/`currentPackage` are nil for the
    /// duration, so without this a second `load` (a default-model switch
    /// racing a compute-unit change or a memory-pressure reload) would
    /// interleave two `factory.make`/`unload` sequences on the same actor.
    /// The warm-up (ADR-022 item 8) made that window measurably wider.
    private var loadInProgress = false
    // MARK: Runtime
    private var computeUnits: SpeechComputeUnits = .default
    private var statistics = TranscriptionRuntimeStatistics()
    private let loadClock = ContinuousClock()

    public init(
        factory: any WhisperRuntimeFactory = WhisperKitRuntimeFactory(),
        trustedReleases: [WhisperModelReleaseTrustAnchor],
        tokenizerPreflight: any WhisperLocalTokenizerPreflight = WhisperKitLocalTokenizerPreflight(),
        streamingPolicy: WhisperStreamingPolicy = WhisperStreamingPolicy(),
        diagnostics: (any DiagnosticLogging)? = nil
    ) {
        self.factory = factory
        self.packageValidator = WhisperModelPackageValidator(trustedReleases: trustedReleases)
        self.tokenizerPreflight = tokenizerPreflight
        self.streamingPolicy = streamingPolicy
        self.diagnostics = diagnostics
    }

    public var loadedModelID: ModelID? {
        currentPackage?.manifest.modelID
    }

    /// The domain foundation uses `ModelLifecycleState` as the canonical model
    /// runtime state. This accessor intentionally does not introduce a second
    /// lifecycle enum in the adapter package.
    public var state: ModelLifecycleState {
        lifecycle
    }

    // MARK: Runtime

    /// The compute units the resident (or next) runtime is loaded with.
    public var currentComputeUnits: SpeechComputeUnits {
        computeUnits
    }

    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        statistics
    }

    // MARK: Dictionary (ADR-018)

    /// The cap the resident WhisperKit runtime enforces on prompt tokens
    /// (111 under WhisperKit 1.1.0: `(Constants.maxTokenContext / 2) - 1`,
    /// read from the pinned package so it follows the pin), or `.unsupported`
    /// for a runtime that reports no cap. `nil` while nothing is loaded.
    public var promptTokenLimit: PromptTokenLimit? {
        get async {
            guard let runtime, currentPackage != nil else { return nil }
            guard let limit = await runtime.promptTokenLimit() else { return .unsupported }
            return .tokens(limit)
        }
    }

    /// `text` encoded exactly as `transcribe` will encode a prompt.
    public func promptTokenCount(of text: String) async -> Int? {
        guard let runtime, currentPackage != nil else { return nil }
        return await runtime.encodePrompt(text).count
    }

    /// Encodes the prompt and enforces the runtime's cap. WhisperKit would
    /// otherwise keep the *last* tokens and drop the lead-in; keeping the
    /// first ones preserves the glossary shape. The budget in the UI is
    /// below the cap, so a cut means the resident model changed to one with
    /// a smaller limit after the list was written — logged as a scalar
    /// (`tokenCount` is the length before the cut, never the text).
    private func promptTokens(
        for prompt: String?,
        runtime: any WhisperRuntime,
        jobID: JobID
    ) async -> [Int]? {
        guard let prompt, !prompt.isEmpty, let limit = await runtime.promptTokenLimit() else { return nil }
        let tokens = await runtime.encodePrompt(prompt)
        guard !tokens.isEmpty else { return nil }
        guard tokens.count > limit else { return tokens }
        await diagnostics?.log(
            DiagnosticEvent(
                name: .sttPromptTruncated,
                jobID: jobID,
                result: .warning,
                attributes: DiagnosticAttributes(
                    reason: "dictionaryPromptTruncated",
                    tokenCount: tokens.count
                )
            )
        )
        return Array(tokens.prefix(limit))
    }

    /// Stores the choice and, when a package is resident, replaces the
    /// runtime with one loaded under the new units — the only way Core ML
    /// re-plans a graph. Refused while a batch pass or a streaming session
    /// holds the runtime. A failed reload falls back to the previous units
    /// so the model does not vanish because of a device choice.
    public func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        guard units != computeUnits else { return }
        if let activeJobID {
            throw WhisperTranscriptionError.inferenceInProgress(activeJobID)
        }
        if let streaming {
            throw WhisperTranscriptionError.inferenceInProgress(streaming.jobID)
        }
        let previousUnits = computeUnits
        computeUnits = units
        guard let package = currentPackage, runtime != nil else { return }
        do {
            try await replaceRuntime(with: package)
        } catch {
            computeUnits = previousUnits
            // `replaceRuntime` already tried to restore the previous package
            // under the (failed) new units; try once more with the old ones.
            if runtime == nil {
                try? await replaceRuntime(with: package)
            }
            throw error
        }
    }

    public func load(_ package: InstalledModelPackage) async throws {
        guard activeJobID == nil else {
            throw WhisperTranscriptionError.inferenceInProgress(activeJobID!)
        }
        guard !loadInProgress else {
            throw WhisperTranscriptionError.loadInProgress
        }

        do {
            try packageValidator.validate(package)
            do {
                try await tokenizerPreflight.validate(
                    tokenizerFolderURL: package.tokenizerFolderURL
                )
            } catch let error as WhisperPackageValidationError {
                throw error
            } catch {
                throw WhisperPackageValidationError.tokenizerSemanticsInvalid
            }
        } catch {
            if let currentPackage, runtime != nil {
                lifecycle = .ready(Self.summary(for: currentPackage))
            } else {
                lifecycle = .error(Self.runtimeFailure(error.localizedDescription))
            }
            await logLoadFailure(site: "validatePackage", reason: "invalidModelPackage", package: package)
            if let validationError = error as? WhisperPackageValidationError {
                throw WhisperTranscriptionError.invalidModelPackage(validationError)
            }
            throw error
        }

        guard Self.hasExplicitPaths(package) else {
            lifecycle = .error(Self.runtimeFailure("Verified package paths are missing."))
            await logLoadFailure(site: "packagePaths", reason: "invalidModelPaths", package: package)
            throw WhisperTranscriptionError.invalidModelPaths
        }

        if currentPackage == package, runtime != nil {
            lifecycle = .ready(Self.summary(for: package))
            return
        }

        try await replaceRuntime(with: package)
    }

    /// Unloads whatever is resident and loads `package` under the current
    /// compute units, timing the load. Shared by `load` (a new package) and
    /// `setComputeUnits` (the same package, re-planned).
    private func replaceRuntime(with package: InstalledModelPackage) async throws {
        guard !loadInProgress else {
            throw WhisperTranscriptionError.loadInProgress
        }
        loadInProgress = true
        defer { loadInProgress = false }
        let previousPackage = currentPackage
        let previousRuntime = runtime
        lifecycle = .loading
        runtime = nil
        currentPackage = nil

        // Do not keep two Core ML model graphs resident while replacing a
        // package. The verified package reference is retained for restoration.
        await previousRuntime?.unload()

        do {
            var newRuntime: any WhisperRuntime
            repeat {
                // The actor is reentrant across the await: a compute-unit
                // change that lands while Core ML is loading would otherwise
                // leave a runtime built under the old units while
                // `computeUnits` reports the new ones. Reload once more in
                // that case rather than lie about the placement.
                let unitsAtStart = computeUnits
                let loadStart = loadClock.now
                newRuntime = try await factory.make(configuration: configuration(for: package))
                if Task.isCancelled {
                    await newRuntime.unload()
                    throw CancellationError()
                }
                statistics.lastLoadDuration = loadClock.now - loadStart
                // ADR-022 item 8: warm up *before* the runtime becomes
                // resident, so the model reads as "still loading" to the
                // dictation start gate until the first-inference compile is
                // done. The warm-up is short (≤ ~1 s of audio) and is let
                // finish rather than interleaved with a real job; a
                // compute-unit change that lands during it is caught by
                // the check below, as during the load itself.
                await warmUp(newRuntime, package: package)
                if Task.isCancelled {
                    await newRuntime.unload()
                    throw CancellationError()
                }
                if computeUnits == unitsAtStart { break }
                await newRuntime.unload()
            } while true
            runtime = newRuntime
            currentPackage = package
            lifecycle = .ready(Self.summary(for: package))
        } catch {
            // ADR-022 item 9: one scalar event per load failure, before the
            // restore attempt so it is logged whatever the restore does.
            await logLoadFailure(
                site: "runtimeMake",
                reason: error is CancellationError ? "loadCancelled" : "runtimeLoadFailed",
                package: package
            )
            // A failed replacement must leave the previously verified package
            // usable whenever a fresh resident runtime can be restored.
            if let previousPackage {
                do {
                    let restoredRuntime = try await factory.make(
                        configuration: configuration(for: previousPackage)
                    )
                    // A restored runtime is a fresh Core ML load and is
                    // warmed up like any other.
                    await warmUp(restoredRuntime, package: previousPackage)
                    runtime = restoredRuntime
                    currentPackage = previousPackage
                    lifecycle = .ready(Self.summary(for: previousPackage))
                } catch {
                    runtime = nil
                    currentPackage = nil
                    lifecycle = .error(
                        Self.runtimeFailure("Whisper runtime failed to load or restore a verified package.")
                    )
                }
            } else {
                runtime = nil
                currentPackage = nil
                lifecycle = .error(Self.runtimeFailure("Whisper runtime failed to load the verified package."))
            }
            throw error
        }
    }

    /// ADR-022 item 9: every load failure the manager turns into
    /// `ModelLifecycleState.error` (and the HUD into Blocked / "model
    /// unavailable") leaves exactly one scalar line naming the gate.
    private func logLoadFailure(site: String, reason: String, package: InstalledModelPackage) async {
        await diagnostics?.log(
            DiagnosticEvent(
                name: .modelLoadCompleted,
                result: .failure,
                errorCode: .modelLoadFailed,
                attributes: DiagnosticAttributes(
                    modelID: package.manifest.modelID,
                    reason: reason,
                    site: site
                )
            )
        )
    }

    /// One silent pass straight to the runtime (never through `transcribe`,
    /// so it is not a job, not gated by `SpeechGate`, and not counted in
    /// `lastRealTimeFactor`). A failure is swallowed with one scalar event
    /// — the model loaded; the user merely pays the compile on the first
    /// real sentence — and `lastWarmUpDuration` stays nil for it.
    /// Cancellation is left to the caller, which checks `Task.isCancelled`.
    private func warmUp(_ runtime: any WhisperRuntime, package: InstalledModelPackage) async {
        let start = loadClock.now
        do {
            try await runtime.warmUp(samples: WarmUpAudio.samples())
            statistics.lastWarmUpDuration = loadClock.now - start
            await diagnostics?.log(
                DiagnosticEvent(
                    name: .modelWarmUpCompleted,
                    result: .success,
                    durationMilliseconds: Self.milliseconds(loadClock.now - start),
                    attributes: DiagnosticAttributes(modelID: package.manifest.modelID, site: "warmUp")
                )
            )
        } catch {
            statistics.lastWarmUpDuration = nil
            guard !Task.isCancelled else { return }
            await diagnostics?.log(
                DiagnosticEvent(
                    name: .modelWarmUpCompleted,
                    result: .warning,
                    errorCode: .modelLoadFailed,
                    attributes: DiagnosticAttributes(
                        modelID: package.manifest.modelID,
                        reason: "warmupFailed",
                        site: "warmUp"
                    )
                )
            )
        }
    }

    public func unload() async {
        guard activeJobID == nil else { return }
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        await runtime?.unload()
        runtime = nil
        currentPackage = nil
        lifecycle = .absent
    }

    /// Requests cancellation for a known job ID. WhisperKit observes task
    /// cancellation at decoder checkpoints; the ID set here additionally
    /// prevents a late runtime result from becoming a domain result if the
    /// underlying decoder finishes after cancellation was requested. A
    /// streaming session for the job is dropped the same way: its worker is
    /// cancelled and no partial can be published after this returns.
    public func cancel(jobID: JobID) {
        if let streaming, streaming.jobID == jobID {
            streaming.worker.cancel()
            self.streaming = nil
        }
        guard activeJobID == jobID else { return }
        cancelledJobIDs.insert(jobID)
        activeInference?.cancel()
    }

    // MARK: - Streaming (ADR-017)

    /// One live streaming dictation. `generation` guards late worker
    /// callbacks: a pass that finishes after `endStreaming` finds a different
    /// generation (or no session) and is discarded.
    private struct StreamingState {
        let jobID: JobID
        let generation: UInt64
        let events: @Sendable (TranscriptionEvent) async -> Void
        var session: WhisperStreamingSession
        var worker: Task<Void, Never>
    }

    /// The last streaming session's encoded prompt, for tests.
    public private(set) var streamingPromptTokens: [Int]?

    private var streamingGeneration: UInt64 = 0

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        guard let runtime, currentPackage != nil else {
            throw WhisperTranscriptionError.noModelLoaded
        }
        guard activeJobID == nil else {
            throw WhisperTranscriptionError.inferenceInProgress(activeJobID!)
        }
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }

        // Encoded once; every pass of the session sends the same prompt.
        let promptTokens = await promptTokens(for: initialPrompt, runtime: runtime, jobID: jobID)
        streamingPromptTokens = promptTokens
        streamingGeneration &+= 1
        let generation = streamingGeneration
        let worker = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runStreamingWorker(
                jobID: jobID,
                generation: generation,
                languageHint: languageHint,
                promptTokens: promptTokens
            )
        }
        streaming = StreamingState(
            jobID: jobID,
            generation: generation,
            events: events,
            session: WhisperStreamingSession(policy: streamingPolicy),
            worker: worker
        )
    }

    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        guard streaming?.jobID == jobID, chunk.isEngineCompatible else { return }
        streaming?.session.append(chunk.samples)
    }

    public func endStreaming(jobID: JobID) async {
        guard let state = streaming, state.jobID == jobID else { return }
        streaming = nil
        state.worker.cancel()
        // The worker may be inside a runtime pass; WhisperKit stops at its
        // next checkpoint. Waiting here is what guarantees the runtime is not
        // used concurrently by the batch pass that usually follows.
        await state.worker.value
    }

    /// The partial text of the live session, for callers that want the last
    /// value without an event (tests, the resident wrapper).
    public var streamingPartialText: String? {
        streaming?.session.partialText
    }

    private func runStreamingWorker(
        jobID: JobID,
        generation: UInt64,
        languageHint: String?,
        promptTokens: [Int]?
    ) async {
        while !Task.isCancelled {
            guard let runtime, streaming?.jobID == jobID, streaming?.generation == generation else { return }
            guard let window = streaming?.session.beginPass() else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let result: WhisperRuntimeResult
            do {
                result = try await runtime.transcribe(
                    samples: window,
                    languageHint: languageHint,
                    promptTokens: promptTokens
                )
            } catch {
                guard !Task.isCancelled,
                      streaming?.jobID == jobID, streaming?.generation == generation else { return }
                streaming?.session.abandonPass()
                // A failed pass (for example a decoder fallback exhausted on
                // a noisy window) is not fatal to the dictation; the batch
                // pass still produces the final text. Back off briefly.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard !Task.isCancelled,
                  streaming?.jobID == jobID, streaming?.generation == generation else { return }
            let partial = streaming!.session.apply(result, windowSampleCount: window.count)
            let events = streaming!.events
            await events(.partialText(partial))
        }
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> KvoiceDomain.TranscriptionResult {
        guard request.task == .transcribe else {
            throw WhisperTranscriptionError.unsupportedTask
        }
        // Streaming and the batch pass never overlap on the runtime.
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        guard request.audio.isEngineCompatible else {
            throw WhisperTranscriptionError.invalidAudio(
                sampleRate: request.audio.sampleRate,
                channelCount: request.audio.channelCount
            )
        }
        guard let runtime, let package = currentPackage else {
            throw WhisperTranscriptionError.noModelLoaded
        }
        guard activeJobID == nil else {
            throw WhisperTranscriptionError.inferenceInProgress(activeJobID!)
        }

        try Task.checkCancellation()
        cancelledJobIDs.remove(request.jobID)
        activeJobID = request.jobID
        let summary = Self.summary(for: package)
        lifecycle = .inference(summary, jobID: request.jobID)
        let clock = ContinuousClock()
        let requestStart = clock.now

        defer {
            cancelledJobIDs.remove(request.jobID)
            if activeJobID == request.jobID {
                activeInference = nil
                activeJobID = nil
                if currentPackage != nil {
                    lifecycle = .ready(summary)
                } else {
                    lifecycle = .absent
                }
            }
        }

        await events(.phase(.preparingAudio))
        try Task.checkCancellation()
        await events(.phase(.encoding))
        try Task.checkCancellation()
        await events(.phase(.decoding))
        try Task.checkCancellation()

        let promptTokens = await promptTokens(for: request.initialPrompt, runtime: runtime, jobID: request.jobID)
        let inferenceStart = clock.now
        let waiter = RuntimeInferenceWaiter()
        // Short-clip floor (this file's `ShortClipPadding`): a batch clip at
        // or under WhisperKit's `windowClipTime` never reaches the encoder
        // otherwise. Padding happens here, once, so every runtime — real or
        // a test double — sees the already-padded sample count; streaming
        // windows are unaffected (`runStreamingWorker` calls `runtime
        // .transcribe` directly, growing windows that are not this failure
        // mode in practice).
        let paddedSamples = ShortClipPadding.applied(to: Array(request.audio.samples))
        let runtimeTask = Task { [runtime] in
            try await runtime.transcribe(
                samples: paddedSamples,
                languageHint: request.languageHint,
                promptTokens: promptTokens
            )
        }
        activeInference = ActiveInference(
            jobID: request.jobID,
            runtimeTask: runtimeTask,
            waiter: waiter
        )
        if cancelledJobIDs.contains(request.jobID) {
            activeInference?.cancel()
        }
        Task { [runtimeTask, waiter] in
            do {
                waiter.finish(.success(try await runtimeTask.value))
            } catch {
                waiter.finish(.failure(error))
            }
        }

        let runtimeResult = try await withTaskCancellationHandler(operation: {
            try await waiter.wait()
        }, onCancel: {
            runtimeTask.cancel()
            waiter.cancel()
        })
        let inferenceEnd = clock.now

        // Both task cancellation and an explicit job cancellation invalidate
        // the result. This check is intentionally after the runtime returns so
        // a non-cooperative runtime cannot leak a late completion.
        try Task.checkCancellation()
        guard activeJobID == request.jobID, !cancelledJobIDs.contains(request.jobID) else {
            throw CancellationError()
        }

        await events(.phase(.finalizing))
        try Task.checkCancellation()

        let normalizedText = runtimeResult.text.precomposedStringWithCanonicalMapping
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WhisperTranscriptionError.emptyTranscript
        }

        // Runtime statistics: scalars only. The runtime's own RTF when it has
        // one, else wall inference time over the audio duration.
        let inferenceDuration = inferenceEnd - inferenceStart
        statistics.lastInferenceDuration = inferenceDuration
        statistics.lastRealTimeFactor = runtimeResult.runtimeReportedRealTimeFactor
            ?? Self.realTimeFactor(inference: inferenceDuration, audio: request.audio.duration)

        let segments = runtimeResult.segments.map { segment in
            TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text.precomposedStringWithCanonicalMapping
            )
        }
        return TranscriptionResult(
            text: normalizedText,
            detectedLanguage: runtimeResult.detectedLanguage,
            segments: segments,
            timings: TranscriptionTimings(
                requestStart: requestStart,
                inferenceStart: inferenceStart,
                inferenceEnd: inferenceEnd,
                runtimeReportedRealTimeFactor: runtimeResult.runtimeReportedRealTimeFactor
            ),
            modelID: package.manifest.modelID
        )
    }

    private static func hasExplicitPaths(_ package: InstalledModelPackage) -> Bool {
        package.modelFolderURL.isFileURL &&
            !package.modelFolderURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            package.tokenizerFolderURL.isFileURL &&
            !package.tokenizerFolderURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configuration(for package: InstalledModelPackage) -> WhisperRuntimeConfiguration {
        WhisperRuntimeConfiguration(
            modelFolderURL: package.modelFolderURL,
            tokenizerFolderURL: package.tokenizerFolderURL,
            download: false,
            prewarm: false,
            load: true,
            computeUnits: computeUnits
        )
    }

    static func realTimeFactor(inference: Duration, audio: Duration) -> Double? {
        let audioSeconds = Self.seconds(audio)
        guard audioSeconds > 0 else { return nil }
        return Self.seconds(inference) / audioSeconds
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        seconds(duration) * 1_000
    }

    private static func summary(for package: InstalledModelPackage) -> InstalledModelSummary {
        InstalledModelSummary(
            modelID: package.manifest.modelID,
            revision: package.manifest.source.revision,
            ownership: package.ownership
        )
    }

    private static func runtimeFailure(_ message: String) -> ModelFailure {
        ModelFailure(code: "MODEL-RUNTIME-FAILED", message: message)
    }
}

private struct ActiveInference: Sendable {
    let jobID: JobID
    let runtimeTask: Task<WhisperRuntimeResult, Error>
    let waiter: RuntimeInferenceWaiter

    func cancel() {
        runtimeTask.cancel()
        waiter.cancel()
    }
}

/// Completes the actor-side wait immediately when cancellation is requested,
/// while allowing a non-cooperative runtime task to unwind in the background.
/// The late task result is discarded and can never cross the transcription
/// method's cancellation checks.
private final class RuntimeInferenceWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WhisperRuntimeResult, Error>?
    private var completedResult: Result<WhisperRuntimeResult, Error>?

    func wait() async throws -> WhisperRuntimeResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(with: completedResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<WhisperRuntimeResult, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

/// Production factory for WhisperKit 1.1.0. The exact package pin is owned by
/// the root Swift package manifest; this adapter additionally hard-codes the
/// runtime safety switches that must remain disabled for offline operation.
public struct WhisperKitRuntimeFactory: WhisperRuntimeFactory {
    public init() {}

    public func make(configuration: WhisperRuntimeConfiguration) async throws -> any WhisperRuntime {
        let whisperConfiguration = WhisperKitConfig(
            modelFolder: configuration.modelFolderURL.path,
            tokenizerFolder: configuration.tokenizerFolderURL,
            computeOptions: Self.computeOptions(for: configuration.computeUnits),
            verbose: false,
            logLevel: .none,
            prewarm: configuration.prewarm,
            load: configuration.load,
            download: false
        )
        let whisperKit = try await WhisperKit(whisperConfiguration)
        return WhisperKitRuntimeAdapter(whisperKit: whisperKit)
    }

    /// The one place the domain choice becomes Core ML units. The mel
    /// spectrogram keeps WhisperKit's `cpuAndGPU` under the Neural Engine
    /// choice because that graph is not ANE-eligible and WhisperKit's default
    /// already reflects that; the encoder and decoder are what the user is
    /// choosing a device for.
    static func computeOptions(for units: SpeechComputeUnits) -> ModelComputeOptions {
        switch units {
        case .neuralEngineAndCPU:
            return ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .gpuAndCPU:
            return ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            )
        case .all:
            return ModelComputeOptions(
                melCompute: .all,
                audioEncoderCompute: .all,
                textDecoderCompute: .all
            )
        case .cpuOnly:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
        }
    }
}

private final class WhisperKitRuntimeAdapter: WhisperRuntime, @unchecked Sendable {
    private let whisperKit: WhisperKit

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    /// WhisperKit 1.1.0 `TextDecoder.prefillDecoderInputs`: the prompt is
    /// kept to `(Constants.maxTokenContext / 2) - 1` tokens (`suffix`, so
    /// the *start* is what it drops), special tokens are filtered out, and
    /// `<|startofprev|>` is prepended by WhisperKit itself. Read from the
    /// pinned constant rather than written as 111 so a pin bump moves it.
    func promptTokenLimit() async -> Int? {
        (Constants.maxTokenContext / 2) - 1
    }

    /// The shape WhisperKit's own CLI uses for `--prompt`: a leading space
    /// (Whisper's BPE merges the space into the first word token, as it is
    /// mid-transcript) and no special tokens.
    func encodePrompt(_ text: String) async -> [Int] {
        guard let tokenizer = whisperKit.tokenizer else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return tokenizer.encode(text: " " + trimmed)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// ADR-022 item 8. Bounded on purpose: the mel, the encoder and a few
    /// decoder steps are what compile the Neural Engine kernels; a full
    /// decode of near-silence would instead run Whisper's temperature
    /// fallback loop (up to six decodes on a low-logprob window) for text
    /// nobody reads. `language: "en"` with detection off skips the
    /// language-detection decode as well — same decoder graph, so nothing
    /// is left cold. `windowClipTime: 0` is load-bearing: WhisperKit 1.1.0
    /// stops seeking `windowClipTime` (1 s by default) before the end of
    /// the clip to avoid tail hallucinations, so a one-second clip under
    /// the default never reaches the encoder at all (measured: a 3 ms
    /// "warm-up" with `timings.encoding == 0`). This same fact is what a
    /// real batch clip at or under `windowClipTime` runs into —
    /// `ShortClipPadding` pads the batch path's input instead of touching
    /// `windowClipTime`, since a real clip needs the tail protection this
    /// warm-up deliberately disables.
    func warmUp(samples: [Float]) async throws {
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperatureFallbackCount: 0,
            sampleLength: 8,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 0
        )
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: { _ in Task.isCancelled ? false : nil }
        )
        // The encoder must actually have run, or the warm-up warmed nothing;
        // report that as a failure so the diagnostic line says so.
        guard let timings = results.first?.timings, timings.encoding > 0 else {
            throw WhisperTranscriptionError.emptyTranscript
        }
    }

    func transcribe(
        samples: [Float],
        languageHint: String?,
        promptTokens: [Int]?
    ) async throws -> WhisperRuntimeResult {
        // `usePrefillPrompt` must stay true: WhisperKit only reads
        // `promptTokens` inside `prefillDecoderInputs` (ADR-018).
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageHint,
            usePrefillPrompt: true,
            detectLanguage: languageHint == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            promptTokens: promptTokens
        )
        let results = await whisperKit.transcribeWithResults(
            audioArrays: [samples],
            decodeOptions: options,
            callback: { _ in
                // No partial text is forwarded to the domain. Returning false
                // lets WhisperKit stop at its next decoder checkpoint when the
                // calling task has been cancelled.
                Task.isCancelled ? false : nil
            }
        )
        guard let first = results.first else {
            throw WhisperTranscriptionError.emptyTranscript
        }
        let batch = try first.get()
        guard let result = batch.first else {
            throw WhisperTranscriptionError.emptyTranscript
        }

        let segments = result.segments.map { segment in
            WhisperRuntimeSegment(
                start: .seconds(Double(segment.start)),
                end: .seconds(Double(segment.end)),
                text: segment.text
            )
        }
        let rtf = result.timings.realTimeFactor
        return WhisperRuntimeResult(
            text: result.text,
            detectedLanguage: result.language,
            segments: segments,
            runtimeReportedRealTimeFactor: rtf.isFinite ? rtf : nil
        )
    }

    func unload() async {
        await whisperKit.unloadModels()
    }
}
