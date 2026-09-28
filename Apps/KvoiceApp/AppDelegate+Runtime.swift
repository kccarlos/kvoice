import AppKit
import KvoiceAppCore
import KvoiceAppleSpeech
import KvoiceDomain
import KvoiceModelManagement
import KvoiceParakeet
import KvoiceTranscription
import KvoiceUI

/// Speech Models › Runtime: the card that lets the user verify the model
/// runs on the intended silicon. Fills `RuntimeCardHooks` with the resident
/// engine's facts, plans placement with Core ML when the resident model or
/// its compute units change, applies a compute-unit change through the
/// library (which reloads the model), and runs the performance test on the
/// same reserved engine "Transcribe File…" uses.
///
/// Everything the card shows is a scalar; nothing here reaches diagnostics.
extension AppDelegate {
    /// Called once from `applicationDidFinishLaunching`. Assigning closures
    /// is idempotent.
    func installRuntimeHooks() {
        RuntimeCardHooks.snapshot = { [weak self] in
            await self?.runtimeSnapshot()
        }
        RuntimeCardHooks.setComputeUnits = { [weak self] units in
            guard let self else { throw KVoiceError(code: .appCancelled) }
            try await self.setSpeechComputeUnits(units)
        }
        RuntimeCardHooks.transcribePerformanceSample = { [weak self] in
            guard let self else { throw KVoiceError(code: .appCancelled) }
            return try await self.transcribePerformanceSample()
        }
    }

    // MARK: Snapshot

    private func runtimeSnapshot() async -> RuntimeSnapshot? {
        guard let library = composition.modelManager else { return nil }
        let engine = composition.residentEngine
        let resident = await engine.loadedModelID
        let units = await engine.currentComputeUnits
        let statistics = await engine.runtimeStatistics
        // ADR-019: "loading" is read from whichever per-runtime engine the
        // default model belongs to; the switching engine has no state of
        // its own.
        let engineIsLoading = await self.residentEngineIsLoading(defaultModelID: library.defaultModelID)
        guard !terminationInProgress else { return nil }
        let runtime = resident.flatMap { library.catalog.entry(id: $0)?.runtime }
        if let resident, runtime?.hasComputeUnitChoice != false {
            planPlacementIfNeeded(modelID: resident, units: units, library: library)
        } else if runtimePlacement != nil {
            // Nothing resident, or a runtime that places its own model
            // (ADR-025): no Core ML plan to make.
            runtimePlacement = nil
        }
        // ADR-022 item 5: every busy fact below is the library's activity.
        let activity = modelActivity
        let exercising = latestState.kind != .idle || activity == .transcribingFile
        return RuntimeSnapshot(
            residentModelID: resident,
            residentModelName: resident.flatMap { library.catalog.entry(id: $0)?.fullDisplayName },
            runtime: runtime,
            computeUnits: units,
            placement: runtimePlacement,
            placementIsPending: runtimePlacementTask != nil,
            statistics: statistics,
            isReloading: engineIsLoading || activity == .reloadingUnits,
            dictationIsActive: exercising || activity != .idle,
            isExercisingRuntime: exercising,
            computeUnitsAvailability: settingAvailability(.speechComputeUnits)
        )
    }

    /// The library's `ModelActivity` as the shell's gates read it — the
    /// synchronous copy, always equal to the actor's own (ADR-022 item 5).
    /// `.idle` without a library (trust failure): nothing can be busy.
    var modelActivity: ModelActivity {
        composition.modelManager?.currentActivity ?? .idle
    }

    /// Whether the engine that serves the default model is mid-load (the
    /// compute-unit reload, or the launch load). Both adapters expose the
    /// same `state`; the switching engine tells us which one to ask.
    private func residentEngineIsLoading(defaultModelID: ModelID) async -> Bool {
        let state: ModelLifecycleState?
        switch composition.residentEngine.engine(forModelID: defaultModelID) {
        case let whisper as WhisperTranscriptionEngine: state = await whisper.state
        case let parakeet as ParakeetTranscriptionEngine: state = await parakeet.state
        case let appleSpeech as AppleSpeechTranscriptionEngine: state = await appleSpeech.state
        default: state = nil
        }
        if case .loading = state { return true }
        return false
    }

    /// Plans once per (model, units) pair. `MLComputePlan` on the two
    /// large graphs takes a moment, so it runs off the poll and the card
    /// shows "Planning…" meanwhile; a result for a pair that is no longer
    /// current is simply superseded on the next tick.
    private func planPlacementIfNeeded(modelID: ModelID, units: SpeechComputeUnits, library: SpeechModelLibrary) {
        if let current = runtimePlacement, current.modelID == modelID, current.computeUnits == units { return }
        guard runtimePlacementTask == nil else { return }
        runtimePlacementTask = Task { [weak self] in
            defer { self?.runtimePlacementTask = nil }
            guard let package = await library.residentPackage(),
                  package.manifest.modelID == modelID else { return }
            let report = await CoreMLModelPlacementReporter().placement(for: package, computeUnits: units)
            guard let self, !self.terminationInProgress else { return }
            self.runtimePlacement = report
        }
    }

    // MARK: Compute units

    /// Reloads the resident model under the new units, then persists the
    /// choice. Refused while anything owns the engine, with the same
    /// `appBusy` the History transcriber uses, so the card can say "Finish
    /// the current dictation first." The availability row is the first
    /// check (it carries the reason); the library's `.reloadingUnits`
    /// activity is the authority (ADR-022 item 5) — a refusal from it is
    /// the same busy error. The setting is written only after the engine
    /// accepted the change, so a failed reload never persists a choice that
    /// does not run — which is why the reducer's `.setSpeechComputeUnits`
    /// row has no `.reloadModel` effect (KNOWN_ISSUES "Accepted
    /// deviations": the card awaits this outcome to snap back, and an
    /// effect the shell runs after a commit cannot be awaited by the
    /// caller or condition the write).
    func setSpeechComputeUnits(_ units: SpeechComputeUnits) async throws {
        guard let library = composition.modelManager else { throw KVoiceError(code: .modelNotInstalled) }
        guard settingAvailability(.speechComputeUnits).isEnabled else {
            throw KVoiceError(code: .appBusy)
        }
        do {
            try await library.setComputeUnits(units)
        } catch ModelManagementError.busy {
            throw KVoiceError(code: .appBusy)
        } catch is ModelActivityRefusal {
            throw KVoiceError(code: .appBusy)
        }
        sendSettingsIntent(.setSpeechComputeUnits(units, origin: .page(.models)))
        runtimePlacement = nil
    }

    // MARK: Performance test

    /// Transcribes the bundled sample on the reserved engine (the library's
    /// inference reservation applies, exactly as for "Transcribe File…").
    /// The run is the library's `.testing` activity (ADR-022 item 5): begun
    /// under the transition table, so a file, a reload, an unload or a
    /// model operation cannot interleave with it, and refused with the same
    /// `appBusy` when one of those is already running. The language hint is
    /// fixed to English, the sample's language, so the run measures
    /// transcription rather than language detection.
    func transcribePerformanceSample() async throws -> PerformanceSampleRun {
        guard let library = composition.modelManager else { throw KVoiceError(code: .modelNotInstalled) }
        guard latestState.kind == .idle else { throw KVoiceError(code: .appBusy) }
        do {
            try await library.beginActivity(.testing)
        } catch is ModelActivityRefusal {
            throw KVoiceError(code: .appBusy)
        }
        refreshSettingsAvailability()
        do {
            let run = try await runPerformanceSample()
            await library.endActivity()
            refreshSettingsAvailability()
            return run
        } catch {
            await library.endActivity()
            refreshSettingsAvailability()
            throw error
        }
    }

    private func runPerformanceSample() async throws -> PerformanceSampleRun {
        let recording = try PerformanceSampleAudio.load()
        let request = TranscriptionRequest(jobID: JobID(), audio: recording, languageHint: "en")
        let result = try await composition.transcriptionEngine.transcribe(request) { _ in }
        let inference = result.timings.inferenceEnd - result.timings.inferenceStart
        let factor = result.timings.runtimeReportedRealTimeFactor
            ?? Self.seconds(inference) / max(Self.seconds(recording.duration), 0.001)
        return PerformanceSampleRun(
            realTimeFactor: factor,
            audioDuration: recording.duration,
            inferenceDuration: inference
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
