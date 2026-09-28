import Foundation
import KvoiceAI
import KvoiceAppleIntelligence
import KvoiceAppleSpeech
import KvoiceAppCore
import KvoiceAudio
import KvoiceDiagnostics
import KvoiceDomain
import KvoiceHotkeys
import KvoiceInsertion
import KvoiceModelManagement
import KvoiceParakeet
import KvoicePersistence
import KvoiceTranscription
import KvoiceUI

/// The one application composition root for the M2 process.
///
/// These are concrete instances, not a service registry: each service is
/// created exactly once and the controller receives the same resident engine
/// that the model manager loads. Trust material is optional at launch because
/// this checkout intentionally has no known-good production manifest. In that
/// case the app remains usable for onboarding and Skip, while model actions
/// fail closed with a recoverable Not Ready state.
@MainActor
final class AppComposition {
    /// ADR-026: which distribution this bundle is, read once from its
    /// Info.plist (`KvoiceDistributionEdition`) and injected from here — the
    /// insertion service, the permission adapter, the hotkey adapter, the
    /// auto-send trust check, the legacy defaults copy and the environment
    /// profile's availability rows all follow it.
    let edition: DistributionEdition
    /// ADR-022 slice 5: the developer-defaults layer, read once here and
    /// handed to every consumer at construction — no global, nothing
    /// re-reads a file. `overrideOutcome` is logged after the diagnostics
    /// sinks exist (`logLaunchOutcomes`).
    let developerDefaults: LoadedDeveloperDefaults
    /// 2026-09-27: what the one-time copy of the `com.kccarlos.kvoice`
    /// defaults domain did this launch; logged after the diagnostics sinks
    /// exist (`logLaunchOutcomes`).
    /// `nil` when the edition does not run it (ADR-026: the App Store
    /// edition cannot read another identifier's defaults domain).
    let legacyDefaultsMigration: LegacyDefaultsDomainMigration.Outcome?
    let settingsStore: SettingsStore
    /// ADR-022 slice 5: the machine-local blob beside the settings blob.
    let localStateStore: LocalStateStore
    let secretsStore: SecretsFileStore
    let historyStore: HistorySQLiteStore
    /// History and data: opt-in WAVs next to the database, the Auto Daily
    /// Export writer, and the daily retention pass. Wired to the controller
    /// and the History section in `AppDelegate+History.swift`.
    let historyAudioStore: HistoryAudioFileStore
    let autoDailyExporter: AutoDailyExporter
    let historyMaintenance: HistoryMaintenance
    /// The OpenAI-compatible endpoint client. Held on its own for what only
    /// an endpoint has: model discovery (`availableModels`).
    let aiClient: OpenAICompatibleAIProcessingClient
    /// ADR-024: Apple's on-device model. Held on its own for the one thing
    /// the shell reads from it directly, the availability fact
    /// (`EnvironmentProfile.appleIntelligenceAvailability`).
    let appleIntelligenceClient: AppleIntelligenceProcessingClient
    /// ADR-027: Apple's server model on Private Cloud Compute — the same
    /// client type over `PrivateCloudComputeRuntime`. Built with the
    /// edition / signature refusal, so the Developer ID edition and every
    /// unentitled build never ask the framework anything. Held on its own
    /// for the availability and quota facts and the "Show Options…" hook.
    let privateCloudComputeClient: AppleIntelligenceProcessingClient
    /// ADR-024: the one client the request paths call — the job runner, the
    /// Selection Action runner, the prompt preview and the configuration
    /// test — routing by `AIEndpointSettings.provider`.
    let aiProcessingClient: AIProviderRoutingClient
    let audioRecorder: AVAudioCaptureService
    let residentWhisperEngine: WhisperTranscriptionEngine
    /// ADR-019: the Parakeet engine behind FluidAudio. Both per-runtime
    /// engines exist for the life of the process; `residentEngine` routes
    /// a load to the one the catalog names for the model.
    let residentParakeetEngine: ParakeetTranscriptionEngine
    /// ADR-025: Apple's `SpeechAnalyzer` behind the Speech framework
    /// (macOS 26+; below that every call reports "requires macOS 26"). Held
    /// on its own for the one thing the shell tells it directly: the
    /// transcription language (its warm-up locale).
    let residentAppleSpeechEngine: AppleSpeechTranscriptionEngine
    /// The one engine the library loads into and the shell reads runtime
    /// facts (compute units, resident runtime) from.
    let residentEngine: RuntimeSwitchingTranscriptionEngine
    let transcriptionEngine: ResidentModelTranscriptionEngine
    /// ADR-017: one manager per catalog model behind one library. Named as
    /// before because the shell addresses the default model through the
    /// manager's method names.
    let modelManager: SpeechModelLibrary?
    let modelTrustFailure: ModelFailure?
    /// ADR-026: `AXTextInsertionService` (Developer ID) or
    /// `TypedTextInsertionService` (App Store).
    let insertionService: any EditionTextInsertionService
    /// Scalar-only sinks shared by the insertion service and the Selection
    /// Action runner (rule 3: never transcript text, audio, or secrets).
    let diagnostics: any DiagnosticLogging
    let shortcutAdapter: KeyboardShortcutsAdapter
    let hudController: HUDController
    /// The one cue player: the controller plays a job's cues through it,
    /// and the Recording page's Preview button plays a start cue through
    /// the same instance (`AppDelegate.installTriggers`).
    let feedbackPlayer: SystemRecordingFeedbackPlayer
    let dictationController: DictationController
    let onboardingIntentRouter: AppOnboardingIntentRouter
    let onboardingViewModel: OnboardingViewModel
    let microphonePermission: any MicrophonePermissionProviding
    let accessibilityPermission: any AccessibilityPermissionProviding
    /// Later waves: memory-pressure warnings. System-wide, not this
    /// process's footprint (`MemoryPressureObserving`'s doc comment). One
    /// instance for the process's life; `AppDelegate+Memory.swift` consumes
    /// its stream once and fans the level out to the status menu and the
    /// Runtime card's shared `MemoryPressureViewModel`.
    let memoryPressureObserver: any MemoryPressureObserving
    /// The one Mach/IOKit telemetry adapter: the Runtime card samples it,
    /// the memory-pressure diagnostic reads the footprint bucket from it,
    /// and the slow poll fills `EnvironmentProfile` from it.
    let runtimeTelemetry: SystemRuntimeTelemetryProvider

    init(
        edition: DistributionEdition,
        trustedRelease: WhisperModelReleaseTrustAnchor? = nil,
        trustLoader: any AppTrustedModelReleaseLoading = BundledTrustedModelReleaseLoader(),
        storageDirectoryURL: URL? = nil,
        microphonePermission: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        accessibilityPermission: (any AccessibilityPermissionProviding)? = nil,
        makeModelDownloader: @escaping @Sendable () -> any ModelDownloadClient = { URLSessionModelDownloadClient() },
        modelURLProvider: any ModelDownloadURLProviding = PinnedHuggingFaceModelURLProvider(),
        catalogLoader: any SpeechModelCatalogLoading = BundledSpeechModelCatalogLoader(),
        developerDefaultsLoader: DeveloperDefaultsLoader = .standard()
    ) {
        // Before any store or KeyboardShortcuts reads the standard defaults:
        // bring the pre-2026-09-27 bundle identifier's domain across once.
        // Developer ID edition only: a sandboxed process reads its
        // container's preferences, never another identifier's (ADR-026).
        let legacyDefaultsMigration = edition.migratesLegacyDefaultsDomain
            ? LegacyDefaultsDomainMigration.standard().run()
            : nil
        // ADR-026: the permission the "Accessibility" card and onboarding
        // step ask for — full Accessibility trust, or the PostEvent
        // privilege a sandboxed app can hold.
        let accessibilityPermission: any AccessibilityPermissionProviding = accessibilityPermission
            ?? (edition.canControlOtherAppsThroughAccessibility
                ? SystemAccessibilityPermissionAdapter()
                : EventPostingPermissionAdapter())
        // The first read of the process: everything below is built from it.
        let developerDefaults = developerDefaultsLoader.load()
        let tunables = developerDefaults.values
        let settingsStore = SettingsStore()
        let localStateStore = LocalStateStore()
        let secretsStore = SecretsFileStore()
        let historyStore = HistorySQLiteStore()
        // Both read the persisted settings on every pass rather than a
        // captured copy, so a retention or folder change applies without a
        // relaunch; `AppSettings` carries no secret, so this costs nothing.
        let historyAudioStore = HistoryAudioFileStore()
        let currentSettings: @Sendable () async -> AppSettings = {
            (try? await settingsStore.load()) ?? AppSettings()
        }
        let currentLocalState: @Sendable () async -> LocalState = {
            (try? await localStateStore.load()) ?? .fresh
        }
        let autoDailyExporter = AutoDailyExporter(
            settingsProvider: currentSettings,
            localStateProvider: currentLocalState
        )
        let historyMaintenance = HistoryMaintenance(
            repository: historyStore,
            audioStore: historyAudioStore,
            settingsProvider: currentSettings
        )
        let aiClient = OpenAICompatibleAIProcessingClient()
        let appleIntelligenceClient = AppleIntelligenceProcessingClient()
        // ADR-027: the edition decides first (Apple offers Private Cloud
        // Compute to App Store distribution only); the signature second.
        let privateCloudComputeClient = AppleIntelligenceProcessingClient.privateCloudCompute(
            staticRefusal: edition.privateCloudComputeRefusal(
                isEntitled: edition.offersPrivateCloudCompute
                    && PrivateCloudComputeSigning.currentProcessIsEntitled()
            )
        )
        let aiProcessingClient = AIProviderRoutingClient(
            endpoint: aiClient,
            onDevice: appleIntelligenceClient,
            privateCloudCompute: privateCloudComputeClient
        )
        let audioRecorder = AVAudioCaptureService(
            signalPeakThresholdDBFS: tunables.signalPeakThresholdDBFS
        )

        // The app-bundled manifest stays a trust anchor for the uncompressed
        // package; ADR-017's catalog carries every downloadable entry and
        // is the material the library is built from.
        let release: WhisperModelReleaseTrustAnchor?
        if let trustedRelease {
            release = trustedRelease
        } else {
            release = try? trustLoader.load()
        }

        // The engine needs its anchors before the library exists, and the
        // library needs the engine; load the catalog once for both.
        let loadedCatalog: LoadedSpeechModelCatalog?
        var trustFailure: ModelFailure?
        do {
            loadedCatalog = try catalogLoader.load()
        } catch {
            loadedCatalog = nil
            trustFailure = ModelFailure(
                code: "model.trust.materialUnavailable",
                message: error.localizedDescription
            )
        }
        var anchors = loadedCatalog.map { Array($0.anchors.values) } ?? []
        if let release, !anchors.contains(where: { $0.manifest == release.manifest }) {
            anchors.append(release)
        }
        // Scalar-only diagnostics. Without this the app emitted no log at all,
        // so a clipboard fallback could not be told apart from a successful
        // insertion. Both sinks are used because OSLog is not always readable —
        // this machine's local log store is corrupt — so the file is the
        // reliable one:
        //   tail -f ~/Library/Application\ Support/kvoice/diagnostics.jsonl
        // Built before the engines so their load-failure and warm-up events
        // (ADR-022 items 8 and 9) have a sink; until 2026-09-14 the Whisper
        // engine's `diagnostics` was never wired here.
        let diagnostics = CompositeDiagnosticLogger([
            OSLogDiagnosticLogger(),
            FileDiagnosticLogger()
        ])
        let residentWhisperEngine = WhisperTranscriptionEngine(
            trustedReleases: anchors,
            streamingPolicy: WhisperStreamingPolicy(speechGate: tunables.speechGate),
            diagnostics: diagnostics
        )
        let residentParakeetEngine = ParakeetTranscriptionEngine(
            runtime: FluidAudioParakeetRuntime(),
            trustedReleases: anchors,
            diagnostics: diagnostics
        )
        // ADR-025: one framework runtime shared by the engine (analysis)
        // and the assets adapter (AssetInventory), so both map the
        // transcription language to the same platform locale.
        let appleSpeechRuntime = SpeechFrameworkRuntime()
        let residentAppleSpeechEngine = AppleSpeechTranscriptionEngine(
            runtime: appleSpeechRuntime,
            diagnostics: diagnostics
        )
        // With no catalog there is nothing to route; an empty catalog makes
        // every load fail closed as `unknownModel`, which is the state the
        // trust failure below already reports.
        let residentEngine = RuntimeSwitchingTranscriptionEngine(
            catalog: loadedCatalog?.catalog ?? SpeechModelCatalog(entries: []),
            factory: StaticSpeechRuntimeFactory(engines: [
                .whisperKitCoreML: residentWhisperEngine,
                .fluidAudioParakeetTDT: residentParakeetEngine,
                .fluidAudioParakeetUnified: residentParakeetEngine,
                .fluidAudioNemotronStreaming: residentParakeetEngine,
                .fluidAudioSenseVoice: residentParakeetEngine,
                .fluidAudioParaformer: residentParakeetEngine,
                .fluidAudioParakeetEOU: residentParakeetEngine,
                .appleSpeech: residentAppleSpeechEngine
            ])
        )

        let modelManager: SpeechModelLibrary?
        if let loadedCatalog {
            do {
                modelManager = try SpeechModelLibrary(
                    loaded: loadedCatalog,
                    storageDirectoryURL: storageDirectoryURL
                        ?? ModelPackageManager.defaultStorageDirectoryURL(),
                    engine: residentEngine,
                    makeDownloader: makeModelDownloader,
                    urlProvider: modelURLProvider,
                    // ADR-022 item 5: the `model.activity.refused` lines.
                    diagnosticLogger: diagnostics,
                    // ADR-025: the system-managed entry's assets. The
                    // transcription language follows once settings load
                    // (`restoreSelectedModelFromSettings`) and on every
                    // change after that.
                    systemAssets: [.appleSpeech: AppleSpeechModelAssets(runtime: appleSpeechRuntime)]
                )
            } catch {
                modelManager = nil
                trustFailure = ModelFailure(
                    code: "model.trust.materialUnavailable",
                    message: error.localizedDescription
                )
            }
        } else {
            modelManager = nil
        }
        // Immutable from here on: the prerequisite checker below captures it.
        let modelTrustFailure = trustFailure

        let transcriptionEngine = ResidentModelTranscriptionEngine(
            engine: residentEngine,
            modelManager: modelManager
        )
        let insertionService: any EditionTextInsertionService
        switch edition.insertionStrategy {
        case .accessibilityThenTyped:
            insertionService = AXTextInsertionService(
                diagnostics: diagnostics,
                typedChunkPacing: tunables.typedChunkPacing,
                focusRetryCount: tunables.axFocusRetryCount,
                focusRetryDelay: tunables.axFocusRetryDelay
            )
        case .typedOnly:
            insertionService = TypedTextInsertionService(
                typedChunkPacing: tunables.typedChunkPacing,
                diagnostics: diagnostics
            )
        }
        let shortcutAdapter = KeyboardShortcutsAdapter(
            globalInputMonitorsAvailable: edition.hasGlobalInputMonitors
        )
        let hudController = HUDController(dismissTimings: tunables.hudDismissTimings)
        let onboardingIntentRouter = AppOnboardingIntentRouter()
        let onboardingViewModel = OnboardingViewModel(
            modelState: modelTrustFailure.map { .error($0) } ?? .absent,
            microphonePermission: microphonePermission,
            audioCapture: audioRecorder,
            accessibilityPermission: accessibilityPermission,
            edition: edition,
            onIntent: { [weak onboardingIntentRouter] intent in
                onboardingIntentRouter?.send(intent)
            }
        )

        self.edition = edition
        self.developerDefaults = developerDefaults
        self.legacyDefaultsMigration = legacyDefaultsMigration
        self.settingsStore = settingsStore
        self.localStateStore = localStateStore
        self.secretsStore = secretsStore
        self.historyStore = historyStore
        self.historyAudioStore = historyAudioStore
        self.autoDailyExporter = autoDailyExporter
        self.historyMaintenance = historyMaintenance
        self.aiClient = aiClient
        self.appleIntelligenceClient = appleIntelligenceClient
        self.privateCloudComputeClient = privateCloudComputeClient
        self.aiProcessingClient = aiProcessingClient
        self.audioRecorder = audioRecorder
        self.residentWhisperEngine = residentWhisperEngine
        self.residentParakeetEngine = residentParakeetEngine
        self.residentAppleSpeechEngine = residentAppleSpeechEngine
        self.residentEngine = residentEngine
        self.transcriptionEngine = transcriptionEngine
        self.modelManager = modelManager
        self.modelTrustFailure = modelTrustFailure
        self.insertionService = insertionService
        self.diagnostics = diagnostics
        self.shortcutAdapter = shortcutAdapter
        self.hudController = hudController
        self.onboardingIntentRouter = onboardingIntentRouter
        self.onboardingViewModel = onboardingViewModel
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.memoryPressureObserver = SystemMemoryPressureObserver()
        self.runtimeTelemetry = SystemRuntimeTelemetryProvider()
        let feedbackPlayer = SystemRecordingFeedbackPlayer()
        self.feedbackPlayer = feedbackPlayer
        // C.5 step 3 / FR-PERM-002: the controller verifies microphone
        // permission and model readiness before any engine start, and a
        // blocked start is shown in the HUD rather than silently dropped.
        self.dictationController = DictationController(
            audio: audioRecorder,
            transcription: transcriptionEngine,
            insertion: insertionService,
            settings: settingsStore,
            ai: aiProcessingClient,
            secrets: secretsStore,
            history: historyStore,
            // Until 2026-09-16 this argument was omitted, so the controller
            // logged to `NullDiagnosticLogger` and none of its lines — the
            // ADR-022 item 9 `dictation.failed`, the per-job timing on
            // `dictation.completed` — ever reached the file or OSLog.
            diagnosticLogger: diagnostics,
            prerequisiteChecker: {
                switch await microphonePermission.authorization() {
                case .granted:
                    break
                case .notDetermined:
                    return .blocked(.microphoneNotRequested)
                case .denied, .restricted:
                    return .blocked(.microphonePermission)
                }
                if modelTrustFailure != nil {
                    return .blocked(.modelUnavailable)
                }
                guard let modelManager else {
                    return .blocked(.modelUnavailable)
                }
                // The state → prerequisite mapping is the pure
                // `ModelStartPrerequisite.check` (KvoiceAppCore) — the
                // sentence per state is tested there; this closure only
                // gathers the inputs and runs the one side effect.
                let state = await modelManager.state
                // ADR-017: only the default model is resident; another
                // installed model in the engine does not count.
                let isResident = await modelManager.isDefaultModelResident()
                // ADR-025: a system-managed default (Apple Speech) blocks
                // with its own sentence — the assets are per language.
                let isSystemManaged = await modelManager.defaultEntry?.isSystemManaged ?? false
                if ModelStartPrerequisite.wantsReload(state, isResident: isResident) {
                    // Verified but not resident: the launch load hasn't
                    // reached it yet, memory pressure released it ("Unload
                    // model now" or the auto-unload opt-in), or a
                    // Runtime-card compute-units change is reloading it
                    // right now (that reload clears `loadedModelID` for its
                    // duration without ever touching this manager's state).
                    // Every case is Blocked/loading, not a failure — and,
                    // since nothing else would ever ask the engine to load
                    // it again, kick off the reload now so the *next* press
                    // succeeds instead of blocking forever. ADR-022 item 5:
                    // the kickoff is `.loading(default)` under the library's
                    // transition table, so while a compute-units reload (or
                    // any other activity) is in flight it is a refused
                    // transition, never a second, uncoordinated
                    // `engine.load(_:)` (the 2026-09-14 review). The idle
                    // check here only saves a refusal line per press; the
                    // table is the guard.
                    if modelManager.currentActivity == .idle {
                        Task { try? await modelManager.reloadResidentRuntimeIfNeeded() }
                    }
                }
                return ModelStartPrerequisite.check(state, isResident: isResident, isSystemManaged: isSystemManaged)
            },
            // Recording options (product decision #5): sound cues, output
            // muting, and auto-send's Return, each behind a domain protocol.
            feedbackPlayer: feedbackPlayer,
            outputMuter: SystemOutputMuter(),
            // ADR-026: in the App Store edition the Return is posted under
            // the PostEvent grant, since Accessibility trust never comes.
            returnKeySender: edition.canControlOtherAppsThroughAccessibility
                ? AutoSendReturnKeySender()
                : AutoSendReturnKeySender(trust: EventPostingTrustProvider()),
            tunables: DictationController.Tunables(defaults: tunables),
            // ADR-022 item 7: the developer flag as loaded; the shell pushes
            // the resolver's environment-clamped row from the first
            // `refreshSettingsAvailability()` on (`AppDelegate+SettingsCoordinator`).
            overlappingJobs: Resolved(
                tunables.overlappingJobs,
                developerDefaults.provenance(of: .overlappingJobs)
            )
        )
    }

    /// Scalar lines for what launch did before the sinks existed: the
    /// override file's fate (`config.override.loaded` /
    /// `config.override.rejected`) and the legacy defaults copy
    /// (`settings.legacyDomain.migration`); nothing for either when there
    /// was nothing to say. Called once from `applicationDidFinishLaunching`.
    func logLaunchOutcomes() {
        let events = [
            DistributionEdition.launchDiagnostic(
                infoDictionary: Bundle.main.infoDictionary,
                environment: ProcessInfo.processInfo.environment
            ),
            DeveloperDefaultsLoader.diagnosticEvent(for: developerDefaults.overrideOutcome),
            legacyDefaultsMigration.flatMap(LegacyDefaultsDomainMigration.diagnosticEvent(for:))
        ].compactMap { $0 }
        guard !events.isEmpty else { return }
        let diagnostics = diagnostics
        Task {
            for event in events {
                await diagnostics.log(event)
            }
        }
    }
}
