import Foundation
import KvoiceDomain

/// ADR-022 item 4: every settings write the app makes, as one enum.
///
/// A surface never mutates `AppSettings`; it sends one of these to
/// `SettingsCoordinator.send(_:)`, which runs `SettingsReducer` under the
/// shell's `SettingsGate` and hands the resulting `SettingsEffect`s to the
/// shell. The `origin` is an attribute, not a switch: the reducer decides
/// the same way whichever door the intent came through, and the origin is
/// there for diagnostics and for the one rule that reads it (a page has
/// already asked the relaunch consent for `setInterfaceLanguage`).
///
/// Adding a setting: add a case here, a row in `SettingsReducer.reduce`
/// (gate + state change + effects), a row in `SettingsReducerTests`, and —
/// if a page shows it — a `SettingKey` and an availability row. A fact
/// about *this Mac* rather than a preference is a `LocalStateIntent`.
public enum SettingsIntent: Equatable, Sendable {
    // MARK: General (Settings › General / Shortcuts / Recording)

    /// The recording shortcut, from the General model, the hotkey recorder,
    /// or the setup wizard. `nil` clears it.
    case setShortcut(ShortcutDefinition?, origin: SettingsOrigin)
    case setRecordingInteraction(RecordingInteraction, origin: SettingsOrigin)
    case setShowDockIcon(Bool, origin: SettingsOrigin)
    /// The stored flag only. `GeneralSettingsViewModel` has already talked
    /// to `SMAppService`; the login item is real launchd state, not this bit.
    case setLaunchAtLogin(Bool, origin: SettingsOrigin)
    case setTypedInsertionEnabled(Bool, origin: SettingsOrigin)
    case setFreeModelMemoryUnderCriticalPressure(Bool, origin: SettingsOrigin)
    /// Persisted at once; the picker has already mirrored the override into
    /// `AppleLanguages` and asked about a relaunch (the `.replaceAll` path
    /// owes that consent itself — see `SettingsEffect.offerRelaunch`).
    case setInterfaceLanguage(InterfaceLanguage, origin: SettingsOrigin)

    // MARK: Triggers, recording options, audio input

    /// Shortcuts and Recording: the Cancel shortcut, auto-send,
    /// middle mouse, feedback, the duration limit, the inserted-text options,
    /// the recorder style — everything a job snapshot freezes.
    case setTriggers(TriggerSettingsSnapshot, origin: SettingsOrigin)
    /// Not idle-gated: the controller hands the capture service the
    /// selection per job, so a running recording keeps the device it
    /// started with.
    case setAudioInput(AudioInputSettings, origin: SettingsOrigin)

    // MARK: AI

    /// The whole AI block: endpoint, master switch, default action, actions,
    /// profile, selection slots. Not idle-gated: a running job holds its own
    /// snapshot, and the menu disables its AI items while one runs.
    case setAI(AIEndpointSettings, origin: SettingsOrigin)
    /// API keys. Never enter `AppSettings` (rule 2); the reducer leaves the
    /// state untouched and emits `.saveSecrets` only.
    case setSecrets(SecretSettings, origin: SettingsOrigin)

    // MARK: Dictionary

    case setDictionary(DictionarySettings, origin: SettingsOrigin)

    // MARK: History and data

    case setHistoryEnabled(Bool, origin: SettingsOrigin)
    /// Data & Privacy: retention, stored audio, Auto Daily Export.
    case setDataPrivacy(
        historyRetention: HistoryRetentionSettings,
        audioStorage: AudioStorageSettings,
        export: ExportSettings,
        origin: SettingsOrigin
    )

    // MARK: Speech models (ADR-017)

    /// Written after `SpeechModelLibrary.setDefaultModel` succeeded; the
    /// operation itself was idle-gated by the shell before the engine call,
    /// so this records what the library accepted.
    case setDefaultSpeechModel(ModelID, origin: SettingsOrigin)
    case setSpeechModelMode(ModelID, SpeechTranscriptionMode, origin: SettingsOrigin)
    /// `nil` is auto-detect.
    case setTranscriptionLanguage(String?, origin: SettingsOrigin)
    case setVoiceActivityDetection(Bool, origin: SettingsOrigin)
    /// Written after the engine reloaded under the new units, so a failed
    /// reload never persists a choice that does not run (`AppDelegate+Runtime`).
    case setSpeechComputeUnits(SpeechComputeUnits, origin: SettingsOrigin)
    /// The manager's current selection (managed / external / none), so it
    /// survives relaunch.
    case setSelectedModel(ModelReference?, origin: SettingsOrigin)

    // Local app state (the sidebar section, the tutorial flag, onboarding
    // completion, the export folder grant) is `LocalStateIntent` since
    // ADR-022 slice 5: those facts are not in `AppSettings` any more.

    // MARK: Reset to default (ADR-022 slice 5)

    /// A page's "Reset to default" on one row: the compiled `AppSettings`
    /// default for that `ResettableSetting`, with the effects the edit it
    /// undoes would run. Idle-gated like that edit.
    case resetToDefault(ResettableSetting, origin: SettingsOrigin)

    // MARK: Whole-blob writes

    /// Import / Restore Previous Settings: the file's blob replaces the
    /// state, then every derived effect runs as after a fresh load.
    case replaceAll(AppSettings, origin: SettingsOrigin)
    /// General › Reset Preferences: the documented subset back to defaults.
    case resetPreferences(origin: SettingsOrigin)

    public var origin: SettingsOrigin {
        switch self {
        case .setShortcut(_, let origin), .setRecordingInteraction(_, let origin),
             .setShowDockIcon(_, let origin), .setLaunchAtLogin(_, let origin),
             .setTypedInsertionEnabled(_, let origin),
             .setFreeModelMemoryUnderCriticalPressure(_, let origin),
             .setInterfaceLanguage(_, let origin), .setTriggers(_, let origin),
             .setAudioInput(_, let origin), .setAI(_, let origin), .setSecrets(_, let origin),
             .setDictionary(_, let origin), .setHistoryEnabled(_, let origin),
             .setDataPrivacy(_, _, _, let origin), .setDefaultSpeechModel(_, let origin),
             .setSpeechModelMode(_, _, let origin), .setTranscriptionLanguage(_, let origin),
             .setVoiceActivityDetection(_, let origin), .setSpeechComputeUnits(_, let origin),
             .setSelectedModel(_, let origin), .resetToDefault(_, let origin),
             .replaceAll(_, let origin), .resetPreferences(let origin):
            return origin
        }
    }

    /// A scalar name for diagnostics.
    public var name: String {
        switch self {
        case .setShortcut: return "setShortcut"
        case .setRecordingInteraction: return "setRecordingInteraction"
        case .setShowDockIcon: return "setShowDockIcon"
        case .setLaunchAtLogin: return "setLaunchAtLogin"
        case .setTypedInsertionEnabled: return "setTypedInsertionEnabled"
        case .setFreeModelMemoryUnderCriticalPressure: return "setFreeModelMemoryUnderCriticalPressure"
        case .setInterfaceLanguage: return "setInterfaceLanguage"
        case .setTriggers: return "setTriggers"
        case .setAudioInput: return "setAudioInput"
        case .setAI: return "setAI"
        case .setSecrets: return "setSecrets"
        case .setDictionary: return "setDictionary"
        case .setHistoryEnabled: return "setHistoryEnabled"
        case .setDataPrivacy: return "setDataPrivacy"
        case .setDefaultSpeechModel: return "setDefaultSpeechModel"
        case .setSpeechModelMode: return "setSpeechModelMode"
        case .setTranscriptionLanguage: return "setTranscriptionLanguage"
        case .setVoiceActivityDetection: return "setVoiceActivityDetection"
        case .setSpeechComputeUnits: return "setSpeechComputeUnits"
        case .setSelectedModel: return "setSelectedModel"
        case .resetToDefault: return "resetToDefault"
        case .replaceAll: return "replaceAll"
        case .resetPreferences: return "resetPreferences"
        }
    }
}

/// Which door an intent came through (ADR-022: "every surface sends a
/// `SettingsIntent` … with its origin as an attribute").
public enum SettingsOrigin: Equatable, Sendable {
    /// A main-window page. Since ADR-022 slice 7 the section is the page
    /// whose projection sent the intent (diagnostics name it).
    case page(SettingsSection)
    case statusMenu
    /// The setup wizard (`OnboardingIntent`).
    case wizard
    /// The KeyboardShortcuts recorder outside the wizard.
    case hotkeyRecorder
    /// Shortcuts / Siri / Spotlight (ADR-020). Confirmed in slice 7 part A:
    /// the five shipped intents write no setting (start / stop / toggle /
    /// cancel a dictation, read the last transcription), so nothing sends
    /// with this origin today. An App Intent that writes a setting goes
    /// through `AppDelegate.sendSettingsIntent` with this origin and no
    /// other route.
    case appIntent
    /// General › Backup › Import.
    case `import`
    /// General › Backup › Restore Previous Settings.
    case restore
    /// The shell itself — a model operation recording its outcome, the
    /// launch load's seeding.
    case shell

    public var name: String {
        switch self {
        case .page(let section): return "page.\(section.rawValue)"
        case .statusMenu: return "statusMenu"
        case .wizard: return "wizard"
        case .hotkeyRecorder: return "hotkeyRecorder"
        case .appIntent: return "appIntent"
        case .import: return "import"
        case .restore: return "restore"
        case .shell: return "shell"
        }
    }
}

/// The main-window pages that edit settings, as the reducer knows them.
/// Mirrors `MainWindowSection` (KvoiceUI) for the sections that write;
/// KvoiceAppCore cannot import that type.
public enum SettingsSection: String, Equatable, Sendable, CaseIterable {
    case general
    case shortcuts
    case recording
    case audioInput
    case aiActions
    case dictionary
    case history
    case dataPrivacy
    case models
}
