import Foundation
import KvoiceDomain
import Observation

/// Where the active (or expected) model package lives.
public enum ModelSourceDescription: Sendable, Equatable {
    /// Downloaded and owned by kvoice under Application Support.
    case managed(URL)
    /// A user-chosen, read-only folder that kvoice verified but does not own.
    case external(URL)
    /// Nothing installed; `URL` is where a managed download would land.
    case notInstalled(expectedLocation: URL?)
    /// ADR-025: the OS owns the assets (Apple Speech); nothing on kvoice's
    /// disk, no folder to reveal, no external folder to forget.
    case systemManaged

    public var displayName: String {
        switch self {
        case .managed: return String(localized: "Managed by KVoice", bundle: .module)
        case .external: return String(localized: "External folder", bundle: .module)
        case .notInstalled: return String(localized: "Not installed", bundle: .module)
        case .systemManaged: return String(localized: "Managed by macOS", bundle: .module)
        }
    }

    public var location: URL? {
        switch self {
        case .managed(let url), .external(let url): return url
        case .notInstalled(let url): return url
        case .systemManaged: return nil
        }
    }

    public var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }

    public var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

/// A snapshot of the model identity for the Model tab. The app shell builds
/// it from the trusted manifest and, when a package is installed, from that
/// package; the view model never touches the file system.
public struct ModelDescriptor: Sendable, Equatable {
    public var modelID: ModelID
    public var revision: String
    public var source: ModelSourceDescription
    /// Sum of the manifest's file sizes when known.
    public var installedBytes: Int64?
    /// Host of the manifest's download repository, for the network matrix.
    public var repository: String?
    public var manifestSchemaVersion: Int?

    public init(
        modelID: ModelID,
        revision: String,
        source: ModelSourceDescription,
        installedBytes: Int64? = nil,
        repository: String? = nil,
        manifestSchemaVersion: Int? = nil
    ) {
        self.modelID = modelID
        self.revision = revision
        self.source = source
        self.installedBytes = installedBytes
        self.repository = repository
        self.manifestSchemaVersion = manifestSchemaVersion
    }
}

/// Free-space preflight for a download (spec C.2 step 3).
public struct ModelSpaceEstimate: Sendable, Equatable {
    public let requiredBytes: Int64
    public let availableBytes: Int64?

    public init(requiredBytes: Int64, availableBytes: Int64?) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var isSufficient: Bool? {
        availableBytes.map { $0 >= requiredBytes }
    }
}

/// The actions the Model tab can offer. Which ones appear depends on the
/// lifecycle state (FR-MODEL-017: nothing mutating while a job is active).
public enum ModelSettingsAction: String, Sendable, Equatable, CaseIterable, Identifiable {
    case download
    case resume
    case cancel
    case retry
    case chooseExisting
    case revealInFinder
    case delete
    case forget

    public var id: Self { self }

    public var title: String {
        switch self {
        case .download: return String(localized: "Download", bundle: .module)
        case .resume: return String(localized: "Resume", bundle: .module)
        case .cancel: return String(localized: "Cancel", bundle: .module)
        case .retry: return String(localized: "Retry", bundle: .module)
        case .chooseExisting: return String(localized: "Choose Existing…", bundle: .module)
        case .revealInFinder: return String(localized: "Reveal in Finder", bundle: .module)
        case .delete: return String(localized: "Delete", bundle: .module)
        case .forget: return String(localized: "Forget", bundle: .module)
        }
    }

    public var isDestructive: Bool {
        self == .delete || self == .forget
    }

    /// Cancel and Reveal do not mutate the package, so they stay enabled while
    /// the others are locked out.
    public var isMutation: Bool {
        switch self {
        case .cancel, .revealInFinder: return false
        case .download, .resume, .retry, .chooseExisting, .delete, .forget: return true
        }
    }

    /// Actions whose effect shows up as a lifecycle-state change, and which
    /// therefore get an in-flight lock until it does. Choose Existing opens
    /// a panel the user may cancel, and Reveal changes nothing, so neither
    /// waits.
    public var awaitsStateChange: Bool {
        switch self {
        case .download, .resume, .cancel, .retry, .delete, .forget: return true
        case .chooseExisting, .revealInFinder: return false
        }
    }

    /// What the tab says while the shell is still reacting to the click.
    public var inProgressDescription: String {
        switch self {
        case .download: return String(localized: "Starting the download…", bundle: .module)
        case .resume: return String(localized: "Resuming the download…", bundle: .module)
        case .cancel: return String(localized: "Stopping the download…", bundle: .module)
        case .retry: return String(localized: "Retrying…", bundle: .module)
        case .chooseExisting: return String(localized: "Choosing a folder…", bundle: .module)
        case .revealInFinder: return String(localized: "Revealing in Finder…", bundle: .module)
        case .delete: return String(localized: "Removing the package…", bundle: .module)
        case .forget: return String(localized: "Forgetting the folder…", bundle: .module)
        }
    }
}

/// State for the Model tab. The shell pushes lifecycle state and the
/// descriptor in; the view model decides what to show and which actions are
/// offered, and forwards each action to the closure the shell supplied.
@Observable
@MainActor
public final class ModelSettingsViewModel {
    public private(set) var state: ModelLifecycleState
    public private(set) var descriptor: ModelDescriptor?
    /// True while the dictation controller is not idle. Model mutation is
    /// refused then because the running job holds the model.
    public private(set) var dictationIsActive = false
    public private(set) var spaceEstimate: ModelSpaceEstimate?

    /// The state-changing action the user just asked for, until the shell's
    /// published state moves on. The shell reflects a click only on its next
    /// sync tick (up to 250 ms), during which the buttons used to stay live
    /// and a double-click could start two downloads or two deletes. Cleared
    /// when `state` changes, or after `pendingActionTimeout` if the shell
    /// never reacts (for example the Forget hook is not wired).
    public private(set) var pendingAction: ModelSettingsAction?
    /// ADR-017: the catalog half of the Models section (default-model card,
    /// language, per-model cards, Manage Models). Fed through
    /// `SpeechModelsHooks`, so the shell that owns this view model needs no
    /// new plumbing to show it.
    public let speechModels: SpeechModelsViewModel
    /// The Runtime card under the default-model card: placement, compute
    /// units, memory, timings, the performance test, and the sparklines.
    /// Fed through `RuntimeCardHooks`; the shell passes the system telemetry
    /// provider, previews and tests get `NoRuntimeTelemetry`.
    public let runtime: RuntimeCardViewModel
    /// Later waves: memory-pressure warnings. The shell passes its one
    /// app-lifetime instance (the `generalSettingsViewModel` pattern), so
    /// the banner shown here always reflects the same level and unload
    /// state as the status menu.
    public let memoryPressure: MemoryPressureViewModel

    private let onAction: @MainActor (ModelSettingsAction) -> Void
    private let modelSpaceEstimate: @MainActor () async -> ModelSpaceEstimate?
    private let pendingActionTimeout: Duration
    /// Internal (not private) so tests can await the timer they advanced.
    @ObservationIgnored private(set) var pendingActionTask: Task<Void, Never>?
    /// Times the pending-action expiry; tests inject a `ParkingClock`.
    private let clock: any KvoiceClock

    public init(
        state: ModelLifecycleState = .absent,
        descriptor: ModelDescriptor? = nil,
        pendingActionTimeout: Duration = .seconds(5),
        onAction: @escaping @MainActor (ModelSettingsAction) -> Void = { _ in },
        modelSpaceEstimate: @escaping @MainActor () async -> ModelSpaceEstimate? = { nil },
        speechModels: SpeechModelsViewModel = SpeechModelsViewModel(),
        runtime: RuntimeCardViewModel = RuntimeCardViewModel(),
        memoryPressure: MemoryPressureViewModel = MemoryPressureViewModel(),
        clock: any KvoiceClock = SystemKvoiceClock()
    ) {
        self.clock = clock
        self.state = state
        self.descriptor = descriptor
        self.pendingActionTimeout = pendingActionTimeout
        self.onAction = onAction
        self.modelSpaceEstimate = modelSpaceEstimate
        self.speechModels = speechModels
        self.runtime = runtime
        self.memoryPressure = memoryPressure
    }

    // MARK: Inputs from the shell

    // The shell pushes these four times a second. `@Observable` invalidates
    // every reader on each assignment, equal or not, so an unchanged value
    // is dropped here rather than re-rendering the tab on every tick.

    public func setState(_ state: ModelLifecycleState) {
        guard state != self.state else { return }
        self.state = state
        clearPendingAction()
    }

    public func setDescriptor(_ descriptor: ModelDescriptor?) {
        guard descriptor != self.descriptor else { return }
        self.descriptor = descriptor
    }

    public func setDictationActive(_ active: Bool) {
        guard active != dictationIsActive else { return }
        dictationIsActive = active
    }

    public func refreshSpaceEstimate() async {
        spaceEstimate = await modelSpaceEstimate()
    }

    /// Changes whenever the download preflight is worth re-reading: the
    /// estimate only matters while a download can be offered, and free space
    /// moves after a download, a delete, or an install. The view keys its
    /// `.task(id:)` on this.
    public var spaceEstimateKey: String {
        switch state {
        case .absent: return "absent"
        case .downloadPaused: return "paused"
        case .corrupt, .incompatible, .error, .unavailable: return "failed"
        case .ready(let summary): return "ready:\(summary.ownership.rawValue)"
        default: return "busy"
        }
    }

    // MARK: Actions

    public func perform(_ action: ModelSettingsAction) {
        guard availableActions.contains(action), isEnabled(action) else { return }
        if action.awaitsStateChange {
            pendingAction = action
            pendingActionTask?.cancel()
            pendingActionTask = Task { [weak self, pendingActionTimeout, clock] in
                try? await clock.sleep(for: pendingActionTimeout)
                guard !Task.isCancelled, let self, self.pendingAction == action else { return }
                self.clearPendingAction()
            }
        }
        onAction(action)
    }

    public func isEnabled(_ action: ModelSettingsAction) -> Bool {
        !(action.isMutation && mutationDisabledReason != nil)
    }

    private func clearPendingAction() {
        pendingActionTask?.cancel()
        pendingActionTask = nil
        pendingAction = nil
    }

    /// The actions that make sense for the current state, in display order.
    public var availableActions: [ModelSettingsAction] {
        let ownershipActions: [ModelSettingsAction]
        switch descriptor?.source {
        case .managed: ownershipActions = [.revealInFinder, .delete]
        case .external: ownershipActions = [.forget]
        // ADR-025: Delete releases the platform reservation; no folder.
        case .systemManaged: ownershipActions = [.delete]
        case .notInstalled, nil: ownershipActions = []
        }

        switch state {
        case .absent:
            return [.download, .chooseExisting]
        case .downloadPaused:
            return [.resume, .chooseExisting]
        case .downloading:
            return [.cancel]
        case .validatingExternal, .verifying, .installing, .loading, .optimizing, .deleting:
            return []
        case .ready where descriptor?.source == .systemManaged:
            return ownershipActions
        case .ready:
            return ownershipActions + [.chooseExisting]
                + (descriptor?.source.isExternal == true ? [.download] : [])
        case .inference:
            return ownershipActions.filter { !$0.isMutation }
        case .corrupt, .incompatible, .error:
            return [.retry, .chooseExisting] + ownershipActions
        case .unavailable:
            // ADR-025: nothing to retry, nothing to delete; the default
            // model is never a system-managed entry this Mac cannot run,
            // but the state is total here.
            return []
        }
    }

    /// Why mutating actions are disabled, or nil when they are allowed. The
    /// view shows this text beside the buttons rather than leaving them dead.
    public var mutationDisabledReason: String? {
        if let pendingAction {
            return pendingAction.inProgressDescription
        }
        if dictationIsActive {
            return String(localized: "Model changes are unavailable while dictation is running.", bundle: .module)
        }
        switch state {
        case .validatingExternal:
            return String(localized: "Checking the selected folder. Wait for verification to finish.", bundle: .module)
        case .downloading:
            return String(localized: "A download is in progress. Cancel it to make other changes.", bundle: .module)
        case .verifying:
            return String(localized: "Verifying the package. Wait for verification to finish.", bundle: .module)
        case .installing:
            return String(localized: "Installing the package.", bundle: .module)
        case .loading:
            return String(localized: "Loading the model. Wait for it to finish.", bundle: .module)
        case .optimizing:
            return String(localized: "Optimizing the model for your Mac. This happens only the first time and can take a few minutes; model changes are available when it finishes.", bundle: .module)
        case .deleting:
            return String(localized: "Removing the package.", bundle: .module)
        case .inference:
            return String(localized: "The model is transcribing. Wait for the current dictation to finish.", bundle: .module)
        case .absent, .downloadPaused, .ready, .corrupt, .incompatible, .error, .unavailable:
            return nil
        }
    }

    public var isBusy: Bool {
        if pendingAction != nil { return true }
        switch state {
        case .validatingExternal, .downloading, .verifying, .installing, .loading, .optimizing, .deleting, .inference:
            return true
        case .absent, .downloadPaused, .ready, .corrupt, .incompatible, .error, .unavailable:
            return false
        }
    }

    // MARK: Presentation

    public var statusDescription: String {
        Self.statusDescription(for: state)
    }

    public var progress: Double? {
        Self.progress(for: state)
    }

    /// Shared with the catalog cards (ADR-017) so one lifecycle state reads
    /// the same everywhere.
    nonisolated public static func statusDescription(for state: ModelLifecycleState) -> String {
        switch state {
        case .absent: return String(localized: "Not installed", bundle: .module)
        case .validatingExternal: return String(localized: "Checking existing package…", bundle: .module)
        case .downloading(let completed, let total):
            guard total > 0 else { return String(localized: "Downloading…", bundle: .module) }
            return String(localized: "Downloading — \(Self.formatBytes(completed)) of \(Self.formatBytes(total))", bundle: .module)
        case .downloadPaused(let resumable):
            if let resumable, resumable > 0 {
                return String(localized: "Paused — \(Self.formatBytes(resumable)) downloaded", bundle: .module)
            }
            return String(localized: "Paused", bundle: .module)
        case .verifying(let done, let total):
            return total > 0 ? String(localized: "Verifying — \(done) of \(total) files", bundle: .module) : String(localized: "Verifying…", bundle: .module)
        case .installing: return String(localized: "Installing…", bundle: .module)
        case .loading: return String(localized: "Loading into the Neural Engine…", bundle: .module)
        case .optimizing: return String(localized: "Optimizing for your Mac — first time only, this can take a few minutes…", bundle: .module)
        case .ready: return String(localized: "Ready", bundle: .module)
        case .inference: return String(localized: "Busy — dictation active", bundle: .module)
        case .corrupt(let failure): return String(localized: "Corrupt — \(DomainCopy.localized(failure.message))", bundle: .module)
        case .incompatible(let failure): return String(localized: "Incompatible — \(DomainCopy.localized(failure.message))", bundle: .module)
        case .error(let failure): return String(localized: "Error — \(DomainCopy.localized(failure.message))", bundle: .module)
        case .deleting: return String(localized: "Removing…", bundle: .module)
        // ADR-025: the reason is the whole status ("Requires macOS 26 or
        // later."); no "Error —" prefix because nothing went wrong.
        case .unavailable(let failure): return DomainCopy.localized(failure.message)
        }
    }

    nonisolated public static func progress(for state: ModelLifecycleState) -> Double? {
        switch state {
        case .downloading(let completed, let total) where total > 0:
            return min(max(Double(completed) / Double(total), 0), 1)
        case .verifying(let done, let total) where total > 0:
            return min(max(Double(done) / Double(total), 0), 1)
        default:
            return nil
        }
    }

    public var sizeDescription: String {
        guard let bytes = descriptor?.installedBytes else { return String(localized: "Unknown", bundle: .module) }
        return Self.formatBytes(bytes)
    }

    /// "about 1.6 GB · 120 GB free", or just the requirement when free space
    /// is unknown, or nil when nothing is known.
    public var spaceEstimateDescription: String? {
        Self.describe(spaceEstimate)
    }

    static func describe(_ estimate: ModelSpaceEstimate?) -> String? {
        guard let estimate else { return nil }
        let required = String(localized: "about \(formatBytes(estimate.requiredBytes))", bundle: .module)
        guard let available = estimate.availableBytes else { return required }
        return String(localized: "\(required) · \(formatBytes(available)) free", bundle: .module)
    }

    nonisolated static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
