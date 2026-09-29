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

    /// One shell-driven library operation at a time, queued behind the
    /// previous one (awaited, so the transition table never sees the two
    /// race).
    ///
    /// 2026-09-29: the previous task is **cancelled only when it is a
    /// download in its byte phase** — the documented "pressing Download on
    /// a second card pauses the first" (the cancel pauses it; Resume picks
    /// it up). Until then every new operation cancelled whatever ran, and
    /// the owner's TestFlight log shows what that cost: the launch
    /// restore's 3.5-minute first Neural Engine compile ended in
    /// `model.load.completed … loadCancelled`, thrown away because a later
    /// operation cancelled the task it ran in. A load or a verification
    /// cannot be paused, so a user operation that arrives during one is
    /// now refused *with its reason*, said where the user clicked
    /// (`onRefused`), and logged as one scalar `model.operation.refused`
    /// line; a supersession logs `model.operation.superseded`. The pure
    /// policy is `ModelOperationAdmission`.
    ///
    /// `operation` is the scalar token for those lines. `nil` marks a
    /// system operation (the settings-load restore) that is never refused
    /// and never cancels anything: it waits its turn.
    @discardableResult
    private func runModelTask(
        _ operation: String?,
        onRefused: ((String) -> Void)? = nil,
        _ body: @escaping @MainActor () async -> Void
    ) -> Bool {
        let previous = modelTask
        let running = composition.modelManager?.currentActivity ?? .idle
        var admission = ModelOperationAdmission.start
        if let operation {
            admission = modelOperationAdmission
            switch admission {
            case .refuse(let reason):
                logModelOperation(.modelOperationRefused, operation: operation, running: running)
                onRefused?(DomainCopy.localized(reason.message))
                return false
            case .supersedeDownload:
                logModelOperation(.modelOperationSuperseded, operation: operation, running: running)
            case .start:
                break
            }
        }
        // The order (never cancelling `previous`) is `ModelOperationSequence`.
        let library = composition.modelManager
        modelTask = Task { [weak self] in
            await ModelOperationSequence.run(
                admission,
                downloadID: running.modelID,
                previous: previous,
                cancelDownload: { id in await library?.cancel(id) },
                waitUntilIdle: { await library?.waitUntilIdle() },
                body: {
                    guard self != nil else { return }
                    await body()
                }
            )
        }
        return true
    }

    /// What a user's model operation would do right now
    /// (`ModelOperationAdmission`), from the library's activity and the
    /// last polled state of the model it concerns. Also what the status
    /// menu and panel disable their model choices with.
    var modelOperationAdmission: ModelOperationAdmission {
        guard let library = composition.modelManager else { return .start }
        let running = library.currentActivity
        let runningState = running.modelID.flatMap { speechModelMenuCache.states[$0] }
        return ModelOperationAdmission.decide(running: running, runningModelState: runningState)
    }

    private func logModelOperation(_ name: DiagnosticEventName, operation: String, running: ModelActivity) {
        let event = DiagnosticEvent(
            name: name,
            attributes: DiagnosticAttributes(reason: running.name, site: operation)
        )
        let diagnostics = composition.diagnostics
        Task { await diagnostics.log(event) }
    }

    /// The wizard's model card shows a refusal (the wizard is the door that
    /// can be pressed in the moment before the first state poll lands).
    private func showOnboardingModelNotice(_ message: String) {
        composition.onboardingViewModel.showModelNotice(message)
    }

    /// The Models section shows a refusal under its cards until the next
    /// action (`SpeechModelsSnapshot.actionNote`).
    private func showSpeechModelsNotice(_ message: String) {
        speechModelMenuCache.actionNote = message
    }

    // MARK: Refresh

    func refreshModelInBackground() {
        installSpeechModelHooks()
        guard let modelManager = composition.modelManager else {
            publishTrustFailureOrAbsent()
            return
        }
        runModelTask(nil) { [weak self] in
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
        // 2026-09-29: the library refresh only while nothing runs. It would
        // be refused anyway (its own `.installing` against the running
        // activity), and each refusal was a `model.activity.refused` line —
        // fourteen in the owner's TestFlight log during one download and
        // compile, read as "clicks ignored". The state is still republished:
        // it is how operations outside the shell's task (the automatic
        // asset install, a pressure reload) reach the wizard and the menu.
        if modelManager.currentActivity.isIdle {
            await modelManager.refresh()
        }
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
        // 2026-09-29 (owner decision 1): a fresh setup may start with Apple
        // Speech. Only possibly fresh when nothing is saved and onboarding
        // never completed; the package states are checked once observed.
        let onboardingCompleted = currentLocalState.onboardingVersionCompleted
        let mayBeFreshSetup = onboardingCompleted == nil && preferredDefault == nil && reference == nil
        if mayBeFreshSetup {
            composition.onboardingViewModel.setDeterminingModel(true)
        }
        runModelTask(nil) { [weak self] in
            guard let self else { return }
            defer { self.composition.onboardingViewModel.setDeterminingModel(false) }
            guard !Task.isCancelled else { return }
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
                if mayBeFreshSetup {
                    await self.adoptSetupDefaultIfFresh(
                        modelManager,
                        onboardingCompleted: onboardingCompleted,
                        transcriptionLanguage: settings.transcriptionLanguage
                    )
                }
            }
            await MainActor.run { self.updateMenu(for: self.latestState) }
        }
    }

    /// The Mac's own language as a transcription-language code — what
    /// Auto-detect means for a system runtime (ADR-025) — for the setup
    /// recommendation's coverage check.
    static var macLanguageCode: String? {
        Locale.current.language.languageCode?.identifier
    }

    /// Owner decision 1 (2026-09-29): with every entry observed, a fresh
    /// setup adopts Apple Speech when this Mac can run it for the language
    /// (`SetupSpeechModelDefault.choice`); the choice is saved like a user's
    /// pick, and the ADR-025 automatic install fetches its assets on the
    /// next language poll. Otherwise the recommended default stays.
    private func adoptSetupDefaultIfFresh(
        _ library: SpeechModelLibrary,
        onboardingCompleted: Int?,
        transcriptionLanguage: String?
    ) async {
        // The restore can lose its turn to an activation refresh; either
        // way every entry must have looked at this Mac before deciding.
        await library.waitUntilIdle()
        var observed = await library.observedStates()
        if observed == nil {
            await library.refresh()
            observed = await library.observedStates()
        }
        guard let states = observed else { return }
        let catalog = library.catalog
        guard SetupSpeechModelDefault.isFreshSetup(
            onboardingCompletedVersion: onboardingCompleted,
            savedDefaultModelID: nil,
            selectedModel: nil,
            catalog: catalog,
            states: states
        ) else { return }
        let choice = SetupSpeechModelDefault.usableSystemModel(
            catalog: catalog,
            states: states,
            transcriptionLanguage: transcriptionLanguage,
            macLanguageCode: Self.macLanguageCode
        )
        var adopted: ModelID?
        if let choice, (try? await library.setDefaultModel(choice)) != nil {
            adopted = choice
            // Installed here, inside the restore's polled body, so the
            // wizard's card shows the percent and then Ready — and before
            // the settings write, whose language effect would otherwise
            // start the same install from an unobserved task.
            if case .absent? = await library.state(of: choice) {
                try? await library.install(choice)
            }
            sendSettingsIntent(.setDefaultSpeechModel(choice, origin: .wizard))
        }
        let fallbackID = await library.defaultModelID
        let chosen = adopted ?? fallbackID
        let event = DiagnosticEvent(
            name: .modelSetupDefaultChosen,
            attributes: DiagnosticAttributes(
                modelID: chosen,
                reason: adopted == nil ? "systemManagedUnavailable" : "systemManagedAvailable"
            )
        )
        await composition.diagnostics.log(event)
    }

    /// The wizard card's "Use … Instead" (2026-09-29): the entry becomes
    /// the default and, when nothing of it is installed, its install starts
    /// in the same click — the card's note said what that downloads. Busy
    /// operations refuse with the card's notice, like the Download button.
    func useSetupModel(_ id: ModelID) {
        guard let library = composition.modelManager else {
            reportTrustFailure()
            return
        }
        guard latestState.kind == .idle else { return }
        runModelTask("use", onRefused: showOnboardingModelNotice) { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    _ = try await library.setDefaultModel(id)
                } catch let refusal as ModelActivityRefusal {
                    self.showOnboardingModelNotice(Self.refusalSentence(refusal))
                    return
                } catch {
                    return
                }
                // The order is `SetupSpeechModelDefault.savesChoiceBeforeInstall`.
                let saveFirst = library.catalog.entry(id: id).map(SetupSpeechModelDefault.savesChoiceBeforeInstall) ?? true
                if saveFirst {
                    self.sendSettingsIntent(.setDefaultSpeechModel(id, origin: .wizard))
                }
                if case .absent? = await library.state(of: id) {
                    try? await library.install(id)
                }
                if !saveFirst {
                    self.sendSettingsIntent(.setDefaultSpeechModel(id, origin: .wizard))
                }
                await self.persistSelectedModel(from: library)
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
        // 2026-09-29: the other model, one click away on the wizard's card.
        let alternative = SetupSpeechModelDefault.alternative(
            to: defaultModelID,
            catalog: modelManager.catalog,
            states: states,
            transcriptionLanguage: currentSettings.transcriptionLanguage,
            macLanguageCode: Self.macLanguageCode
        )
        composition.onboardingViewModel.setAlternativeModelEntry(alternative.flatMap(modelManager.catalog.entry(id:)))
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
        runModelTask("download", onRefused: showOnboardingModelNotice) { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            // 2026-09-29: a Download queued behind the launch restore (the
            // wizard can offer it before the first state report lands)
            // must not re-download a model the restore just loaded.
            switch await modelManager.state {
            case .ready, .inference, .loading, .optimizing: return
            default: break
            }
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
        runModelTask("chooseExisting", onRefused: showOnboardingModelNotice) { [weak self] in
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
        runModelTask("retry", onRefused: showOnboardingModelNotice) { [weak self] in
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
        runModelTask("delete", onRefused: showOnboardingModelNotice) { [weak self] in
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
        runModelTask("forget", onRefused: showOnboardingModelNotice) { [weak self] in
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
        // The refusal's sentence goes once an operation would start again.
        if modelOperationAdmission == .start {
            speechModelMenuCache.actionNote = nil
        }
        return SpeechModelsSnapshot(
            catalog: library.catalog,
            states: states,
            defaultModelID: defaultModelID,
            residentModelID: resident,
            dictationIsActive: latestState.kind != .idle,
            activity: modelActivity,
            actionNote: speechModelMenuCache.actionNote
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
        speechModelMenuCache.actionNote = nil
        switch action {
        case .download(let id):
            runSpeechModelOperation(library, "download") { try await library.install(id) }
        case .resume(let id):
            runSpeechModelOperation(library, "resume") { try await library.retry(id) }
        case .retry(let id):
            runSpeechModelOperation(library, "retry") { try await library.retry(id) }
        case .cancel(let id):
            Task { await library.cancel(id) }
        case .delete(let id):
            runSpeechModelOperation(library, "delete") { try await library.delete(id) }
        case .use(let id):
            useSpeechModel(id, in: library, origin: origin)
        }
    }

    /// Same shape as the default-model operations above: idle only, one
    /// task at a time, state republished while it runs, failures retained in
    /// the library's fail-closed state.
    private func runSpeechModelOperation(
        _ library: SpeechModelLibrary,
        _ operation: String,
        _ body: @escaping @Sendable () async throws -> Void
    ) {
        guard latestState.kind == .idle else { return }
        runModelTask(operation, onRefused: showSpeechModelsNotice) { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    try await body()
                } catch let refusal as ModelActivityRefusal {
                    // Lost a race the admission check could not see (an
                    // activity that began after it); said, not swallowed.
                    self.showSpeechModelsNotice(Self.refusalSentence(refusal))
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
        let onRefused: (String) -> Void = origin == .wizard ? showOnboardingModelNotice : showSpeechModelsNotice
        runModelTask("use", onRefused: onRefused) { [weak self] in
            guard let self,
                  await self.composition.dictationController.state.kind == .idle,
                  !Task.isCancelled else { return }
            await self.withModelStatePolling {
                do {
                    _ = try await library.setDefaultModel(id)
                } catch let refusal as ModelActivityRefusal {
                    onRefused(Self.refusalSentence(refusal))
                    return
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

    /// The sentence for a library refusal that beat the admission check.
    private static func refusalSentence(_ refusal: ModelActivityRefusal) -> String {
        let reason = ModelOperationAdmission.decide(running: refusal.running, runningModelState: nil)
            .refusalReason ?? .modelOperationInProgress
        return DomainCopy.localized(reason.message)
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
        // 2026-09-29: a model pick during a load says why it waits.
        let busyReason = modelOperationAdmission.refusalReason.map { DomainCopy.localized($0.message) }
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
                item.isEnabled = idle && !isDefault && busyReason == nil
                if !isDefault, let busyReason { item.toolTip = busyReason }
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
        let busy = modelOperationAdmission.refusalReason != nil
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
                enabled = idle && !isDefault && !busy
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
    /// 2026-09-29: the last refused Models-section action's sentence,
    /// shown until the next action (`SpeechModelsSnapshot.actionNote`).
    var actionNote: String?
}

@MainActor
private let speechModelMenuCache = SpeechModelMenuCache()
