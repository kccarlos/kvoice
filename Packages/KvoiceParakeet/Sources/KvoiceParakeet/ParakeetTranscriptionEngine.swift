import Foundation
import KvoiceDomain
import KvoiceTranscription

public enum ParakeetTranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case invalidModelPackage(ParakeetPackageValidationError)
    case noModelLoaded
    case invalidAudio(sampleRate: Double, channelCount: Int)
    case unsupportedTask
    case inferenceInProgress(JobID)
    /// A second `load` arrived while a load (Core ML build plus the
    /// ADR-022 warm-up) was still in flight on this actor.
    case loadInProgress
    case streamingUnsupported(ParakeetModelVariant)
    /// The runtime was asked for a separate streaming graph set for a
    /// variant that streams over its resident pipeline (Nemotron). The
    /// engine never asks — it takes the batch decoder's session first —
    /// so this is the runtime naming the invariant, not a user-facing path.
    case streamingSessionUnavailable(ParakeetModelVariant)
    case streamingSessionActive(JobID)
    /// The model's graphs cannot be loaded under this compute-unit choice
    /// (Unified's int8 encoder on the GPU aborts Core ML; Paraformer's
    /// encoder is NaN off the Neural Engine). Never attempted.
    case computeUnitsUnsupported(ParakeetModelVariant, SpeechComputeUnits)

    public var errorDescription: String? {
        switch self {
        case let .invalidModelPackage(error):
            return "The model package failed runtime validation: \(error.localizedDescription)"
        case .noModelLoaded:
            return "A verified local Parakeet model is not loaded."
        case let .invalidAudio(sampleRate, channelCount):
            return "Audio must be mono 16 kHz Float32 (received \(sampleRate) Hz, \(channelCount) channels)."
        case .unsupportedTask:
            return "Parakeet models transcribe only; translation belongs to the optional text API."
        case let .inferenceInProgress(jobID):
            return "A transcription job is already running (\(jobID.uuidString))."
        case .loadInProgress:
            return "A model load is already in progress."
        case let .streamingUnsupported(variant):
            return "\(variant.rawValue) is a batch-only model and cannot stream."
        case let .streamingSessionActive(jobID):
            return "A streaming session is already open (\(jobID.uuidString))."
        case let .computeUnitsUnsupported(variant, units):
            // Concrete guidance, derived from the variant's own table so
            // the sentence cannot drift from what the engine accepts.
            let allowed = SpeechComputeUnits.allCases
                .filter(variant.supportsComputeUnits)
                .map(\.displayName)
                .joined(separator: ", ")
            return "\(variant.rawValue) cannot run under \(units.displayName): \(variant.computeUnitsRefusalReason). Choose \(allowed) in Speech Models › Runtime."
        case let .streamingSessionUnavailable(variant):
            return "\(variant.rawValue) streams over its resident pipeline; the runtime has no separate streaming graph set for it."
        }
    }
}

/// Actor-isolated resident FluidAudio adapter (ADR-019), the Parakeet
/// counterpart of `WhisperTranscriptionEngine`.
///
/// One instance stays loaded until the package is replaced or unloaded. It
/// validates the verified package again at the runtime boundary, asks the
/// `ParakeetRuntime` to build the pipeline from the package's `model/`
/// folder, and never asks the runtime to find, cache or download anything.
///
/// Prompt: these models take no conditioning text, so the protocol defaults
/// stand — `promptTokenLimit` is `.unsupported` while loaded and
/// `promptTokenCount` is nil — and the Dictionary section shows its
/// "no dictionary" state (ADR-018 rule 3).
public actor ParakeetTranscriptionEngine: StreamingTranscriptionEngine {
    public let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: true,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )

    private let runtime: any ParakeetRuntime
    private let validator: ParakeetModelPackageValidator
    /// Scalar-only sink for the load-failure and warm-up events
    /// (ADR-022 items 8 and 9); nil logs nothing.
    private let diagnostics: (any DiagnosticLogging)?
    private var decoder: (any ParakeetBatchDecoder)?
    private var currentPackage: InstalledModelPackage?
    private var currentVariant: ParakeetModelVariant?
    /// The variant a `replaceRuntime` is building right now. `currentVariant`
    /// is nil for the duration of a load, so `setComputeUnits` validates a
    /// choice against this instead; without it a click landing mid-load
    /// could store GPU + CPU and the loop would build the Unified encoder
    /// under it (the abort the refusal exists to prevent).
    private var pendingVariant: ParakeetModelVariant?
    /// True for the whole of `replaceRuntime` (factory build, warm-up,
    /// reload loop): the actor is reentrant across those awaits with
    /// `decoder`/`currentPackage` nil, so a second `load` racing in would
    /// interleave two build/unload sequences. See the Whisper engine.
    private var loadInProgress = false
    private var lifecycle: ModelLifecycleState = .absent
    private var activeJobID: JobID?
    private var computeUnits: SpeechComputeUnits = .default
    private var statistics = TranscriptionRuntimeStatistics()
    private let clock = ContinuousClock()

    /// One live streaming dictation (Unified, Nemotron, Parakeet EOU). The session is opened
    /// on `beginStreaming` and dropped on `endStreaming`; `generation`
    /// guards a late worker result against a session that has since ended.
    /// Audio accumulates in `pending` and one worker drains it, so a slow
    /// encoder coalesces chunks into one bigger pass instead of queueing a
    /// pass per capture buffer (the queue would otherwise grow without
    /// bound for the length of the recording).
    private struct StreamingState {
        let jobID: JobID
        let generation: UInt64
        let events: @Sendable (TranscriptionEvent) async -> Void
        let session: any ParakeetStreamingSession
        var lastPublished: String
        /// The end-of-utterance scalar as last published (ADR-023 seam):
        /// the event goes out only when the session's answer changes.
        var lastEndOfUtterance: Bool
        var pending: [Float]
        var worker: Task<Void, Never>?
    }

    private var streaming: StreamingState?
    private var streamingGeneration: UInt64 = 0

    public init(
        runtime: any ParakeetRuntime,
        trustedReleases: [WhisperModelReleaseTrustAnchor],
        diagnostics: (any DiagnosticLogging)? = nil
    ) {
        self.runtime = runtime
        self.validator = ParakeetModelPackageValidator(trustedReleases: trustedReleases)
        self.diagnostics = diagnostics
    }

    public var loadedModelID: ModelID? {
        currentPackage?.manifest.modelID
    }

    public var loadedVariant: ParakeetModelVariant? {
        currentVariant
    }

    public var state: ModelLifecycleState {
        lifecycle
    }

    public var currentComputeUnits: SpeechComputeUnits {
        computeUnits
    }

    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        statistics
    }

    // MARK: - Load / unload

    public func load(_ package: InstalledModelPackage) async throws {
        if let activeJobID {
            throw ParakeetTranscriptionError.inferenceInProgress(activeJobID)
        }
        guard !loadInProgress else {
            throw ParakeetTranscriptionError.loadInProgress
        }
        let variant: ParakeetModelVariant
        do {
            variant = try validator.validate(package)
        } catch let error as ParakeetPackageValidationError {
            if currentPackage == nil || decoder == nil {
                lifecycle = .error(Self.runtimeFailure(error.localizedDescription))
            }
            await logLoadFailure(site: "validatePackage", reason: "invalidModelPackage", package: package)
            throw ParakeetTranscriptionError.invalidModelPackage(error)
        }
        if currentPackage == package, decoder != nil {
            lifecycle = .ready(Self.summary(for: package))
            return
        }
        guard variant.supportsComputeUnits(computeUnits) else {
            let error = ParakeetTranscriptionError.computeUnitsUnsupported(variant, computeUnits)
            if currentPackage == nil || decoder == nil {
                lifecycle = .error(Self.runtimeFailure(error.localizedDescription))
            }
            await logLoadFailure(site: "computeUnits", reason: "computeUnitsUnsupported", package: package)
            throw error
        }
        try await replaceRuntime(with: package, variant: variant)
    }

    /// Unloads whatever is resident and loads `package` under the current
    /// compute units, timing the load (Core ML compiles for the Neural
    /// Engine on first use, like Whisper). Shared by `load` and
    /// `setComputeUnits`.
    private func replaceRuntime(with package: InstalledModelPackage, variant: ParakeetModelVariant) async throws {
        guard !loadInProgress else {
            throw ParakeetTranscriptionError.loadInProgress
        }
        // As in the Whisper engine (2026-09-29): cancellation is honoured
        // here, before anything moves; past this point a built decoder is
        // finished compile work and becomes resident.
        try Task.checkCancellation()
        loadInProgress = true
        defer { loadInProgress = false }
        let previous = (package: currentPackage, variant: currentVariant, decoder: decoder)
        // Both callers validated `computeUnits` for `variant` before calling;
        // this is the value to fall back to if a concurrent change slips a
        // refused choice past them.
        let safeUnits = computeUnits
        lifecycle = .loading
        decoder = nil
        currentPackage = nil
        currentVariant = nil
        pendingVariant = variant
        defer { pendingVariant = nil }
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        // Never two graph sets resident at once.
        await previous.decoder?.unload()

        do {
            var newDecoder: any ParakeetBatchDecoder
            repeat {
                // Reentrancy across the await: a compute-unit change landing
                // while Core ML loads would leave a pipeline built under the
                // old units. Load once more in that case.
                let unitsAtStart = computeUnits
                // Belt and braces for the refusal: never hand the runtime a
                // choice this variant cannot take, whatever path stored it.
                guard variant.supportsComputeUnits(unitsAtStart) else {
                    computeUnits = safeUnits
                    throw ParakeetTranscriptionError.computeUnitsUnsupported(variant, unitsAtStart)
                }
                let start = clock.now
                newDecoder = try await runtime.makeBatchDecoder(
                    configuration: ParakeetRuntimeConfiguration(
                        variant: variant,
                        modelFolderURL: package.modelFolderURL,
                        computeUnits: unitsAtStart
                    )
                )
                statistics.lastLoadDuration = clock.now - start
                // ADR-022 item 8: warm up before the decoder becomes
                // resident (the model still reads as loading to the start
                // gate); a compute-unit change landing during the warm-up
                // is caught by the check below, as during the load.
                await warmUp(newDecoder, package: package)
                if computeUnits == unitsAtStart { break }
                await newDecoder.unload()
            } while true
            decoder = newDecoder
            currentPackage = package
            currentVariant = variant
            lifecycle = .ready(Self.summary(for: package))
        } catch {
            // ADR-022 item 9: one scalar event per load failure, logged
            // before the restore attempt whatever the restore does.
            await logLoadFailure(
                site: "runtimeMake",
                reason: error is CancellationError ? "loadCancelled" : "runtimeLoadFailed",
                package: package
            )
            if let previousPackage = previous.package, let previousVariant = previous.variant,
               let restored = try? await runtime.makeBatchDecoder(
                   configuration: configuration(for: previousPackage, variant: previousVariant)
               ) {
                // A restored graph set is a fresh Core ML load and is warmed
                // up like any other, so the fallback is at full speed too.
                await warmUp(restored, package: previousPackage)
                decoder = restored
                currentPackage = previousPackage
                currentVariant = previousVariant
                lifecycle = .ready(Self.summary(for: previousPackage))
            } else {
                decoder = nil
                currentPackage = nil
                currentVariant = nil
                lifecycle = .error(Self.runtimeFailure(
                    "The Parakeet runtime failed to load the verified package: \(error.localizedDescription)"
                ))
            }
            throw error
        }
    }

    /// ADR-022 item 9: every load failure leaves exactly one scalar line
    /// naming the gate; the manager turns the throw into `.error` and the
    /// HUD into Blocked / "model unavailable".
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

    /// One silent pass straight to the decoder — not a job, not gated, not
    /// counted in `lastRealTimeFactor`. A failure is swallowed with one
    /// scalar event and leaves `lastWarmUpDuration` nil; the load stands.
    /// Cancellation is left to the caller, which checks `Task.isCancelled`.
    private func warmUp(_ decoder: any ParakeetBatchDecoder, package: InstalledModelPackage) async {
        let start = clock.now
        do {
            _ = try await decoder.transcribe(samples: WarmUpAudio.samples(), languageHint: nil)
            let duration = clock.now - start
            statistics.lastWarmUpDuration = duration
            await diagnostics?.log(
                DiagnosticEvent(
                    name: .modelWarmUpCompleted,
                    result: .success,
                    durationMilliseconds: Self.seconds(duration) * 1_000,
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
        await decoder?.unload()
        decoder = nil
        currentPackage = nil
        currentVariant = nil
        lifecycle = .absent
    }

    // MARK: - Runtime

    /// Stores the choice and, when a package is resident, rebuilds the
    /// pipeline under the new units — the only way Core ML re-plans. Refused
    /// while a batch pass or a streaming session holds the runtime. A failed
    /// reload falls back to the previous units.
    public func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        guard units != computeUnits else { return }
        if let activeJobID {
            throw ParakeetTranscriptionError.inferenceInProgress(activeJobID)
        }
        if let streaming {
            throw ParakeetTranscriptionError.streamingSessionActive(streaming.jobID)
        }
        if let variant = currentVariant ?? pendingVariant, !variant.supportsComputeUnits(units) {
            // Refused outright: the stored choice stays, nothing is unloaded.
            // `pendingVariant` covers a choice made while that model loads.
            throw ParakeetTranscriptionError.computeUnitsUnsupported(variant, units)
        }
        let previousUnits = computeUnits
        computeUnits = units
        guard let package = currentPackage, let variant = currentVariant, decoder != nil else { return }
        do {
            try await replaceRuntime(with: package, variant: variant)
        } catch {
            computeUnits = previousUnits
            if decoder == nil {
                try? await replaceRuntime(with: package, variant: variant)
            }
            throw error
        }
    }

    private func configuration(for package: InstalledModelPackage, variant: ParakeetModelVariant) -> ParakeetRuntimeConfiguration {
        ParakeetRuntimeConfiguration(
            variant: variant,
            modelFolderURL: package.modelFolderURL,
            computeUnits: computeUnits
        )
    }

    // MARK: - Batch

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        let requestStart = clock.now
        guard let decoder, let package = currentPackage, let variant = currentVariant else {
            throw ParakeetTranscriptionError.noModelLoaded
        }
        guard request.task == .transcribe else {
            throw ParakeetTranscriptionError.unsupportedTask
        }
        guard request.audio.isEngineCompatible else {
            throw ParakeetTranscriptionError.invalidAudio(
                sampleRate: request.audio.sampleRate,
                channelCount: request.audio.channelCount
            )
        }
        if let activeJobID {
            throw ParakeetTranscriptionError.inferenceInProgress(activeJobID)
        }
        // The streaming session (display only) must be gone before the batch
        // pass so the runtime is never used concurrently (ADR-017 rule 3).
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        activeJobID = request.jobID
        defer { activeJobID = nil }

        await events(.phase(.preparingAudio))
        try Task.checkCancellation()
        await events(.phase(.encoding))
        await events(.phase(.decoding))

        let hint = variant.runtimeLanguageHint(for: request.languageHint)
        let samples = Array(request.audio.samples)
        let inferenceStart = clock.now
        let runtimeTask = Task { [decoder] in
            try await decoder.transcribe(samples: samples, languageHint: hint)
        }
        let transcript = try await withTaskCancellationHandler(operation: {
            try await runtimeTask.value
        }, onCancel: {
            runtimeTask.cancel()
        })
        let inferenceEnd = clock.now
        try Task.checkCancellation()
        await events(.phase(.finalizing))

        let inferenceDuration = inferenceEnd - inferenceStart
        statistics.lastInferenceDuration = inferenceDuration
        statistics.lastRealTimeFactor = transcript.runtimeReportedRealTimeFactor
            ?? Self.realTimeFactor(inference: inferenceDuration, audio: request.audio.duration)

        // An empty transcript is a result, not a failure: the controller
        // turns it into `sttEmpty` ("nothing heard"), which is the honest
        // outcome for silence handed to a model that never hallucinates a
        // closing phrase.
        let text = transcript.text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text,
            detectedLanguage: transcript.detectedLanguage ?? variant.reportedLanguage(forHint: request.languageHint),
            segments: Self.segments(for: text, tokens: transcript.tokens, audioDuration: request.audio.duration),
            timings: TranscriptionTimings(
                requestStart: requestStart,
                inferenceStart: inferenceStart,
                inferenceEnd: inferenceEnd,
                runtimeReportedRealTimeFactor: transcript.runtimeReportedRealTimeFactor
            ),
            modelID: package.manifest.modelID
        )
    }

    /// One segment spanning the decoded tokens. RNNT/TDT emit tokens at
    /// frames, not sentence chunks, so a Whisper-style segmentation would be
    /// invented; the span is the honest fact and is what `SpeechGate`'s
    /// per-segment energy check needs.
    static func segments(for text: String, tokens: [ParakeetTokenSpan], audioDuration: Duration) -> [TranscriptSegment] {
        guard !text.isEmpty else { return [] }
        let start = tokens.first.map { Duration.seconds(max(0, $0.start)) } ?? .zero
        let end = tokens.last.map { Duration.seconds(max(0, $0.end)) } ?? audioDuration
        return [TranscriptSegment(start: start, end: max(start, end), text: text)]
    }

    // MARK: - Streaming (ADR-017; Unified, Nemotron and Parakeet EOU)

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        guard let package = currentPackage, let variant = currentVariant, let decoder else {
            throw ParakeetTranscriptionError.noModelLoaded
        }
        guard variant.supportsStreaming else {
            throw ParakeetTranscriptionError.streamingUnsupported(variant)
        }
        if let activeJobID {
            throw ParakeetTranscriptionError.inferenceInProgress(activeJobID)
        }
        if let streaming {
            throw ParakeetTranscriptionError.streamingSessionActive(streaming.jobID)
        }
        // `initialPrompt` is ignored: the model takes none (ADR-018 rule 3).
        streamingGeneration += 1
        // A model whose one pipeline serves both modes (Nemotron, Parakeet
        // EOU) streams over the resident graphs; Unified loads its
        // streaming export.
        let session: any ParakeetStreamingSession
        if let shared = try await decoder.makeStreamingSession(
            languageHint: variant.runtimeLanguageHint(for: languageHint)
        ) {
            session = shared
        } else {
            session = try await runtime.makeStreamingSession(
                configuration: configuration(for: package, variant: variant)
            )
        }
        streaming = StreamingState(
            jobID: jobID,
            generation: streamingGeneration,
            events: events,
            session: session,
            lastPublished: "",
            lastEndOfUtterance: false,
            pending: [],
            worker: nil
        )
    }

    /// Queues the chunk and makes sure a worker is draining the queue. A
    /// chunk for another job, or for a job whose session ended, is dropped.
    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        guard let state = streaming, state.jobID == jobID, chunk.isEngineCompatible else { return }
        streaming?.pending.append(contentsOf: chunk.samples)
        guard state.worker == nil else { return }
        let generation = state.generation
        streaming?.worker = Task { await self.drainStreamingQueue(generation: generation) }
    }

    /// Runs on the actor between passes; each pass suspends the actor while
    /// the session encodes, so appends keep flowing into `pending`.
    private func drainStreamingQueue(generation: UInt64) async {
        while let work = takePendingStreamingAudio(generation: generation) {
            guard let text = try? await work.session.append(samples: work.samples) else { continue }
            if publishPartial(text, generation: generation) {
                await work.events(.partialText(text))
            }
            // The end-of-utterance scalar rides after the partial it belongs
            // to, on change only. Nothing downstream acts on it (FR-AUD-007;
            // the planned ADR-023 is where that would change).
            let endOfUtterance = await work.session.endOfUtteranceDetected()
            if publishEndOfUtterance(endOfUtterance, generation: generation) {
                await work.events(.endOfUtteranceDetected(endOfUtterance))
            }
        }
    }

    /// The next batch of queued samples, or nil — clearing the worker slot —
    /// when the queue is empty or the session is gone.
    private func takePendingStreamingAudio(
        generation: UInt64
    ) -> (samples: [Float], session: any ParakeetStreamingSession, events: @Sendable (TranscriptionEvent) async -> Void)? {
        guard var state = streaming, state.generation == generation, !state.pending.isEmpty, !Task.isCancelled else {
            if streaming?.generation == generation { streaming?.worker = nil }
            return nil
        }
        let samples = state.pending
        state.pending = []
        streaming = state
        return (samples, state.session, state.events)
    }

    /// Records the text as published if the session is still the same one
    /// and the text changed; the caller then emits it.
    private func publishPartial(_ text: String, generation: UInt64) -> Bool {
        guard var state = streaming, state.generation == generation, state.lastPublished != text else {
            return false
        }
        state.lastPublished = text
        streaming = state
        return true
    }

    /// Records the end-of-utterance scalar if the session is still the same
    /// one and the value changed; the caller then emits it.
    private func publishEndOfUtterance(_ detected: Bool, generation: UInt64) -> Bool {
        guard var state = streaming, state.generation == generation, state.lastEndOfUtterance != detected else {
            return false
        }
        state.lastEndOfUtterance = detected
        streaming = state
        return true
    }

    /// Waits until every queued chunk has been decoded and its partial
    /// published. For tests and for a caller that wants the last partial
    /// before ending the session; `endStreaming` itself discards audio
    /// still queued, as the Whisper session does.
    public func awaitStreamingPasses() async {
        while let worker = streaming?.worker {
            await worker.value
        }
    }

    /// Waits for the pass in flight, drops the session and releases the
    /// streaming graphs. No partial is published after this returns.
    public func endStreaming(jobID: JobID) async {
        guard let state = streaming, state.jobID == jobID else { return }
        streaming = nil
        state.worker?.cancel()
        await state.worker?.value
        await state.session.unload()
    }

    // MARK: - Helpers

    static func realTimeFactor(inference: Duration, audio: Duration) -> Double? {
        let audioSeconds = seconds(audio)
        guard audioSeconds > 0 else { return nil }
        return seconds(inference) / audioSeconds
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
