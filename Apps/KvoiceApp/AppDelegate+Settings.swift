import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

/// Loading settings, the change handlers that remain, and shortcut
/// registration.
///
/// Since ADR-022 slice 3 every handler here is one line of policy: turn what
/// the view model emitted into a `SettingsIntent` and send it. Since slice 7
/// every settings page is a projection over the coordinator and sends its
/// own intents (`SettingsProjectionHost`, `makeSettingsProjectionHost()`),
/// so there is no per-page change handler left in this file. The two
/// invariants that used to be repeated per handler live in
/// `SettingsReducer` behind the one `SettingsGate`:
///
/// - Nothing persists before `settingsLoaded` is true, so the initial load
///   cannot be mistaken for a user edit and write defaults over stored values.
/// - Settings changes that affect a running job wait for idle. A live job holds
///   its own settings snapshot, and changing the shortcut or endpoint underneath
///   it would make its behavior nondeterministic.
///
/// What a handler does after the reducer accepted the intent is the effect
/// list in the reducer's table, run by `AppDelegate+SettingsCoordinator.swift`.
extension AppDelegate {
    func loadSettingsAndRegisterShortcut() {
        settingsLoadTask = Task { [weak self] in
            guard let self else { return }
            let settings: AppSettings
            let localState: LocalState
            let secrets: SecretSettings
            do {
                settings = try await self.composition.settingsStore.load()
            } catch {
                settings = AppSettings()
            }
            // ADR-022 slice 5: the local blob loads beside the settings; on
            // the first launch after the split the store seeds it from the
            // old settings blob (`LocalStateStore.load`).
            do {
                localState = try await self.composition.localStateStore.load()
            } catch {
                localState = .fresh
            }
            do {
                secrets = try await self.composition.secretsStore.load()
            } catch {
                secrets = SecretSettings()
            }

            await MainActor.run {
                guard !self.terminationInProgress else { return }
                self.settingsLoaded = false
                // First run has no modes stored; seed the shipped ones so the
                // menu is never empty. Done on the loaded value before it
                // becomes the coordinator's state, so the load stays one
                // hydration rather than a load plus a gated write.
                var settings = settings
                let seededPromptModes = settings.ai.promptModes.isEmpty
                if seededPromptModes {
                    settings.ai.seedBuiltInPromptModesIfNeeded()
                }
                // Every page is a projection over the coordinator and needs
                // no hydration; loading here is the one place a load-time
                // value reaches them at all.
                self.settingsCoordinator.load(settings)
                self.settingsCoordinator.load(localState: localState)
                // Re-mirror the interface language into `AppleLanguages` so a
                // restored settings file or a cleared defaults domain converges
                // on the next launch (this process already read the old value).
                InterfaceLanguageOverride.apply(settings.interfaceLanguage)
                // The key is observed state, never read from `AppSettings`
                // (rule 2): this is its one load-time seed.
                self.aiSettingsViewModel.applySecrets(secrets)
                // The AI pair's own drafts (endpoint fields, the profile)
                // seeded as empty defaults at `AppDelegate.init`, before this
                // load ran — `discardStaleDrafts()` re-seeds them from what
                // just loaded. Without this they self-heal on the next read
                // or flush anyway, but a page opened in the gap between
                // `init` and this load would show the empty defaults until
                // then; closing the gap explicitly is cheap and precise.
                self.aiSettingsViewModel.discardStaleDrafts()
                self.promptModeSettingsViewModel.discardStaleDrafts()
                self.refreshDictionaryCatalogLimit()
                self.settingsLoaded = true
                if seededPromptModes {
                    self.persistCurrentSettings()
                }
                // Retention runs against the loaded settings, never the defaults.
                self.startHistoryMaintenance()
                self.applyActivationPolicy()
                self.registerShortcut(from: settings)
                self.applyTriggerSettings(settings)
                self.applyDerivedSettings(settings)
                self.restoreSelectedModelFromSettings(settings)
                // FR-ONB-009: completion lives in local state, independent
                // of readiness. A version bump replays onboarding; the
                // 2026-09-16 six-step restructure deliberately did not bump
                // (see `OnboardingViewModel.currentOnboardingVersion`).
                if OnboardingViewModel.shouldPresentSetup(completedVersion: localState.onboardingVersionCompleted) {
                    self.showSetup()
                }
                self.updateMenu(for: self.latestState)
                self.refreshSettingsAvailability()
            }
        }
    }

    /// Pushes settings that other components mirror: the controller's live
    /// history flag and the insertion tier policy.
    func applyDerivedSettings(_ settings: AppSettings) {
        let historyEnabled = settings.historyEnabled
        composition.insertionService.setTypedInsertionEnabled(settings.typedInsertionEnabled)
        Task { [weak self] in
            await self?.composition.dictationController.setHistoryEnabled(historyEnabled)
        }
    }

    /// FR-ONB-010: replays the education flow without deleting the model,
    /// history, or settings.
    func resetOnboarding() {
        guard sendLocalStateIntent(.resetOnboarding(origin: .page(.general))) == nil else { return }
        composition.onboardingViewModel.restart()
        showSetup()
    }

    /// General › Reset Preferences (under Help until the 2026-09-13 regroup).
    /// What is reset and what is deliberately kept is the reducer's
    /// `.resetPreferences` row; the login-item removal and the window-frame
    /// reset are its effects.
    func resetPreferences() {
        sendSettingsIntent(.resetPreferences(origin: .page(.general)))
    }

    /// Help › Restart: launches a second instance of this bundle and, once
    /// it is running, terminates this one through the ordinary quit path so
    /// an active dictation is cancelled cleanly (FR-APP-004). The new
    /// instance is told which process it replaces (`--replaces-pid`), so
    /// its `InstanceHandoff` waits on — and may terminate — this process
    /// and no other (`AppDelegate+Lifecycle.swift`).
    func restartApp() {
        guard !terminationInProgress else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [
            InstanceHandoff.replacesProcessArgument,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                // If the relaunch failed, quitting would leave the user
                // with no app at all; stay running instead.
                guard error == nil else {
                    NSSound.beep()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// The main window's sidebar selection, persisted so the window reopens
    /// on the same section. Not gated on idle: it affects no job.
    func mainWindowSectionChanged(_ section: MainWindowSection) {
        sendLocalStateIntent(.setMainWindowSection(section.rawValue, origin: .shell))
    }

    /// Hooks the Settings/onboarding surfaces need from the shell: Forget for
    /// an external model, the download space estimate, and history metrics.
    func installSettingsSurfaceHooks() {
        SettingsSurface.onForgetExternalModel = { [weak self] in
            self?.forgetExternalModel()
        }
        SettingsSurface.modelSpaceEstimate = { [weak self] in
            guard let self, let estimate = await self.modelInstallationSpaceEstimate() else { return nil }
            return (requiredBytes: estimate.requiredBytes, availableBytes: estimate.availableBytes)
        }
        SettingsSurface.historyMetrics = { [weak self] in
            guard let self else { return nil }
            let store = self.composition.historyStore
            guard let count = try? await store.count(),
                  let bytes = try? await store.storageSizeBytes() else { return nil }
            return HistoryMetrics(entryCount: count, databaseBytes: bytes)
        }
    }

    func persistCurrentSettings() {
        let snapshot = currentSettings
        Task { [weak self] in
            guard let self else { return }
            try? await self.composition.settingsStore.save(snapshot)
        }
    }

    /// The `.persistLocalState` effect (ADR-022 slice 5).
    func persistCurrentLocalState() {
        let snapshot = currentLocalState
        Task { [weak self] in
            guard let self else { return }
            try? await self.composition.localStateStore.save(snapshot)
        }
    }

    // MARK: Shortcut registration

    func registerShortcut(from settings: AppSettings) {
        composition.shortcutAdapter.unregister()
        shortcutError = nil
        guard let shortcut = settings.shortcut else {
            updateMenu(for: latestState)
            return
        }

        do {
            try composition.shortcutAdapter.register(shortcut) { [weak self] event in
                self?.receiveShortcut(event)
            }
            composition.onboardingViewModel.setShortcutRegistrationState(
                composition.shortcutAdapter.registrationState
            )
        } catch {
            shortcutError = error.localizedDescription
            composition.onboardingViewModel.setShortcutRegistrationState(
                composition.shortcutAdapter.registrationState
            )
        }
        updateMenu(for: latestState)
    }

    func receiveShortcut(
        _ event: ShortcutEvent,
        trigger: DictationController.ShortcutTrigger = .primary
    ) {
        guard !terminationInProgress else { return }
        // The wizard's Try It indicator (shortcut page) borrows the primary
        // shortcut's edges while it is visible (`onboardingHotkeyTestHook`,
        // installed and removed only by `.beginHotkeyTest`/`.endHotkeyTest`)
        // and must not start a dictation. The middle-mouse trigger is unaffected: it
        // is not what the step is testing.
        if trigger == .primary, let onboardingHotkeyTestHook {
            onboardingHotkeyTestHook(event)
            return
        }
        // The edge's instant is taken here, synchronously: the start edge
        // awaits target capture and engine start, and Hybrid would otherwise
        // measure a quick tap as a hold.
        let at = ContinuousClock.now
        // Controller start/stop calls contain awaits (target capture,
        // permission, and settings snapshots). Queue key edges here so a fast
        // release cannot enter the actor while key-down is still admitting the
        // job and leave a newly-started recording without its matching stop.
        let previous = shortcutEventTask
        shortcutEventTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            guard !self.terminationInProgress else { return }
            // No readiness guard here: the controller's prerequisite check
            // turns a press with no model or no microphone into a Blocked HUD
            // (C.8, Q matrix) instead of silently dropping it.
            // A file transcription, the Runtime performance test, or a
            // compute-unit reload owns the resident engine
            // (`ModelActivity.refusesDictationStart`); starting a dictation
            // now would fail rather than be Blocked on a missing model, so
            // the press gets the busy beep. Any other activity (a download,
            // a pressure unload/reload) reaches the controller, whose
            // prerequisite check shows the Blocked HUD with its reason.
            // Key-up and a toggle stop still go through, so a running
            // recording can always end.
            if event == .keyDown, self.latestState.kind == .idle,
               self.modelActivity.refusesDictationStart {
                NSSound.beep()
                return
            }
            let mode = self.currentSettings.recordingInteraction
            _ = await self.composition.dictationController.handleShortcut(
                event,
                mode: mode,
                trigger: trigger,
                at: at
            )
        }
    }

    // MARK: Prompt preview

    /// Runs sample text through a candidate prompt using the live endpoint.
    ///
    /// Deliberately goes through the ordinary AI client rather than a shortcut,
    /// so what the user sees in the editor is what a real dictation would
    /// produce with that prompt.
    func runPromptPreview(mode: PromptMode, sample: String) async throws -> String {
        var settings = currentSettings.ai
        settings.apply(promptMode: mode)
        // ADR-024: complete for an endpoint (URL and model) or the on-device
        // transport (nothing to fill in).
        guard settings.canEnableProcessing else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }

        let credentials = aiSettingsViewModel.apiKey.isEmpty
            ? nil
            : AICredentialSnapshot(apiKey: aiSettingsViewModel.apiKey)
        let request = AIProcessRequest(
            jobID: UUID(),
            mode: settings.mode,
            rawTranscript: sample,
            modelID: settings.modelID,
            targetLanguage: settings.mode == .translate ? settings.translationLanguage : nil,
            polishPrompt: settings.promptConfiguration.systemPrompt(
                for: settings.mode,
                targetLanguage: settings.translationLanguage
            )
        )
        let result = try await composition.aiProcessingClient.process(
            request,
            settings: settings,
            credentials: credentials
        )
        return result.text
    }
}
