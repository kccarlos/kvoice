import AppIntents
import AppKit
import KvoiceAppCore

/// ADR-020: wires the App Intents surface. The service is the only object
/// the intents depend on; it is registered with `AppDependencyManager` at
/// launch so an intent that arrives from Shortcuts, Siri, or Spotlight —
/// with the app frontmost or not — finds the same controller the hotkey
/// uses. When the app is not running the system launches it in the
/// background first, so registration happens before any `perform()`.
extension AppDelegate {
    func installAppIntents() {
        let service = DictationCommandService(
            controller: composition.dictationController,
            history: composition.historyStore,
            settingsProvider: { [weak self] in self?.currentSettings ?? .init() },
            // The same refusal the hotkey path makes (`receiveShortcut`):
            // a file transcription, the Runtime performance test, or a
            // compute-unit reload owns the resident engine
            // (`ModelActivity.refusesDictationStart`, ADR-022 item 5).
            startGate: { [weak self] in
                guard let self, !self.terminationInProgress else { return false }
                return !self.modelActivity.refusesDictationStart
            },
            diagnosticLogger: composition.diagnostics
        )
        AppDependencyManager.shared.add(dependency: service)
        // Lets the system index the phrases at launch (and re-index them
        // after a locale change) rather than waiting for a Shortcuts visit.
        KvoiceShortcuts.updateAppShortcutParameters()
    }
}
