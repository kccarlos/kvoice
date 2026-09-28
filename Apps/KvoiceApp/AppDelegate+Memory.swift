import AppKit
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import KvoiceUI

/// Later waves: memory-pressure warnings. Consumes the one
/// `MemoryPressureObserving` stream for the app's life and fans it into
/// `memoryPressureViewModel` — the single source both the status menu
/// (`AppDelegate+Menu.swift`'s `statusSummary` and `unloadModelMenuItem`)
/// and the Runtime card's banner (`AppDelegate+SettingsSurface.swift`) read,
/// so both surfaces always agree.
///
/// There is no per-poll diagnostic here: `MemoryPressureViewModel.apply`
/// already de-duplicates, so `onLevelChange` (wired in `AppDelegate.swift`'s
/// `memoryPressureViewModel` initializer) fires once per real transition.
extension AppDelegate {
    /// Called once from `applicationDidFinishLaunching`.
    func installMemoryPressureObservation() {
        memoryPressureTask?.cancel()
        memoryPressureTask = Task { [weak self] in
            guard let self else { return }
            let observer = self.composition.memoryPressureObserver
            let initial = await observer.currentLevel
            guard !Task.isCancelled, !self.terminationInProgress else { return }
            self.memoryPressureViewModel.apply(level: initial)
            self.updateMenu(for: self.latestState)
            for await level in observer.changes() {
                guard !Task.isCancelled, !self.terminationInProgress else { return }
                self.memoryPressureViewModel.apply(level: level)
                // ADR-022 slice 5: the level is an environment fact the
                // resolver clamps on (overlapping jobs off under pressure).
                self.environmentProfile.memoryPressureLevel = level
                self.settingsCoordinator.observe(environment: self.environmentProfile)
                self.updateMenu(for: self.latestState)
            }
        }
    }

    /// "Unload model now" — the status-menu item and the Runtime card's
    /// banner button both reach this through `memoryPressureViewModel`'s
    /// injected `unload` action, so they share one in-flight state and one
    /// error message. Refused with the same `appBusy` `setSpeechComputeUnits`
    /// uses (`AppDelegate+Runtime.swift`), so the message is the familiar
    /// "Finish the current dictation first."
    ///
    /// The package stays verified and selected — only the engine's runtime
    /// is released — so the model is Not Ready only in the sense a
    /// just-launched, not-yet-loaded model is: the next dictation's
    /// prerequisite check (`AppComposition`'s `prerequisiteChecker`) sees it
    /// unloaded, shows Blocked/loading, and reloads it in the background.
    func unloadResidentModelNow() async throws {
        guard let library = composition.modelManager else {
            throw KVoiceError(code: .modelNotInstalled)
        }
        // ADR-022 item 3: "Unload Model while anything holds the engine" is
        // the projection's `.unloadModel` row; the same row drives the
        // banner button and the menu item through `memoryPressureViewModel`.
        guard settingAvailability(.unloadModel).isEnabled else {
            throw KVoiceError(code: .appBusy)
        }
        // ADR-022 item 5: the library's `.unloading` activity is the
        // authority; a refusal that beat the availability row (a reload
        // that began between the two reads) is the same busy error.
        do {
            try await library.unloadResidentRuntime()
        } catch is ModelActivityRefusal {
            throw KVoiceError(code: .appBusy)
        }
        runtimePlacement = nil
        updateMenu(for: latestState)
    }

    /// One scalar diagnostic per level change (never per poll — the view
    /// model's `apply` already de-duplicates before calling this). `reason`
    /// carries the new level; `memoryBucket` the footprint band read through
    /// the same Mach adapter the Runtime card uses, at the moment of the
    /// change — never the exact byte count (rule 3).
    func recordMemoryPressureDiagnostic(_ level: MemoryPressureLevel) {
        let bucket = composition.runtimeTelemetry.memoryFootprintBytes()
            .map { MemoryFootprintBucket.token(forBytes: $0).rawValue }
        let event = DiagnosticEvent(
            name: .memoryPressureLevelChanged,
            attributes: DiagnosticAttributes(reason: level.rawValue, memoryBucket: bucket)
        )
        let diagnostics = composition.diagnostics
        Task { await diagnostics.log(event) }
    }
}
