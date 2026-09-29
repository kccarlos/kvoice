import Foundation
import KvoiceDomain
import KvoiceTranscription

/// Which catalog model owns the resident runtime. Shared between the library
/// and the per-model runtime loaders, so a loader can tell whether its model
/// should actually be loaded into the engine or only verified.
final class RuntimeResidency: @unchecked Sendable {
    private let lock = NSLock()
    private var residentModelID: ModelID

    init(residentModelID: ModelID) {
        self.residentModelID = residentModelID
    }

    var current: ModelID {
        get { lock.withLock { residentModelID } }
        set { lock.withLock { residentModelID = newValue } }
    }
}

/// The compute units the engine loads with, as the library last set them
/// (`setComputeUnits`), for the loaders' compile record (2026-09-29).
final class ComputeUnitsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeechComputeUnits = .default

    var current: SpeechComputeUnits {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The library's `ModelActivity`, readable without entering the actor.
///
/// The transition table is applied inside the actor (`SpeechModelLibrary`
/// serialises every `begin`/`end`); this box is the published copy the
/// shell's synchronous gates read (`AppDelegate.settingsGate`, the
/// shortcut's busy beep, the App Intents start gate) so they never lag a
/// mirror behind the truth. Written only by the actor, in the same
/// statement that changes its own state.
final class ModelActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ModelActivity = .idle

    var current: ModelActivity {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The bundled catalog with the ADR-025 language overlay applied, readable
/// without entering the actor (the shell's menus read it synchronously).
/// Written only by the actor.
final class CatalogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeechModelCatalog

    init(catalog: SpeechModelCatalog) {
        value = catalog
    }

    var current: SpeechModelCatalog {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The per-entry lifecycle the library routes to (ADR-025): a
/// `ModelPackageManager` for a kvoice-manifest entry, a
/// `SystemManagedModelManager` for a system-managed one. The two share the
/// operations the library forwards; the external-folder operations exist
/// only for packages on disk and are refused for a system entry.
enum ModelManagerReference: Sendable {
    case package(ModelPackageManager)
    case system(SystemManagedModelManager)

    var packageManager: ModelPackageManager? {
        if case .package(let manager) = self { return manager }
        return nil
    }

    var systemManager: SystemManagedModelManager? {
        if case .system(let manager) = self { return manager }
        return nil
    }

    var state: ModelLifecycleState {
        get async {
            switch self {
            case .package(let manager): return await manager.state
            case .system(let manager): return await manager.state
            }
        }
    }

    func refresh() async {
        switch self {
        case .package(let manager): await manager.refresh()
        case .system(let manager): await manager.refresh()
        }
    }

    func installRecommendedModel() async throws {
        switch self {
        case .package(let manager): try await manager.installRecommendedModel()
        case .system(let manager): try await manager.installRecommendedModel()
        }
    }

    func resumeInstallation() async throws {
        switch self {
        case .package(let manager): try await manager.resumeInstallation()
        case .system(let manager): try await manager.resumeInstallation()
        }
    }

    func retryInstallation() async throws {
        switch self {
        case .package(let manager): try await manager.retryInstallation()
        case .system(let manager): try await manager.retryInstallation()
        }
    }

    func cancelInstallation() async {
        switch self {
        case .package(let manager): await manager.cancelInstallation()
        case .system(let manager): await manager.cancelInstallation()
        }
    }

    func deleteManagedPackage() async throws {
        switch self {
        case .package(let manager): try await manager.deleteManagedPackage()
        case .system(let manager): try await manager.deleteManagedPackage()
        }
    }

    func selectExternalPackage(at url: URL, modelID: ModelID) async throws {
        switch self {
        case .package(let manager): try await manager.selectExternalPackage(at: url)
        case .system: throw ModelManagementError.unsupportedModel(modelID)
        }
    }

    func restoreSelectedModel(_ reference: ModelReference?) async {
        switch self {
        case .package(let manager): await manager.restoreSelectedModel(reference)
        case .system(let manager): await manager.refresh()
        }
    }

    func forgetExternalPackage() async {
        switch self {
        case .package(let manager): await manager.forgetExternalPackage()
        case .system: break
        }
    }

    func verifiedPackage() async throws -> InstalledModelPackage {
        switch self {
        case .package(let manager): return try await manager.verifiedPackage()
        case .system(let manager): return try await manager.verifiedPackage()
        }
    }

    func installedPackageSummary() async -> InstalledModelSummary? {
        switch self {
        case .package(let manager): return await manager.installedPackageSummary()
        case .system(let manager): return await manager.installedPackageSummary()
        }
    }

    func currentModelReference() async -> ModelReference? {
        switch self {
        case .package(let manager): return await manager.currentModelReference()
        case .system(let manager): return await manager.currentModelReference()
        }
    }

    func installationSpaceEstimate() async -> ModelInstallationSpaceEstimate {
        switch self {
        case .package(let manager): return await manager.installationSpaceEstimate()
        case .system(let manager): return await manager.installationSpaceEstimate()
        }
    }

    func loadResidentRuntime() async {
        switch self {
        case .package(let manager): await manager.loadResidentRuntime()
        case .system(let manager): await manager.loadResidentRuntime()
        }
    }

    func releaseResidentRuntime() async {
        switch self {
        case .package(let manager): await manager.releaseResidentRuntime()
        case .system(let manager): await manager.releaseResidentRuntime()
        }
    }

    func beginInference(jobID: JobID) async throws {
        switch self {
        case .package(let manager): try await manager.beginInference(jobID: jobID)
        case .system(let manager): try await manager.beginInference(jobID: jobID)
        }
    }

    func endInference(jobID: JobID) async {
        switch self {
        case .package(let manager): await manager.endInference(jobID: jobID)
        case .system(let manager): await manager.endInference(jobID: jobID)
        }
    }
}

/// A runtime loader that loads its model into the shared engine only while
/// that model is the resident (default) one. Any other model is verified by
/// its manager and reported `.ready` without touching the engine. Unload
/// releases the engine only if the engine currently holds this model, so
/// deleting a non-default package never evicts the default.
///
/// 2026-09-29: it is also where "first-time compile" is known and recorded,
/// because only here is it certain that a load reaches the engine (a
/// non-default model's "load" is a no-op). With a `compileRecord`, a
/// package-backed load that the record has never seen under the current
/// compute units is announced as first-time (`loadWillCompileFirstTime`)
/// and, once the engine accepted it, recorded; each real load leaves a
/// scalar `model.load.started` / `model.load.completed` pair whose
/// `reason` is `firstCompile` or `cached` and whose duration is the load's.
struct ResidencyGatedRuntimeLoader: ModelRuntimeLoader {
    let modelID: ModelID
    let engine: any TranscriptionEngine
    let residency: RuntimeResidency
    var compileRecord: (any ModelCompileRecording)?
    var computeUnits: ComputeUnitsBox?
    var diagnostics: (any DiagnosticLogging)?
    var clock: ModelClock = { Date() }

    func load(_ package: InstalledModelPackage) async throws {
        guard residency.current == modelID else { return }
        let key = compileKey(for: package)
        let firstCompile: Bool
        if let key, let compileRecord {
            firstCompile = await !compileRecord.hasCompiled(key)
        } else {
            firstCompile = false
        }
        let reason = firstCompile ? "firstCompile" : "cached"
        await diagnostics?.log(DiagnosticEvent(
            name: .modelLoadStarted,
            attributes: DiagnosticAttributes(modelID: modelID, reason: reason, site: "engineLoad")
        ))
        let start = clock()
        do {
            try await engine.load(package)
        } catch {
            // The pair always closes: a failed load logs its own line
            // (scalars only — the case of the failure, never its message)
            // beside whatever the engine logged, then the error goes on.
            let elapsed = clock().timeIntervalSince(start)
            await diagnostics?.log(DiagnosticEvent(
                name: .modelLoadCompleted,
                result: .failure,
                durationMilliseconds: max(elapsed, 0) * 1000,
                errorCode: .modelLoadFailed,
                attributes: DiagnosticAttributes(
                    modelID: modelID,
                    reason: error is CancellationError ? "loadCancelled" : "\(reason)Failed",
                    site: "engineLoad"
                )
            ))
            throw error
        }
        let elapsed = clock().timeIntervalSince(start)
        if let key {
            await compileRecord?.recordCompiled(key)
        }
        await diagnostics?.log(DiagnosticEvent(
            name: .modelLoadCompleted,
            result: .success,
            durationMilliseconds: max(elapsed, 0) * 1000,
            attributes: DiagnosticAttributes(modelID: modelID, reason: reason, site: "engineLoad")
        ))
    }

    func loadWillCompileFirstTime(_ package: InstalledModelPackage) async -> Bool {
        guard residency.current == modelID, let key = compileKey(for: package), let compileRecord else { return false }
        return await !compileRecord.hasCompiled(key)
    }

    /// Nil for a system-managed package: the OS owns that model and there
    /// is no Core ML build of kvoice's to wait for (ADR-025).
    private func compileKey(for package: InstalledModelPackage) -> ModelCompileKey? {
        guard package.ownership != .systemManaged, let computeUnits else { return nil }
        return ModelCompileKey(
            modelID: package.manifest.modelID,
            revision: package.manifest.source.revision,
            computeUnits: computeUnits.current
        )
    }

    func unload() async {
        guard await engine.loadedModelID == modelID else { return }
        await engine.unload()
    }
}

/// Coordinates one `ModelPackageManager` per catalog entry (ADR-017) — or,
/// for a system-managed entry (ADR-025), one `SystemManagedModelManager`
/// over the assets adapter the composition supplies per runtime.
///
/// Every fail-closed guarantee of the single-model manager holds per model.
/// The library adds four things: per-model routing of the lifecycle
/// operations, a single resident runtime (the default model's), a
/// façade with the manager's own method names for the default model so the
/// app shell's existing orchestration keeps working unchanged (it does not
/// adopt `ModelPackageProviding`, whose synchronous `state` cannot be
/// answered by an actor that has to ask another actor), and — ADR-022
/// item 5 — the one `ModelActivity` every operation begins and ends.
///
/// **Activity (ADR-022 slice 4).** Until 2026-09-16 the library kept a
/// `runtimeOperationInProgress` flag for the four engine-touching methods
/// and the shell kept three more (`isReloadingComputeUnits`,
/// `isRunningPerformanceTest`, `isTranscribingFile`); the two reentrancy
/// bugs of 2026-09-14 (GPU units reaching the Unified encoder mid-reload;
/// the memory-pressure reload racing a compute-unit reload) were missing
/// transitions in a machine that did not exist. Now every operation runs
/// inside `withActivity`: `ModelActivityTransition` decides whether it may
/// begin (only from `.idle`), the activity returns to `.idle` on
/// completion, failure or cancellation, and a refused begin throws
/// `ModelActivityRefusal` and logs one scalar `model.activity.refused`
/// line. The engines' own `loadInProgress` guard stays as the belt-and-
/// braces safety net below this table; the library never calls `load`
/// outside `.loading`, `.downloading`, `.installing`.
public actor SpeechModelLibrary {
    /// The bundled catalog, every entry listed so the section can show the
    /// unrunnable ones as unavailable. ADR-025: a system-managed entry's
    /// language coverage is overlaid with what the platform reported at the
    /// last refresh, so this changes when the overlay does — read it, do
    /// not cache it.
    public nonisolated var catalog: SpeechModelCatalog { catalogBox.current }
    /// Catalog order, restricted to entries this build can run and verify.
    public nonisolated let modelIDs: [ModelID]

    private let catalogBox: CatalogBox
    private let managers: [ModelID: ModelManagerReference]
    private let engine: any TranscriptionEngine
    private let residency: RuntimeResidency
    private let computeUnitsBox = ComputeUnitsBox()
    private let compileRecord: (any ModelCompileRecording)?
    private let activityBox = ModelActivityBox()
    private let diagnosticLogger: (any DiagnosticLogging)?
    private var activityContinuations: [UUID: AsyncStream<ModelActivity>.Continuation] = [:]
    public private(set) var defaultModelID: ModelID

    /// ADR-022 item 5: what the library is doing right now. `.idle` between
    /// operations; never two at once.
    public private(set) var activity: ModelActivity = .idle {
        didSet {
            activityBox.current = activity
            for continuation in activityContinuations.values {
                continuation.yield(activity)
            }
        }
    }

    /// `activity`, readable synchronously from any isolation (the shell's
    /// gates). Always equal to the actor's `activity`.
    public nonisolated var currentActivity: ModelActivity { activityBox.current }

    /// - Parameters:
    ///   - loaded: the verified catalog. Entries without an anchor or with a
    ///     runtime this build lacks are listed in `catalog` but get no
    ///     manager; they show as unavailable.
    ///   - preferredDefaultModelID: the persisted setting; an unknown or
    ///     unrunnable ID falls back to the catalog's recommended entry.
    ///   - makeDownloader: one download client per manager, because a
    ///     `URLSessionModelDownloadClient` allows one task at a time.
    ///   - diagnosticLogger: receives the `model.activity.refused` lines
    ///     (scalars only); nil drops them.
    ///   - systemAssets: ADR-025 — the assets adapter per system-managed
    ///     runtime (`.appleSpeech: AppleSpeechModelAssets`). A system-managed
    ///     entry whose runtime has no adapter here is listed but gets no
    ///     manager, like an entry with no anchor.
    ///   - transcriptionLanguage: the persisted transcription language, so
    ///     a system-managed manager observes the right locale from the
    ///     first refresh; `setTranscriptionLanguage` keeps it current.
    public init(
        loaded: LoadedSpeechModelCatalog,
        storageDirectoryURL: URL,
        engine: any TranscriptionEngine,
        preferredDefaultModelID: ModelID? = nil,
        makeDownloader: @Sendable () -> any ModelDownloadClient = { URLSessionModelDownloadClient() },
        urlProvider: any ModelDownloadURLProviding = PinnedHuggingFaceModelURLProvider(),
        volumeCapacity: any ModelVolumeCapacityProviding = FileManagerVolumeCapacityProvider(),
        clock: @escaping ModelClock = { Date() },
        appVersion: String = ModelPackageManager.defaultAppVersion(),
        diagnosticLogger: (any DiagnosticLogging)? = nil,
        systemAssets: [SpeechModelRuntime: any SystemManagedModelAssets] = [:],
        transcriptionLanguage: String? = nil,
        compileRecord: (any ModelCompileRecording)? = nil
    ) throws {
        catalogBox = CatalogBox(catalog: loaded.catalog)
        self.diagnosticLogger = diagnosticLogger
        self.compileRecord = compileRecord
        let runnable = loaded.catalog.runnableEntries.filter { entry in
            entry.isSystemManaged ? systemAssets[entry.runtime] != nil : loaded.anchors[entry.id] != nil
        }
        guard !runnable.isEmpty else {
            throw SpeechModelCatalogError.emptyCatalog
        }
        modelIDs = runnable.map(\.id)
        let fallback = runnable.first(where: \.isRecommended)?.id ?? runnable[0].id
        let chosen = preferredDefaultModelID.flatMap { id in runnable.contains { $0.id == id } ? id : nil } ?? fallback
        defaultModelID = chosen
        residency = RuntimeResidency(residentModelID: chosen)
        self.engine = engine

        var managers: [ModelID: ModelManagerReference] = [:]
        for entry in runnable {
            let loader = ResidencyGatedRuntimeLoader(
                modelID: entry.id,
                engine: engine,
                residency: residency,
                compileRecord: compileRecord,
                computeUnits: computeUnitsBox,
                // The load lines belong to the compile tracking: without a
                // record there is no first/cached distinction to report.
                diagnostics: compileRecord == nil ? nil : diagnosticLogger,
                clock: clock
            )
            if entry.isSystemManaged {
                guard let assets = systemAssets[entry.runtime] else { continue }
                managers[entry.id] = .system(SystemManagedModelManager(
                    entry: entry,
                    assets: assets,
                    runtimeLoader: loader,
                    languageCode: transcriptionLanguage
                ))
                continue
            }
            guard let anchor = loaded.anchors[entry.id] else { continue }
            managers[entry.id] = .package(ModelPackageManager(
                trustedRelease: anchor,
                storageDirectoryURL: storageDirectoryURL,
                runtimeLoader: loader,
                downloader: makeDownloader(),
                urlProvider: urlProvider,
                volumeCapacity: volumeCapacity,
                clock: clock,
                appVersion: appVersion
            ))
        }
        self.managers = managers
    }

    // MARK: - System-managed entries (ADR-025)

    /// Forwards the transcription language to every system-managed manager
    /// (their state is per locale) and re-applies the language overlay. A
    /// no-op when nothing changed; the shell calls it from the
    /// `.refreshCatalogLimit` effect and the slow poll. A change re-observes
    /// the platform and may load or release the resident engine, so it runs
    /// as `.installing(id)` under the activity table (ADR-022 item 5); when
    /// another activity is in flight the change is left for the next call —
    /// the slow poll retries within a second. Then, once per language, the
    /// default model's assets are installed automatically when it is
    /// system-managed and the platform has none for that language
    /// (`installDefaultSystemAssetsIfNeeded`).
    public func setTranscriptionLanguage(_ code: String?) async {
        // Not a refused transition: the one-second poll calls this, and a
        // refusal line per second for the length of a download would be
        // noise, not a signal. The next idle call applies the change.
        var changed = false
        if activity.isIdle {
            for (id, manager) in managers {
                guard let system = manager.systemManager else { continue }
                let snapshot = await system.snapshot()
                if snapshot.languageCode != code {
                    try? await withActivity(.installing(id)) { await system.setLanguageCode(code) }
                    changed = true
                } else if !snapshot.hasObservedAssets, case .ready = snapshot.state {
                    // The language changed while a job held the model, so
                    // the manager skipped the observation and `endInference`
                    // restored `.ready` for a language it never looked at;
                    // nothing else re-observes before the next activation
                    // refresh. The idle poll does it now (cheap, idempotent).
                    // `.ready` only: the constructor's `.absent` before the
                    // launch refresh is not this case, and observing it here
                    // would double the launch-time platform query that
                    // `restoreSelectedModel` makes a moment later.
                    try? await withActivity(.installing(id)) { await system.refresh() }
                }
            }
            await overlayObservedLanguages()
        }
        // Runs on the busy path too: the *decision* is taken on the
        // manager's state (a card Install in flight settles the language
        // as the user's), only the kickoff needs `.idle`.
        await installDefaultSystemAssetsIfNeeded(site: changed ? "languageChange" : "poll")
    }

    // MARK: Automatic asset install (ADR-025 amendment, 2026-09-16)

    /// The transcription language the automatic install was last decided
    /// for, so the decision is made **once per language**: the one-second
    /// poll calls `setTranscriptionLanguage` with the same code for the
    /// life of the process, and neither a failed install (`.error`, with
    /// the card's Retry / Delete) nor a Delete (`.absent` again, by the
    /// user's hand) may re-trigger it. `nil` = never decided (launch).
    private var autoInstallDecision: AutoInstallDecision?

    /// `String?` wrapped so "decided for Auto-detect" and "never decided"
    /// are different values.
    private struct AutoInstallDecision: Equatable {
        let languageCode: String?
    }

    /// Starts the default model's install when it is system-managed and the
    /// platform holds no assets for the language just chosen — through the
    /// same `.downloading(id)` transaction as the card's Install, so the
    /// card shows the percent, the prerequisite check sees `.downloading`
    /// (HUD "still loading"), and the runtime loads as resident when done.
    ///
    /// Why: the platform's "installed" is per locale (ADR-025), so a user
    /// who installed Apple Speech once and switched the language to Chinese
    /// found the card at "Not installed" and the hotkey Blocked, with no
    /// hint that a second install was expected — Whisper never asked. Only
    /// `.absent` is acted on: `.unavailable` (unsupported language, older
    /// macOS, ineligible Mac) and `.error` keep their states and actions.
    /// Only the default model: a non-default system entry keeps the
    /// per-language "Not installed" display. A state that was never
    /// observed (before the launch refresh) is not `.absent` in any useful
    /// sense, so the decision waits for the first observation — the poll
    /// brings it back within a second.
    ///
    /// The decision is taken on the manager's state, not on the activity:
    /// a state the user is already handling — the card's own Install in
    /// flight (`.downloading`), a Delete (`.deleting`) — counts as decided,
    /// so cancelling that install does not hand the language to this
    /// method a second later.
    private func installDefaultSystemAssetsIfNeeded(site: String) async {
        guard let system = defaultManager.systemManager else { return }
        // One actor turn for the three facts: a language change suspended
        // in the platform call (over a second on a test Mac) has
        // already moved `languageCode` while `state` is still the old
        // language's, and `hasObservedAssets` is false exactly then — read
        // separately, the poll could latch the decision on a stale
        // `.ready` and the change's own kickoff would find it taken.
        let snapshot = await system.snapshot()
        let decision = AutoInstallDecision(languageCode: snapshot.languageCode)
        guard decision != autoInstallDecision, snapshot.hasObservedAssets else { return }
        guard case .absent = snapshot.state else {
            autoInstallDecision = decision
            return
        }
        // Absent, but the library is busy (the caller's idle branch was
        // skipped): not decided, the next poll looks again.
        guard activity.isIdle else { return }
        autoInstallDecision = decision
        recordAutoInstall(modelID: defaultModelID, languageCode: decision.languageCode, site: site)
        do {
            // The idle check, the decision and `beginActivity` run in one
            // synchronous actor region — no hop — so the begin cannot be
            // refused here; the catch below is belt-and-braces only.
            try await withActivity(.downloading(defaultModelID)) { try await system.installRecommendedModel() }
        } catch is ModelActivityRefusal {
            autoInstallDecision = nil
        } catch {
            // The manager keeps the fail-closed `.error` (the reservation
            // cap, a download failure) and the card shows Retry / Delete;
            // the decision stands so the poll does not retry on its own.
        }
    }

    /// One scalar line per kickoff (rule 3): the model ID, the language
    /// *code* and which door — never a language name or transcript.
    private func recordAutoInstall(modelID: ModelID, languageCode: String?, site: String) {
        guard let diagnosticLogger else { return }
        let event = DiagnosticEvent(
            name: .modelAssetsAutoInstall,
            attributes: DiagnosticAttributes(modelID: modelID, reason: languageCode ?? "auto", site: site)
        )
        Task { await diagnosticLogger.log(event) }
    }

    /// Replaces each system-managed entry's shipped language list with what
    /// its manager observed, when it observed anything.
    private func overlayObservedLanguages() async {
        var catalog = catalogBox.current
        for (id, manager) in managers {
            guard let system = manager.systemManager, let entry = catalog.entry(id: id) else { continue }
            let codes = await system.supportedLanguageCodes
            guard !codes.isEmpty, codes != entry.languageCodes else { continue }
            catalog = catalog.replacing(entry.observingLanguages(
                codes: codes,
                summary: Self.languageSummary(count: codes.count)
            ))
        }
        catalogBox.current = catalog
    }

    /// "21 languages on this Mac" — the observed coverage, worded as a fact
    /// about this machine rather than about the model.
    public static func languageSummary(count: Int) -> String {
        count == 1 ? "1 language on this Mac" : "\(count) languages on this Mac"
    }

    // MARK: - Activity (ADR-022 item 5)

    /// Delivers the current activity immediately, then every change; each
    /// subscriber keeps only the newest value (the shell recomputes its
    /// availability table and menu from it).
    public func activityChanges() -> AsyncStream<ModelActivity> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelActivity>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityContinuation(id) }
        }
        activityContinuations[id] = continuation
        continuation.yield(activity)
        return stream
    }

    private func removeActivityContinuation(_ id: UUID) {
        activityContinuations.removeValue(forKey: id)
    }

    /// Begins an activity the caller runs itself on the resident engine —
    /// the Runtime card's `.testing` and History's `.transcribingFile` —
    /// under the same table as the library's own operations. The caller
    /// must pair it with `endActivity()` (a `defer`), whatever the outcome.
    /// Throws `ModelActivityRefusal` when another activity is running.
    public func beginActivity(_ requested: ModelActivity) throws {
        switch ModelActivityTransition.next(activity, .begin(requested)) {
        case .success(let next):
            activity = next
        case .failure(let refusal):
            recordRefusal(refusal)
            throw refusal
        }
    }

    /// Returns once the library is `.idle` (at once when it already is).
    /// 2026-09-29: the shell waits here after superseding a download, which
    /// may run outside the shell's own task (the ADR-025 automatic asset
    /// install), so the next operation is not refused by the table while
    /// the cancelled one unwinds.
    public func waitUntilIdle() async {
        for await next in activityChanges() where next.isIdle {
            return
        }
    }

    /// Returns the library to `.idle`. Harmless when nothing is running.
    public func endActivity() {
        endActivity(.completed)
    }

    private func endActivity(_ event: ModelActivityTransition.Event) {
        if case .success(let next) = ModelActivityTransition.next(activity, event) {
            activity = next
        }
    }

    /// Every library operation: begin under the table, run, return to
    /// `.idle` whatever happened. A throw that is a cancellation ends the
    /// activity as `.cancelled`, any other as `.failed` — the same `.idle`
    /// either way, kept distinct so the transition function is honest.
    private func withActivity<T: Sendable>(
        _ requested: ModelActivity,
        _ body: () async throws -> T
    ) async throws -> T {
        try beginActivity(requested)
        do {
            let result = try await body()
            endActivity(.completed)
            return result
        } catch {
            endActivity(Self.isCancellation(error) ? .cancelled : .failed)
            throw error
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case ModelManagementError.cancelled? = error as? ModelManagementError { return true }
        return false
    }

    /// One scalar line per refusal (rule 3): the requested and the running
    /// activity by case name — never a model ID.
    private func recordRefusal(_ refusal: ModelActivityRefusal) {
        guard let diagnosticLogger else { return }
        let event = DiagnosticEvent(
            name: .modelActivityRefused,
            attributes: DiagnosticAttributes(reason: refusal.requested.name, site: refusal.running.name)
        )
        Task { await diagnosticLogger.log(event) }
    }

    // MARK: - Lookup

    /// The package manager of a kvoice-manifest entry; nil for a
    /// system-managed one (its lifecycle has no files to manage).
    public func manager(for id: ModelID) -> ModelPackageManager? {
        managers[id]?.packageManager
    }

    public func entry(for id: ModelID) -> SpeechModelCatalogEntry? {
        catalog.entry(id: id)
    }

    public var defaultEntry: SpeechModelCatalogEntry? {
        catalog.entry(id: defaultModelID)
    }

    private var defaultManager: ModelManagerReference {
        // Every ID in `modelIDs` has a manager, and `defaultModelID` is
        // always drawn from `modelIDs`.
        managers[defaultModelID]!
    }

    /// The default model's lifecycle state (the `ModelPackageProviding` view).
    public var state: ModelLifecycleState {
        get async { await defaultManager.state }
    }

    public func state(of id: ModelID) async -> ModelLifecycleState? {
        guard let manager = managers[id] else { return nil }
        return await manager.state
    }

    public func states() async -> [ModelID: ModelLifecycleState] {
        var result: [ModelID: ModelLifecycleState] = [:]
        for id in modelIDs {
            result[id] = await managers[id]!.state
        }
        return result
    }

    /// Every lifecycle state, but only once each system-managed entry has
    /// observed the platform for the current language (nil before that):
    /// its constructor state `.absent` says nothing about this Mac, and a
    /// decision taken on it (the fresh-setup default, 2026-09-29) would
    /// pick Apple Speech on a Mac that cannot run it.
    public func observedStates() async -> [ModelID: ModelLifecycleState]? {
        for id in modelIDs {
            guard let system = managers[id]?.systemManager else { continue }
            guard await system.snapshot().hasObservedAssets else { return nil }
        }
        return await states()
    }

    /// True when the default model is verified and the engine holds it.
    public func isDefaultModelResident() async -> Bool {
        switch await defaultManager.state {
        case .ready, .inference:
            return await engine.loadedModelID == defaultModelID
        default:
            return false
        }
    }

    // MARK: - Default model

    /// Makes `id` the default: the old default's runtime is released and the
    /// new one's verified package (if installed) is loaded. Refused with
    /// `ModelManagementError.busy` while the current default is
    /// transcribing (the package fact), and with `ModelActivityRefusal`
    /// while any other activity runs — a compute-unit reload, an unload, a
    /// pressure reload, a download (the 2026-09-14 slice-2 review: this
    /// method too releases and loads on the same engine actor). Returns
    /// whether the default changed.
    @discardableResult
    public func setDefaultModel(_ id: ModelID) async throws -> Bool {
        guard managers[id] != nil else {
            throw ModelManagementError.unsupportedModel(id)
        }
        guard id != defaultModelID else { return false }
        if case .inference = await defaultManager.state {
            throw ModelManagementError.busy
        }
        return try await withActivity(.loading(id)) {
            let previous = defaultManager
            defaultModelID = id
            residency.current = id
            await previous.releaseResidentRuntime()
            await managers[id]!.loadResidentRuntime()
            return true
        }
    }

    // MARK: - Runtime

    /// Reloads the resident runtime under `units` (Speech Models › Runtime)
    /// as `.reloadingUnits`. Refused with `.busy` while the default model
    /// is transcribing, because the engine would refuse too and the card
    /// should say why before anything moves; refused with
    /// `ModelActivityRefusal` while any other activity runs. `setComputeUnits`
    /// reaches the engine directly (never through a manager), so
    /// `ModelPackageManager.state` stays `.ready` for the whole multi-second
    /// reload while `engine.loadedModelID` is transiently `nil` — the
    /// activity, not the package state, is what tells the other callers to
    /// wait. The engine keeps the choice for the next load even when
    /// nothing is resident yet, so this is also how the persisted setting
    /// is applied before the launch refresh.
    public func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        if case .inference = await defaultManager.state {
            throw ModelManagementError.busy
        }
        try await withActivity(.reloadingUnits) {
            try await engine.setComputeUnits(units)
        }
        computeUnitsBox.current = units
        // 2026-09-29: a reload under new units is a Core ML build of the
        // resident model under them; the next launch's load of the same
        // combination is a cached one.
        if let compileRecord, let package = await residentPackage(), package.ownership != .systemManaged {
            await compileRecord.recordCompiled(ModelCompileKey(
                modelID: package.manifest.modelID,
                revision: package.manifest.source.revision,
                computeUnits: units
            ))
        }
    }

    /// Releases the default model's runtime while keeping it verified and
    /// selected (memory-pressure warnings: "Unload model now" and the
    /// critical-pressure auto-unload) as `.unloading`. Refused with
    /// `ModelActivityRefusal` while any other activity runs; still a no-op
    /// on the manager while a job holds it — the shell checks the
    /// `.unloadModel` availability row first, so the ordinary case surfaces
    /// as "finish the current dictation" and this refusal catches the
    /// narrower race with a reload.
    public func unloadResidentRuntime() async throws {
        try await withActivity(.unloading) {
            await defaultManager.releaseResidentRuntime()
        }
    }

    /// Reloads the default model's runtime if it is verified and the
    /// manager is idle, as `.loading(default)`; a no-op on the manager
    /// otherwise. Refused with `ModelActivityRefusal` while another
    /// activity is already in flight — this is what stops the prerequisite
    /// checker's reload-on-unload kickoff from racing a `setComputeUnits`
    /// reload (2026-09-14 review). Used to bring a memory-pressure-unloaded
    /// model back once the prerequisite check for a new dictation notices
    /// it is missing.
    public func reloadResidentRuntimeIfNeeded() async throws {
        try await withActivity(.loading(defaultModelID)) {
            await defaultManager.loadResidentRuntime()
        }
    }

    /// Load and last-pass timings from the engine.
    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        get async { await engine.runtimeStatistics }
    }

    /// The default model's verified package when the engine holds it, for
    /// the placement report. Nil while nothing is resident.
    public func residentPackage() async -> InstalledModelPackage? {
        guard await isDefaultModelResident() else { return nil }
        return try? await defaultManager.verifiedPackage()
    }

    // MARK: - Refresh and restore

    /// Refreshes every manager, the default first so the resident runtime
    /// comes back before the others are verified. Runs as
    /// `.installing(default)` because a refresh can verify and load; it
    /// is non-throwing (it runs at launch and on every activation, and
    /// failures stay visible through `state`), so a refusal — another
    /// activity is running, and the managers would have skipped
    /// themselves anyway — is returned rather than thrown.
    @discardableResult
    public func refresh() async -> ModelActivityRefusal? {
        do {
            try await withActivity(.installing(defaultModelID)) {
                await defaultManager.refresh()
                for id in modelIDs where id != defaultModelID {
                    await managers[id]!.refresh()
                }
                await overlayObservedLanguages()
            }
            return nil
        } catch let refusal as ModelActivityRefusal {
            return refusal
        } catch {
            return nil
        }
    }

    /// Restores a persisted external selection for whichever entry it names
    /// and refreshes everything else, as `.installing` of that entry (or
    /// the default). Same refusal contract as `refresh()`.
    @discardableResult
    public func restoreSelectedModel(_ reference: ModelReference?) async -> ModelActivityRefusal? {
        let referencedID: ModelID?
        switch reference {
        case let .external(_, expectedModelID, _): referencedID = expectedModelID
        case let .managed(modelID, _): referencedID = modelID
        case nil: referencedID = nil
        }
        do {
            try await withActivity(.installing(referencedID ?? defaultModelID)) {
                if let referencedID, let manager = managers[referencedID] {
                    await manager.restoreSelectedModel(reference)
                }
                await defaultManager.refresh()
                for id in modelIDs where id != defaultModelID && id != referencedID {
                    await managers[id]!.refresh()
                }
                await overlayObservedLanguages()
            }
            return nil
        } catch let refusal as ModelActivityRefusal {
            return refusal
        } catch {
            return nil
        }
    }

    // MARK: - Per-model operations

    /// The install transaction (download → verify → install → load when
    /// `id` is the default) as `.downloading(id)`; `resume` and `retry`
    /// are the same transaction. `cancel` is not an activity: it makes the
    /// running one throw, which returns the library to `.idle`.

    public func install(_ id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.downloading(id)) { try await manager.installRecommendedModel() }
    }

    public func resume(_ id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.downloading(id)) { try await manager.resumeInstallation() }
    }

    public func retry(_ id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.downloading(id)) { try await manager.retryInstallation() }
    }

    public func cancel(_ id: ModelID) async {
        await managers[id]?.cancelInstallation()
    }

    public func delete(_ id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.installing(id)) { try await manager.deleteManagedPackage() }
    }

    public func selectExternalPackage(at url: URL, for id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.installing(id)) { try await manager.selectExternalPackage(at: url, modelID: id) }
    }

    public func forgetExternalPackage(for id: ModelID) async throws {
        let manager = try require(id)
        try await withActivity(.installing(id)) { await manager.forgetExternalPackage() }
    }

    public func installationSpaceEstimate(for id: ModelID) async -> ModelInstallationSpaceEstimate? {
        await managers[id]?.installationSpaceEstimate()
    }

    public func verifiedPackage(for id: ModelID) async throws -> InstalledModelPackage {
        try await require(id).verifiedPackage()
    }

    public func installedPackageSummary(for id: ModelID) async -> InstalledModelSummary? {
        await managers[id]?.installedPackageSummary()
    }

    /// The reference to persist for `id`, or nil when nothing is selected.
    public func modelReference(for id: ModelID) async -> ModelReference? {
        await managers[id]?.currentModelReference()
    }

    private func require(_ id: ModelID) throws -> ModelManagerReference {
        guard let manager = managers[id] else {
            throw ModelManagementError.unsupportedModel(id)
        }
        return manager
    }

    // MARK: - Default-model façade (ModelPackageProviding)

    public func installRecommendedModel() async throws {
        try await install(defaultModelID)
    }

    public func resumeInstallation() async throws {
        try await resume(defaultModelID)
    }

    public func retryInstallation() async throws {
        try await retry(defaultModelID)
    }

    public func cancelInstallation() async {
        await defaultManager.cancelInstallation()
    }

    public func selectExternalPackage(at url: URL) async throws {
        try await selectExternalPackage(at: url, for: defaultModelID)
    }

    public func forgetExternalPackage() async throws {
        try await forgetExternalPackage(for: defaultModelID)
    }

    public func deleteManagedPackage() async throws {
        try await delete(defaultModelID)
    }

    public func verifiedPackage() async throws -> InstalledModelPackage {
        try await defaultManager.verifiedPackage()
    }

    public func installationSpaceEstimate() async -> ModelInstallationSpaceEstimate {
        await defaultManager.installationSpaceEstimate()
    }

    public func currentModelReference() async -> ModelReference? {
        await defaultManager.currentModelReference()
    }

    public func installedPackageSummary() async -> InstalledModelSummary? {
        await defaultManager.installedPackageSummary()
    }

    public func beginInference(jobID: JobID) async throws {
        try await defaultManager.beginInference(jobID: jobID)
    }

    public func endInference(jobID: JobID) async {
        await defaultManager.endInference(jobID: jobID)
    }
}
