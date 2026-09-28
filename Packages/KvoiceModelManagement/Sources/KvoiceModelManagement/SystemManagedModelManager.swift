import Foundation
import KvoiceDomain

/// The per-model lifecycle of a catalog entry whose weights the OS owns
/// (ADR-025: Apple Speech through `AssetInventory`), the counterpart of
/// `ModelPackageManager` for a `.systemManaged` entry.
///
/// Nothing is downloaded, hashed or stored by kvoice: the platform fetches,
/// verifies and shares the assets, and this actor only *observes* them
/// through `SystemManagedModelAssets` and turns the answer into the same
/// `ModelLifecycleState` the cards, the status menu and the prerequisite
/// check already read. The one twist is that the platform's assets are per
/// locale, so "installed" is only meaningful for the transcription language
/// in use: the library forwards `AppSettings.transcriptionLanguage` through
/// `setLanguageCode`, and a change re-observes the state.
///
/// Mapping (`SystemManagedAssetState` → `ModelLifecycleState`):
/// `.unavailable(reason)` → `.unavailable` (shown, no action);
/// `.notInstalled` → `.absent` (Download); `.downloading` → `.downloading`
/// (percent, not bytes); `.installed` → `.ready` — and, when this model is
/// the default, the resident engine is loaded through the residency-gated
/// loader exactly as for a verified package.
///
/// Install = `installAssets` (the platform reserves the locale and downloads
/// what it lacks); Delete = `releaseAssets` (the reservation goes, the
/// platform removes the files later). Retry and Resume are Install again:
/// the platform consolidates requests and resumes on its own.
public actor SystemManagedModelManager {
    public private(set) var state: ModelLifecycleState = .absent
    public nonisolated let modelID: ModelID
    /// The package handed to the engine: identity only, nothing on disk.
    public nonisolated let package: InstalledModelPackage

    private let entry: SpeechModelCatalogEntry
    private let assets: any SystemManagedModelAssets
    private let runtimeLoader: any ModelRuntimeLoader
    /// The transcription language the state describes (`setLanguageCode`).
    public private(set) var languageCode: String?
    /// True when `state` describes the platform's answer **for the current
    /// `languageCode`**: false before the first observation (the
    /// constructor's `.absent` says nothing about the assets), and false
    /// again from the moment `setLanguageCode` takes a new code until the
    /// observation for it has landed — the platform calls suspend for
    /// over a second, and a reader that arrives in between must not take
    /// the old language's state for the new one. The library's automatic
    /// install (ADR-025 amendment) decides only on an observed state.
    public private(set) var hasObservedAssets = false

    /// The three facts the library's automatic install reads, taken in
    /// one actor turn so they cannot tear across the reentrancy of a
    /// suspended refresh (the swift-reviewer's finding on this piece).
    public struct Snapshot: Sendable, Equatable {
        public let languageCode: String?
        public let hasObservedAssets: Bool
        public let state: ModelLifecycleState

        public init(languageCode: String?, hasObservedAssets: Bool, state: ModelLifecycleState) {
            self.languageCode = languageCode
            self.hasObservedAssets = hasObservedAssets
            self.state = state
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(languageCode: languageCode, hasObservedAssets: hasObservedAssets, state: state)
    }
    private var activeJobID: JobID?
    private var installTask: Task<Void, any Error>?
    private var observedLanguageCodes: [String] = []

    public init(
        entry: SpeechModelCatalogEntry,
        assets: any SystemManagedModelAssets,
        runtimeLoader: any ModelRuntimeLoader,
        languageCode: String? = nil
    ) {
        self.entry = entry
        modelID = entry.id
        package = .systemManaged(modelID: entry.id, family: entry.family)
        self.assets = assets
        self.runtimeLoader = runtimeLoader
        self.languageCode = languageCode
    }

    // MARK: - Language

    /// The transcription language whose assets the state describes. A
    /// change re-observes the platform (cheap) so the card follows the
    /// language picker; the same value is a no-op.
    public func setLanguageCode(_ code: String?) async {
        guard code != languageCode else { return }
        languageCode = code
        // `state` is the old language's until the observation below lands
        // (and it does not land at all while a job holds the model —
        // `refresh` skips; the library re-observes on its next idle poll).
        hasObservedAssets = false
        await refresh()
    }

    /// The language codes the platform reported at the last refresh
    /// (`SystemManagedModelAssets.supportedLanguageCodes`), for the
    /// library's catalog overlay; empty until observed or when unavailable.
    public var supportedLanguageCodes: [String] {
        observedLanguageCodes
    }

    // MARK: - Refresh

    /// Re-reads the platform's state for the current language. Loads the
    /// runtime when the assets are installed (the loader decides whether
    /// this model is the resident one) and releases it when they are not.
    public func refresh() async {
        guard activeJobID == nil, installTask == nil else { return }
        observedLanguageCodes = await assets.supportedLanguageCodes()
        await observe()
    }

    private func observe() async {
        let observedCode = languageCode
        switch await assets.assetState(languageCode: observedCode) {
        case .unavailable(let reason):
            await runtimeLoader.unload()
            state = .unavailable(reason.modelFailure)
        case .notInstalled:
            // The engine may hold this model for another language; the
            // chosen one has no assets, so it cannot serve a dictation
            // (the residency-gated loader makes this a no-op otherwise).
            await runtimeLoader.unload()
            state = .absent
        case .downloading(let fraction):
            await runtimeLoader.unload()
            state = .downloading(completed: Self.percent(fraction), total: 100)
        case .installed:
            do {
                try await runtimeLoader.load(package)
                state = .ready(summary)
            } catch {
                state = .error(ModelFailure(code: "MODEL-RUNTIME-FAILED", message: error.localizedDescription))
            }
        }
        // Only once `state` is assigned, and only if the language did not
        // move underneath the platform call (a second `setLanguageCode`
        // during the suspension re-observes on its own).
        if observedCode == languageCode {
            hasObservedAssets = true
        }
    }

    // MARK: - Installation

    public func installRecommendedModel() async throws {
        guard activeJobID == nil else { throw ModelManagementError.busy }
        guard installTask == nil else { throw ModelManagementError.busy }
        if case .unavailable = state {
            // Refuse before touching the platform: the card already says why.
            throw ModelManagementError.unsupportedModel(modelID)
        }
        // The platform reserves the locale before it downloads. If the app
        // held no reservation before this install, a failed or cancelled
        // one must give the slot back — the card cannot release what it
        // never showed as installed (the adapter does the same one level
        // down; `release` is harmless when nothing is reserved).
        let heldReservationBefore = isReadyOrInInference
        state = .downloading(completed: 0, total: 100)
        let languageCode = languageCode
        let assets = assets
        let task = Task<Void, any Error> {
            try await assets.installAssets(languageCode: languageCode) { fraction in
                await self.applyProgress(fraction)
            }
        }
        installTask = task
        defer { installTask = nil }
        do {
            try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
        } catch is CancellationError {
            await releaseAfterFailedInstall(heldReservationBefore: heldReservationBefore)
            await observe()
            throw ModelManagementError.cancelled
        } catch let error as SystemManagedAssetError {
            await releaseAfterFailedInstall(heldReservationBefore: heldReservationBefore)
            state = .error(error.modelFailure)
            throw ModelManagementError.downloadFailed(error.message)
        } catch {
            await releaseAfterFailedInstall(heldReservationBefore: heldReservationBefore)
            state = .error(ModelFailure(code: "MODEL-ASSET-DOWNLOAD-FAILED", message: error.localizedDescription))
            throw ModelManagementError.downloadFailed(error.localizedDescription)
        }
        await observe()
    }

    private func releaseAfterFailedInstall(heldReservationBefore: Bool) async {
        guard !heldReservationBefore else { return }
        try? await assets.releaseAssets(languageCode: languageCode)
    }

    private func applyProgress(_ fraction: Double) {
        guard installTask != nil, case .downloading = state else { return }
        state = .downloading(completed: Self.percent(fraction), total: 100)
    }

    /// The platform resumes on its own; asking again is the resume.
    public func resumeInstallation() async throws {
        try await installRecommendedModel()
    }

    public func retryInstallation() async throws {
        try await installRecommendedModel()
    }

    public func cancelInstallation() async {
        installTask?.cancel()
    }

    // MARK: - Deletion

    /// Releases the reservation for the current language. Refused while a
    /// job holds the model or an install runs. Accepted from `.error` too:
    /// a failed install may have left a reservation, and Delete is the
    /// card's way to give the slot back.
    public func deleteManagedPackage() async throws {
        guard activeJobID == nil, installTask == nil else { throw ModelManagementError.busy }
        switch state {
        case .ready, .error: break
        default: throw ModelManagementError.noManagedPackage
        }
        state = .deleting(summary)
        await runtimeLoader.unload()
        do {
            try await assets.releaseAssets(languageCode: languageCode)
        } catch let error as SystemManagedAssetError {
            state = .error(error.modelFailure)
            throw ModelManagementError.deleteFailed(error.message)
        } catch {
            state = .error(ModelFailure(code: "MODEL-ASSET-RELEASE-FAILED", message: error.localizedDescription))
            throw ModelManagementError.deleteFailed(error.localizedDescription)
        }
        await observe()
    }

    // MARK: - Inference reservation

    public func verifiedPackage() throws -> InstalledModelPackage {
        guard isReadyOrInInference else { throw ModelManagementError.noVerifiedPackage }
        return package
    }

    public func beginInference(jobID: JobID) throws {
        guard installTask == nil else { throw ModelManagementError.busy }
        guard case .ready = state else { throw ModelManagementError.noVerifiedPackage }
        activeJobID = jobID
        state = .inference(summary, jobID: jobID)
    }

    public func endInference(jobID: JobID) {
        guard activeJobID == jobID else { return }
        activeJobID = nil
        state = .ready(summary)
    }

    public func installedPackageSummary() -> InstalledModelSummary? {
        isReadyOrInInference ? summary : nil
    }

    /// What the settings file remembers: the system revision, so a later
    /// launch restores the same entry as the selection.
    public func currentModelReference() -> ModelReference? {
        isReadyOrInInference ? .managed(modelID: modelID, revision: InstalledModelPackage.systemManagedRevision) : nil
    }

    /// Nothing lands on kvoice's disk: the platform stores the assets.
    public func installationSpaceEstimate() -> ModelInstallationSpaceEstimate {
        ModelInstallationSpaceEstimate(remainingDownloadBytes: 0, workingSpaceBytes: 0, availableBytes: nil)
    }

    // MARK: - Residency (ADR-017)

    public func loadResidentRuntime() async {
        guard activeJobID == nil, installTask == nil, isReadyOrInInference else { return }
        do {
            try await runtimeLoader.load(package)
        } catch {
            state = .error(ModelFailure(code: "MODEL-RUNTIME-FAILED", message: error.localizedDescription))
        }
    }

    public func releaseResidentRuntime() async {
        guard activeJobID == nil, installTask == nil, isReadyOrInInference else { return }
        await runtimeLoader.unload()
    }

    // MARK: - Helpers

    private var isReadyOrInInference: Bool {
        switch state {
        case .ready, .inference: return true
        default: return false
        }
    }

    private var summary: InstalledModelSummary {
        InstalledModelSummary(modelID: modelID, revision: InstalledModelPackage.systemManagedRevision, ownership: .systemManaged)
    }

    private static func percent(_ fraction: Double) -> Int64 {
        Int64((min(max(fraction, 0), 1) * 100).rounded())
    }
}
