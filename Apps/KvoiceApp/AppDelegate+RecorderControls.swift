import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceHotkeys
import KvoiceUI

/// ADR-021: the recorder styles and the in-recorder AI controls.
///
/// Glue only. `KvoiceHotkeys` owns the ⌘1–⌘0 / ⌘⇧A observers
/// (`RecordingAIControlMonitor`, scoped here to `.recording` exactly as the
/// Escape monitor is scoped to a job), `KvoiceAppCore` owns the seam that
/// swaps the running job's AI snapshot (`DictationController.setAIAction` /
/// `setAIEnabled`), and `KvoiceUI` renders the indicator from the published
/// snapshot. Nothing here writes settings: the persisted default action and
/// master switch are untouched by anything a user does mid-dictation.
extension AppDelegate {
    // MARK: Recording key monitor

    /// Called from `applyDictationSnapshot` beside `syncEscapeMonitoring`.
    /// The observers exist only while *this* job is recording; a new job id
    /// restarts them so a stale handler can never reach a later job.
    func syncRecordingAIControlMonitoring(for state: DictationState) {
        guard case .recording = state, let jobID = state.jobID else {
            if aiControlMonitoredJobID != nil {
                composition.shortcutAdapter.endRecordingAIControlMonitoring()
                aiControlMonitoredJobID = nil
            }
            return
        }
        guard aiControlMonitoredJobID != jobID else { return }

        composition.shortcutAdapter.endRecordingAIControlMonitoring()
        aiControlMonitoredJobID = jobID
        _ = composition.shortcutAdapter.beginRecordingAIControlMonitoring { [weak self] control in
            self?.handleRecordingAIControl(control)
        }
    }

    /// Routes a chord to the controller seam. The action id is resolved
    /// through the same saved-order lookup the AI Actions grid badges use
    /// (`PromptModeSettingsViewModel.action(forShortcutNumber:)`), so ⌘2 in
    /// the recorder is the action the grid shows as ⌘2.
    func handleRecordingAIControl(_ control: RecordingAIControl) {
        guard !terminationInProgress, latestState.kind == .recording else { return }
        switch control {
        case .action(let number):
            guard let action = promptModeSettingsViewModel.action(forShortcutNumber: number) else { return }
            Task { [weak self] in
                _ = await self?.composition.dictationController.setAIAction(id: action.id)
            }
        case .toggleAIEnabled:
            // The job snapshot, not the persisted setting, is what is
            // being flipped; `activeSettings` is that snapshot.
            let current = latestSnapshot?.activeSettings?.ai.mode ?? currentSettings.ai.mode
            let enable = current == .off
            Task { [weak self] in
                _ = await self?.composition.dictationController.setAIEnabled(enable)
            }
        }
    }

    // MARK: HUD projection

    /// The indicator the recorder shows for `snapshot`'s job, or nil for the
    /// onboarding in-app test (it never runs AI, C.2 step 9). "On" means a
    /// request will actually be made — the snapshot's derived `mode`, which
    /// also folds in the endpoint check — so the sparkles never promise a
    /// polish that cannot happen.
    func hudAIIndicator(for snapshot: DictationController.Snapshot, settings: AppSettings) -> HUDAIIndicator? {
        guard case .recording = snapshot.state, snapshot.state.jobID != inAppTestJobID else { return nil }
        let action = settings.ai.activePromptMode
        return HUDAIIndicator(
            isEnabled: settings.ai.mode != .off,
            actionName: action?.name,
            shortcutBadge: action.flatMap { promptModeSettingsViewModel.shortcutBadge(for: $0.id) }
        )
    }
}
