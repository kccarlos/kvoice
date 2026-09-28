import AppKit
import Darwin
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

/// ADR-022 slice 3: the shell's side of the settings state chart.
///
/// Every settings write in the shell is `sendSettingsIntent(_:)`. The
/// coordinator (`AppDelegate.settingsCoordinator`) asks `settingsGate` for
/// the facts, runs the pure reducer, and hands each `SettingsEffect` to
/// `runSettingsEffect(_:)` — the one place the old handler bodies now live.
/// `currentSettings` is a read-only projection of the coordinator's state.
///
/// After every send the availability projection (`settingsAvailability`)
/// is recomputed from the same gate plus the `EnvironmentProfile` the slow
/// poll keeps, so a page that shows a disabled control with a reason is
/// never a poll behind the write that changed it.
extension AppDelegate {
    // MARK: Sending

    /// The one door. Returns the refusal so a caller whose control must snap
    /// back can do so; every refusal is also logged as scalars.
    @discardableResult
    func sendSettingsIntent(_ intent: SettingsIntent) -> SettingsRefusal? {
        let refusal = settingsCoordinator.send(intent)
        refreshSettingsAvailability()
        return refusal
    }

    /// The local-state door (ADR-022 slice 5). No availability row reads
    /// local state, so nothing is recomputed.
    @discardableResult
    func sendLocalStateIntent(_ intent: LocalStateIntent) -> SettingsRefusal? {
        settingsCoordinator.send(intent)
    }

    /// ADR-022 slice 7: the projection a settings view model is built over.
    /// One host per view model (each keeps its own refusal note for its own
    /// page), all over the one coordinator, all sending through the two
    /// doors above so the availability table follows every commit. The
    /// closures capture the delegate weakly because the app-lifetime view
    /// models are lazy properties of it.
    func makeSettingsProjectionHost() -> SettingsProjectionHost {
        SettingsProjectionHost(
            coordinator: settingsCoordinator,
            send: { [weak self] intent in self?.sendSettingsIntent(intent) },
            sendLocalState: { [weak self] intent in self?.sendLocalStateIntent(intent) }
        )
    }

    // MARK: Gate

    /// `SettingsGate` from facts the shell already has. ADR-022 item 5:
    /// `model` is the library's own `ModelActivity`, read synchronously
    /// (`SpeechModelLibrary.currentActivity`) so the gate never lags a
    /// mirror; a file transcription and the performance test are activities
    /// of that same machine, not shell flags.
    var settingsGate: SettingsGate {
        SettingsGate(
            dictation: latestState.kind == .idle ? .idle : .jobActive,
            model: modelActivity,
            settingsLoaded: settingsLoaded,
            terminationInProgress: terminationInProgress
        )
    }

    // MARK: Effects

    /// Runs one effect against the *committed* state (`currentSettings`
    /// already reads the new value when this is called). Each case is the
    /// body of the handler that used to own it; see the reducer's table.
    func runSettingsEffect(_ effect: SettingsEffect) {
        switch effect {
        case .persist:
            persistCurrentSettings()

        case .persistLocalState:
            persistCurrentLocalState()

        case .saveSecrets(let secrets):
            Task { [weak self] in
                guard let self else { return }
                try? await self.composition.secretsStore.save(secrets)
            }
            // The key is observed state, never read from `AppSettings`
            // (rule 2): every accepted `.setSecrets`, from any door, feeds
            // it back here. Idempotent when this model originated the
            // change; the correction the status menu's configuration pick
            // needs when it did not.
            aiSettingsViewModel.applySecrets(secrets)

        case .registerShortcut:
            registerShortcut(from: currentSettings)

        case .applyActivationPolicy:
            applyActivationPolicy()

        case .applyTriggerSettings:
            applyTriggerSettings(currentSettings)

        case .applyDerivedSettings:
            applyDerivedSettings(currentSettings)

        case .restoreSelectedModel:
            restoreSelectedModelFromSettings(currentSettings)

        case .offerRelaunch(let language):
            // Mirror the override only when the language actually changed
            // (the reducer emits this only then), then raise the picker's
            // own relaunch alert by hand so an import gets the same consent
            // a manual pick gets.
            InterfaceLanguageOverride.apply(language)
            generalSettingsViewModel.isRelaunchForLanguagePending = true

        case .refreshCatalogLimit:
            refreshDictionaryCatalogLimit()
            // ADR-025: the system-managed entry's state follows the
            // transcription language; every speech-model intent ends here.
            propagateTranscriptionLanguage(currentSettings)

        case .rebuildMenu:
            updateMenu(for: latestState)

        case .unregisterLoginItem:
            // Runs after the commit: `generalSettingsViewModel.launchAtLogin`
            // (a projection) already reads the reducer's stored `false`, so
            // the status re-read below finds nothing to flip back.
            try? generalSettingsViewModel.launchAtLoginService.unregister()
            generalSettingsViewModel.refreshLaunchAtLoginStatus()

        case .resetMainWindowFrame:
            if let mainWindow {
                NSWindow.removeFrame(usingName: "kvoice.main")
                mainWindow.window?.setContentSize(MainWindowController.defaultContentSize)
                mainWindow.window?.center()
            }
        }
    }

    /// One scalar line per refusal (rule 3): the intent's name, the door,
    /// and the typed reason — never the value.
    func recordSettingsRefusal(_ intent: SettingsIntent, _ refusal: SettingsRefusal) {
        recordRefusal(intentName: intent.name, origin: intent.origin, refusal)
    }

    func recordLocalStateRefusal(_ intent: LocalStateIntent, _ refusal: SettingsRefusal) {
        recordRefusal(intentName: intent.name, origin: intent.origin, refusal)
    }

    private func recordRefusal(intentName: String, origin: SettingsOrigin, _ refusal: SettingsRefusal) {
        let event = DiagnosticEvent(
            name: .settingsIntentRefused,
            attributes: DiagnosticAttributes(
                reason: "\(refusal.reason)",
                site: "\(intentName).\(origin.name)"
            )
        )
        let diagnostics = composition.diagnostics
        Task { await diagnostics.log(event) }
    }

    // MARK: Availability (ADR-022 item 3)

    /// The observed facts the rules read (ADR-022 slice 5). `hasNotch` is
    /// re-read from the recording-start screen each time (cheap, and the
    /// display can change); everything else is what the slow poll sampled.
    var availabilityEnvironment: EnvironmentProfile {
        var profile = environmentProfile
        profile.hasNotch = HUDController.geometry(of: nil).notch != nil
        return profile
    }

    /// The identity facts that never change for the process, filled once
    /// from `applicationDidFinishLaunching`.
    func installEnvironmentIdentity() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        environmentProfile.appVersion = [version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        environmentProfile.machineClass = Self.hardwareModelIdentifier()
    }

    /// `hw.machine` (Mac16,6 style): a hardware class, never a serial.
    private static func hardwareModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Recomputes the table the pages observe. Called after every intent,
    /// on every dictation-state change, and from the one-second slow poll.
    /// The "changed from default" affordance (ADR-022 item 2) needs no
    /// refresh of its own any more: `SettingsResetRow` reads
    /// `host.effective` straight from the page's own projection host.
    func refreshSettingsAvailability() {
        settingsAvailability.update(
            SettingsAvailability.table(
                settings: currentSettings,
                environment: availabilityEnvironment,
                gate: settingsGate
            )
        )
        pushOverlappingJobsIfChanged()
    }

    /// ADR-022 item 7: the controller reads the effective `overlappingJobs`
    /// row at each key-down; this is the one place it is handed over, after
    /// every re-resolve (an intent, a dictation-state change, the slow poll
    /// that carries memory pressure, compute units and the last RTF).
    private func pushOverlappingJobsIfChanged() {
        let row = settingsCoordinator.effective.overlappingJobs
        guard row != lastPushedOverlappingJobs else { return }
        lastPushedOverlappingJobs = row
        // Chained on the previous push so two re-resolves in quick
        // succession reach the actor in order (two free tasks could not
        // promise that).
        let previous = overlappingJobsPushTask
        overlappingJobsPushTask = Task { [weak self] in
            await previous?.value
            await self?.composition.dictationController.setOverlappingJobs(row)
        }
    }

    /// One key, for the shell-owned snapshots (the Runtime card's compute
    /// units, the memory-pressure unload).
    func settingAvailability(_ key: SettingKey) -> SettingAvailability {
        SettingsAvailability.availability(
            key: key, settings: currentSettings, environment: availabilityEnvironment, gate: settingsGate
        )
    }
}
