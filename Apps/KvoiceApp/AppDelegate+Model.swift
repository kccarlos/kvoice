import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceModelManagement
import KvoiceUI

/// Model lifecycle: refresh, download, external selection, retry, deletion, and
/// republishing state to the UI.
///
/// Every operation follows the same shape — refuse unless the controller is
/// idle, replace any in-flight `modelTask` (`runModelTask`), then run inside
/// `withModelStatePolling` so the UI keeps moving during a multi-minute
/// operation. Failures are deliberately swallowed here: the model manager
/// retains a fail-closed lifecycle state, and the recovery action lives in the
/// Readiness settings surface.
///
/// ADR-022 item 5: every library call below is one `ModelActivity` under
/// the library's transition table. The shell keeps no flag of its own; the
/// gates read `modelActivity` (`AppDelegate+Runtime.swift`) and the pages
/// are refreshed from `installModelActivityObservation()`.
///
/// This still wants to be a dedicated coordinator rather than an extension on
/// the app delegate; see KNOWN_ISSUES.md.
extension AppDelegate {
    // MARK: Activity (ADR-022 item 5)

    /// Called once from `applicationDidFinishLaunching`. Recomputes the
    /// availability table and the status menu on every activity change, so
    /// a control disabled by a library operation (a download, a reload)
    /// says so without waiting for the slow poll.
    func installModelActivityObservation() {
        guard let library = composition.modelManager else { return }
        modelActivityTask?.cancel()
        modelActivityTask = Task { [weak self] in
            for await _ in await library.activityChanges() {
                guard let self, !Task.isCancelled, !self.terminationInProgress else { return }
                self.refreshSettingsAvailability()
                self.updateMenu(for: self.latestState)
            }
        }
    }

    /// One shell-driven library operation at a time. The previous task is
    /// cancelled *and awaited* before `body` runs: a cancel is asynchronous
    /// (the download unwinds at its next check), and until it has unwound
    /// its activity is still running — without the wait, the next
    /// operation would race it and be refused by the transition table. The
    /// observable behaviour is the old one: pressing Download on a second
    /// card pauses the first download and starts the second.
    private func runModelTask(_ body: @escaping @MainActor () async -> Void) {
        let previous = modelTask
        previous?.cancel()
        modelTask = Task { [weak self] in
            if let previous { await previous.value }
            guard self != nil, !Task.isCancelled else { return }
            await body()
        }
    }

    // MARK: Refresh

    func refreshModelInBackground() {
        installSpeechModelHooks()
        guard let modelManager = composition.modelManager else {
            publishTrustFailureOrAbsent()
            return
        }
        runModelTask { [weak self] in
            // A refusal (another activity is running) is logged by the
            // library; the managers would have skipped themselves anyway.
            await modelManager.refresh()
            guard let self, !Task.isCancelled else { return }
            await self.refreshModelState()
        }
    }

    func refreshModelInBackgroundAndWait() async {
        guard let modelManager = composition.modelManager else {
            publishTrustFailureOrAbsent()
            return
        }
        await modelManager.refresh()
        await refreshModelState()
    }

    /// Re-establishes the model selection persisted in settings (spec C.4
    /// step 6). Call once from the settings-load path after `currentSettings`
    /// is populated. An external reference is re-validated from its stored
    /// path and fails closed if the folder is missing, unmounted, or changed;
    /// a managed or empty reference is an ordinary refresh.
    /// ADR-025: the system-managed entry's state is per language, so the
    /// library (and the Apple Speech engine's warm-up locale) follow the
    /// transcription language: after a settings load, on every
    /// speech-model intent (`.refreshCatalogLimit`) and on the slow poll.
    /// Cheap and idempotent when nothing changed.
    func propagateTranscriptionLanguage(_ settings: AppSettings) {
        let code = settings.transcriptionLanguage
        let library = composition.modelManager
        let engine = composition.residentAppleSpeechEngine
        Task {
            await engine.setPreferredLanguageCode(code)
            await library?.setTranscriptionLanguage(code)
        }
    }

    func restoreSelectedModelFromSettings(_ settings: AppSettings) {
        installSpeechModelHooks()
        guard let modelManager = composition.modelManager else {
            publishTrustFailureOrAbsent()
            return
        }
        let reference = settings.selectedModel
        let preferredDefault = settings.defaultSpeechModelID
        let appleSpeechEngine = composition.residentAppleSpeechEngine
        runModelTask { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.withModelStatePolling {
                // ADR-025: the transcription language before the first
                // observation, so the system-managed entry reports the
                // right locale's assets from the start.
                await appleSpeechEngine.setPreferredLanguageCode(settings.transcriptionLanguage)
                await modelManager.setTranscriptionLanguage(settings.transcriptionLanguage)
                // The persisted compute units reach the engine before the
                // first load, so that load already uses them (nothing is
                // resident yet, so this stores the choice and reloads
                // nothing). A launch refresh that raced ahead is corrected
                // by the reload inside `setComputeUnits`.
                try? await modelManager.setComputeUnits(settings.speechComputeUnits)
                // ADR-017: the persisted default becomes the resident model
                // before anything is loaded, so the launch refresh loads it.
                if let preferredDefault {
                    _ = try? await modelManager.setDefaultModel(preferredDefault)
                }
                await modelManager.restoreSelectedModel(reference)
            }
            await MainActor.run { self.updateMenu(for: self.latestState) }
        }
    }

    // MARK: Selection persistence

    /// Writes the manager's current selection into settings so it survives
    /// relaunch. Managed installs persist `.managed`, external selections
    /// persist `.external` with a standardized absolute path, and delete or
    /// forget clear it. A no-op before settings have loaded, so the initial
    /// launch refresh cannot overwrite stored values with defaults.
    private func persistSelectedModel(from modelManager: SpeechModelLibrary) async {
        let reference = await modelManager.currentModelReference()
        sendSettingsIntent(.setSelectedModel(reference, origin: .shell))
    }

    /// Runs a model operation while republishing the model lifecycle to the UI.
    ///
    /// Download, external selection, retry, and delete can each run for
    /// minutes: verification hashes every artifact and the first CoreML load
    /// compiles the model for the Neural Engine. The model manager publishes
    /// intermediate states (`validatingExternal`, `verifying`, `loading`, …),
    /// but nothing observed them, so the onboarding step kept showing the
    /// pre-operation status for the whole operation and looked stalled or as
    /// though no model had been selected at all.
    private func withModelStatePolling(_ body: () async -> Void) async {
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await self?.refreshModelState()
            }
        }
        await body()
        poller.cancel()
        await refreshModelState()
    }

    private func refreshModelState() async {
        guard let modelManager = composition.modelManager else { return }
        let state = await modelManager.state
        let states = await modelManager.states()
        let defaultModelID = await modelManager.defaultModelID
        let defaultEntry = await modelManager.defaultEntry
        guard !terminationInProgress else { return }
        speechModelMenuCache.states = states
        speechModelMenuCache.defaultModelID = defaultModelID
        latestModelState = state
        // The wizard's model card names this entry (2026-09-16); the state
        // it shows was always the current model's.
        composition.onboardingViewModel.setModelEntry(defaultEntry)
        composition.onboardingViewModel.setModelState(state)
        modelReady = await composition.transcriptionEngine.loadedModelID != nil
            && Self.isUsableModelState(state)
        updateMenu(for: latestState)
    }

    /// Used on the refresh paths, where there may be no manager because the
    /// bundled trust material is missing — in which case that failure is the
    /// useful message — or simply no package yet.
    private func publishTrustFailureOrAbsent() {
        latestModelState = composition.modelTrustFailure
            .map { ModelLifecycleState.error($0) } ?? .absent
        composition.onboardingViewModel.setModelState(latestModelState)
    }

    /// Used on the operation paths, where a missing manager always means the
    /// app release has no trusted model manifest.
    private func reportTrustFailure() {
        guard let failure = composition.modelTrustFailure else { return }
        latestModelState = .error(failure)
        composition.onboardingViewModel.setModelState(latestModelState)
        updateMenu(for: latestState)
    }

    // MARK: Operations

    func downloadModel() {
        guard let modelManager = composition.modelManager else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await modelManager.installRecommendedModel()
                } catch {
                    // The manager retains a fail-closed lifecycle state. The
                    // settings view exposes the exact recovery action.
                }
                await self.persistSelectedModel(from: modelManager)
            }
        }
    }

    func chooseExistingModel() {
        guard composition.modelManager != nil else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose a verified KVoice model package", table: "Shell")
        panel.message = "Choose the package root containing ModelManifest.json, model/, and tokenizer/."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectExistingModel(at: url)
        }
    }

    private func selectExistingModel(at url: URL) {
        guard let modelManager = composition.modelManager,
              latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await modelManager.selectExternalPackage(at: url)
                } catch {
                    // Verification failures remain visible through the model
                    // lifecycle state and never activate the unverified package.
                }
                await self.persistSelectedModel(from: modelManager)
            }
        }
    }

    func cancelModelDownload() {
        guard let modelManager = composition.modelManager else {
            reportTrustFailure()
            return
        }
        Task { await modelManager.cancelInstallation() }
    }

    func retryModel() {
        guard let modelManager = composition.modelManager else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await modelManager.retryInstallation()
                } catch {
                    // State is intentionally retained for the next Retry.
                }
                await self.persistSelectedModel(from: modelManager)
            }
        }
    }

    func deleteModel() {
        guard let modelManager = composition.modelManager else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await modelManager.deleteManagedPackage()
                } catch {
                    // External packages are never deleted by this action.
                }
                await self.persistSelectedModel(from: modelManager)
            }
        }
    }

    /// Forget only clears the external reference (FR-MODEL-012); the user's
    /// files are never touched. Also the recovery action when a persisted
    /// external path is missing or has changed.
    func forgetExternalModel() {
        guard let modelManager = composition.modelManager else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await modelManager.forgetExternalPackage()
                } catch {
                    // A refused begin (another activity is running) is
                    // logged by the library; the reference stays until the
                    // next Forget.
                }
                await self.persistSelectedModel(from: modelManager)
            }
        }
    }

    // MARK: Readiness settings surface

    func currentModelStateForSettings() -> ModelLifecycleState {
        latestModelState
    }

    func startModelDownloadFromSettings() {
        downloadModel()
    }

    func chooseExistingModelFromSettings() {
        chooseExistingModel()
    }

    func retryModelFromSettings() {
        retryModel()
    }

    func deleteModelFromSettings() {
        deleteModel()
    }

    func forgetExternalModelFromSettings() {
        forgetExternalModel()
    }

    /// "About X, Y free" for the download surfaces. `nil` without trust
    /// material; `availableBytes` is `nil` when the volume cannot be queried.
    func modelInstallationSpaceEstimate() async -> ModelInstallationSpaceEstimate? {
        guard let modelManager = composition.modelManager else { return nil }
        return await modelManager.installationSpaceEstimate()
    }

    // MARK: - Speech models (ADR-017)

    /// Binds the Models section (`SpeechModelsHooks`) and the status menu's
    /// `Model ▸` and `Language ▸` submenus to the library. Assigning closures
    /// is idempotent, so this runs on every launch refresh and settings load.
    func installSpeechModelHooks() {
        SpeechModelsHooks.snapshot = { [weak self] in
            await self?.speechModelsSnapshot()
        }
        SpeechModelsHooks.perform = { [weak self] action in
            self?.performSpeechModelAction(action)
        }
        modelSubmenuProvider = { [weak self] submenu in
            self?.fillModelSubmenu(submenu) ?? false
        }
        languageSubmenuProvider = { [weak self] submenu in
            self?.fillLanguageSubmenu(submenu) ?? false
        }
    }

    private func speechModelsSnapshot() async -> SpeechModelsSnapshot? {
        guard let library = composition.modelManager else { return nil }
        let states = await library.states()
        let defaultModelID = await library.defaultModelID
        let resident = await composition.residentEngine.loadedModelID
        guard !terminationInProgress else { return nil }
        speechModelMenuCache.states = states
        speechModelMenuCache.defaultModelID = defaultModelID
        return SpeechModelsSnapshot(
            catalog: library.catalog,
            states: states,
            defaultModelID: defaultModelID,
            residentModelID: resident,
            dictationIsActive: latestState.kind != .idle,
            activity: modelActivity
        )
    }

    /// `origin` is the door the action came through: the Models section
    /// (`SpeechModelsHooks.perform`) or the status menu's `Model ▸` submenu.
    /// Every case left here is a library operation — the settings-only
    /// actions (language, per-model mode, VAD) are `SettingsIntent`s
    /// `SpeechModelsViewModel` and `selectTranscriptionLanguage` send
    /// directly (ADR-022 slice 7 part B). `.use` still writes a setting, but
    /// only after the library accepted the new default, hence the same idle
    /// check the operations below keep for themselves.
    func performSpeechModelAction(_ action: SpeechModelAction, origin: SettingsOrigin = .page(.models)) {
        guard let library = composition.modelManager else {
            reportTrustFailure()
            return
        }
        switch action {
        case .download(let id):
            runSpeechModelOperation(library) { try await library.install(id) }
        case .resume(let id), .retry(let id):
            runSpeechModelOperation(library) { try await library.retry(id) }
        case .cancel(let id):
            Task { await library.cancel(id) }
        case .delete(let id):
            runSpeechModelOperation(library) { try await library.delete(id) }
        case .use(let id):
            useSpeechModel(id, in: library, origin: origin)
        }
    }

    /// Same shape as the default-model operations above: idle only, one
    /// task at a time, state republished while it runs, failures retained in
    /// the library's fail-closed state.
    private func runSpeechModelOperation(
        _ library: SpeechModelLibrary,
        _ body: @escaping @Sendable () async throws -> Void
    ) {
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await body()
                } catch {
                    // The library keeps the per-model failure state; the
                    // card shows it with Retry.
                }
                await self.persistSelectedModel(from: library)
            }
            await MainActor.run { self.updateMenu(for: self.latestState) }
        }
    }

    private func useSpeechModel(_ id: ModelID, in library: SpeechModelLibrary, origin: SettingsOrigin) {
        guard latestState.kind == .idle else { return }
        runModelTask { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    _ = try await library.setDefaultModel(id)
                } catch {
                    return
                }
                // Recorded only after the library accepted the switch.
                await MainActor.run {
                    self.sendSettingsIntent(.setDefaultSpeechModel(id, origin: origin))
                }
                await self.persistSelectedModel(from: library)
            }
            await MainActor.run { self.updateMenu(for: self.latestState) }
        }
    }

    // MARK: Status-menu submenus

    /// The last polled lifecycle state of one model (`refreshModelState`),
    /// for the header row's install progress (P-D3).
    func speechModelState(for id: ModelID) -> ModelLifecycleState? {
        speechModelMenuCache.states[id]
    }

    private func fillModelSubmenu(_ submenu: NSMenu) -> Bool {
        guard let library = composition.modelManager else { return false }
        let cache = speechModelMenuCache
        let idle = latestState.kind == .idle && !terminationInProgress
        for entry in library.catalog.entries {
            let item = NSMenuItem(
                title: entry.fullDisplayName,
                action: #selector(selectSpeechModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            let isDefault = entry.id == cache.defaultModelID
            item.state = isDefault ? .on : .off
            let installed: Bool
            switch cache.states[entry.id] {
            case .ready?, .inference?: installed = true
            default: installed = false
            }
            if !entry.runtime.isAvailableInThisBuild {
                item.title = String(localized: "\(item.title) (Not Available in This Version)", table: "Shell")
                item.isEnabled = false
            } else if case .unavailable(let failure)? = cache.states[entry.id] {
                // ADR-025: a system-managed model this Mac cannot run.
                item.title = String(localized: "\(item.title) (Unavailable)", table: "Shell")
                item.toolTip = DomainCopy.localized(failure.message)
                item.isEnabled = false
            } else if !installed {
                item.title = String(localized: "\(item.title) (Not Installed)", table: "Shell")
                item.isEnabled = false
            } else {
                item.isEnabled = idle && !isDefault
            }
            submenu.addItem(item)
        }
        if let entry = library.catalog.entry(id: cache.defaultModelID) {
            modelMenuItem?.title = String(localized: "Model: \(entry.fullDisplayName)", table: "Shell")
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: String(localized: "Manage Models…", table: "Shell"), action: #selector(openModels), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
        return true
    }

    private func fillLanguageSubmenu(_ submenu: NSMenu) -> Bool {
        let current = currentSettings.transcriptionLanguage
        let idle = latestState.kind == .idle && !terminationInProgress
        languageItem?.title = String(localized: "Language: \(LanguageNames.transcriptionLanguageName(forCode: current))", table: "Shell")

        let auto = NSMenuItem(
            title: String(localized: "Auto-detect", table: "Shell"),
            action: #selector(selectTranscriptionLanguage(_:)),
            keyEquivalent: ""
        )
        auto.target = self
        auto.representedObject = ""
        auto.state = current == nil ? .on : .off
        auto.isEnabled = idle
        submenu.addItem(auto)
        submenu.addItem(.separator())

        let allowed = composition.modelManager.flatMap { library in
            library.catalog.entry(id: speechModelMenuCache.defaultModelID)
        }
        for language in TranscriptionLanguage.whisperLanguages
        where allowed?.supportsLanguage(language.code) ?? true {
            let item = NSMenuItem(
                title: LanguageNames.transcriptionLanguageName(forCode: language.code),
                action: #selector(selectTranscriptionLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.code
            item.state = language.code == current ? .on : .off
            item.isEnabled = idle
            submenu.addItem(item)
        }
        return true
    }

    // MARK: Status-panel choosers (P-D4)

    /// The panel's Model chooser: the same entries, order, titles and
    /// enabled states as `fillModelSubmenu`, built from the same cache, with
    /// Manage Models… after the separator. Nil without a library, where the
    /// submenu shows the lifecycle state instead (`updateModelMenu`).
    func statusPanelModelChooser() -> StatusPanelChooser? {
        guard let library = composition.modelManager else { return nil }
        let cache = speechModelMenuCache
        let idle = latestState.kind == .idle && !terminationInProgress
        var choices: [StatusPanelChoice] = []
        for entry in library.catalog.entries {
            let isDefault = entry.id == cache.defaultModelID
            let installed: Bool
            switch cache.states[entry.id] {
            case .ready?, .inference?: installed = true
            default: installed = false
            }
            var title = entry.fullDisplayName
            let enabled: Bool
            if !entry.runtime.isAvailableInThisBuild {
                title = String(localized: "\(title) (Not Available in This Version)", table: "Shell")
                enabled = false
            } else if case .unavailable? = cache.states[entry.id] {
                // ADR-025: a system-managed model this Mac cannot run.
                title = String(localized: "\(title) (Unavailable)", table: "Shell")
                enabled = false
            } else if !installed {
                title = String(localized: "\(title) (Not Installed)", table: "Shell")
                enabled = false
            } else {
                enabled = idle && !isDefault
            }
            choices.append(StatusPanelChoice(id: entry.id, title: title, isSelected: isDefault, isEnabled: enabled, command: .selectModel(entry.id)))
        }
        return StatusPanelChooser(
            choices: choices,
            footer: [StatusPanelChoice(id: "manage", title: String(localized: "Manage Models…", table: "Shell"), command: .openModels)]
        )
    }

    /// The default model's name for the panel's Model row — what
    /// `fillModelSubmenu` puts after "Model:" — or nil without a library
    /// entry, where the row falls back to `modelMenuTitle`.
    var statusPanelModelName: String? {
        composition.modelManager?.catalog.entry(id: speechModelMenuCache.defaultModelID)?.fullDisplayName
    }

    /// The panel's Language chooser: Auto-detect, then the languages the
    /// default model supports, as `fillLanguageSubmenu` lists them.
    func statusPanelLanguageChooser() -> StatusPanelChooser {
        let current = currentSettings.transcriptionLanguage
        let idle = latestState.kind == .idle && !terminationInProgress
        var choices = [StatusPanelChoice(
            id: "auto",
            title: String(localized: "Auto-detect", table: "Shell"),
            isSelected: current == nil,
            isEnabled: idle,
            command: .selectLanguage(nil),
            separatorAfter: true
        )]
        let allowed = composition.modelManager.flatMap { library in
            library.catalog.entry(id: speechModelMenuCache.defaultModelID)
        }
        for language in TranscriptionLanguage.whisperLanguages
        where allowed?.supportsLanguage(language.code) ?? true {
            choices.append(StatusPanelChoice(
                id: language.code,
                title: LanguageNames.transcriptionLanguageName(forCode: language.code),
                isSelected: language.code == current,
                isEnabled: idle,
                command: .selectLanguage(language.code)
            ))
        }
        return StatusPanelChooser(choices: choices)
    }

    @objc func selectSpeechModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ModelID else { return }
        performSpeechModelAction(.use(id), origin: .statusMenu)
    }

    @objc func selectTranscriptionLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        sendSettingsIntent(.setTranscriptionLanguage(code.isEmpty ? nil : code, origin: .statusMenu))
    }
}

/// Per-model states for the synchronous menu builders. Extensions cannot add
/// stored properties, and the menu is rebuilt on the main actor from the
/// last values the async refresh produced.
@MainActor
private final class SpeechModelMenuCache {
    var states: [ModelID: ModelLifecycleState] = [:]
    var defaultModelID: ModelID = ""
}

@MainActor
private let speechModelMenuCache = SpeechModelMenuCache()
