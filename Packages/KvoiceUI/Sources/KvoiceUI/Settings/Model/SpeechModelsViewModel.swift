import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

// MARK: - Shell → view model

/// Everything the Models section shows about the model library, pushed by
/// the app shell (ADR-017). The view model never touches the model library,
/// the settings store, or the file system.
///
/// ADR-022 slice 7 part B: the transcription language, per-model mode, and
/// VAD rows used to be copied in here on every poll tick, with
/// `SpeechModelsViewModel` mutating its own copy optimistically so a picker
/// would not snap back between polls. They are plain `AppSettings` fields
/// with no engine coupling — `AppDelegate.performSpeechModelAction`'s
/// `.setMode` / `.setLanguage` / `.setVoiceActivityDetection` cases were
/// already one-line `sendSettingsIntent` calls — so the view model now reads
/// them from `host.settings` (live, no poll lag) and sends the intent
/// itself. `defaultModelID`, `residentModelID`, `catalog`, `states`, and
/// `activity` stay here: they come from the library and the resident
/// engine, not from settings.
public struct SpeechModelsSnapshot: Sendable, Equatable {
    public var catalog: SpeechModelCatalog
    /// Lifecycle state per runnable catalog ID. A missing entry means this
    /// build has no manager for it (reserved runtime).
    public var states: [ModelID: ModelLifecycleState]
    public var defaultModelID: ModelID
    /// The model the engine actually holds, if any.
    public var residentModelID: ModelID?
    /// True while a dictation job holds the model.
    public var dictationIsActive: Bool
    /// ADR-022 item 5: what the library is doing. A package operation shows
    /// on its own card through `states`; the engine-holding activities
    /// (a compute-unit reload, the performance test, a file transcription,
    /// an unload) disable every card's mutating buttons with their reason.
    public var activity: ModelActivity

    public init(
        catalog: SpeechModelCatalog,
        states: [ModelID: ModelLifecycleState],
        defaultModelID: ModelID,
        residentModelID: ModelID? = nil,
        dictationIsActive: Bool = false,
        activity: ModelActivity = .idle
    ) {
        self.catalog = catalog
        self.states = states
        self.defaultModelID = defaultModelID
        self.residentModelID = residentModelID
        self.dictationIsActive = dictationIsActive
        self.activity = activity
    }
}

/// What the Models section can ask the shell to do. Every remaining case is
/// a library operation; the settings-only actions (language, per-model
/// mode, VAD) are `SettingsIntent`s `SpeechModelsViewModel` sends itself.
public enum SpeechModelAction: Sendable, Equatable {
    case download(ModelID)
    case resume(ModelID)
    case cancel(ModelID)
    case retry(ModelID)
    case delete(ModelID)
    /// Make the model the default (and resident) one.
    case use(ModelID)
}

/// The two closures the shell installs at launch. Static, like
/// `SettingsSurface`'s hooks, so the view model can be created by whoever
/// owns the Models section without the shell threading a reference through.
/// Defaults render an empty section with an explanatory note.
@MainActor
public enum SpeechModelsHooks {
    public static var snapshot: @MainActor () async -> SpeechModelsSnapshot? = { nil }
    public static var perform: @MainActor (SpeechModelAction) async -> Void = { _ in }
}

// MARK: - Derived card state

/// The buttons a model card can show, in display order.
public enum ModelCardAction: String, Sendable, Equatable, Identifiable, CaseIterable {
    case download, resume, cancel, retry, use, delete

    public var id: Self { self }

    public var title: String {
        switch self {
        case .download: return String(localized: "Download", bundle: .module)
        case .resume: return String(localized: "Resume", bundle: .module)
        case .cancel: return String(localized: "Cancel", bundle: .module)
        case .retry: return String(localized: "Retry", bundle: .module)
        case .use: return String(localized: "Use", bundle: .module)
        case .delete: return String(localized: "Delete", bundle: .module)
        }
    }

    public var isDestructive: Bool { self == .delete }

    /// Cancel does not mutate the package and stays enabled during a job.
    public var isMutation: Bool { self != .cancel }
}

/// One catalog entry as the section renders it.
public struct ModelCardState: Sendable, Equatable, Identifiable {
    public let entry: SpeechModelCatalogEntry
    public let state: ModelLifecycleState?
    public let isDefault: Bool
    public let isResident: Bool
    public let mode: SpeechTranscriptionMode
    public let actions: [ModelCardAction]

    public var id: ModelID { entry.id }

    /// "On-Device", "Streaming or Batch", "Punctuation and capitalization",
    /// "650 MB" — the axes that differ between models (ADR-019): mode,
    /// punctuation, size; language coverage is shown beside them.
    public var badges: [String] {
        var badges = [DomainCopy.localized(entry.hosting.displayName)]
        switch (entry.supportsStreaming, entry.supportsBatch) {
        case (true, true): badges.append(String(localized: "Streaming or Batch", bundle: .module))
        case (true, false): badges.append(String(localized: "Streaming", bundle: .module))
        case (false, true): badges.append(String(localized: "Batch", bundle: .module))
        case (false, false): break
        }
        if let punctuation = entry.punctuationSummary {
            badges.append(punctuation)
        }
        // ADR-025: the OS owns the weights; there is no size to download.
        badges.append(entry.isSystemManaged
            ? String(localized: "System-managed", bundle: .module)
            : ModelSettingsViewModel.formatBytes(entry.downloadBytes))
        return badges
    }

    /// The button's title for this card: a system-managed entry is
    /// *installed* (the OS fetches and keeps the assets), not downloaded by
    /// KVoice; every other action reads the same on every card.
    public func title(for action: ModelCardAction) -> String {
        if action == .download, entry.isSystemManaged {
            return String(localized: "Install", bundle: .module)
        }
        return action.title
    }

    /// The weights' license, with the attribution the license requires when
    /// the catalog carries one ("CC-BY-4.0 · Parakeet TDT 0.6B v3 by
    /// NVIDIA…"). Nil for an older catalog entry that states neither.
    public var licenseLine: String? {
        switch (entry.license, entry.attribution) {
        case let (license?, attribution?): return "\(license) · \(attribution)"
        case let (license?, nil): return license
        case let (nil, attribution?): return attribution
        case (nil, nil): return nil
        }
    }

    public var isInstalled: Bool {
        switch state {
        case .ready, .inference: return true
        default: return false
        }
    }

    public var isAvailableInThisBuild: Bool {
        state != nil
    }

    public var statusDescription: String {
        guard let state else { return String(localized: "Not available in this version", bundle: .module) }
        switch state {
        case .ready:
            if isDefault {
                return isResident ? String(localized: "Default · Ready", bundle: .module) : String(localized: "Default · Loading…", bundle: .module)
            }
            return String(localized: "Installed", bundle: .module)
        case .inference: return String(localized: "Busy — dictation active", bundle: .module)
        case .downloading(let completed, let total) where entry.isSystemManaged && total > 0:
            // ADR-025: the platform reports a fraction, never bytes.
            return String(localized: "Downloading — \(Int(completed * 100 / total)) %", bundle: .module)
        default:
            return ModelSettingsViewModel.statusDescription(for: state)
        }
    }

    public var progress: Double? {
        state.flatMap(ModelSettingsViewModel.progress(for:))
    }

    public var isBusy: Bool {
        guard let state else { return false }
        switch state {
        case .validatingExternal, .downloading, .verifying, .installing, .loading, .deleting, .inference:
            return true
        case .absent, .downloadPaused, .ready, .corrupt, .incompatible, .error, .unavailable:
            return false
        }
    }
}

public enum ModelCardFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case recommended
    case all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .recommended: return String(localized: "Recommended", bundle: .module)
        case .all: return String(localized: "All", bundle: .module)
        }
    }
}

// MARK: - View model

/// State for the catalog half of the Models section: the default-model card,
/// the language picker, the Recommended/All list of cards, and the Manage
/// Models panel. The shell pushes a `SpeechModelsSnapshot` through
/// `SpeechModelsHooks.snapshot` (polled while the section is visible) and
/// receives actions through `SpeechModelsHooks.perform`.
///
/// Lifecycle actions (download, use, delete, …) wait for the shell's next
/// snapshot, with a per-model pending marker so a button cannot be
/// double-clicked into two downloads. Language, per-model mode, and VAD are
/// projections over `host.settings` (ADR-022 slice 7 part B): reading them
/// is always live, and a picker never has to snap back for a poll tick.
@Observable
@MainActor
public final class SpeechModelsViewModel {
    /// The coordinator projection and the intent door for the
    /// settings-only rows (language, per-model mode, VAD).
    public let host: SettingsProjectionHost
    public private(set) var snapshot: SpeechModelsSnapshot?
    public var filter: ModelCardFilter = .recommended
    public var isShowingManagePanel = false
    /// Card IDs with a lifecycle action in flight, until the shell's
    /// snapshot changes that card's state (or `pendingActionTimeout`).
    public private(set) var pendingActions: [ModelID: ModelCardAction] = [:]

    private let snapshotProvider: @MainActor () async -> SpeechModelsSnapshot?
    private let performer: @MainActor (SpeechModelAction) async -> Void
    private let pendingActionTimeout: Duration
    /// Internal (not private) so tests can await the timer they advanced.
    @ObservationIgnored private(set) var pendingTasks: [ModelID: Task<Void, Never>] = [:]
    /// Times the pending-action expiry; tests inject a `ParkingClock`.
    private let clock: any KvoiceClock
    /// The language the language names are shown in. Defaults to the
    /// interface language; tests pin English so they do not follow the
    /// machine's own language.
    @ObservationIgnored public var languageNameLocale: Locale = LanguageNames.interfaceLocale

    public init(
        host: SettingsProjectionHost = .detached(),
        snapshot: SpeechModelsSnapshot? = nil,
        pendingActionTimeout: Duration = .seconds(5),
        snapshotProvider: @escaping @MainActor () async -> SpeechModelsSnapshot? = { await SpeechModelsHooks.snapshot() },
        perform: @escaping @MainActor (SpeechModelAction) async -> Void = { await SpeechModelsHooks.perform($0) },
        clock: any KvoiceClock = SystemKvoiceClock()
    ) {
        self.clock = clock
        self.host = host
        self.snapshot = snapshot
        self.pendingActionTimeout = pendingActionTimeout
        self.snapshotProvider = snapshotProvider
        self.performer = perform
    }

    // MARK: Inputs

    /// Equality-guarded: `@Observable` invalidates readers on every
    /// assignment, and the shell polls four times a second.
    public func apply(_ snapshot: SpeechModelsSnapshot?) {
        guard snapshot != self.snapshot else { return }
        let previous = self.snapshot
        self.snapshot = snapshot
        // A lifecycle action is "acknowledged" once that card's state moves.
        for (id, _) in pendingActions where previous?.states[id] != snapshot?.states[id] {
            clearPending(id)
        }
    }

    public func refresh() async {
        apply(await snapshotProvider())
    }

    /// Runs from the section's `.task` and stops when it is hidden.
    public func pollWhileVisible(interval: Duration = .milliseconds(250)) async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    // MARK: Derived state

    public var isAvailable: Bool { snapshot != nil }

    public var cards: [ModelCardState] {
        guard let snapshot else { return [] }
        return snapshot.catalog.entries.map { card(for: $0, in: snapshot) }
    }

    public var filteredCards: [ModelCardState] {
        switch filter {
        case .all: return cards
        case .recommended:
            let recommended = cards.filter { $0.entry.isRecommended || $0.isDefault }
            return recommended.isEmpty ? cards : recommended
        }
    }

    public var defaultCard: ModelCardState? {
        cards.first { $0.isDefault }
    }

    public var transcriptionLanguage: String? {
        host.settings.transcriptionLanguage
    }

    public var transcriptionLanguageDisplayName: String {
        LanguageNames.transcriptionLanguageName(forCode: transcriptionLanguage, locale: languageNameLocale)
    }

    /// Auto-detect first, then Whisper's list by name; entries the default
    /// model cannot take are excluded — except the one currently selected,
    /// which stays listed so the picker keeps showing what is set while
    /// `languageCoverageWarning` explains the problem.
    public var languageOptions: [TranscriptionLanguage] {
        let all = TranscriptionLanguage.whisperLanguages
        guard let entry = defaultCard?.entry else { return all }
        let selected = transcriptionLanguage
        return all.filter { entry.supportsLanguage($0.code) || $0.code == selected }
    }

    /// ADR-019 fallback rule: set when the chosen transcription language is
    /// outside the default model's coverage; names a Whisper model as the
    /// way out. Nil for auto-detect or a covered language.
    public var languageCoverageWarning: String? {
        defaultCard?.entry.languageCoverageWarning(forLanguageCode: transcriptionLanguage)
    }

    public var dictationIsActive: Bool {
        snapshot?.dictationIsActive ?? false
    }

    public func mode(for id: ModelID) -> SpeechTranscriptionMode {
        host.settings.speechModelModes[id] ?? .batch
    }

    public func isPending(_ id: ModelID) -> Bool {
        pendingActions[id] != nil
    }

    /// The engine-holding activity's reason, or nil while the library is
    /// idle or busy with a package operation (which its own card shows).
    /// The sentences are the availability projection's, so the Runtime
    /// card and the model cards say the same thing.
    public var engineActivityReason: String? {
        let reason: SettingAvailabilityReason
        switch snapshot?.activity ?? .idle {
        case .reloadingUnits: reason = .reloadingComputeUnits
        case .testing: reason = .performanceTestRunning
        case .transcribingFile: reason = .fileTranscriptionRunning
        case .unloading: reason = .modelOperationInProgress
        case .idle, .downloading, .installing, .loading: return nil
        }
        return DomainCopy.localized(reason.message)
    }

    /// Why a card's mutating buttons are disabled, or nil.
    public func mutationDisabledReason(for card: ModelCardState) -> String? {
        if let pending = pendingActions[card.id] {
            return String(localized: "\(pending.title)…", bundle: .module)
        }
        if dictationIsActive {
            return String(localized: "Model changes are unavailable while dictation is running.", bundle: .module)
        }
        if let engineActivityReason {
            return engineActivityReason
        }
        if card.isBusy, card.state.map({ if case .inference = $0 { return false } else { return true } }) ?? false {
            return card.statusDescription
        }
        // ADR-025: offered, not hidden — Install is shown disabled with the
        // reason this Mac cannot run the model.
        if case .unavailable(let failure) = card.state {
            return DomainCopy.localized(failure.message)
        }
        return nil
    }

    public func isEnabled(_ action: ModelCardAction, for card: ModelCardState) -> Bool {
        guard card.actions.contains(action) else { return false }
        if !action.isMutation { return !isPending(card.id) }
        return mutationDisabledReason(for: card) == nil
    }

    // MARK: Actions

    public func perform(_ action: ModelCardAction, on card: ModelCardState) {
        guard isEnabled(action, for: card) else { return }
        markPending(card.id, action)
        let request: SpeechModelAction
        switch action {
        case .download: request = .download(card.id)
        case .resume: request = .resume(card.id)
        case .cancel: request = .cancel(card.id)
        case .retry: request = .retry(card.id)
        case .use: request = .use(card.id)
        case .delete: request = .delete(card.id)
        }
        Task { await performer(request) }
    }

    /// The last refusal's sentence; nil otherwise. Only the settings-only
    /// rows below (language, mode, VAD) can produce one — the lifecycle
    /// actions above go through `performer`, not the host.
    public var refusalNote: String? { host.refusalNote }

    public func setMode(_ mode: SpeechTranscriptionMode, for id: ModelID) {
        guard self.mode(for: id) != mode else { return }
        host.send(.setSpeechModelMode(id, mode, origin: .page(.models)))
    }

    public func setTranscriptionLanguage(_ code: String?) {
        guard transcriptionLanguage != code else { return }
        host.send(.setTranscriptionLanguage(code, origin: .page(.models)))
    }

    public var voiceActivityDetectionEnabled: Bool {
        get { host.settings.voiceActivityDetectionEnabled }
        set {
            guard newValue != voiceActivityDetectionEnabled else { return }
            host.send(.setVoiceActivityDetection(newValue, origin: .page(.models)))
        }
    }

    // MARK: Internals

    private func card(for entry: SpeechModelCatalogEntry, in snapshot: SpeechModelsSnapshot) -> ModelCardState {
        let state = snapshot.states[entry.id]
        let isDefault = entry.id == snapshot.defaultModelID
        return ModelCardState(
            entry: entry,
            state: state,
            isDefault: isDefault,
            isResident: snapshot.residentModelID == entry.id,
            mode: mode(for: entry.id),
            actions: Self.actions(for: state, isDefault: isDefault)
        )
    }

    static func actions(for state: ModelLifecycleState?, isDefault: Bool) -> [ModelCardAction] {
        guard let state else { return [] }
        switch state {
        case .absent:
            return [.download]
        case .downloadPaused:
            return [.resume]
        case .downloading:
            return [.cancel]
        case .validatingExternal, .verifying, .installing, .loading, .deleting:
            return []
        case .ready:
            return isDefault ? [.delete] : [.use, .delete]
        case .inference:
            return []
        case .corrupt, .incompatible, .error:
            return [.retry, .delete]
        case .unavailable:
            // ADR-025: Install is offered but disabled, with the reason as
            // the card's note (`mutationDisabledReason`).
            return [.download]
        }
    }

    private func markPending(_ id: ModelID, _ action: ModelCardAction) {
        pendingActions[id] = action
        pendingTasks[id]?.cancel()
        pendingTasks[id] = Task { [weak self, pendingActionTimeout, clock] in
            try? await clock.sleep(for: pendingActionTimeout)
            guard !Task.isCancelled, let self, self.pendingActions[id] == action else { return }
            self.clearPending(id)
        }
    }

    private func clearPending(_ id: ModelID) {
        pendingTasks[id]?.cancel()
        pendingTasks[id] = nil
        pendingActions[id] = nil
    }
}
