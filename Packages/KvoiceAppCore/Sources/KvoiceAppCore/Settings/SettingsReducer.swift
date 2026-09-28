import Foundation
import KvoiceDomain

/// ADR-022 item 4: the pure decision behind every settings write.
///
/// `reduce(state:intent:gate:)` does no I/O and touches no view model. It
/// returns the next `AppSettings`, the ordered effects the shell must run,
/// and — when the gate refuses the intent — a typed refusal with the state
/// untouched and no effects. The gating encoded here is exactly the gating
/// the per-handler `guard latestState.kind == .idle` lines used to spread
/// across `AppDelegate+Settings.swift`, `+Model.swift`, `+Menu.swift`, and
/// `+Onboarding.swift`; the effects per intent are what each handler body
/// did, so the shell's observable behaviour is unchanged by the move.
///
/// The table (`SettingsReducerTests` asserts every row):
///
/// | Intent | Gate | Effects |
/// | --- | --- | --- |
/// | setShortcut | idle | registerShortcut, persist, rebuildMenu |
/// | setRecordingInteraction | idle | persist, rebuildMenu |
/// | setShowDockIcon | idle | applyActivationPolicy, persist, rebuildMenu |
/// | setLaunchAtLogin | idle | persist, rebuildMenu |
/// | setTypedInsertionEnabled | idle | applyDerivedSettings, persist, rebuildMenu |
/// | setFreeModelMemoryUnderCriticalPressure | idle | persist, rebuildMenu |
/// | setInterfaceLanguage | idle | persist, rebuildMenu (+ offerRelaunch unless from a page) |
/// | setTriggers | idle (control snaps back, with a note) | applyTriggerSettings, persist, rebuildMenu |
/// | setAudioInput | loaded | persist, rebuildMenu |
/// | setAI | loaded (idle when from the status menu) | persist, rebuildMenu |
/// | setSecrets | loaded | saveSecrets (state untouched) |
/// | setDictionary | idle (control snaps back, with a note) | persist |
/// | setHistoryEnabled | loaded | persist, applyDerivedSettings |
/// | setDataPrivacy | loaded | persist |
/// | setDefaultSpeechModel | loaded, no-op if unchanged | persist, refreshCatalogLimit, rebuildMenu |
/// | setSpeechModelMode / setVoiceActivityDetection | loaded, no-op if unchanged | persist, refreshCatalogLimit |
/// | setTranscriptionLanguage | loaded, no-op if unchanged | persist, refreshCatalogLimit, rebuildMenu |
/// | setSpeechComputeUnits | loaded, no-op if unchanged | persist, refreshCatalogLimit |
/// | setSelectedModel | loaded, no-op if unchanged | persist |
/// | resetToDefault(row) | idle, no-op if already default | the row's block: trigger-snapshot rows → applyTriggerSettings, persist, rebuildMenu; typedInsertionEnabled → applyDerivedSettings, persist, rebuildMenu; memory opt-in → persist, rebuildMenu |
/// | replaceAll | idle | offerRelaunch?, refreshCatalogLimit, applyActivationPolicy, registerShortcut, applyTriggerSettings, applyDerivedSettings, restoreSelectedModel, persist, rebuildMenu |
/// | resetPreferences | idle | unregisterLoginItem?, applyActivationPolicy, applyTriggerSettings, applyDerivedSettings, persist, resetMainWindowFrame, rebuildMenu |
///
/// "loaded" means `settingsLoaded && !terminationInProgress`; "idle" adds
/// `dictation == .idle`. No intent is gated on the model's activity: the
/// three writes that follow an engine operation (`setDefaultSpeechModel`,
/// `setSpeechComputeUnits`, `setSelectedModel`) record what the library
/// already accepted, and the shell gated the *operation* before calling it.
///
/// ADR-022 slice 7 (parts A and B, complete as of 2026-09-16): every page is
/// a projection over the coordinator (`SettingsProjectionHost`) and
/// re-renders from the committed state with no effect. There is no `hydrate`
/// effect and no `SettingsProjection` enum any more — the shell never
/// re-applies a value to a view model, because no view model holds a copy.
public enum SettingsReducer {
    public struct Result: Equatable, Sendable {
        public var state: AppSettings
        public var effects: [SettingsEffect]
        public var refusal: SettingsRefusal?

        public init(state: AppSettings, effects: [SettingsEffect] = [], refusal: SettingsRefusal? = nil) {
            self.state = state
            self.effects = effects
            self.refusal = refusal
        }

        static func refused(_ state: AppSettings, _ reason: SettingsRefusal.Reason, _ intent: SettingsIntent, note: SettingsRefusalNote? = nil) -> Result {
            Result(state: state, refusal: SettingsRefusal(intent: intent.name, reason: reason, note: note))
        }
    }

    public static func reduce(state: AppSettings, intent: SettingsIntent, gate: SettingsGate) -> Result {
        var next = state
        let origin = intent.origin

        switch intent {
        // MARK: General fields (idle-gated: a live job's snapshot must not move)

        case .setShortcut(let shortcut, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.shortcut = shortcut
            return Result(state: next, effects: [.registerShortcut, .persist, .rebuildMenu])

        case .setRecordingInteraction(let interaction, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.recordingInteraction = interaction
            return Result(state: next, effects: [.persist, .rebuildMenu])

        case .setShowDockIcon(let show, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.showDockIcon = show
            return Result(state: next, effects: [.applyActivationPolicy, .persist, .rebuildMenu])

        case .setLaunchAtLogin(let enabled, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.launchAtLogin = enabled
            return Result(state: next, effects: [.persist, .rebuildMenu])

        case .setTypedInsertionEnabled(let enabled, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.typedInsertionEnabled = enabled
            return Result(state: next, effects: [.applyDerivedSettings, .persist, .rebuildMenu])

        case .setFreeModelMemoryUnderCriticalPressure(let enabled, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.freeModelMemoryUnderCriticalPressure = enabled
            return Result(state: next, effects: [.persist, .rebuildMenu])

        case .setInterfaceLanguage(let language, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next.interfaceLanguage = language
            var effects: [SettingsEffect] = []
            // The General picker mirrors the override and asks about the
            // relaunch itself; any other door owes the user that consent.
            if !origin.isPage, language != state.interfaceLanguage {
                effects.append(.offerRelaunch(language))
            }
            return Result(state: next, effects: effects + [.persist, .rebuildMenu])

        // MARK: Triggers, recording options, audio input

        case .setTriggers(let snapshot, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            snapshot.apply(to: &next)
            return Result(state: next, effects: [.applyTriggerSettings, .persist, .rebuildMenu])

        case .setAudioInput(let audioInput, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.audioInput = audioInput
            return Result(state: next, effects: [.persist, .rebuildMenu])

        // MARK: AI

        case .setAI(let ai, _):
            // The AI Actions page edits during a job (the running job holds
            // its own snapshot); the status menu's AI items are disabled
            // while one runs and their handlers refused — the same rule,
            // now in the table.
            if origin == .statusMenu {
                if let refusal = idleRefusal(state, intent, gate) { return refusal }
            } else if let refusal = loadedRefusal(state, intent, gate) {
                return refusal
            }
            next.ai = ai
            return Result(state: next, effects: [.persist, .rebuildMenu])

        case .setSecrets(let secrets, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            // Rule 2: secrets never reach `AppSettings`.
            return Result(state: state, effects: [.saveSecrets(secrets)])

        // MARK: Dictionary (ADR-018)

        case .setDictionary(let dictionary, _):
            if let refusal = idleRefusal(state, intent, gate, note: .dictionaryKeepsListDuringDictation) { return refusal }
            next.dictionary = dictionary
            return Result(state: next, effects: [.persist])

        // MARK: History and data

        case .setHistoryEnabled(let enabled, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.historyEnabled = enabled
            return Result(state: next, effects: [.persist, .applyDerivedSettings])

        case .setDataPrivacy(let retention, let audioStorage, let export, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.historyRetention = retention
            next.audioStorage = audioStorage
            next.export = export
            return Result(state: next, effects: [.persist])

        // MARK: Speech models (ADR-017) — `updateSpeechModelSettings`'s shape:
        // loaded, no-op when nothing changed, a new default may take a
        // different prompt.

        case .setDefaultSpeechModel(let id, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.defaultSpeechModelID = id
            return speechModelResult(state, next, extra: [.rebuildMenu])

        case .setSpeechModelMode(let id, let mode, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.speechModelModes[id] = mode
            return speechModelResult(state, next)

        case .setTranscriptionLanguage(let code, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.transcriptionLanguage = code
            return speechModelResult(state, next, extra: [.rebuildMenu])

        case .setVoiceActivityDetection(let enabled, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.voiceActivityDetectionEnabled = enabled
            return speechModelResult(state, next)

        case .setSpeechComputeUnits(let units, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            next.speechComputeUnits = units
            return speechModelResult(state, next)

        case .setSelectedModel(let reference, _):
            if let refusal = loadedRefusal(state, intent, gate) { return refusal }
            guard reference != state.selectedModel else { return Result(state: state) }
            next.selectedModel = reference
            return Result(state: next, effects: [.persist])

        // Local app state (`setMainWindowSection`, `markTutorialSeen`,
        // `completeOnboarding`, `resetOnboarding`, the export folder) is
        // `LocalStateIntent` / `LocalStateReducer` since ADR-022 slice 5.

        // MARK: Reset to default (ADR-022 slice 5)

        case .resetToDefault(let row, _):
            // The same gate as the edit it undoes: every resettable row is
            // either a recording setting or the General model's, all idle.
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            guard row.isChangedFromDefault(in: state) else { return Result(state: state) }
            row.reset(in: &next)
            // Every resettable row is shown by a projection, which reads the
            // committed value; only the row's derived effects remain.
            switch row {
            case .maxRecordingSeconds, .recordingFeedback, .recorderStyle, .addSpaceAfterInsertion,
                 .automaticTextFormatting, .triggers:
                return Result(state: next, effects: [.applyTriggerSettings, .persist, .rebuildMenu])
            case .typedInsertionEnabled:
                return Result(state: next, effects: [.applyDerivedSettings, .persist, .rebuildMenu])
            case .freeModelMemoryUnderCriticalPressure:
                return Result(state: next, effects: [.persist, .rebuildMenu])
            }

        // MARK: Whole-blob writes

        case .replaceAll(let imported, _):
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            next = imported
            var effects: [SettingsEffect] = []
            // An import that changes the interface language owes the user
            // the same relaunch consent a manual pick gets, never a silent
            // switch (mirrors `applyImportedSettings` before the move).
            if imported.interfaceLanguage != state.interfaceLanguage {
                effects.append(.offerRelaunch(imported.interfaceLanguage))
            }
            effects += [
                .refreshCatalogLimit, .applyActivationPolicy, .registerShortcut,
                .applyTriggerSettings, .applyDerivedSettings, .restoreSelectedModel,
                .persist, .rebuildMenu
            ]
            return Result(state: next, effects: effects)

        case .resetPreferences:
            if let refusal = idleRefusal(state, intent, gate) { return refusal }
            // General › Reset Preferences: appearance and behaviour back to
            // defaults. Deliberately kept: AI settings and configurations,
            // the shortcut and trigger mode, secrets, the selected model,
            // history rows — and every `LocalState` fact (onboarding
            // completion, the sidebar section, the export folder grant),
            // which this reducer cannot reach by construction.
            let defaults = AppSettings()
            next.showDockIcon = defaults.showDockIcon
            next.launchAtLogin = defaults.launchAtLogin
            next.typedInsertionEnabled = defaults.typedInsertionEnabled
            next.historyEnabled = defaults.historyEnabled
            next.maxRecordingSeconds = defaults.maxRecordingSeconds
            next.recordingFeedback = defaults.recordingFeedback
            next.freeModelMemoryUnderCriticalPressure = defaults.freeModelMemoryUnderCriticalPressure
            var effects: [SettingsEffect] = []
            // The login item is real state in launchd, not just a flag. The
            // General projection already reads the flag as off, so the
            // status re-read that comes with the effect has nothing to flip
            // back.
            if state.launchAtLogin { effects.append(.unregisterLoginItem) }
            effects += [
                .applyActivationPolicy, .applyTriggerSettings, .applyDerivedSettings,
                .persist, .resetMainWindowFrame, .rebuildMenu
            ]
            return Result(state: next, effects: effects)
        }
    }

    // MARK: Gate rows

    /// Nothing is written before the settings file has been read, and
    /// nothing after termination began.
    private static func loadedRefusal(_ state: AppSettings, _ intent: SettingsIntent, _ gate: SettingsGate) -> Result? {
        if !gate.settingsLoaded { return .refused(state, .notLoaded, intent) }
        if gate.terminationInProgress { return .refused(state, .terminating, intent) }
        return nil
    }

    /// A live job holds its own settings snapshot; changing what it froze
    /// would make its behaviour nondeterministic, so these wait for idle.
    private static func idleRefusal(
        _ state: AppSettings, _ intent: SettingsIntent, _ gate: SettingsGate, note: SettingsRefusalNote? = nil
    ) -> Result? {
        if let refusal = loadedRefusal(state, intent, gate) { return refusal }
        if gate.dictation == .jobActive { return .refused(state, .dictationInProgress, intent, note: note) }
        return nil
    }

    private static func speechModelResult(_ state: AppSettings, _ next: AppSettings, extra: [SettingsEffect] = []) -> Result {
        guard next != state else { return Result(state: state) }
        return Result(state: next, effects: [.persist, .refreshCatalogLimit] + extra)
    }
}

/// What the shell must do after the reducer accepted an intent, in order.
/// `AppDelegate+SettingsCoordinator.swift` is the only runner.
public enum SettingsEffect: Equatable, Sendable {
    /// Write the new `AppSettings` through the settings store.
    case persist
    /// Write the new `LocalState` through the local-state store (ADR-022
    /// slice 5; produced only by `LocalStateReducer`).
    case persistLocalState
    /// Write `SecretSettings` through the secrets store (mode 0600).
    case saveSecrets(SecretSettings)
    /// Unregister and re-register the global shortcut from the new state.
    case registerShortcut
    /// `NSApp.setActivationPolicy` from `showDockIcon`.
    case applyActivationPolicy
    /// The Cancel shortcut, middle mouse trigger, and hold ceiling.
    case applyTriggerSettings
    /// The controller's live history flag and the insertion tier policy.
    case applyDerivedSettings
    /// Re-establish the persisted model selection (after an import).
    case restoreSelectedModel
    /// Mirror the language into `AppleLanguages` and ask about a relaunch.
    case offerRelaunch(InterfaceLanguage)
    /// The Dictionary budget follows the default model (ADR-018).
    case refreshCatalogLimit
    /// `updateMenu(for:)`.
    case rebuildMenu
    /// Reset Preferences: remove the launchd login item so
    /// `SMAppService.status` agrees with the toggle afterwards.
    case unregisterLoginItem
    /// Reset Preferences: forget the autosaved main-window frame.
    case resetMainWindowFrame
}

/// Why the reducer left the state untouched. The shell reads `note` for the
/// two controls that snap back visibly (triggers, dictionary) and logs the
/// rest as scalars.
public struct SettingsRefusal: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case notLoaded
        case terminating
        case dictationInProgress
    }

    /// `SettingsIntent.name`.
    public let intent: String
    public let reason: Reason
    public let note: SettingsRefusalNote?

    public init(intent: String, reason: Reason, note: SettingsRefusalNote? = nil) {
        self.intent = intent
        self.reason = reason
        self.note = note
    }
}

/// The user-facing note a refusal carries. The shell owns the localized
/// sentence (Shell string table) so the key stays extractable; this is the
/// typed key.
public enum SettingsRefusalNote: Equatable, Sendable {
    /// "Finish the current dictation first — a running dictation keeps the
    /// list it started with." (Dictionary, ADR-018).
    case dictionaryKeepsListDuringDictation
}

extension SettingsOrigin {
    var isPage: Bool {
        if case .page = self { return true }
        return false
    }
}
