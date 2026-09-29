import AppKit
import AVFoundation
import KvoiceAppCore
import KvoiceAudio
import KvoiceDomain
import KvoiceInsertion
import KvoiceModelManagement
import KvoiceTranscription
import KvoiceUI

/// Glue between the app shell and the main-window sections / onboarding
/// screens that need more than `generalSettingsViewModel`.
///
/// `AppDelegate` cannot grow stored properties from an extension, so the
/// view models for the Permissions, Audio Input, Models, Data & Privacy, and
/// Help sections live in `SettingsSurface`, which `MainWindowController`
/// owns for the life of the window. Everything here reads the app delegate's existing state
/// (`currentSettings`, `latestModelState`, `latestState`, `composition.*`) and
/// calls its existing operations; it does not change how those are computed.
///
/// Integration hooks the app shell does not yet provide are marked `TODO`
/// and default to no-ops. The integrator wires them:
///
/// - `SettingsSurface.onForgetExternalModel` — `modelManager.forgetExternalPackage()`
///   exists but model orchestration lives in `AppDelegate+Model.swift`.
/// - `SettingsSurface.modelSpaceEstimate` — required/available bytes for the
///   download preflight (manifest byte sum + `workingSpaceBytes`, and
///   `volumeAvailableCapacityForImportantUsage` of the storage volume).
/// - `SettingsSurface.historyMetrics` — entry count and file size of the
///   history store.
/// - The General, Trigger, Audio Input, Dictionary, Data & Privacy and
///   memory view models are projections over `SettingsCoordinator` (ADR-022
///   slice 7, `SettingsProjectionHost`): they read the committed settings
///   and send their own intents, so nothing here hydrates or routes them.
/// - `OnboardingViewModel.setDictationTestResult(_:)` should be called from
///   the dictation observation path when a test job reaches a terminal state.
@MainActor
final class SettingsSurface {
    let permissionStatusViewModel: PermissionStatusViewModel
    let microphoneTestViewModel: MicrophoneTestViewModel
    let modelSettingsViewModel: ModelSettingsViewModel
    let privacyAboutViewModel: PrivacyAboutViewModel
    /// Data & Privacy retention, stored audio, and Auto Daily Export: a
    /// projection over the coordinator (slice 7).
    let dataPrivacyViewModel: DataPrivacyViewModel
    let helpViewModel: HelpViewModel
    /// Dictation › Dictionary (ADR-018). Counts against the resident engine's
    /// tokenizer; a projection over the coordinator (slice 7) that sends
    /// `.setDictionary` itself.
    let dictionaryViewModel: DictionaryViewModel
    /// Settings › General › Backup (export/import/restore). File I/O runs
    /// directly against `~/Library/Application Support/kvoice/Backups`;
    /// only the panels and the shell's idle-gated apply are hooks.
    let backupSettingsViewModel: BackupSettingsViewModel

    // MARK: Integration hooks (TODO: integrator)
    //
    // Static so they can be assigned once at launch and reach both the
    // Settings window (created on demand) and the onboarding window.

    /// TODO(integrator): route to `composition.modelManager?.forgetExternalPackage()`
    /// through the model orchestration in `AppDelegate+Model.swift`, then
    /// republish state. Default: no-op; the Forget button confirms and does
    /// nothing.
    static var onForgetExternalModel: @MainActor () -> Void = {}

    /// TODO(integrator): return the download requirement and the free space
    /// on the managed storage volume. Default: nil, which renders nothing in
    /// the Model tab and on the onboarding model step.
    static var modelSpaceEstimate: @MainActor () async -> (requiredBytes: Int64, availableBytes: Int64?)? = { nil }

    /// TODO(integrator): return the history entry count and file size.
    /// Default: nil, which hides the row in Privacy & About.
    static var historyMetrics: @MainActor () async -> HistoryMetrics? = { nil }

    /// Bindings for the Settings › Recording controls (sound feedback, mute
    /// system audio, keep transcript on clipboard, maximum length) and the
    /// Settings › Shortcuts trigger controls (Cancel shortcut,
    /// auto-send, middle mouse). Filled by `AppDelegate.installTriggers()`
    /// from `TriggerSettingsViewModel`; the defaults render the controls
    /// disabled with a note.
    static var recordingOptionBindings: @MainActor () -> RecordingOptionBindings = { RecordingOptionBindings() }
    static var triggerOptionBindings: @MainActor () -> TriggerOptionBindings = { TriggerOptionBindings() }

    var recordingOptionBindings: RecordingOptionBindings {
        Self.recordingOptionBindings()
    }

    var triggerOptionBindings: TriggerOptionBindings {
        Self.triggerOptionBindings()
    }

    private weak var appDelegate: AppDelegate?
    private var lastDescriptorStateKey: String?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let composition = appDelegate.composition

        permissionStatusViewModel = PermissionStatusViewModel(
            microphonePermission: SystemMicrophonePermissionProvider(),
            // ADR-026: the edition's adapter (Accessibility or PostEvent).
            accessibilityPermission: composition.accessibilityPermission,
            edition: composition.edition,
            openSystemSettings: { kind in
                Self.openSystemSettings(for: kind)
            }
        )

        microphoneTestViewModel = MicrophoneTestViewModel(
            audioCapture: composition.audioRecorder,
            inputDeviceNameProvider: { Self.defaultInputDeviceName() }
        )

        let manifest = Self.bundledManifest()
        let modelHost = KvoiceManagedModel.defaultDownloadHost.host() ?? "huggingface.co"

        // `self` is not available to these closures until after init, so
        // they reach the surface through the app delegate's window.
        modelSettingsViewModel = ModelSettingsViewModel(
            state: appDelegate.latestModelState,
            descriptor: manifest.map { Self.descriptor(from: $0, package: nil) },
            onAction: { [weak appDelegate] action in
                appDelegate?.settingsSurface?.performModelAction(action)
            },
            modelSpaceEstimate: {
                guard let estimate = await Self.modelSpaceEstimate() else { return nil }
                return ModelSpaceEstimate(
                    requiredBytes: estimate.requiredBytes,
                    availableBytes: estimate.availableBytes
                )
            },
            // ADR-022 slice 7 part B: the language, per-model mode, and VAD
            // rows are a projection; everything else here still comes
            // through `SpeechModelsHooks`.
            speechModels: SpeechModelsViewModel(host: appDelegate.makeSettingsProjectionHost()),
            // The Runtime card reads the process's memory and CPU and the
            // GPU counter through the one Mach/IOKit adapter; its hooks are
            // filled by `installRuntimeHooks()`.
            runtime: RuntimeCardViewModel(
                telemetry: composition.runtimeTelemetry,
                expectations: composition.developerDefaults.values.runtimeExpectations
            ),
            // Later waves: memory-pressure warnings. The app-lifetime
            // instance (`AppDelegate.memoryPressureViewModel`), so the
            // banner always agrees with the status menu.
            memoryPressure: appDelegate.memoryPressureViewModel
        )

        // The General view model is built in `AppDelegate.swift` with the
        // service-free defaults; give it the real launchd adapter and the
        // reset route now that the shell is fully constructed.
        appDelegate.generalSettingsViewModel.launchAtLoginService = SystemLaunchAtLoginService()
        appDelegate.generalSettingsViewModel.onResetOnboarding = { [weak appDelegate] in
            appDelegate?.resetOnboarding()
        }
        // "Relaunch Now" after an interface-language change reuses Restart.
        appDelegate.generalSettingsViewModel.onRestartApp = { [weak appDelegate] in
            appDelegate?.restartApp()
        }

        privacyAboutViewModel = PrivacyAboutViewModel(
            dataFolderURL: ModelPackageManager.defaultStorageDirectoryURL(),
            modelRepositoryHost: manifest.map { "\(modelHost) (\($0.source.repository))" } ?? modelHost,
            modelManifestDescription: manifest.map {
                "schema \($0.schemaVersion) · \($0.modelID) @ \(String($0.source.revision.prefix(12)))"
            },
            licensesProvider: { Self.thirdPartyNotices() },
            diagnosticsProvider: { [weak appDelegate] in
                appDelegate?.diagnosticsSnapshot()
            },
            historyMetrics: {
                await Self.historyMetrics()
            }
        )

        // The folder grant is local state (ADR-022 slice 5), never in the
        // settings blob; the host's local-state door carries it.
        dataPrivacyViewModel = DataPrivacyViewModel(host: appDelegate.makeSettingsProjectionHost())
        dataPrivacyViewModel.runCleanup = { [weak appDelegate] in
            await appDelegate?.runHistoryCleanupNow()
        }
        dataPrivacyViewModel.metricsProvider = { [weak appDelegate] in
            await appDelegate?.historyStorageMetrics()
        }

        // The resident engine is the `PromptTokenCounting`; while no model
        // is loaded the default catalog entry's limit and the ≈ estimate
        // stand in (`DictionaryTokenBudget.resolve`).
        dictionaryViewModel = DictionaryViewModel(
            host: appDelegate.makeSettingsProjectionHost(),
            counter: composition.transcriptionEngine,
            catalogPromptTokenLimit: appDelegate.catalogPromptTokenLimit(for: appDelegate.currentSettings),
            reserveFraction: composition.developerDefaults.values.dictionaryReserveFraction
        )

        backupSettingsViewModel = BackupSettingsViewModel(
            host: appDelegate.makeSettingsProjectionHost(),
            automaticBackupRetentionCount: composition.developerDefaults.values.automaticBackupRetentionCount
        )
        backupSettingsViewModel.isIdle = { [weak appDelegate] in
            appDelegate?.latestState.kind == .idle
        }

        helpViewModel = HelpViewModel(
            actions: HelpActions(
                resetOnboarding: { [weak appDelegate] in appDelegate?.resetOnboarding() },
                resetPreferences: { [weak appDelegate] in appDelegate?.resetPreferences() },
                restartApp: { [weak appDelegate] in appDelegate?.restartApp() },
                showTutorial: { [weak appDelegate] in appDelegate?.showTutorial() }
            ),
            diagnosticsProvider: { [weak appDelegate] in
                appDelegate?.diagnosticsSnapshot()
            }
        )
    }

    // MARK: Model tab

    /// Keeps the Model tab in step with the shell's published state while the
    /// Settings window is on screen. Run from the root view's `.task`.
    func syncWhileVisible() async {
        while !Task.isCancelled {
            await syncOnce()
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    private func syncOnce() async {
        guard let appDelegate else { return }
        let state = appDelegate.latestModelState
        modelSettingsViewModel.setState(state)
        modelSettingsViewModel.setDictationActive(appDelegate.latestState.kind != .idle)

        // The descriptor only changes when the package does, so rebuild it
        // on state-class transitions rather than every tick.
        let key = Self.descriptorKey(for: state)
        if key != lastDescriptorStateKey {
            lastDescriptorStateKey = key
            let descriptor = await currentModelDescriptor()
            guard !Task.isCancelled else { return }
            modelSettingsViewModel.setDescriptor(descriptor)
        }
    }

    private func performModelAction(_ action: ModelSettingsAction) {
        guard let appDelegate, !appDelegate.terminationInProgress else { return }
        switch action {
        case .download:
            appDelegate.downloadModel()
        case .resume, .retry:
            // `retryInstallation()` resumes a pending download when one
            // exists and otherwise starts afresh.
            appDelegate.retryModel()
        case .cancel:
            appDelegate.cancelModelDownload()
        case .chooseExisting:
            appDelegate.chooseExistingModel()
        case .revealInFinder:
            guard let location = modelSettingsViewModel.descriptor?.source.location,
                  modelSettingsViewModel.descriptor?.source.isManaged == true else { return }
            NSWorkspace.shared.activateFileViewerSelecting([location])
        case .delete:
            appDelegate.deleteModel()
        case .forget:
            Self.onForgetExternalModel()
        }
    }

    private func currentModelDescriptor() async -> ModelDescriptor? {
        let manifest = Self.bundledManifest()
        if let manager = appDelegate?.composition.modelManager,
           let package = try? await manager.verifiedPackage() {
            return Self.descriptor(from: package.manifest, package: package)
        }
        return manifest.map { Self.descriptor(from: $0, package: nil) }
    }

    private static func descriptor(from manifest: ModelManifest, package: InstalledModelPackage?) -> ModelDescriptor {
        let source: ModelSourceDescription
        if let package {
            switch package.ownership {
            case .managedByKvoice: source = .managed(package.packageURL)
            case .externalReadOnly: source = .external(package.packageURL)
            case .systemManaged: source = .systemManaged
            }
        } else {
            source = .notInstalled(expectedLocation: ModelPackageManager.defaultStorageDirectoryURL())
        }
        return ModelDescriptor(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            source: source,
            // A system-managed package has no files on kvoice's disk.
            installedBytes: package == nil || package?.ownership == .systemManaged ? nil : manifest.files.reduce(0) { $0 + $1.bytes },
            repository: manifest.source.repository,
            manifestSchemaVersion: manifest.schemaVersion
        )
    }

    private static func descriptorKey(for state: ModelLifecycleState) -> String {
        switch state {
        case .absent: return "absent"
        case .validatingExternal: return "validatingExternal"
        case .downloading: return "downloading"
        case .downloadPaused: return "downloadPaused"
        case .verifying: return "verifying"
        case .installing: return "installing"
        case .loading: return "loading"
        case .optimizing: return "optimizing"
        case .ready(let summary): return "ready:\(summary.ownership.rawValue)"
        case .inference(let summary, _): return "inference:\(summary.ownership.rawValue)"
        case .corrupt: return "corrupt"
        case .incompatible: return "incompatible"
        case .deleting: return "deleting"
        case .error: return "error"
        case .unavailable: return "unavailable"
        }
    }

    private static func bundledManifest() -> ModelManifest? {
        (try? BundledTrustedModelReleaseLoader().load())?.manifest
    }

    // MARK: System helpers

    static func openSystemSettings(for kind: PermissionKind) -> Bool {
        let url: URL?
        switch kind {
        case .microphone: url = SystemMicrophonePermissionProvider.microphoneSettingsURL
        case .accessibility: url = SystemAccessibilityPermissionAdapter.accessibilitySettingsURL
        }
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }

    nonisolated static func defaultInputDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// `THIRD_PARTY_NOTICES.md` is copied into the bundle by the Resources
    /// build phase. Nil when a build omits it; the view says so.
    private static func thirdPartyNotices() -> String? {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

extension AppDelegate {
    /// The surface owned by the main window, if it has been created.
    var settingsSurface: SettingsSurface? {
        mainWindow?.surface
    }

    // MARK: Dictionary (ADR-018)

    /// The default catalog entry's prompt limit — the Dictionary budget's
    /// source until a model is resident. Nil (no catalog, or an entry
    /// without a limit) reads as "no prompt" in the section.
    func catalogPromptTokenLimit(for settings: AppSettings) -> Int? {
        composition.modelManager?.catalog
            .defaultEntry(preferring: settings.defaultSpeechModelID)?
            .promptTokenLimit
    }

    /// Re-points the Dictionary budget at the current default model. Called
    /// after a settings load and as the `.refreshCatalogLimit` effect of
    /// every speech-model intent; the section's own poll picks up the new
    /// value on its next tick.
    func refreshDictionaryCatalogLimit() {
        settingsSurface?.dictionaryViewModel.catalogPromptTokenLimit = catalogPromptTokenLimit(for: currentSettings)
    }

    /// Called by `OnboardingWindowController` when it is created, since
    /// `showSetup()` in `AppDelegate+Onboarding.swift` constructs the window
    /// without these hooks.
    func installOnboardingSurfaceHooks() {
        let viewModel = composition.onboardingViewModel
        viewModel.openSystemSettingsHandler = { kind in
            SettingsSurface.openSystemSettings(for: kind)
        }
        // The microphone prompt and the Accessibility prompt both take
        // activation with them and leave the setup window behind other
        // windows; bring it back once the request returns.
        viewModel.permissionRequestDidReturn = { [weak self] _ in
            guard let self, !self.terminationInProgress else { return }
            self.onboardingWindow?.restoreFocus()
        }
        // Ready's two optional links (P-W1, 2026-09-16): "Set up AI Actions"
        // opens the main window on that section; "Take the Quick Tour" is
        // Help › Quick Tour's `showTutorial()`, the same window and the same
        // `tutorialSeen` bookkeeping. The wizard stays open behind either.
        viewModel.openMainWindowHandler = { [weak self] section in
            self?.openMainWindow(section: section)
        }
        viewModel.openTutorialHandler = { [weak self] in
            self?.showTutorial()
        }
        viewModel.microphoneTest.refreshInputDevice()
        // Best-effort: the estimate hook defaults to nil until the integrator
        // wires it, in which case the model step shows nothing.
        Task { [weak self] in
            guard let self, !self.terminationInProgress,
                  let estimate = await SettingsSurface.modelSpaceEstimate() else { return }
            self.composition.onboardingViewModel.setModelSpaceEstimate(
                requiredBytes: estimate.requiredBytes,
                availableBytes: estimate.availableBytes
            )
        }
    }

    /// The redacted facts Copy Diagnostics is allowed to see (FR-DIAG-005).
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsSnapshot(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            activationPolicy: NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            modelState: latestModelState,
            shortcut: currentSettings.shortcut,
            shortcutRegistration: composition.shortcutAdapter.registrationState,
            recordingInteraction: currentSettings.recordingInteraction,
            aiMode: currentSettings.ai.mode,
            aiEndpoint: currentSettings.ai.baseURL,
            aiProvider: currentSettings.ai.provider,
            appleIntelligenceAvailability: environmentProfile.appleIntelligenceAvailability,
            privateCloudComputeAvailability: environmentProfile.privateCloudComputeAvailability,
            historyEnabled: currentSettings.historyEnabled,
            escapeMonitorStatus: composition.shortcutAdapter.escapeMonitoringStatus.rawValue,
            typedInsertionEnabled: currentSettings.typedInsertionEnabled,
            launchAtLoginStatus: generalSettingsViewModel.launchAtLoginStatus
        )
    }
}
