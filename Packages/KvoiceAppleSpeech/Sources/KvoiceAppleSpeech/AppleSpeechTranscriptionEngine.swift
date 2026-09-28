import Foundation
import KvoiceDomain

public enum AppleSpeechTranscriptionError: Error, Sendable, Equatable, LocalizedError {
    /// The package handed to `load` is not the Apple Speech system entry.
    case invalidModelPackage(ModelID)
    case noModelLoaded
    case invalidAudio(sampleRate: Double, channelCount: Int)
    case unsupportedTask
    case inferenceInProgress(JobID)
    case loadInProgress
    case streamingSessionActive(JobID)
    /// The framework cannot run on this Mac (macOS 15, or ineligible hardware).
    case unavailable(AppleSpeechAvailability)
    /// The chosen transcription language has no supported locale here. The
    /// Models section warns before this is reached (the catalog overlay);
    /// this is the engine's own refusal, typed like the compute-unit ones.
    case unsupportedLanguage(code: String?)
    /// The locale's assets are not installed for this app: Install the
    /// model (for this language) in Speech Models.
    case assetsNotInstalled(localeIdentifier: String)
    /// The framework refused or failed the analysis.
    case runtime(AppleSpeechError)

    public var errorDescription: String? {
        switch self {
        case let .invalidModelPackage(id):
            return "The package \(id) is not the Apple Speech system entry."
        case .noModelLoaded:
            return "Apple Speech is not loaded."
        case let .invalidAudio(sampleRate, channelCount):
            return "Audio must be mono 16 kHz Float32 (received \(sampleRate) Hz, \(channelCount) channels)."
        case .unsupportedTask:
            return "Apple Speech transcribes only; translation belongs to the optional text API."
        case let .inferenceInProgress(jobID):
            return "A transcription job is already running (\(jobID.uuidString))."
        case .loadInProgress:
            return "A model load is already in progress."
        case let .streamingSessionActive(jobID):
            return "A streaming session is already open (\(jobID.uuidString))."
        case .unavailable(.requiresNewerMacOS):
            return SystemManagedUnavailableReason.requiresNewerMacOS.message
        case .unavailable:
            return SystemManagedUnavailableReason.deviceNotEligible.message
        case let .unsupportedLanguage(code):
            let language = TranscriptionLanguage.displayName(forCode: code)
            return "Apple Speech does not support \(language) on this Mac. Choose a supported language in Speech Models, or use a Whisper model for \(language)."
        case let .assetsNotInstalled(localeIdentifier):
            return "The Apple Speech assets for \(localeIdentifier) are not installed. Install the model for this language in Speech Models."
        case let .runtime(error):
            return "Apple Speech failed: \(error)."
        }
    }
}

/// Actor-isolated Apple Speech adapter (ADR-025), the counterpart of
/// `WhisperTranscriptionEngine` and `ParakeetTranscriptionEngine` over a
/// runtime the OS owns.
///
/// "Loading" a system model is cheap — there is no package to open — so
/// `load` checks the framework's availability, records the system package
/// and runs the ADR-022 warm-up pass (one short analysis in the preferred
/// language, which makes the platform bring its models into the process;
/// skipped without failing when that language's assets are not installed).
/// A batch pass is one analyzer over the whole clip; a streaming session
/// is one analyzer fed as the recording continues, whose volatile results
/// become `.partialText` and whose finalized ones close each range. The
/// batch pass is still the source of the final text (ADR-017 rule), so a
/// streaming session is torn down before it runs.
///
/// Dictionary: the terms arrive as the rendered prompt (ADR-018) and are
/// recovered with `DictionaryPrompt.terms(fromRendered:)`, capped at
/// `contextualStringsLimit`, and handed to the platform as contextual
/// strings — so `promptTokenLimit` is `.phrases(100)` while loaded.
public actor AppleSpeechTranscriptionEngine: StreamingTranscriptionEngine {
    /// Apple's documented ceiling for `AnalysisContext.contextualStrings`:
    /// "limit the total number of phrases across all tags to no more than
    /// 100". The engine sends the first hundred terms and the Dictionary
    /// section shows the count against this.
    public static let contextualStringsLimit = 100
    /// The catalog id of the one system-managed Apple Speech entry.
    public static let modelID: ModelID = "apple-speech"

    public let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: true,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )

    private let runtime: any AppleSpeechRuntime
    private let diagnostics: (any DiagnosticLogging)?
    /// The locale the mapping resolves against (`Locale.current` in the
    /// app; injected so tests are deterministic).
    private let currentLocale: Locale
    private var currentPackage: InstalledModelPackage?
    private var lifecycle: ModelLifecycleState = .absent
    private var loadInProgress = false
    private var activeJobID: JobID?
    private var statistics = TranscriptionRuntimeStatistics()
    /// The last `supportedLocaleIdentifiers` read, refreshed on every load.
    private var supportedLocales: [String] = []
    /// The transcription language the shell last told us about, for the
    /// warm-up's locale; the request carries its own hint.
    private var preferredLanguageCode: String?
    private let clock = ContinuousClock()

    private struct StreamingState {
        let jobID: JobID
        let generation: UInt64
        let events: @Sendable (TranscriptionEvent) async -> Void
        let session: any AppleSpeechSession
        var finalized: [String]
        var volatile: String
        var lastPublished: String
    }

    private var streaming: StreamingState?
    private var streamingGeneration: UInt64 = 0

    public init(
        runtime: any AppleSpeechRuntime,
        diagnostics: (any DiagnosticLogging)? = nil,
        currentLocale: Locale = .current
    ) {
        self.runtime = runtime
        self.diagnostics = diagnostics
        self.currentLocale = currentLocale
    }

    public var loadedModelID: ModelID? {
        currentPackage?.manifest.modelID
    }

    public var state: ModelLifecycleState {
        lifecycle
    }

    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        statistics
    }

    /// The locales the platform reported at the last load, for the shell's
    /// runtime facts and the live check.
    public var supportedLocaleIdentifiers: [String] {
        supportedLocales
    }

    /// The transcription language the shell has set (the warm-up's locale
    /// and the default for a request without a hint).
    public func setPreferredLanguageCode(_ code: String?) {
        preferredLanguageCode = code
    }

    // MARK: - Load / unload

    public func load(_ package: InstalledModelPackage) async throws {
        if let activeJobID {
            throw AppleSpeechTranscriptionError.inferenceInProgress(activeJobID)
        }
        guard !loadInProgress else {
            throw AppleSpeechTranscriptionError.loadInProgress
        }
        guard package.manifest.modelID == Self.modelID, package.ownership == .systemManaged else {
            lifecycle = .error(Self.runtimeFailure("MODEL-RUNTIME-FAILED", AppleSpeechTranscriptionError.invalidModelPackage(package.manifest.modelID).localizedDescription))
            await logLoadFailure(site: "validatePackage", reason: "invalidModelPackage", package: package)
            throw AppleSpeechTranscriptionError.invalidModelPackage(package.manifest.modelID)
        }
        if currentPackage == package {
            lifecycle = .ready(Self.summary(for: package))
            return
        }
        loadInProgress = true
        defer { loadInProgress = false }
        lifecycle = .loading
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        let start = clock.now
        let availability = await runtime.availability()
        guard availability == .available else {
            currentPackage = nil
            let reason: SystemManagedUnavailableReason = availability == .requiresNewerMacOS ? .requiresNewerMacOS : .deviceNotEligible
            lifecycle = .unavailable(reason.modelFailure)
            await logLoadFailure(site: "availability", reason: reason.rawValue, package: package)
            throw AppleSpeechTranscriptionError.unavailable(availability)
        }
        supportedLocales = await runtime.supportedLocaleIdentifiers()
        statistics.lastLoadDuration = clock.now - start
        if Task.isCancelled {
            lifecycle = .absent
            throw CancellationError()
        }
        // ADR-022 item 8: warm up before the model reads as ready.
        await warmUp(package: package)
        currentPackage = package
        lifecycle = .ready(Self.summary(for: package))
    }

    /// One short analysis in the preferred language so the platform loads
    /// its models now rather than on the first sentence. Skipped, not
    /// failed, when that language's assets are not installed: the load
    /// still stands and the first pass pays the cost instead.
    private func warmUp(package: InstalledModelPackage) async {
        guard let locale = AppleSpeechLocaleMapping.localeIdentifier(
            forLanguageCode: preferredLanguageCode,
            supportedLocales: supportedLocales,
            current: currentLocale
        ), await runtime.assetStatus(localeIdentifier: locale) == .installed else {
            statistics.lastWarmUpDuration = nil
            return
        }
        let start = clock.now
        do {
            let session = try await runtime.makeSession(
                configuration: AppleSpeechSessionConfiguration(localeIdentifier: locale, progressive: false, contextualStrings: []),
                results: { _ in }
            )
            try await session.append(samples: WarmUpAudio.samples())
            try await session.finish()
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
                    attributes: DiagnosticAttributes(modelID: package.manifest.modelID, reason: "warmupFailed", site: "warmUp")
                )
            )
        }
    }

    private func logLoadFailure(site: String, reason: String, package: InstalledModelPackage) async {
        await diagnostics?.log(
            DiagnosticEvent(
                name: .modelLoadCompleted,
                result: .failure,
                errorCode: .modelLoadFailed,
                attributes: DiagnosticAttributes(modelID: package.manifest.modelID, reason: reason, site: site)
            )
        )
    }

    public func unload() async {
        guard activeJobID == nil else { return }
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        currentPackage = nil
        lifecycle = .absent
        await runtime.releaseRetainedModels()
    }

    // MARK: - Dictionary (ADR-018 → contextual strings)

    public var promptTokenLimit: PromptTokenLimit? {
        currentPackage == nil ? nil : .phrases(Self.contextualStringsLimit)
    }

    public func promptTokenCount(of _: String) async -> Int? {
        nil
    }

    /// The contextual strings for a request: the dictionary terms recovered
    /// from the rendered prompt, the first `contextualStringsLimit` of them.
    static func contextualStrings(fromRendered prompt: String?) -> [String] {
        Array(DictionaryPrompt.terms(fromRendered: prompt).prefix(contextualStringsLimit))
    }

    // MARK: - Batch

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        let requestStart = clock.now
        guard let package = currentPackage else {
            throw AppleSpeechTranscriptionError.noModelLoaded
        }
        guard request.task == .transcribe else {
            throw AppleSpeechTranscriptionError.unsupportedTask
        }
        guard request.audio.isEngineCompatible else {
            throw AppleSpeechTranscriptionError.invalidAudio(
                sampleRate: request.audio.sampleRate,
                channelCount: request.audio.channelCount
            )
        }
        if let activeJobID {
            throw AppleSpeechTranscriptionError.inferenceInProgress(activeJobID)
        }
        let locale = try resolveLocale(forLanguageCode: request.languageHint)
        // The streaming session (display only) must be gone before the batch
        // pass so the two analyzers never overlap (ADR-017 rule 3).
        if let streaming {
            await endStreaming(jobID: streaming.jobID)
        }
        activeJobID = request.jobID
        defer { activeJobID = nil }

        await events(.phase(.preparingAudio))
        try Task.checkCancellation()
        await events(.phase(.encoding))
        await events(.phase(.decoding))

        let collector = ResultCollector()
        let samples = Array(request.audio.samples)
        let inferenceStart = clock.now
        let session: any AppleSpeechSession
        do {
            session = try await runtime.makeSession(
                configuration: AppleSpeechSessionConfiguration(
                    localeIdentifier: locale,
                    progressive: false,
                    contextualStrings: Self.contextualStrings(fromRendered: request.initialPrompt)
                ),
                results: { event in await collector.receive(event) }
            )
        } catch {
            throw Self.mapped(error)
        }
        let runtimeTask = Task {
            try await session.append(samples: samples)
            try await session.finish()
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await runtimeTask.value
            }, onCancel: {
                runtimeTask.cancel()
                Task { await session.cancel() }
            })
        } catch {
            await session.cancel()
            throw Self.mapped(error)
        }
        let inferenceEnd = clock.now
        try Task.checkCancellation()
        await events(.phase(.finalizing))

        let inferenceDuration = inferenceEnd - inferenceStart
        statistics.lastInferenceDuration = inferenceDuration
        statistics.lastRealTimeFactor = Self.realTimeFactor(inference: inferenceDuration, audio: request.audio.duration)

        let finals = await collector.finalized
        let segments = Self.segments(from: finals)
        // An empty transcript is a result, not a failure: the controller
        // turns it into `sttEmpty` ("nothing heard").
        let text = Self.join(finals.map(\.text))
        return TranscriptionResult(
            text: text,
            detectedLanguage: Self.languageCode(forLocaleIdentifier: locale),
            segments: segments,
            timings: TranscriptionTimings(
                requestStart: requestStart,
                inferenceStart: inferenceStart,
                inferenceEnd: inferenceEnd,
                runtimeReportedRealTimeFactor: nil
            ),
            modelID: package.manifest.modelID
        )
    }

    /// Collects a batch session's finalized results off the actor: the
    /// runtime calls the handler from its own task.
    private actor ResultCollector {
        private(set) var finalized: [AppleSpeechResultEvent] = []

        func receive(_ event: AppleSpeechResultEvent) {
            if case .finalized = event { finalized.append(event) }
        }
    }

    /// The transcriber locale for a request, or the typed refusal.
    private func resolveLocale(forLanguageCode code: String?) throws -> String {
        let hint = code ?? preferredLanguageCode
        guard let locale = AppleSpeechLocaleMapping.localeIdentifier(
            forLanguageCode: hint,
            supportedLocales: supportedLocales,
            current: currentLocale
        ) else {
            throw AppleSpeechTranscriptionError.unsupportedLanguage(code: hint)
        }
        return locale
    }

    /// One segment per finalized result: the platform's own phrase ranges,
    /// which is what `SpeechGate`'s per-segment energy check wants.
    static func segments(from finals: [AppleSpeechResultEvent]) -> [TranscriptSegment] {
        finals.compactMap { event in
            guard case let .finalized(text, start, end) = event else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let startSeconds = max(0, start)
            return TranscriptSegment(
                start: .seconds(startSeconds),
                end: .seconds(max(startSeconds, end)),
                text: trimmed
            )
        }
    }

    /// Finalized phrases, each trimmed, joined by one space (the platform's
    /// phrases carry their own punctuation).
    static func join(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    /// `zh_CN` → `zh`, `yue_CN` / `zh_HK` → `yue`, `en_US` → `en`: the
    /// Whisper code kvoice reports as the detected language.
    static func languageCode(forLocaleIdentifier identifier: String) -> String? {
        AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: [identifier]).first { $0 == "yue" }
            ?? AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: [identifier]).first
    }

    // MARK: - Streaming (ADR-017)

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        guard currentPackage != nil else {
            throw AppleSpeechTranscriptionError.noModelLoaded
        }
        if let activeJobID {
            throw AppleSpeechTranscriptionError.inferenceInProgress(activeJobID)
        }
        if let streaming {
            throw AppleSpeechTranscriptionError.streamingSessionActive(streaming.jobID)
        }
        let locale = try resolveLocale(forLanguageCode: languageHint)
        streamingGeneration += 1
        let generation = streamingGeneration
        let session: any AppleSpeechSession
        do {
            session = try await runtime.makeSession(
                configuration: AppleSpeechSessionConfiguration(
                    localeIdentifier: locale,
                    progressive: true,
                    contextualStrings: Self.contextualStrings(fromRendered: initialPrompt)
                ),
                results: { [weak self] event in
                    await self?.receiveStreamingResult(event, generation: generation)
                }
            )
        } catch {
            throw Self.mapped(error)
        }
        streaming = StreamingState(
            jobID: jobID,
            generation: generation,
            events: events,
            session: session,
            finalized: [],
            volatile: "",
            lastPublished: ""
        )
    }

    /// Volatile text replaces the open range; a finalized result closes it.
    /// The display is every finalized phrase plus the open one, published
    /// on change only.
    private func receiveStreamingResult(_ event: AppleSpeechResultEvent, generation: UInt64) async {
        guard var state = streaming, state.generation == generation else { return }
        switch event {
        case .volatile(let text, _, _):
            state.volatile = text
        case .finalized(let text, _, _):
            state.finalized.append(text)
            state.volatile = ""
        }
        let text = Self.join(state.finalized + [state.volatile])
        guard text != state.lastPublished else {
            streaming = state
            return
        }
        state.lastPublished = text
        streaming = state
        await state.events(.partialText(text))
    }

    /// Appends the chunk to the live session. A chunk for another job, or
    /// for a job whose session ended, is dropped; a rejected append ends
    /// the session (the batch pass still produces the final text).
    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        guard let state = streaming, state.jobID == jobID, chunk.isEngineCompatible else { return }
        do {
            try await state.session.append(samples: Array(chunk.samples))
        } catch {
            await endStreaming(jobID: jobID)
        }
    }

    /// Drops the session without waiting for a final result: the batch pass
    /// is the source of the final text. No partial is published after this.
    public func endStreaming(jobID: JobID) async {
        guard let state = streaming, state.jobID == jobID else { return }
        streaming = nil
        await state.session.cancel()
    }

    // MARK: - Helpers

    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? AppleSpeechTranscriptionError { return error }
        guard let error = error as? AppleSpeechError else { return AppleSpeechTranscriptionError.runtime(.analysisFailed) }
        switch error {
        case .unavailable(let availability): return AppleSpeechTranscriptionError.unavailable(availability)
        case .unsupportedLanguage(let code): return AppleSpeechTranscriptionError.unsupportedLanguage(code: code)
        case .assetsNotInstalled(let locale): return AppleSpeechTranscriptionError.assetsNotInstalled(localeIdentifier: locale)
        default: return AppleSpeechTranscriptionError.runtime(error)
        }
    }

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

    private static func runtimeFailure(_ code: String, _ message: String) -> ModelFailure {
        ModelFailure(code: code, message: message)
    }
}
