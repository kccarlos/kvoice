import Foundation
import KvoiceDomain

/// The start edge of `DictationController` (the coordinator): admission —
/// the terminal-HUD restart, the C.6 busy pulse, the ADR-022 item 7 FIFO —
/// then target capture, the settings snapshot, the prerequisite check, the
/// runner's `.start`, and the capture kick-off. Same actor as
/// `DictationController.swift`; the members it touches are internal (not
/// `private`) for that reason only.
extension DictationController {
    /// completed / failed / blocked: a terminal HUD still on screen for its
    /// auto-dismiss (`HUDViewState.autoDismissAfter`). A shortcut press here
    /// is the user's deliberate "go again", not a stray repeat, so
    /// `startRecording` dismisses it and starts in the same gesture instead
    /// of waiting for the timer (2026-09-16, ADR-022 item 6 amendment).
    static let restartableTerminalKinds: Set<DictationStateKind> = [.completed, .failed, .blocked]

    // MARK: Start admission (C.6 and ADR-022 item 7)

    enum StartRefusal {
        /// A job is recording or finishing and overlapping is off: the C.6
        /// busy pulse, exactly as before the split.
        case busy
        /// Overlapping is on but two jobs are already finishing.
        case queueFull
        /// The developer turned overlapping on and the environment turned
        /// it off; the busy pulse plus one note saying why.
        case limitedBy(OverlapPauseReason)
    }

    enum StartAdmission {
        case admit(overlapping: Bool)
        case refuse(StartRefusal)
    }

    /// Whether a start would be admitted now. Pure — no side effect and no
    /// suspension — so `handleShortcut` can ask before committing to a
    /// Hybrid hold and `startRecording` can ask again after its dismiss.
    /// The focused terminal HUD counts as gone, because `startRecording`
    /// dismisses it first; a failed job kept behind a newer one holds no
    /// slot (its pipeline is over).
    func startAdmission() -> StartAdmission {
        guard !startInProgress, recordingRunner == nil, !terminating else { return .refuse(.busy) }
        var remaining = runners
        if let focused = focusedRunner, Self.restartableTerminalKinds.contains(focused.state.kind) {
            remaining.removeAll { $0 === focused }
        }
        let finishing = remaining.filter(\.isFinishing)
        guard !finishing.isEmpty else { return .admit(overlapping: false) }
        if overlappingJobs.value {
            return finishing.count < 2 ? .admit(overlapping: true) : .refuse(.queueFull)
        }
        if let fact = overlappingJobs.limitingFact, let reason = OverlapPauseReason(limitingFact: fact) {
            return .refuse(.limitedBy(reason))
        }
        return .refuse(.busy)
    }

    func refuseStart(_ refusal: StartRefusal) async {
        switch refusal {
        case .busy:
            await logIgnoredStart()
        case .queueFull:
            busyShortcutCount += 1
            await logOverlap(.dictationOverlapRefused, reason: "queueFull")
        case .limitedBy(let reason):
            busyShortcutCount += 1
            overlapPausedReason = reason
            await logOverlap(.dictationOverlapRefused, reason: "limitedBy:\(reason.rawValue)")
        }
    }

    func logOverlap(_ name: DiagnosticEventName, reason: String, jobID: JobID? = nil) async {
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: name,
                jobID: jobID,
                result: name == .dictationOverlapRefused ? .ignored : .success,
                errorCode: name == .dictationOverlapRefused ? .appBusy : nil,
                attributes: DiagnosticAttributes(
                    activeState: state.kind,
                    reason: reason,
                    finishingCount: runners.filter(\.isFinishing).count
                )
            )
        )
    }

    /// Starts one job after capturing the target application and settings.
    /// The optional ID is only for deterministic command/test sequences.
    @discardableResult
    public func startRecording(
        jobID requestedJobID: JobID? = nil,
        settings suppliedSettings: AppSettings? = nil,
        delivery: DictationDelivery = .insertIntoTarget,
        options: DictationStartOptions = .init()
    ) async -> DictationState {
        if !startInProgress, let visible = focusedRunner, Self.restartableTerminalKinds.contains(visible.state.kind) {
            // Two reducer-applied snapshots — terminal -> idle here, then
            // idle -> recording below — so every `state`/`hudState` observer
            // (HUD, menu) sees the dismiss edge instead of a direct jump. For
            // `.failed` this also discards any retained recoverable text
            // (`updateJob`/`updateFallbackText` clear it on `.dismiss` from a
            // terminal state): a new press means "record again", not
            // "recover this one". The HUD's own auto-dismiss timer is not a
            // race here — `HUDController.show` cancels the pending timer on
            // the very next render, which the `.idle`/`.recording` snapshots
            // this produces both trigger. Invariant (reviewer, 2026-09-16):
            // nothing on the terminal -> idle path of `apply(.dismiss)`
            // actually suspends, so this dismiss and the `startInProgress`
            // reservation below are atomic on the actor; a second press
            // cannot interleave a stray dismiss onto the new job. If
            // `.dismiss` ever gains real async work (a diagnostics line, a
            // store write), add a test with two overlapping starts.
            _ = try? await visible.apply(.dismiss, self)
        }
        let admission = startAdmission()
        guard case .admit(let overlapping) = admission else {
            if case .refuse(let refusal) = admission {
                await refuseStart(refusal)
            }
            return state
        }

        startInProgress = true
        let jobID = requestedJobID ?? makeJobID()
        // `clock.now` before the target capture, settings load, and
        // prerequisite check awaited below, so `captureStartMilliseconds`
        // includes everything between the user's press and the recorder.
        let runner = makeRunner(jobID: jobID, startCommandAt: clock.now, overlapped: overlapping)

        // Capture the frontmost target before an awaited settings load. The
        // insertion service, not this actor, re-resolves affinity later.
        // Each job captures its own target (ADR-022 item 7).
        let target = await services.insertionService?.captureTargetApplication()
        var settings = await loadSettings(fallback: suppliedSettings ?? AppSettings())
        configuredRecordingInteraction = settings.recordingInteraction

        // ADR-020: an App Intent may name an AI action for this job only. It
        // is copied into the snapshot the job carries, exactly as choosing it
        // from the menu would have, and the switch is turned on for the
        // snapshot because the request was explicit. Nothing is persisted:
        // `settingsRepository` is never written here.
        if delivery == .insertIntoTarget,
           let actionID = options.aiActionID,
           let action = settings.ai.promptModes.first(where: { $0.id == actionID }),
           action.isUsable {
            settings.ai.apply(promptMode: action)
            settings.ai.isEnabled = true
        }

        // The in-app test never processes with AI: it exercises the recorder
        // and STT path and shows the raw transcript (C.2 step 9).
        let mode: DictationMode = delivery == .inApp ? .off : settings.ai.mode
        let job = DictationJob(
            id: jobID,
            startedAt: Date(),
            target: target,
            modeSnapshot: mode,
            translationTargetSnapshot: settings.ai.translationLanguage,
            modelIDSnapshot: modelID(from: settings.selectedModel),
            historyEnabled: settings.historyEnabled,
            aiSettingsSnapshot: settings.ai,
            delivery: delivery,
            options: delivery == .inApp ? .init() : options
        )
        runner.prepare(settings: settings)
        inAppDeliveredText = nil

        // The actor can be re-entered while target/settings are awaited. A
        // newer command cannot steal this reservation; only admit this job if
        // the reservation is still intact and nothing started meanwhile (the
        // old `state == .idle` check: with no overlap admitted, no runner at
        // all may have appeared).
        guard startInProgress, recordingRunner == nil, overlapping || runners.isEmpty else {
            startInProgress = false
            return state
        }

        // Microphone permission and model readiness are verified before any
        // engine start (C.5 step 3, FR-PERM-002). A blocked start surfaces the
        // reason in the HUD instead of silently dropping the shortcut.
        if let prerequisiteChecker {
            let prerequisites = await prerequisiteChecker()
            guard startInProgress, recordingRunner == nil else {
                startInProgress = false
                return state
            }
            if case .blocked = prerequisites {
                startInProgress = false
                runner.clearSettings()
                admit(runner)
                _ = try? await runner.apply(.start(jobID: jobID, prerequisites: prerequisites), self)
                if runner.state.kind == .idle { remove(runner) }
                return state
            }
        }

        admit(runner)
        do {
            _ = try await runner.apply(.start(jobID: jobID, prerequisites: .passed), job: job, self)
        } catch {
            remove(runner)
            startInProgress = false
            return state
        }
        startInProgress = false

        guard runner.state.kind == .recording, runner.job?.id == jobID else {
            if runner.state.kind == .idle { remove(runner) }
            return state
        }
        overlapPausedReason = nil
        // A job that completed during the awaits above — while it was still
        // the shown one, so `runnerPipelineDidFinish` kept it — is now
        // behind this recording and is dismissed here (reviewer,
        // 2026-09-16: otherwise its "Inserted" HUD would show over this
        // job's phases and this job could be taken for the hidden one).
        // Only a runner whose pipeline is over: a row mid-append must not
        // lose its job.
        for other in runners where other !== runner && other.state.kind == .completed && other.pipelineTask == nil {
            await dismissHiddenCompletion(other)
        }
        if overlapping {
            await logOverlap(.dictationOverlapStarted, reason: "overlap", jobID: jobID)
        }

        await runner.beginCapture(self)
        return state
    }

    // MARK: - Helpers

    func loadSettings(fallback: AppSettings) async -> AppSettings {
        guard let settingsRepository else { return fallback }
        do {
            return try await settingsRepository.load()
        } catch {
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .dictationStateChanged,
                    result: .warning,
                    errorCode: .settingsCorrupt,
                    attributes: DiagnosticAttributes(
                        activeState: state.kind,
                        reason: "settingsSnapshotFallback"
                    )
                )
            )
            return fallback
        }
    }

    func logIgnoredStart() async {
        switch state.kind {
        case .finalizing, .transcribing, .processingAI, .inserting:
            busyShortcutCount += 1
        default:
            break
        }
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationStateChanged,
                result: .ignored,
                errorCode: .appBusy,
                attributes: DiagnosticAttributes(
                    activeState: state.kind,
                    reason: "startWhileBusy"
                )
            )
        )
    }

    func modelID(from reference: ModelReference?) -> ModelID {
        switch reference {
        case .managed(let modelID, _): return modelID
        case .external(_, let expectedModelID, _): return expectedModelID
        case .none: return ""
        }
    }
}
