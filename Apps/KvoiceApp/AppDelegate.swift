import AppKit
import KvoiceAppCore
import KvoiceAudio
import KvoiceDomain
import KvoiceHotkeys
import KvoiceUI

/// The app shell: owns the composed graph, the mutable UI-facing state, and the
/// NSApplication lifecycle.
///
/// Everything else is split by concern into extensions in their own files:
///
/// | File | Owns |
/// | --- | --- |
/// | `AppDelegate+Lifecycle.swift` | The restart handshake (2026-09-16): the `NSRunningApplication` lookup behind `InstanceHandoff`, and the `app.terminate.*` / `app.instanceHandoff.*` diagnostics lines |
/// | `AppDelegate+Menu.swift` | The status item, its submenus, the main window routing, the HUD, and escape monitoring |
/// | `AppDelegate+StatusPanel.swift` | P-D4: the left-click panel — the click split, the `StatusPanelContext` and choosers built from the same facts as the menu, and the command handler that maps onto the menu's selectors |
/// | `AppDelegate+Settings.swift` | Loading settings, the change handlers that send `SettingsIntent`s, shortcut registration, Reset Preferences and Restart |
/// | `AppDelegate+SettingsCoordinator.swift` | ADR-022 slice 3: the settings gate, the effect runner behind `SettingsCoordinator`, refusal diagnostics, and the availability projection the pages observe |
/// | `AppDelegate+Model.swift` | Model download, selection, retry, deletion, and state republishing |
/// | `AppDelegate+Onboarding.swift` | The setup window and the onboarding intent router |
/// | `AppDelegate+Tutorial.swift` | The standalone tutorial window, the existing-user banner, and `tutorialSeen` persistence |
/// | `AppDelegate+SettingsSurface.swift` | The view models and hooks behind the main-window sections |
/// | `AppDelegate+AIActions.swift` | The AI context provider, Selection Action shortcut slots, and their HUD feedback |
/// | `AppDelegate+History.swift` | Stored audio, Auto Daily Export, retention cleanup, Transcribe File, and the Data & Privacy hooks |
/// | `AppDelegate+Triggers.swift` | Cancel shortcut, middle mouse trigger, hold ceiling, the Shortcuts/Recording bindings, and the `Microphone ▸` submenu |
/// | `AppDelegate+RecorderControls.swift` | ADR-021: the recording-scoped ⌘1–⌘0 / ⌘⇧A monitor, its route to the controller seam, and the HUD's AI indicator |
/// | `Intents/AppDelegate+Intents.swift` | ADR-020: registers `DictationCommandService` for the App Intents (Shortcuts, Siri, Spotlight) |
///
/// The stored properties below are deliberately `internal` rather than
/// `private`: Swift's `private` is file-scoped, so those extensions could not
/// see them. Treat them as private to this type regardless — nothing outside
/// `AppDelegate` should touch them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ADR-026: decided once, before anything is built, and handed to every
    /// consumer at construction — the composition root, the environment
    /// profile and the availability model — so no page ever renders with the
    /// default edition first.
    static let edition = DistributionEdition(
        infoDictionary: Bundle.main.infoDictionary,
        environment: ProcessInfo.processInfo.environment
    )

    let composition = AppComposition(edition: AppDelegate.edition)

    /// The Settings scene reads the same view model that drives registration
    /// and persistence. ADR-022 slice 7: a projection over the coordinator
    /// (`makeSettingsProjectionHost()`), so it holds no copy of the settings
    /// and every edit is an intent through `sendSettingsIntent`. Lazy so the
    /// host's closures retain the app delegate only weakly after NSObject
    /// initialization has completed.
    private(set) lazy var generalSettingsViewModel = GeneralSettingsViewModel(
        host: makeSettingsProjectionHost()
    )

    /// Later waves: memory-pressure warnings. Lives for the app's life, like
    /// `generalSettingsViewModel` above, not scoped to the Settings window:
    /// the status menu's line and the opt-in automatic unload both need the
    /// level and the unload action whether or not Settings is open. The
    /// Runtime card's banner reads this same instance
    /// (`AppDelegate+SettingsSurface.swift`). Wired in
    /// `AppDelegate+Memory.swift`. The opt-in is read through the host.
    private(set) lazy var memoryPressureViewModel = MemoryPressureViewModel(
        host: makeSettingsProjectionHost(),
        // ADR-022 item 3: the `.unloadModel` availability row.
        isIdle: { [weak self] in
            self?.settingAvailability(.unloadModel).isEnabled ?? false
        },
        unload: { [weak self] in
            try await self?.unloadResidentModelNow()
        },
        onLevelChange: { [weak self] level in
            self?.recordMemoryPressureDiagnostic(level)
        }
    )

    /// Settings › Shortcuts and Recording (product decisions #5 and #10) and
    /// the Microphone section / status submenu. Projections like the
    /// General model; lazy for the same reason; wired in
    /// `AppDelegate+Triggers.swift`.
    private(set) lazy var triggerSettingsViewModel = TriggerSettingsViewModel(
        host: makeSettingsProjectionHost()
    )
    private(set) lazy var audioInputViewModel = AudioInputViewModel(
        host: makeSettingsProjectionHost(),
        deviceProvider: CoreAudioInputDeviceProvider()
    )

    private(set) var aiSettingsViewModel: AISettingsViewModel!
    private(set) var promptModeSettingsViewModel: PromptModeSettingsViewModel!

    private(set) lazy var historyViewModel: HistoryViewModel = {
        let model = HistoryViewModel(
            repository: composition.historyStore,
            host: makeSettingsProjectionHost()
        )
        // P-M8: the History page's "Save History is off" note links to
        // Data & Privacy, the toggle's one remaining home.
        model.openDataPrivacy = { [weak self] in
            self?.openMainWindow(section: .dataPrivacy)
        }
        return model
    }()

    // MARK: Settings state (ADR-022 slice 3)

    /// Owns the single `AppSettings` value. Every write is a `SettingsIntent`
    /// through `sendSettingsIntent(_:)` (`AppDelegate+SettingsCoordinator.swift`);
    /// the gate and the effect runner are the shell's, injected here. Lazy
    /// for the same reason as the view models above (the closures capture
    /// the delegate weakly after NSObject initialization).
    private(set) lazy var settingsCoordinator: SettingsCoordinator = {
        let coordinator = SettingsCoordinator(
            // ADR-022 slice 5: the developer layer, read once by the
            // composition, is fixed for the process.
            developerDefaults: composition.developerDefaults,
            gate: { [weak self] in self?.settingsGate ?? SettingsGate(settingsLoaded: false) },
            effectRunner: { [weak self] effect in self?.runSettingsEffect(effect) }
        )
        coordinator.onRefusal = { [weak self] intent, refusal in
            self?.recordSettingsRefusal(intent, refusal)
        }
        coordinator.onLocalStateRefusal = { [weak self] intent, refusal in
            self?.recordLocalStateRefusal(intent, refusal)
        }
        return coordinator
    }()

    /// A read-only projection of the coordinator's state. Nothing else
    /// stores a copy of the truth; mutate through an intent.
    var currentSettings: AppSettings { settingsCoordinator.settings }
    /// ADR-022 slice 5: this Mac's local state (onboarding completion, the
    /// tutorial flag, the sidebar section, the export folder grant). Mutate
    /// through `sendLocalStateIntent`.
    var currentLocalState: LocalState { settingsCoordinator.localState }
    var settingsLoaded = false
    var shortcutError: String?

    /// ADR-022 item 3: the availability table the pages observe, refreshed
    /// by `refreshSettingsAvailability()`.
    let settingsAvailability = SettingsAvailabilityModel(edition: AppDelegate.edition)
    /// ADR-022 slice 5: the observed facts (`EnvironmentProfile`) the
    /// availability rules and the resolver read. Rebuilt on the one-second
    /// slow poll (`refreshSlowState`) and never persisted; the identity
    /// fields are filled once at launch (`installEnvironmentIdentity`).
    var environmentProfile = EnvironmentProfile(edition: AppDelegate.edition)

    // MARK: Menu state

    var statusItem: NSStatusItem?
    /// P-D4: the `NSMenu` is no longer the status item's `menu` — a set menu
    /// makes every left-click open it. It is kept here and popped up by
    /// `showStatusMenu()` on a right-click or ⌥-click (`statusItemClicked`),
    /// unchanged in content: the keyboard / VoiceOver fallback to the panel.
    var statusMenu: NSMenu?
    /// Owns the menu-bar logo and its glow. Nil only if the status button could
    /// not be created.
    var statusIcon: StatusItemIconController?
    /// P-D3: the model behind the Start Recording item's hosted row
    /// (`StatusMenuHeaderItemView`). Fed by `updateMenu(for:)` (context) and
    /// the HUD's rendered state (meter, clock); owns no task or level source.
    /// P-D4: shared with the status panel, which reads it for its header —
    /// one feed, so the panel's meter is the menu row's and exists only when
    /// that one does.
    let statusMenuHeaderModel = StatusMenuHeaderModel()
    /// P-D4: the model behind the left-click panel (`StatusPanelView`), over
    /// the header model above plus a `StatusPanelContext` filled at the end
    /// of `updateMenu(for:)`. Lazy: it captures the header model, and its
    /// closures the delegate weakly (`installStatusPanel`).
    private(set) lazy var statusPanelModel = StatusPanelModel(header: statusMenuHeaderModel)
    /// P-D4: the popover presenter; nil until `installStatusItem`.
    var statusPanelController: StatusPanelController?
    var readinessItem: NSMenuItem?
    /// D4/N7: shown only while `statusSummary.blocked`, right under Status —
    /// "Status: Model not ready" does not itself say it is the fix; this row
    /// does, naming the section that resolves it.
    var fixItem: NSMenuItem?
    var actionItem: NSMenuItem?
    var cancelItem: NSMenuItem?
    var setupItem: NSMenuItem?
    /// D3/N6: flattened into the App group on 2026-09-16 — "Help & Setup ▸"
    /// was a two-item submenu, which does not earn a level (`menus.md ›
    /// Submenus`).
    var helpItem: NSMenuItem?
    var providerItem: NSMenuItem?
    var modeItem: NSMenuItem?
    var modelMenuItem: NSMenuItem?
    var historyMenuItem: NSMenuItem?
    var aiToggleItem: NSMenuItem?
    var languageItem: NSMenuItem?
    var audioInputItem: NSMenuItem?
    var copyLastTranscriptionItem: NSMenuItem?
    /// ADR-022 item 6: visible only while a failed job keeps its transcript.
    var copyTranscriptItem: NSMenuItem?
    var insertTranscriptAgainItem: NSMenuItem?
    /// Later waves: memory-pressure warnings. Visible only under critical
    /// pressure; shares `memoryPressureViewModel.unloadNow()` with the
    /// Runtime card's banner button.
    var unloadModelMenuItem: NSMenuItem?

    // MARK: Menu hooks for other workstreams
    //
    // Each receives an empty submenu to fill and returns true when it did;
    // false (the default, nil) leaves the placeholder the shell builds.

    /// Models workstream: the `Model ▸` submenu (installed models, Apple
    /// Speech, Manage Models…).
    var modelSubmenuProvider: (@MainActor (NSMenu) -> Bool)?
    /// Models workstream: the `Language ▸` submenu (transcription language).
    var languageSubmenuProvider: (@MainActor (NSMenu) -> Bool)?
    /// Audio workstream: the `Microphone ▸` submenu (input devices).
    var audioInputSubmenuProvider: (@MainActor (NSMenu) -> Bool)?

    // MARK: Windows

    var onboardingWindow: OnboardingWindowController?
    var mainWindow: MainWindowController?
    /// Help › Show Tutorial and the existing-user banner (Later waves:
    /// tutorial pages); see `AppDelegate+Tutorial.swift`.
    var tutorialWindow: TutorialWindowController?

    /// Installed only while the wizard's Try It indicator (shortcut page) is visible
    /// (`AppDelegate+Onboarding.handleOnboardingIntent`, `.beginHotkeyTest` /
    /// `.endHotkeyTest`). While set, `receiveShortcut` reports the primary
    /// shortcut's edges here instead of starting a dictation.
    var onboardingHotkeyTestHook: (@MainActor (ShortcutEvent) -> Void)?

    // MARK: AI actions (AppDelegate+AIActions.swift)

    /// Runs a Selection Action slot; created in `installAIActions()`.
    var selectionActionRunner: SelectionActionRunner?
    /// The run in flight (one at a time, like the runner; cancelled only when
    /// a dictation job starts or the app quits) and the HUD dismissal timer.
    var selectionActionRunTask: Task<Void, Never>?
    var selectionActionDismissTask: Task<Void, Never>?

    // MARK: Observed state

    var monitoredJobID: JobID?
    /// The job whose ⌘1–⌘0 / ⌘⇧A observers are installed (ADR-021,
    /// `AppDelegate+RecorderControls.swift`); nil outside `.recording`.
    var aiControlMonitoredJobID: JobID?
    var latestState: DictationState = .idle
    var latestModelState: ModelLifecycleState = .absent
    var modelReady = false
    var terminationInProgress = false
    /// Set at the end of `finishLaunching()`. While a relaunched instance is
    /// still waiting out the old one (`performInstanceHandoff`), AppKit can
    /// already deliver `applicationDidBecomeActive` (the restart launches
    /// with `activates = true`) and `applicationShouldHandleReopen`; both
    /// refresh the model library, which must not happen before
    /// `loadSettingsAndRegisterShortcut()` has restored the persisted model
    /// reference (see `finishLaunching`). They return early until then.
    var launchCompleted = false
    /// Microphone and Accessibility state for the Status menu item, refreshed
    /// at most once per second (FR-PERM-005) so the 60 ms poll stays cheap.
    var permissionSnapshot = PermissionSnapshot()
    /// The last controller snapshot and the last HUD state rendered from it,
    /// so a re-render can be skipped when nothing the HUD shows has changed.
    var latestSnapshot: DictationController.Snapshot?
    var lastRenderedHUDState: HUDViewState?
    /// ADR-022 item 7: the `overlappingJobs` row last pushed to the
    /// controller, so a re-resolve that did not change it costs nothing.
    var lastPushedOverlappingJobs: Resolved<Bool>?
    /// The push in flight, so the next one is chained after it.
    var overlappingJobsPushTask: Task<Void, Never>?
    /// FR-HIST-008: the history store fell back to a degraded state; dictation
    /// continues and the menu says history is unavailable.
    var historyDegraded = false
    /// C.6 busy pulse: a shortcut press during processing is ignored, and the
    /// HUD shows "Finishing previous dictation" for a moment.
    var lastBusyShortcutCount = 0
    var busyPulseUntil: ContinuousClock.Instant?
    /// The onboarding dictation test's job, so its result is routed to the
    /// in-app field rather than treated as a normal completion.
    var inAppTestJobID: JobID?

    // MARK: Runtime (Speech Models › Runtime card, `AppDelegate+Runtime.swift`)

    /// Core ML's placement plan for the resident model under its current
    /// compute units; recomputed when either changes.
    var runtimePlacement: ModelPlacementReport?
    var runtimePlacementTask: Task<Void, Never>?

    // MARK: Tasks

    private var observationTask: Task<Void, Never>?
    private var slowObservationTask: Task<Void, Never>?
    var busyPulseTask: Task<Void, Never>?
    /// Later waves: memory-pressure warnings — consumes
    /// `composition.memoryPressureObserver.changes()` for the app's life.
    var memoryPressureTask: Task<Void, Never>?
    var settingsLoadTask: Task<Void, Never>?
    var modelTask: Task<Void, Never>?
    /// ADR-022 item 5: consumes `SpeechModelLibrary.activityChanges()` for
    /// the app's life (`AppDelegate+Model.swift`).
    var modelActivityTask: Task<Void, Never>?
    var shortcutEventTask: Task<Void, Never>?
    var terminalDismissTask: Task<Void, Never>?

    struct PermissionSnapshot: Equatable {
        var microphone: PermissionAuthorization = .notDetermined
        var accessibilityTrusted = false
    }

    override init() {
        super.init()
        aiSettingsViewModel = AISettingsViewModel(
            host: makeSettingsProjectionHost(),
            loadedSecrets: SecretSettings(),
            configurationTester: { [weak self] settings, credentials in
                guard let self else { throw KVoiceError(code: .appCancelled) }
                // ADR-024: routed by transport, so an on-device
                // configuration is tested on the on-device client.
                try await self.composition.aiProcessingClient.testConfiguration(
                    settings,
                    credentials: credentials
                )
            },
            modelLister: { [weak self] settings, credentials in
                guard let self else { throw KVoiceError(code: .appCancelled) }
                return try await self.composition.aiClient.availableModels(
                    settings,
                    credentials: credentials
                )
            }
        )
        promptModeSettingsViewModel = PromptModeSettingsViewModel(
            host: makeSettingsProjectionHost(),
            previewRunner: { [weak self] mode, sample in
                guard let self else { throw KVoiceError(code: .appCancelled) }
                return try await self.runPromptPreview(mode: mode, sample: sample)
            }
        )
        latestModelState = composition.modelTrustFailure
            .map { ModelLifecycleState.error($0) } ?? .absent
        composition.onboardingIntentRouter.handler = { [weak self] intent in
            self?.handleOnboardingIntent(intent)
        }
        // ADR-022 slice 7: the wizard writes its settings (trigger mode,
        // shortcut, completion) through the same door as every page.
        composition.onboardingViewModel.settings = makeSettingsProjectionHost()
        // The KeyboardShortcuts recorder serves two doors. While the setup
        // window is up the wizard owns the recording (`setShortcut` sends
        // with origin `.wizard` and shows the step's feedback); otherwise
        // the recorder is the Shortcuts page's "Choose Shortcut…" and sends
        // with origin `.hotkeyRecorder` directly. Either way the wizard's
        // own view of the shortcut follows through
        // `setShortcutRegistrationState`, which `registerShortcut(from:)`
        // reports after every registration.
        composition.shortcutAdapter.onShortcutRecorded = { [weak self] shortcut in
            guard let self, !self.terminationInProgress else { return }
            if self.onboardingWindow?.isVisible == true {
                _ = self.composition.onboardingViewModel.setShortcut(shortcut)
            } else if shortcut.isStructurallyValid {
                self.sendSettingsIntent(.setShortcut(shortcut, origin: .hotkeyRecorder))
            }
        }
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // ADR-022 slice 5: the override file's fate, and (2026-09-27) the
        // legacy defaults copy — one line each, now that the sinks exist
        // (both ran in `AppComposition`).
        composition.logLaunchOutcomes()
        // 2026-09-16: after Help › Restart / "Relaunch Now" the old instance
        // is still quitting when this one launches. Wait it out (bounded)
        // before taking the status item and the global hotkey, or the user
        // sees two KVoice instances. A launch with no other instance runs
        // `finishLaunching` synchronously, as before.
        performInstanceHandoff { [weak self] in
            self?.finishLaunching()
        }
    }

    /// Everything in `applicationDidFinishLaunching` that must wait for a
    /// previous instance to exit (`AppDelegate+Lifecycle.swift`).
    private func finishLaunching() {
        guard !terminationInProgress else { return }
        installEnvironmentIdentity()
        installStatusItem()
        startStateObservation()
        observeSleepForShortcutWatchdog()
        installSettingsSurfaceHooks()
        installAIActions()
        installTriggers()
        installHistoryHooks()
        installRuntimeHooks()
        installModelActivityObservation()
        installMemoryPressureObservation()
        installAppIntents()
        // The settings load restores the persisted model reference (managed
        // or external) once settings are known; a plain refresh here would
        // race it and could not restore an external package at all.
        loadSettingsAndRegisterShortcut()
        launchCompleted = true
    }

    /// FR-HOTKEY-007: display or system sleep can swallow the shortcut key-up,
    /// so the watchdog synthesizes one and the recording stops instead of
    /// running until the hard cap.
    private func observeSleepForShortcutWatchdog() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.composition.shortcutAdapter.displayWillSleep()
                }
            }
        }
    }

    func applicationDidResignActive(_: Notification) {
        // P-D4: the panel's window is key while it is open, so closing it
        // resigns "active" too. That is not an input-delivery boundary —
        // the hotkey is global and its key-up still arrives — so the hold
        // watchdog must not force-stop a held push-to-talk recording for it.
        if statusPanelController?.ownsDeactivation == true { return }
        composition.shortcutAdapter.applicationDidResignActive()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateNow }
        terminationInProgress = true

        observationTask?.cancel()
        slowObservationTask?.cancel()
        busyPulseTask?.cancel()
        memoryPressureTask?.cancel()
        settingsLoadTask?.cancel()
        modelTask?.cancel()
        modelActivityTask?.cancel()
        shortcutEventTask?.cancel()
        terminalDismissTask?.cancel()
        selectionActionRunTask?.cancel()
        selectionActionDismissTask?.cancel()
        SelectionActionShortcuts.uninstall()
        composition.shortcutAdapter.applicationWillTerminate()
        composition.shortcutAdapter.unregister()
        composition.shortcutAdapter.endRecordingAIControlMonitoring()
        composition.hudController.dismiss()
        onboardingHotkeyTestHook = nil

        // NSApplication waits for this reply. This gives the controller a
        // chance to cancel capture/transcription and suppress late callbacks
        // before process teardown, without blocking the main actor.
        //
        // 2026-09-16: bounded. These awaits used to be open-ended, and a
        // step that stalled (a model install in flight, an engine unload)
        // left the process alive with its hotkey after Help › Restart had
        // already launched the replacement. `TerminationHandshake` races
        // them against a deadline and the reply is sent either way; the
        // `app.terminate.*` line says which step stalled. The step names
        // are the `site` tokens the log carries.
        let dictationController = composition.dictationController
        let modelManager = composition.modelManager
        let transcriptionEngine = composition.transcriptionEngine
        let diagnostics = composition.diagnostics
        Task {
            let outcome = await TerminationHandshake().run([
                .init("dictationController") { await dictationController.terminate() },
                .init("modelInstallation") { await modelManager?.cancelInstallation() },
                .init("transcriptionEngine") { await transcriptionEngine.unload() },
            ])
            // The log line is awaited (a detached task would die with the
            // process) but under its own ~500 ms deadline: a stuck logger
            // must not be what withholds the reply.
            let event = Self.terminationEvent(outcome)
            _ = await TerminationHandshake(deadline: .milliseconds(500)).run([
                .init("diagnostics") { await diagnostics.log(event) },
            ])
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        // Covers system shutdown/force-close paths where AppKit does not offer
        // the asynchronous terminate-later handshake.
        observationTask?.cancel()
        slowObservationTask?.cancel()
        memoryPressureTask?.cancel()
        modelTask?.cancel()
        modelActivityTask?.cancel()
        shortcutEventTask?.cancel()
        composition.shortcutAdapter.applicationWillTerminate()
        composition.shortcutAdapter.unregister()
        onboardingHotkeyTestHook = nil
    }

    func applicationDidBecomeActive(_: Notification) {
        // Not before `finishLaunching()`: the instance handoff may still be
        // waiting, and nothing below may run ahead of the settings load.
        guard launchCompleted else { return }
        // P-D4: the panel's `makeKey()` reports the app active without a
        // window activation; none of the below is for it.
        if statusPanelController?.isShown == true { return }
        // Re-apply the current policy after Settings/About activation. The
        // menu-bar app remains accessory unless the user explicitly enables a
        // Dock icon in General settings.
        applyActivationPolicy()
        Task { [weak self] in
            guard let self, !self.terminationInProgress else { return }
            await self.composition.onboardingViewModel.appDidBecomeActive()
            // ADR-024: the user may just have turned Apple Intelligence on
            // in System Settings; re-read it before the next slow poll.
            await self.refreshAppleIntelligenceAvailability()
            await self.refreshPrivateCloudComputeFacts(trigger: .activation)
            await self.refreshModelInBackgroundAndWait()
        }
    }

    /// ADR-024: the observed on-device availability, into the environment
    /// profile and the availability table. Unconditional on activation (the
    /// Add Configuration sheet shows the fact before any configuration
    /// exists); the slow poll refreshes it only while an on-device
    /// configuration is saved.
    func refreshAppleIntelligenceAvailability() async {
        let availability = await composition.appleIntelligenceClient.availability()
        guard !terminationInProgress, environmentProfile.appleIntelligenceAvailability != availability else { return }
        environmentProfile.appleIntelligenceAvailability = availability
        settingsCoordinator.observe(environment: environmentProfile)
        refreshSettingsAvailability()
        updateMenu(for: latestState)
    }

    /// ADR-027: the Private Cloud Compute availability and quota facts, into
    /// the environment profile, the availability table and the page model.
    /// Called on activation, on every slow poll (so a closed gate — AI off,
    /// the last configuration deleted — clears stale facts) and after every
    /// Private Cloud Compute request or connection test (the router's
    /// observer, `installPrivateCloudComputeObserver()`).
    /// `PrivateCloudComputeQueryPolicy` decides whether the framework is
    /// asked at all: only while AI is on and such a configuration is saved,
    /// the slow poll only while it is the active engine and never for the
    /// quota. The static refusal (edition, signature) is read from the
    /// client without touching the framework.
    func refreshPrivateCloudComputeFacts(trigger: PrivateCloudComputeQueryPolicy.Trigger) async {
        let client = composition.privateCloudComputeClient
        let availability: AIProviderAvailability?
        let quota: AIProviderQuota?
        switch PrivateCloudComputeQueryPolicy.decide(
            trigger: trigger,
            staticRefusal: client.staticRefusal,
            settings: currentSettings.ai
        ) {
        case .staticRefusal(let reason):
            availability = .unavailable(reason)
            quota = nil
        case .clear:
            availability = nil
            quota = nil
        case .keep:
            return
        case .read(let includeQuota):
            availability = await client.availability()
            quota = includeQuota ? await client.quota() : environmentProfile.privateCloudComputeQuota
        }
        guard !terminationInProgress else { return }
        settingsAvailability.update(privateCloudComputeStaticRefusal: client.staticRefusal)
        settingsAvailability.update(privateCloudComputeQuota: quota)
        guard environmentProfile.privateCloudComputeAvailability != availability
            || environmentProfile.privateCloudComputeQuota != quota
        else { return }
        environmentProfile.privateCloudComputeAvailability = availability
        environmentProfile.privateCloudComputeQuota = quota
        settingsCoordinator.observe(environment: environmentProfile)
        refreshSettingsAvailability()
        updateMenu(for: latestState)
    }

    // MARK: State observation

    /// Two observation paths with different tempos:
    ///
    /// - The dictation controller publishes a `Snapshot` on every change, so
    ///   the HUD and menu follow it immediately with no polling. Recording
    ///   level is already coalesced to 20 Hz inside the controller (D.5).
    /// - Model lifecycle, permissions, and history health change rarely and
    ///   on their own clocks, so they are sampled once a second (FR-PERM-005),
    ///   plus the 250 ms poll that `withModelStatePolling` runs during a model
    ///   operation.
    private func startStateObservation() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await self.composition.dictationController.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled, !self.terminationInProgress else { return }
                self.applyDictationSnapshot(snapshot)
            }
        }
        slowObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSlowState()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    /// Projects one controller snapshot onto the menu and the HUD.
    private func applyDictationSnapshot(_ snapshot: DictationController.Snapshot) {
        guard !terminationInProgress else { return }
        let state = snapshot.state
        let previousKind = latestState.kind
        let previousSnapshot = latestSnapshot
        latestState = state
        latestSnapshot = snapshot
        // Drives the Ready screen's Stop Recording control, so it tracks the
        // real recorder whether the test or the global shortcut started it.
        composition.onboardingViewModel.setDictationTestRecording(state.kind == .recording)
        deliverInAppTestResultIfNeeded(state: state, delivered: snapshot.inAppDeliveredText)
        // Only a lifecycle change needs the submenus rebuilt. The level and
        // elapsed time the P-D3 header row shows reach it through the HUD's
        // rendered state (`installStatusMenuHeaderFeed`), not through here.
        if state.kind != previousKind {
            updateMenu(for: state)
            syncSelectionActionShortcuts(for: state)
            refreshSettingsAvailability()
            // P-D4: the panel's window is key while it is open. Insertion
            // posts to the PID captured at job start, so nothing can type
            // into the popover; the hazard is the target's
            // `AXFocusedUIElement` failing to resolve while our window is
            // key, which sends the typed tier to a PID with no key window
            // — dropped text. So the panel leaves, without animation, on
            // the edge that ends a recording — whether its own Stop row or
            // the hotkey ended it — before the finishing phases resolve.
            if previousKind == .recording {
                statusPanelController?.closeImmediately()
            }
        } else if snapshot.canRecoverFailedInsertion != previousSnapshot?.canRecoverFailedInsertion
                    || snapshot.overlapPausedReason != previousSnapshot?.overlapPausedReason {
            // ADR-022 item 7: a failed job kept behind a recording, or the
            // overlap note, change what the menu offers without a
            // lifecycle edge of the shown state.
            updateMenu(for: state)
        }

        if snapshot.busyShortcutCount != lastBusyShortcutCount {
            lastBusyShortcutCount = snapshot.busyShortcutCount
            busyPulseUntil = ContinuousClock.now + .milliseconds(1_200)
            // Re-render once the pulse expires, since no snapshot will arrive
            // just for that.
            busyPulseTask?.cancel()
            busyPulseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1_250))
                guard let self, !Task.isCancelled, let latest = self.latestSnapshot else { return }
                self.renderHUD(for: latest)
            }
        }
        renderHUD(for: snapshot)
        syncEscapeMonitoring(for: state)
        syncRecordingAIControlMonitoring(for: state)
    }

    private func renderHUD(for snapshot: DictationController.Snapshot) {
        let state = snapshot.state
        let busyHint = busyPulseUntil.map { $0 > ContinuousClock.now } ?? false
        let settings = snapshot.activeSettings ?? currentSettings
        let hudState = HUDViewState(
            dictationState: state,
            inputLevel: snapshot.inputLevel,
            recordingMode: settings.recordingInteraction,
            translationTarget: settings.ai.translationLanguage,
            partialTranscript: snapshot.partialTranscript,
            recoverableTranscript: snapshot.recoverableTranscript,
            busyHint: busyHint,
            maximumRecordingDuration: Self.hudRecordingLimit(for: settings),
            aiIndicator: hudAIIndicator(for: snapshot, settings: settings),
            canRecoverFailedInsertion: snapshot.canRecoverFailedInsertion,
            captureStarted: snapshot.captureStarted,
            finishingCount: snapshot.finishingCount,
            overlapPausedReason: snapshot.overlapPausedReason
        )
        // The onboarding test shows its result in-app; the floating HUD
        // would otherwise announce "Inserted" over the setup window.
        if case .completed(let jobID, _) = state, jobID == inAppTestJobID {
            composition.hudController.dismiss()
        } else if hudState != lastRenderedHUDState {
            // ADR-021: the style comes from the job's snapshot, so a Settings
            // change mid-dictation applies from the next one.
            composition.hudController.show(hudState, style: settings.recorderStyle)
        }
        lastRenderedHUDState = hudState
        scheduleTerminalDismissal(for: state, hudState: hudState)
    }

    /// The 5:00 warning names the job's limit; "No limit" drops the clock
    /// because the four-hour bound is a memory guard, not a feature.
    static func hudRecordingLimit(for settings: AppSettings) -> Duration? {
        let limit = RecordingDurationLimit(seconds: settings.maxRecordingSeconds)
        return limit.isUnlimited ? nil : .seconds(settings.maxRecordingSeconds)
    }

    /// The slow path: model lifecycle, permission state, and history health.
    private func refreshSlowState() async {
        // ADR-027: every tick, so a closed gate clears stale facts; the
        // policy asks the framework only while the engine is the active one,
        // and never for the quota here.
        await refreshPrivateCloudComputeFacts(trigger: .slowPoll)
        let loadedModelID = await composition.transcriptionEngine.loadedModelID
        let modelState = await composition.modelManager?.state
        let microphone = await composition.microphonePermission.authorization()
        let trusted = await composition.accessibilityPermission.isTrusted(prompt: false)
        let degraded = await composition.historyStore.isDegraded
        let promptLimit = await composition.transcriptionEngine.promptTokenLimit
        let statistics = await composition.residentEngine.runtimeStatistics
        let computeUnits = await composition.residentEngine.currentComputeUnits
        // ADR-024: the one place the fact is kept fresh while the app is in
        // the background — but only when a configuration can use it, so a
        // Mac with no on-device configuration never touches the framework
        // once a second. `nil` here means "keep what was last observed".
        let hasOnDeviceConfiguration = currentSettings.ai.configurations.contains {
            $0.kind.transport == .appleIntelligence
        }
        let appleIntelligenceAvailability: AIProviderAvailability? = hasOnDeviceConfiguration
            ? await composition.appleIntelligenceClient.availability()
            : nil

        guard !terminationInProgress else { return }
        let previous = (modelReady, latestModelState, permissionSnapshot, historyDegraded)
        // The environment profile (ADR-022 slice 5): every observed fact in
        // one value, from the sources this poll already reads.
        environmentProfile.enginePromptTokenLimit = promptLimit
        environmentProfile.catalogPromptTokenLimit = catalogPromptTokenLimit(for: currentSettings)
        environmentProfile.residentModelID = loadedModelID
        environmentProfile.runtime = loadedModelID.flatMap { composition.modelManager?.catalog.entry(id: $0)?.runtime }
        environmentProfile.computeUnits = computeUnits
        environmentProfile.lastRealTimeFactor = statistics.lastRealTimeFactor
        environmentProfile.lastLoadDuration = statistics.lastLoadDuration
        environmentProfile.placement = runtimePlacement
        environmentProfile.accessibilityTrusted = trusted
        environmentProfile.memoryPressureLevel = memoryPressureViewModel.level
        environmentProfile.residentFootprintBytes = composition.runtimeTelemetry.memoryFootprintBytes()
        environmentProfile.gpuCounterReadable = composition.runtimeTelemetry.gpuUtilisation() != nil
        environmentProfile.hasNotch = HUDController.geometry(of: nil).notch != nil
        if let appleIntelligenceAvailability {
            environmentProfile.appleIntelligenceAvailability = appleIntelligenceAvailability
        }
        // Published through the coordinator so the resolver's effective
        // table (the pages' provenance) follows the observed facts.
        settingsCoordinator.observe(environment: environmentProfile)
        if let modelState {
            latestModelState = modelState
            composition.onboardingViewModel.setModelState(modelState)
        }
        modelReady = loadedModelID != nil && Self.isUsableModelState(latestModelState)
        permissionSnapshot = PermissionSnapshot(microphone: microphone, accessibilityTrusted: trusted)
        historyDegraded = degraded
        if previous != (modelReady, latestModelState, permissionSnapshot, historyDegraded) {
            updateMenu(for: latestState)
        }
        // The model flags and the file transcription have no change hook of
        // their own; the one-second poll is what keeps the projection true.
        refreshSettingsAvailability()
        // ADR-025: a no-op unless the language changed under the library
        // (an import, a reset); the intent path already told it.
        if settingsLoaded {
            propagateTranscriptionLanguage(currentSettings)
        }
    }

    /// A model is only usable for dictation once it is resident, which is a
    /// narrower condition than "no error".
    static func isUsableModelState(_ state: ModelLifecycleState) -> Bool {
        switch state {
        case .ready(_), .inference(_, jobID: _):
            return true
        default:
            return false
        }
    }
}
