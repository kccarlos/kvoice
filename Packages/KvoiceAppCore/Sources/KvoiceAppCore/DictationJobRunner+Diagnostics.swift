import Foundation
import KvoiceDomain

/// The scalar lines one job emits (ADR-022 item 9) and the per-job timing
/// stamps behind `dictation.completed` / `dictation.failed` (2026-09-16).
/// Same type as `DictationJobRunner.swift`.
extension DictationJobRunner {
    // MARK: - Diagnostics (ADR-022 item 9 and the timing line)

    /// Every throw the pipeline turns into a HUD-visible failure leaves
    /// exactly one scalar line here — `dictation.failed` for a `.failed`
    /// state, `ai.fallback.used` for an AI stage that ended in the raw
    /// transcript — with `site` naming the pipeline stage that caught it and
    /// `reason` the reducer event. The adapters (insertion, engines) log
    /// their own gate on the same throw; the two lines share the job id.
    nonisolated(nonsending) func logFailureIfNeeded(for event: DictationEvent, nextState: DictationState) async {
        let jobID = nextState.jobID ?? event.jobID
        switch event {
        case .captureFailure(_, let code):
            await logFailure(.dictationFailed, jobID: jobID, code: code, site: "capture", reason: event.kind.rawValue)
        case .invalidAudio(_, let code):
            await logFailure(.dictationFailed, jobID: jobID, code: code, site: "finalize", reason: event.kind.rawValue)
        case .transcriptionFailure(_, let code):
            await logFailure(.dictationFailed, jobID: jobID, code: code, site: "transcribe", reason: event.kind.rawValue)
        case .clipboardFailure(_, let code):
            await logFailure(.dictationFailed, jobID: jobID, code: code, site: "insert", reason: event.kind.rawValue)
        case .aiFailure(_, let code):
            await logFailure(.aiFallbackUsed, jobID: jobID, code: code, site: "processAI", reason: event.kind.rawValue)
        case .aiCancelled:
            await logFailure(.aiFallbackUsed, jobID: jobID, code: .aiCancelled, site: "processAI", reason: event.kind.rawValue)
        case .escape where nextState.kind == .inserting:
            // Escape during the AI stage: the product rule is "insert the
            // raw transcript", which the HUD shows as an AI fallback.
            await logFailure(.aiFallbackUsed, jobID: jobID, code: .aiCancelled, site: "processAI", reason: event.kind.rawValue)
        default:
            break
        }
    }

    private nonisolated(nonsending) func logFailure(
        _ name: DiagnosticEventName,
        jobID: JobID?,
        code: KVoiceErrorCode,
        site: String,
        reason: String
    ) async {
        // The phases measured up to the failure ride along on the failure
        // line (2026-09-16), so a job that was slow *and* failed is one line.
        let timing = name == .dictationFailed && timeline?.jobID == jobID
            ? timeline?.measure(at: clock.now)
            : nil
        // ADR-024: the AI stage's error metadata rides on its fallback line
        // — `endpointClass` (`onDevice` for Apple Intelligence) and, behind
        // `aiInputTooLong`, the input token count. Both scalars.
        let aiMetadata = name == .aiFallbackUsed ? aiFailureMetadata : nil
        if name == .aiFallbackUsed { aiFailureMetadata = nil }
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: name,
                jobID: jobID,
                result: name == .dictationFailed ? .failure : .warning,
                durationMilliseconds: timing?.totalMilliseconds.map(Double.init),
                errorCode: code,
                attributes: DiagnosticAttributes(
                    modelID: job?.modelIDSnapshot,
                    mode: job?.modeSnapshot,
                    endpointClass: aiMetadata?.endpointClass,
                    activeState: state.kind,
                    reason: reason,
                    site: site,
                    tokenCount: aiMetadata?.tokenCount,
                    engineStartMilliseconds: timing?.engineStartMilliseconds,
                    captureStartMilliseconds: timing?.captureStartMilliseconds,
                    leadingPeakDBFS: timing?.leadingPeakDBFS,
                    recordingSeconds: timing?.recordingSeconds,
                    sttMilliseconds: timing?.sttMilliseconds,
                    realTimeFactor: timing?.realTimeFactor,
                    aiMilliseconds: timing?.aiMilliseconds,
                    insertionMilliseconds: timing?.insertionMilliseconds,
                    streaming: timing?.streaming
                )
            )
        )
    }

    /// Stamps the reducer transition that just happened on the job's
    /// timeline. Called from `apply` after the state changed, so every path
    /// into a phase — the shortcut, the hard cap, an App Intent, a direct
    /// `apply` — is measured the same way. Synchronous: no await, no state
    /// change, nothing the pipeline can observe.
    func recordPhaseBoundary(for event: DictationEvent, nextState: DictationState) {
        guard var timeline,
              let jobID = nextState.jobID ?? event.jobID,
              timeline.jobID == jobID else { return }
        let now = clock.now
        switch (event.kind, nextState.kind) {
        case (.stop, .finalizing), (.hardDurationCap, .finalizing):
            // Stop-of-recording: the instant `durationMilliseconds` counts
            // from. The streaming session is still live here (it is torn
            // down after this in `apply`), which is what `streaming` records.
            timeline.recordStopped(at: now, streaming: streamingActive)
        case (.validRecording, .transcribing):
            timeline.recordTranscribing(at: now)
        case (.rawTranscript, .processingAI):
            timeline.recordTranscribed(at: now, aiStarted: true)
        case (.rawTranscript, .inserting):
            timeline.recordTranscribed(at: now, aiStarted: false)
        case (.aiSuccess, .inserting), (.aiFailure, .inserting), (.aiCancelled, .inserting), (.escape, .inserting):
            timeline.recordInserting(at: now)
        case (.retryInsertion, .inserting):
            // Insert Again (ADR-022 item 6): the retry's own insertion is
            // timed; the total is not, since the wait before it was the user's.
            timeline.recordRetry(at: now)
        default:
            break
        }
        self.timeline = timeline
    }

    /// The one `dictation.completed` line per job that reaches `.completed`.
    /// Cancelled jobs emit nothing here (`dictation.job.cancelled` is
    /// unchanged); failures are the `dictation.failed` line above.
    nonisolated(nonsending) func logCompletionIfNeeded(for event: DictationEvent, nextState: DictationState) async {
        guard case .completed(let jobID, let summary) = nextState,
              let timeline, timeline.jobID == jobID else { return }
        let timing = timeline.measure(at: clock.now)
        let strategy: InsertionMethod?
        let fallbackKind: String?
        let result: DiagnosticResult
        switch summary.insertion {
        case .inserted(let method):
            strategy = method
            fallbackKind = nil
            result = .success
        case .copiedToClipboard(let reason):
            // Same vocabulary as `insertion.clipboardFallback`; the HUD shows
            // this completion with a warning too.
            strategy = nil
            fallbackKind = reason.rawValue
            result = .warning
        case .deliveredInApp, .abortedAtTermination:
            strategy = nil
            fallbackKind = nil
            result = .success
        }
        let reason: String?
        switch (timeline.retried, summary.insertion) {
        case (true, _): reason = "retryInsertion"
        case (false, .deliveredInApp): reason = "deliveredInApp"
        default: reason = nil
        }
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationCompleted,
                jobID: jobID,
                result: result,
                durationMilliseconds: timing.totalMilliseconds.map(Double.init),
                attributes: DiagnosticAttributes(
                    modelID: job?.modelIDSnapshot,
                    mode: job?.modeSnapshot,
                    reason: reason,
                    fallbackKind: fallbackKind,
                    strategy: strategy,
                    engineStartMilliseconds: timing.engineStartMilliseconds,
                    captureStartMilliseconds: timing.captureStartMilliseconds,
                    leadingPeakDBFS: timing.leadingPeakDBFS,
                    recordingSeconds: timing.recordingSeconds,
                    sttMilliseconds: timing.sttMilliseconds,
                    realTimeFactor: timing.realTimeFactor,
                    aiMilliseconds: timing.aiMilliseconds,
                    insertionMilliseconds: timing.insertionMilliseconds,
                    streaming: timing.streaming
                )
            )
        )
    }
}
