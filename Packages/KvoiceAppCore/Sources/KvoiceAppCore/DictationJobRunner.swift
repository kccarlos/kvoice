import Foundation
import KvoiceDomain

/// The services one dictation job runs against — every seam
/// `DictationController` is composed with, bundled so a runner is built from
/// one value. Every member is a `Sendable` existential (or nil, for the
/// reducer-only controller the foundation tests use), which is what lets the
/// runner hand them to its pipeline tasks and callbacks.
struct DictationServices: Sendable {
    let diagnosticLogger: any DiagnosticLogging
    let audioService: (any AudioCaptureService)?
    let transcriptionEngine: (any TranscriptionEngine)?
    let insertionService: (any TextInsertionService)?
    let aiProcessingClient: (any AIProcessingClient)?
    let secretsRepository: (any SecretsRepository)?
    let historyRepository: (any HistoryRepository)?
    let clock: any KvoiceClock
    let feedbackPlayer: (any RecordingFeedbackPlaying)?
    let outputMuter: (any SystemOutputMuting)?
    let returnKeySender: (any ReturnKeySending)?
    let tunables: DictationController.Tunables
}

/// One dictation job from its start edge to its terminal state (ADR-022
/// slice 6, the "per-job runner" half of the controller split).
///
/// A runner owns exactly what belongs to one job: its `DictationState` (the
/// pure `DictationReducer` is its transition authority, as it was the
/// controller's), the `DictationJob` aggregate, the settings snapshot taken
/// at the start edge, the `JobTimeline`, the recording → finalize →
/// transcribe → AI → insert pipeline with its tasks, the per-phase Escape
/// matrix for *this* job, and the diagnostics lines it emits. It knows
/// nothing about other jobs: the FIFO, the engine and insertion turns, the
/// published `Snapshot`, and the shortcut edges are the coordinator's
/// (`DictationController`).
///
/// **Isolation.** The runner is a plain (non-`Sendable`) class that lives
/// inside the coordinator actor's isolation domain. Every method that
/// suspends takes the coordinator as an `isolated` parameter (or, for a
/// private helper with no need of it, is `nonisolated(nonsending)`, which
/// runs it on the caller's actor — SE-0461), so its body runs on the
/// coordinator's executor and the two share one serial region —
/// the atomicity invariants the controller relied on (a dismiss and a start
/// reservation cannot interleave; a stale callback finds a state that has
/// already moved on) hold exactly as before, because there is still one
/// actor. The pipeline tasks the runner launches capture the coordinator
/// strongly on purpose: that is what makes the `Task` closure inherit its
/// isolation (a weak capture would not), and the cycle ends with the task.
/// Service callbacks (audio events, streaming text) are `@Sendable` and
/// cannot capture the runner, so they enter through the coordinator, which
/// routes them by job id — a late callback for a finished job finds no
/// runner and is dropped, which is the reentrancy guarantee of 2026-09-14
/// made structural.
///
/// **Publishing.** Every field the HUD or menu can see fires `onChange`,
/// which the coordinator wires to `publishSnapshotIfChanged()` — the same
/// `didSet` discipline the controller's stored properties had, so a new
/// visible field cannot forget to publish.
final class DictationJobRunner {
    typealias Coordinator = DictationController

    let jobID: JobID
    /// True when this job started while an older one was still finishing
    /// (ADR-022 item 7). Its batch pass waits its turn on the engine, and no
    /// streaming session is started for it: one runtime, one pass at a time.
    let overlapped: Bool
    let services: DictationServices
    /// Installed by the coordinator; fires after every change to a field
    /// the published `Snapshot` derives from. Runs synchronously on the
    /// coordinator's executor (the only place runner code ever runs).
    var onChange: (() -> Void)?

    // MARK: Job-visible state

    /// This job's lifecycle state. `.idle` before `.start` and again after
    /// Escape/dismiss/reset, at which point the coordinator drops the runner.
    private(set) var state: DictationState = .idle {
        didSet { onChange?() }
    }
    /// Internal (not `private(set)`) for the same-type extensions in the
    /// sibling `DictationJobRunner+*.swift` files; nothing outside the module
    /// sees the runner.
    var job: DictationJob?
    /// Settings captured at the start edge. Changes made while the job is
    /// active cannot affect its mode or target.
    private(set) var settingsSnapshot: AppSettings? {
        didSet { onChange?() }
    }
    /// The exact final string retained after a result cannot be inserted;
    /// cleared when the job is explicitly discarded.
    var exactFinalTextForFallback: String? {
        didSet { onChange?() }
    }
    /// Bounded microphone level for the recording HUD, at most 20 Hz (D.5).
    private(set) var hudInputLevel: Double = 0 {
        didSet { onChange?() }
    }
    /// True from the first captured buffer with signal until the job leaves
    /// `.recording` (2026-09-16); see `DictationController.Snapshot.captureStarted`.
    private(set) var captureStarted = false {
        didSet { onChange?() }
    }
    /// ADR-017 live partial text, for the HUD only; see the controller.
    private(set) var partialTranscript: String? {
        didSet { onChange?() }
    }
    /// The streaming session is live. Cleared before the engine is asked to
    /// end the session, so a late partial can never be published.
    var streamingActive = false
    /// Phase instants on the injected clock for the one timing line.
    /// Observation only: the reducer, the job and the pipeline never read it.
    var timeline: JobTimeline?
    /// `clock.now` at the start command, before the awaits `startRecording`
    /// does; consumed by the `.start` transition into the timeline.
    private let startCommandAt: ContinuousClock.Instant
    /// The structured pipeline task (transcribe → AI → insert, or a retry).
    var pipelineTask: Task<Void, Never>?
    /// The AI child task, cancellable by Escape without ending the pipeline.
    var aiTask: Task<AIProcessResult, Error>?
    /// The scalar metadata of the `KVoiceError` that ended the AI stage
    /// (ADR-024: `endpointClass`, and the input `tokenCount` behind an
    /// `aiInputTooLong`), for the `ai.fallback.used` line; the reducer event
    /// carries the code only. Cleared once logged.
    var aiFailureMetadata: DiagnosticAttributes?
    /// Set while the output volume is lowered so every exit path restores
    /// it exactly once.
    private var outputMuted = false
    private var lastLevelPublish: ContinuousClock.Instant?

    /// D.5: meter updates at 20 Hz maximum.
    private static let levelPublishInterval: Duration = .milliseconds(50)
    private static let streamingPhases: Set<DictationStateKind> = [.recording, .finalizing, .transcribing]

    init(
        jobID: JobID,
        startCommandAt: ContinuousClock.Instant,
        overlapped: Bool,
        services: DictationServices
    ) {
        self.jobID = jobID
        self.startCommandAt = startCommandAt
        self.overlapped = overlapped
        self.services = services
    }

    /// Seeds a runner for the reducer-only initializer
    /// (`DictationController(initialState:activeJob:)`).
    func seed(state: DictationState, job: DictationJob?) {
        self.state = state
        self.job = job
        exactFinalTextForFallback = job?.finalText
    }

    // MARK: Derived

    var clock: any KvoiceClock { services.clock }
    var tunables: DictationController.Tunables { services.tunables }
    var diagnosticLogger: any DiagnosticLogging { services.diagnosticLogger }

    /// True while the job is in one of the post-processing phases the ADR
    /// calls "finishing": the HUD badge and the FIFO count these.
    var isFinishing: Bool {
        switch state.kind {
        case .finalizing, .transcribing, .processingAI, .inserting: return true
        default: return false
        }
    }

    /// The job is done as far as insertion ordering is concerned: a newer
    /// job may insert once every older job is terminal or gone.
    var isTerminal: Bool {
        switch state.kind {
        case .completed, .failed, .blocked, .terminating, .idle: return true
        default: return false
        }
    }

    /// True while the failure HUD may offer Copy and Insert Again: the job
    /// ended in `.failed` and its exact final text is still retained.
    var recoverableFailure: (jobID: JobID, text: String)? {
        guard case .failed(let jobID?, _) = state,
              let job, job.id == jobID,
              job.delivery == .insertIntoTarget,
              let text = exactFinalTextForFallback ?? job.finalText ?? job.rawTranscript,
              !text.isEmpty
        else { return nil }
        return (jobID, text)
    }

    var activeFeedbackSettings: RecordingFeedbackSettings? {
        settingsSnapshot?.recordingFeedback
    }

    func isCurrent(_ stateKind: DictationStateKind) -> Bool {
        job?.id == jobID && state.kind == stateKind && state.jobID == jobID
    }

    // MARK: - Start edge

    /// The settings the coordinator loaded for this job, before `.start`.
    func prepare(settings: AppSettings) {
        settingsSnapshot = settings
    }

    /// A blocked start carries no settings (the HUD falls back to the live
    /// ones), exactly as the controller cleared its snapshot before the
    /// `.blocked` transition.
    func clearSettings() {
        settingsSnapshot = nil
    }

    // MARK: - In-recorder AI controls (ADR-021)

    /// Phases in which the job's AI snapshot may still be replaced; see
    /// `DictationController.setAIAction`.
    static let aiControlPhases: Set<DictationStateKind> = [.recording, .finalizing]

    func aiControlSettings() -> AIEndpointSettings? {
        guard Self.aiControlPhases.contains(state.kind),
              let job,
              job.id == state.jobID,
              job.delivery == .insertIntoTarget
        else { return nil }
        return job.aiSettingsSnapshot
    }

    func applyAIControl(_ settings: AIEndpointSettings, reason: String, _ coordinator: isolated Coordinator) async {
        guard var job else { return }
        job.applyAISettings(settings)
        self.job = job
        // The published snapshot carries `activeSettings`, which is what the
        // HUD's AI indicator and action name are rendered from; rewriting
        // its `ai` block is what makes the recorder update.
        settingsSnapshot?.ai = settings
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationStateChanged,
                jobID: job.id,
                result: .success,
                attributes: DiagnosticAttributes(
                    mode: settings.mode,
                    activeState: state.kind,
                    reason: reason
                )
            )
        )
    }

    /// Double-press auto-send (product decision #5) for the running recording.
    func armAutoSend() {
        job?.armAutoSend()
    }

    // MARK: - Reducer boundary

    @discardableResult
    func apply(
        _ event: DictationEvent,
        job suppliedJob: DictationJob? = nil,
        _ coordinator: isolated Coordinator
    ) async throws -> DictationState {
        if case .start(let jobID, _) = event, let suppliedJob, suppliedJob.id != jobID {
            throw DictationTransitionError.injectedJobMismatch(expected: jobID, received: suppliedJob.id)
        }

        let event = try await validatedEvent(event)
        // Cancel the task before the reducer clears an escaped job. This keeps
        // cancellation effective even when `updateJob` intentionally discards
        // the active aggregate for recording/transcription Escape.
        if event.isCancellation, let jobID = event.jobID {
            cancelPipelineIfNeeded(for: jobID, event: event)
        } else if case .quit = event {
            pipelineTask?.cancel()
            pipelineTask = nil
        }
        do {
            var next = try DictationReducer.reduce(state, event: event)
            updateJob(for: event, suppliedJob: suppliedJob, nextState: next)
            // The reducer is pure and never sees the job aggregate; attach the
            // AI fallback and duration-cap context here so the HUD can show
            // "Inserted local transcript; AI unavailable" (D.4).
            if case .completed(let jobID, let summary) = next, let job, job.id == jobID {
                next = .completed(
                    jobID,
                    summary.attaching(
                        aiFallback: job.fallbackReason,
                        durationCapReached: job.durationCapReached,
                        maxRecordingSeconds: settingsSnapshot?.maxRecordingSeconds ?? 600
                    )
                )
            }
            state = next
            updateFallbackText(for: event, nextState: next)
            recordPhaseBoundary(for: event, nextState: next)
            await logFailureIfNeeded(for: event, nextState: next)
            await logCompletionIfNeeded(for: event, nextState: next)
            // ADR-017: a streaming session lives only through recording,
            // finalizing, and transcribing. Escape, completion, failure, and
            // quit all drop it here, before any service is told, so a late
            // `.partialText` finds no live session and is ignored.
            if streamingActive,
               event.isCancellation || !Self.streamingPhases.contains(next.kind) {
                tearDownStreaming()
            }

            // Whatever ended the recording — stop, cap, Escape, a capture
            // failure, quit — the output volume comes back here, so no exit
            // path can strand it at zero.
            if outputMuted, next.kind != .recording {
                await endRecordingSideEffects(cue: nil, feedback: nil)
            }

            // Direct reducer callers receive the same cancellation safety as
            // cancel()/terminate(). Services are cancelled after state changes
            // so late callbacks observe a non-active state.
            if event.isCancellation, let jobID = event.jobID {
                await services.audioService?.cancel(jobID: jobID)
            } else if case .quit = event, let jobID = job?.id {
                await services.audioService?.cancel(jobID: jobID)
            }
            await coordinator.runnerDidTransition(self)
            return next
        } catch let transitionError as DictationTransitionError {
            if case .injectedJobMismatch = transitionError {
                throw transitionError
            }
            // Busy/repeat input and late completions are expected races at this
            // boundary. They are observable through diagnostics but cannot
            // mutate state or escape as user-facing errors.
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .dictationStateChanged,
                    jobID: event.jobID,
                    result: .ignored,
                    errorCode: transitionError.errorCode,
                    attributes: DiagnosticAttributes(
                        activeState: state.kind,
                        reason: event.kind.rawValue
                    )
                )
            )
            return state
        }
    }

    private func updateJob(
        for event: DictationEvent,
        suppliedJob: DictationJob?,
        nextState: DictationState
    ) {
        switch event {
        case .start(let jobID, .passed):
            job = suppliedJob ?? DictationJob(
                id: jobID,
                startedAt: Date(),
                target: nil,
                modeSnapshot: .off,
                translationTargetSnapshot: nil,
                modelIDSnapshot: ""
            )
            timeline = JobTimeline(jobID: jobID, startCommandAt: startCommandAt)
        case .hardDurationCap(let jobID):
            recordDurationCap(for: jobID)
        case .aiFailure(let jobID, let code):
            recordAIFallback(code, for: jobID)
        case .aiCancelled(let jobID):
            recordAIFallback(.aiCancelled, for: jobID)
        case .escape(let jobID) where state.kind == .processingAI && state.jobID == jobID:
            // Escape at the AI boundary is a successful, atomic fallback: the
            // immutable raw transcript becomes final before the controller moves
            // to insertion. A late URLSession completion cannot erase this.
            recordAIFallback(.aiCancelled, for: jobID)
        case .reset, .dismiss:
            if state.kind == .completed || state.kind == .failed || state.kind == .blocked {
                job = nil
                settingsSnapshot = nil
                timeline = nil
            }
        default:
            break
        }

        if nextState.kind == .idle, event.kind == .escape {
            // Escape is the state-equivalent cancellation/dismiss command for
            // failed and active non-AI states. Do not retain stale content for
            // a future job after recovery.
            job = nil
            settingsSnapshot = nil
            exactFinalTextForFallback = nil
            timeline = nil
        }
    }

    private nonisolated(nonsending) func validatedEvent(_ event: DictationEvent) async throws -> DictationEvent {
        guard case .rawTranscript(let jobID, let requestedMode) = event,
              let job,
              job.id == jobID else {
            return event
        }

        guard requestedMode != job.modeSnapshot else {
            return event
        }

        // The job snapshot is authoritative. In particular, a stale or forged
        // mode value must not turn an AI-Off job into a network request (or skip
        // an intentionally selected AI mode).
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationStateChanged,
                jobID: jobID,
                result: .warning,
                errorCode: .appInternal,
                attributes: DiagnosticAttributes(
                    mode: job.modeSnapshot,
                    activeState: state.kind,
                    reason: "rawTranscriptModeMismatch"
                )
            )
        )
        return .rawTranscript(jobID: jobID, mode: job.modeSnapshot)
    }

    private func cancelPipelineIfNeeded(for jobID: JobID, event: DictationEvent) {
        guard job?.id == jobID else { return }
        switch event {
        case .escape:
            // AI fallback intentionally continues to insertion. Recording,
            // finalizing, and transcription are discarded and cancelled.
            if state.kind == .recording || state.kind == .finalizing || state.kind == .transcribing {
                pipelineTask?.cancel()
                pipelineTask = nil
            }
        default:
            pipelineTask?.cancel()
            pipelineTask = nil
        }
    }

    private func updateFallbackText(for event: DictationEvent, nextState: DictationState) {
        if event.kind == .reset || event.kind == .dismiss || nextState.kind == .idle {
            if event.kind == .escape || event.kind == .reset || event.kind == .dismiss {
                exactFinalTextForFallback = nil
            }
        }
        if let text = job?.finalText {
            exactFinalTextForFallback = text
        }
    }

    // MARK: - Job content

    /// Both keep the controller's old `activeJob?.id == jobID` guard: a
    /// runner without a job (a `.blocked` attempt) never gains a
    /// recoverable transcript.
    func recordRawTranscript(_ text: String) {
        guard job?.id == jobID else { return }
        job?.recordRawTranscript(text)
        exactFinalTextForFallback = text
    }

    func recordFinalText(_ text: String) {
        guard job?.id == jobID else { return }
        // Once AI fallback has been selected, a late provider completion must
        // not overwrite the saved local transcript chosen for insertion.
        guard job?.fallbackReason == nil else { return }
        job?.recordFinalText(text)
        exactFinalTextForFallback = text
    }

    func recordDurationCap(for jobID: JobID) {
        guard job?.id == jobID else { return }
        job?.markDurationCapReached()
    }

    func recordAIFallback(_ code: AIErrorCode, for jobID: JobID) {
        guard job?.id == jobID else { return }
        job?.recordAIFallback(code)
        exactFinalTextForFallback = job?.finalText
    }

    // MARK: - Capture

    /// Configures and starts the recorder for the admitted job (the state is
    /// already `.recording`), then arms streaming. Mirrors the tail of the
    /// controller's `startRecording`.
    func beginCapture(_ coordinator: isolated Coordinator) async {
        guard let settings = settingsSnapshot else { return }
        guard let audioService = services.audioService else {
            // Reducer-only callers can still use apply; a service-aware start
            // without capture is a recoverable app-internal failure.
            _ = try? await apply(.captureFailure(jobID: jobID, code: .audioInputUnavailable), coordinator)
            return
        }

        // The recording ceiling and the input device follow the settings
        // snapshot per job, so neither needs app-shell wiring.
        if let configurable = audioService as? any AudioCaptureConfiguring {
            await configurable.setMaximumRecordingDuration(.seconds(settings.maxRecordingSeconds))
            await configurable.setInputSelection(settings.audioInput)
            guard isCurrent(.recording) else { return }
        }

        let jobID = jobID
        do {
            try await audioService.start(jobID: jobID) { [weak coordinator] event in
                await coordinator?.receiveAudioEvent(event, for: jobID)
            }
            // The input engine is running: on AirPods this return is what
            // waited for the Bluetooth A2DP→HFP switch — but the route can
            // go on delivering zero-fill for another second or two after it.
            // The start cue and the output mute therefore wait for the first
            // buffer with signal (`receiveAudioEvent`), not for this return;
            // only streaming is armed here.
            timeline?.recordEngineStarted(at: clock.now, for: jobID)
            guard isCurrent(.recording) else {
                await audioService.cancel(jobID: jobID)
                return
            }
            await beginStreamingIfConfigured(settings: settings, coordinator)
        } catch is CancellationError {
            return
        } catch let error as KVoiceError {
            _ = try? await apply(.captureFailure(jobID: jobID, code: error.code), coordinator)
        } catch {
            _ = try? await apply(.captureFailure(jobID: jobID, code: .audioEngineStartFailed), coordinator)
        }
    }

    func receiveAudioEvent(_ event: AudioCaptureEvent, _ coordinator: isolated Coordinator) async {
        if case .warning(.durationCap) = event {
            // The cap can be reported while the user's own stop is already
            // finalizing; the flag is still job context for the completion HUD.
            guard isCurrent(.recording) || isCurrent(.finalizing) else { return }
            recordDurationCap(for: jobID)
            if state.kind == .recording {
                Task {
                    await self.stopAtDurationCap(coordinator)
                }
            }
            return
        }
        guard isCurrent(.recording) else { return }
        switch event {
        case .level(let rms, let peak):
            // The recorder reports one `.level` per tap buffer, so the first
            // one above the meter's silence floor is the first buffer that
            // carried signal — the end of the zeros a Bluetooth route
            // delivers while it switches. Detected once, here: it stamps
            // `captureStartMilliseconds`, flips `captureStarted` for the
            // HUD, and runs the start side effects (cue, then mute).
            // Nothing per buffer is logged.
            if !captureStarted, peak > tunables.speechGate.signalPeakDBFS {
                captureStarted = true
                timeline?.recordCaptureStarted(at: clock.now, for: jobID)
                if let settings = settingsSnapshot {
                    await beginRecordingSideEffects(settings: settings)
                    guard isCurrent(.recording) else { return }
                }
            }
            // Map the bounded dBFS range to a small HUD-friendly level without
            // retaining audio samples or transcript content. The tap reports
            // faster than a meter should move; coalesce to 20 Hz (D.5).
            let now = ContinuousClock.now
            if let last = lastLevelPublish, now - last < Self.levelPublishInterval {
                return
            }
            lastLevelPublish = now
            let bounded = min(max(rms, -60), 0)
            hudInputLevel = Double((bounded + 60) / 60)
        case .elapsed(let elapsed):
            // The clock starts with the recording, at the first buffer with
            // signal (the recorder restarts its elapsed origin there and
            // drops what came before); until then the HUD shows 0:00 under
            // "Starting mic…".
            guard captureStarted else { return }
            state = .recording(RecordingState(jobID: jobID, elapsed: elapsed))
        case .warning:
            break
        case .deviceChanged:
            break
        }
    }

    func receiveTranscriptionEvent(_ event: TranscriptionEvent) {
        // Phase/progress events are intentionally ignored by the lean HUD.
        // ADR-017: partial text is published only for the job whose streaming
        // session is live, and only through recording, finalizing, and
        // transcribing; it never reaches history, insertion, or diagnostics.
        guard case .partialText(let text) = event else { return }
        guard streamingActive,
              job?.id == jobID,
              Self.streamingPhases.contains(state.kind) else { return }
        partialTranscript = text
    }

    // MARK: Recording side effects (sound cues, output muting)

    /// Plays the start cue, then lowers the output volume. Called once per
    /// job from the first captured buffer with signal (2026-09-16): played
    /// any earlier, a Bluetooth headset still switching profiles swallows
    /// or mangles the cue, and the user is told to speak into a route that
    /// records nothing yet. The cue is played first so it is audible; it is
    /// short enough not to overlap speech. A job that ends before any
    /// signal buffer (push-to-talk released during the switch) never plays
    /// it — the stop or cancel cue still does.
    private nonisolated(nonsending) func beginRecordingSideEffects(settings: AppSettings) async {
        if settings.recordingFeedback.soundFeedbackEnabled {
            await services.feedbackPlayer?.play(.start, using: settings.recordingFeedback.cueSet)
        }
        // The cue was awaited on another actor; the job may have ended
        // meanwhile, and then `endRecordingSideEffects` has already run.
        guard isCurrent(.recording) else { return }
        if settings.recordingFeedback.muteSystemAudioDuringRecording, let outputMuter = services.outputMuter, !outputMuted {
            outputMuted = true
            await outputMuter.mute()
        }
    }

    /// Restores the output volume (always, when it was lowered) and plays the
    /// given cue (when sound feedback is on). Called from every path that
    /// ends capture: stop, cap, cancel, capture failure, and termination.
    /// `feedback` is captured by the caller before a transition that may
    /// clear the settings snapshot (Escape does).
    nonisolated(nonsending) func endRecordingSideEffects(
        cue: RecordingFeedbackCue?,
        feedback: RecordingFeedbackSettings?
    ) async {
        if outputMuted, let outputMuter = services.outputMuter {
            outputMuted = false
            await outputMuter.restore()
        }
        if let cue, let feedback, feedback.soundFeedbackEnabled {
            await services.feedbackPlayer?.play(cue, using: feedback.cueSet)
        }
    }

    // MARK: - Streaming (ADR-017)

    /// Starts a streaming session when the loaded model is set to streaming
    /// mode and the engine supports it. Best effort: a session that cannot
    /// start leaves the batch path untouched. Never for an overlapped job
    /// (ADR-022 item 7): the older job's batch pass may be on the runtime.
    private func beginStreamingIfConfigured(settings: AppSettings, _ coordinator: isolated Coordinator) async {
        guard !overlapped,
              let audioService = services.audioService,
              let engine = services.transcriptionEngine as? any StreamingTranscriptionEngine,
              await engine.capabilities.supportsStreaming,
              let modelID = await engine.loadedModelID,
              settings.speechModelModes[modelID] == .streaming,
              isCurrent(.recording)
        else { return }

        let jobID = jobID
        do {
            try await engine.beginStreaming(
                jobID: jobID,
                languageHint: settings.transcriptionLanguage,
                // ADR-018: the job's dictionary, same as the batch pass.
                initialPrompt: DictionaryPrompt.render(settings.dictionary)
            ) { [weak coordinator] event in
                await coordinator?.receiveTranscriptionEvent(event, for: jobID)
            }
        } catch {
            return
        }
        guard isCurrent(.recording) else {
            await engine.endStreaming(jobID: jobID)
            return
        }
        streamingActive = true
        partialTranscript = ""
        await audioService.setStreamingChunkSink(jobID: jobID) { chunk in
            await engine.appendStreamingAudio(chunk, jobID: jobID)
        }
    }

    /// Ends the live session and waits for its last pass, so the batch pass
    /// that follows never overlaps it on the runtime.
    private nonisolated(nonsending) func endStreamingIfActive() async {
        guard streamingActive,
              let engine = services.transcriptionEngine as? any StreamingTranscriptionEngine else { return }
        await engine.endStreaming(jobID: jobID)
    }

    /// Drops the session without waiting (Escape, completion, quit). The
    /// engine's own cancellation stops the pass at its next checkpoint.
    private func tearDownStreaming() {
        guard streamingActive else { return }
        streamingActive = false
        partialTranscript = nil
        guard let engine = services.transcriptionEngine as? any StreamingTranscriptionEngine else { return }
        let jobID = jobID
        Task { await engine.endStreaming(jobID: jobID) }
    }

    // MARK: - Stop, finalize, cancel

    /// The user's stop edge: `.recording → .finalizing`, the stop cue, then
    /// the finalize step. Returns without effect unless this job is recording.
    func stopRecording(_ coordinator: isolated Coordinator) async {
        guard case .recording = state else { return }
        _ = try? await apply(.stop(jobID: jobID), coordinator)
        guard case .finalizing(let finalizingID) = state,
              finalizingID == jobID,
              job?.id == jobID
        else { return }
        await endRecordingSideEffects(cue: .stop, feedback: activeFeedbackSettings)
        await finalizeRecording(coordinator)
    }

    /// The recorder has stopped accepting audio at the hard cap (FR-AUD-009).
    /// Stop and process what was captured; the completion HUD carries the
    /// warning. A later key-up finds the job past `.recording` and is ignored.
    private func stopAtDurationCap(_ coordinator: isolated Coordinator) async {
        guard isCurrent(.recording) else { return }
        _ = try? await apply(.hardDurationCap(jobID: jobID), coordinator)
        guard isCurrent(.finalizing) else { return }
        coordinator.recordingEndedByCap()
        await endRecordingSideEffects(cue: .stop, feedback: activeFeedbackSettings)
        await finalizeRecording(coordinator)
    }

    /// Collects the finished recording, validates it, and launches the
    /// transcription pipeline. Shared by the user stop edge and the hard
    /// duration cap; the state must already be `.finalizing`.
    private func finalizeRecording(_ coordinator: isolated Coordinator) async {
        guard let audioService = services.audioService else {
            _ = try? await apply(.invalidAudio(jobID: jobID, code: .audioInputUnavailable), coordinator)
            return
        }

        // Stop the capture first so the recording ends on the user's edge,
        // then wait for the streaming session's last pass (ADR-017) before
        // the batch pass can start.
        let stopped: Result<AudioRecording, Error>
        do {
            stopped = .success(try await audioService.stop(jobID: jobID))
        } catch {
            stopped = .failure(error)
        }
        await endStreamingIfActive()

        do {
            let recording = try stopped.get()
            guard isCurrent(.finalizing) else { return }
            timeline?.recordRecording(recording, for: jobID)
            guard !recording.samples.isEmpty else {
                _ = try? await apply(.invalidAudio(jobID: jobID, code: .audioNoSamples), coordinator)
                return
            }
            guard recording.isEngineCompatible, recording.samples.allSatisfy(\.isFinite) else {
                _ = try? await apply(.invalidAudio(jobID: jobID, code: .sttInvalidAudio), coordinator)
                return
            }
            guard recording.duration > .milliseconds(10) else {
                _ = try? await apply(.invalidAudio(jobID: jobID, code: .audioTooShort), coordinator)
                return
            }
            // FR-AUD-008: near-silent audio never reaches the model. Whisper
            // large-v3 hallucinates "Thank you." on silence, and a manual test
            // showed exactly that.
            guard recording.peakLevelDBFS > tunables.speechGate.silencePeakDBFS else {
                _ = try? await apply(.invalidAudio(jobID: jobID, code: .audioNoSamples), coordinator)
                return
            }

            _ = try? await apply(.validRecording(jobID: jobID), coordinator)
            guard isCurrent(.transcribing) else { return }
            launchTranscription(recording: recording, coordinator)
        } catch is CancellationError {
            // Escape/termination changes the state first; no failure or
            // insertion may be emitted after that cancellation.
        } catch let error as KVoiceError {
            guard isCurrent(.finalizing) else { return }
            _ = try? await apply(.invalidAudio(jobID: jobID, code: error.code), coordinator)
        } catch {
            guard isCurrent(.finalizing) else { return }
            _ = try? await apply(.invalidAudio(jobID: jobID, code: .audioInputUnavailable), coordinator)
        }
    }

    /// Escape/cancel semantics for this job — the ADR-022 item 6 matrix.
    /// Recording/finalizing/transcribing are discarded; the AI stage
    /// chooses the already-recorded local text and lets insertion continue;
    /// insertion is too late to stop.
    func cancel(_ coordinator: isolated Coordinator) async {
        guard let job else { return }
        switch state {
        case .recording, .finalizing, .transcribing:
            let wasRecording = state.kind == .recording
            let feedback = activeFeedbackSettings
            _ = try? await apply(.escape(jobID: job.id), coordinator)
            // The cancel cue marks a discarded recording; a cancelled
            // transcription of an already-stopped recording stays silent
            // because the stop cue has played.
            await endRecordingSideEffects(cue: wasRecording ? .cancel : nil, feedback: feedback)
        case .processingAI:
            _ = try? await apply(.escape(jobID: job.id), coordinator)
            // The state transition atomically selected the raw transcript.
            // Cancel only the AI child task and the provider request; the
            // structured pipeline stays alive long enough to insert that
            // saved raw text exactly once. Cancelling the child task also
            // covers an Escape that lands while credentials are still loading.
            aiTask?.cancel()
            await services.aiProcessingClient?.cancel(jobID: job.id)
        case .inserting:
            // Insertion has already begun; do not cancel a potentially
            // partially-mutating AX operation. The insertion service owns its
            // own safety gate and fallback behavior.
            return
        default:
            _ = try? await apply(.escape(jobID: job.id), coordinator)
        }
    }

    /// App termination: the AI child is cancelled, the output volume comes
    /// back, the aborted history row (FR-LIFE-009) is written while the job
    /// still holds its transcript, and `.quit` makes every late callback
    /// stale. The volume comes back **first** (2026-09-16 review): the
    /// shell bounds this whole call with `TerminationHandshake`'s ~3 s
    /// deadline and exits either way, so a history write that stalls must
    /// not be what stands between the user and their output volume.
    func terminate(_ coordinator: isolated Coordinator) async {
        aiTask?.cancel()
        // Never leave the user's output volume at zero after a quit.
        await endRecordingSideEffects(cue: nil, feedback: nil)
        await appendAbortedRowIfNeeded(coordinator)
        _ = try? await apply(.quit, coordinator)
    }

    // MARK: - Failure recovery (ADR-022 item 6)

    /// "Insert Again": re-captures the frontmost application, then runs the
    /// ordinary insertion tiers over the retained text through the reducer's
    /// `retryInsertion` row. The job aggregate is reused; a history row is
    /// written only if the original attempt wrote none.
    func retryInsertion(_ coordinator: isolated Coordinator) async -> Result<DictationState, DictationController.RecoveryRefusal> {
        guard case .failed = state else { return .failure(.notFailed) }
        guard recoverableFailure != nil else { return .failure(.noRetainedText) }
        guard let insertionService = services.insertionService else { return .failure(.noInsertionService) }

        // Captured before the transition so a failed capture (nothing
        // frontmost) still runs the same path and ends in the clipboard
        // fallback, exactly as a job without a target does.
        let target = await insertionService.captureTargetApplication()
        guard case .failed = state, job?.id == jobID else { return .failure(.notFailed) }
        job?.retargetForRetry(target)

        do {
            _ = try await apply(.retryInsertion(jobID: jobID), coordinator)
        } catch {
            return .failure(.notFailed)
        }
        guard isCurrent(.inserting) else { return .failure(.notFailed) }

        // The same task discipline as the pipeline: cancellation stays tied
        // to the coordinator, and `waitForCompletion` sees it.
        let task = Task {
            await self.performInsertion(recording: nil, coordinator)
            await coordinator.runnerPipelineDidFinish(self)
        }
        pipelineTask = task
        await task.value
        if pipelineTask == task {
            pipelineTask = nil
        }
        return .success(state)
    }

    /// "Copy" on the failure HUD; see `DictationController.copyRetainedTranscript`.
    nonisolated(nonsending) func copyRetainedTranscript() async -> DictationController.RecoveryRefusal? {
        guard case .failed = state else { return .notFailed }
        guard let (jobID, text) = recoverableFailure else { return .noRetainedText }
        guard let insertionService = services.insertionService else { return .noInsertionService }
        do {
            try await insertionService.copyToClipboard(text, jobID: jobID)
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .insertionClipboardFallback,
                    jobID: jobID,
                    result: .success,
                    attributes: DiagnosticAttributes(reason: "recoveryCopy", site: "failureHUD")
                )
            )
            return nil
        } catch {
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .insertionFailed,
                    jobID: jobID,
                    result: .failure,
                    errorCode: (error as? KVoiceError)?.code ?? .clipboardWriteFailed,
                    attributes: DiagnosticAttributes(reason: "recoveryCopyFailed", site: "failureHUD")
                )
            )
            return .clipboardWriteFailed
        }
    }

}

extension DictationEvent {
    var isCancellation: Bool {
        if case .escape = self { return true }
        return false
    }

    var jobID: JobID? {
        switch self {
        case .start(let jobID, _), .stop(let jobID), .escape(let jobID),
             .hardDurationCap(let jobID), .captureFailure(let jobID, _),
             .validRecording(let jobID), .invalidAudio(let jobID, _),
             .rawTranscript(let jobID, _), .transcriptionFailure(let jobID, _),
             .aiSuccess(let jobID), .aiFailure(let jobID, _), .aiCancelled(let jobID),
             .insertionSucceeded(let jobID, _), .insertionFallback(let jobID, _),
             .clipboardFailure(let jobID, _), .retryInsertion(let jobID):
            return jobID
        case .reset, .dismiss, .quit:
            return nil
        }
    }
}

extension DictationTransitionError {
    var errorCode: KVoiceErrorCode {
        switch self {
        case .staleJob:
            return .appCancelled
        case .illegalTransition:
            return .appBusy
        case .injectedJobMismatch:
            return .appInternal
        }
    }
}