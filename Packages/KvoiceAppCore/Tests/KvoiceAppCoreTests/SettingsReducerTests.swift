import XCTest
import KvoiceDomain
@testable import KvoiceAppCore

/// ADR-022 item 4: one row per intent × gate combination that matters. The
/// table in `SettingsReducer`'s doc comment is what these rows assert.
final class SettingsReducerTests: XCTestCase {
    private static let jobActive = SettingsGate(dictation: .jobActive)
    private static let notLoaded = SettingsGate(settingsLoaded: false)
    private static let terminating = SettingsGate(terminationInProgress: true)
    private static let modelBusy = SettingsGate(model: .transcribingFile)

    private static let shortcut = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])

    private static var base: AppSettings {
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.shortcut = nil
        settings.speechModelModes["whisper"] = .batch
        // Changed from default so the reset rows have something to undo.
        settings.maxRecordingSeconds = 1_800
        settings.recordingFeedback.cueSet = .systemClassic
        settings.recorderStyle = .notch
        settings.triggers.autoSendEnabled = true
        settings.typedInsertionEnabled = false
        settings.freeModelMemoryUnderCriticalPressure = true
        settings.ai.promptModes = BuiltInPromptModes.all
        return settings
    }

    private static var triggersSnapshot: TriggerSettingsSnapshot {
        var snapshot = TriggerSettingsSnapshot(settings: base)
        snapshot.maxRecordingSeconds = 1_800
        snapshot.recorderStyle = .notch
        snapshot.triggers.autoSendEnabled = true
        // The cue set (2026-09-16) rides in the same block, so the three
        // trigger rows prove it commits from the page, from another door,
        // and is refused during a job like the rest.
        snapshot.recordingFeedback.cueSet = .systemClassic
        return snapshot
    }

    private static var importedSettings: AppSettings {
        var settings = AppSettings()
        settings.shortcut = shortcut
        settings.interfaceLanguage = .simplifiedChinese
        settings.historyEnabled = false
        settings.dictionary = DictionarySettings(terms: ["kvoice"])
        return settings
    }

    private struct Row: Sendable {
        let name: String
        let intent: SettingsIntent
        let gate: SettingsGate
        let expectedState: @Sendable (AppSettings) -> AppSettings
        let effects: [SettingsEffect]
        let refusal: SettingsRefusal.Reason?
        let note: SettingsRefusalNote?

        init(
            _ name: String, _ intent: SettingsIntent, gate: SettingsGate = .idle,
            state: @escaping @Sendable (AppSettings) -> AppSettings = { $0 },
            effects: [SettingsEffect] = [], refusal: SettingsRefusal.Reason? = nil, note: SettingsRefusalNote? = nil
        ) {
            self.name = name
            self.intent = intent
            self.gate = gate
            self.expectedState = state
            self.effects = effects
            self.refusal = refusal
            self.note = note
        }
    }

    // MARK: The table

    private static let rows: [Row] = [
        // General fields from the page: idle-gated, effects per field.
        Row("shortcut from page", .setShortcut(shortcut, origin: .page(.shortcuts)),
            state: { var s = $0; s.shortcut = shortcut; return s },
            effects: [.registerShortcut, .persist, .rebuildMenu]),
        Row("shortcut from wizard (a projection needs no hydrate)", .setShortcut(shortcut, origin: .wizard),
            state: { var s = $0; s.shortcut = shortcut; return s },
            effects: [.registerShortcut, .persist, .rebuildMenu]),
        Row("shortcut from recorder", .setShortcut(shortcut, origin: .hotkeyRecorder),
            state: { var s = $0; s.shortcut = shortcut; return s },
            effects: [.registerShortcut, .persist, .rebuildMenu]),
        Row("shortcut cleared", .setShortcut(nil, origin: .page(.shortcuts)),
            effects: [.registerShortcut, .persist, .rebuildMenu]),
        Row("shortcut during a job", .setShortcut(shortcut, origin: .page(.shortcuts)), gate: jobActive,
            refusal: .dictationInProgress),
        Row("shortcut before load", .setShortcut(shortcut, origin: .wizard), gate: notLoaded, refusal: .notLoaded),
        Row("shortcut while terminating", .setShortcut(shortcut, origin: .wizard), gate: terminating, refusal: .terminating),
        Row("shortcut ignores the model's activity", .setShortcut(shortcut, origin: .page(.shortcuts)), gate: modelBusy,
            state: { var s = $0; s.shortcut = shortcut; return s },
            effects: [.registerShortcut, .persist, .rebuildMenu]),

        Row("interaction from page", .setRecordingInteraction(.toggle, origin: .page(.shortcuts)),
            state: { var s = $0; s.recordingInteraction = .toggle; return s },
            effects: [.persist, .rebuildMenu]),
        Row("interaction from wizard", .setRecordingInteraction(.hybrid, origin: .wizard),
            state: { var s = $0; s.recordingInteraction = .hybrid; return s },
            effects: [.persist, .rebuildMenu]),
        Row("interaction during a job", .setRecordingInteraction(.toggle, origin: .wizard), gate: jobActive,
            refusal: .dictationInProgress),

        Row("dock icon", .setShowDockIcon(true, origin: .page(.general)),
            state: { var s = $0; s.showDockIcon = true; return s },
            effects: [.applyActivationPolicy, .persist, .rebuildMenu]),
        Row("dock icon during a job", .setShowDockIcon(true, origin: .page(.general)), gate: jobActive,
            refusal: .dictationInProgress),
        Row("launch at login", .setLaunchAtLogin(false, origin: .page(.general)),
            state: { var s = $0; s.launchAtLogin = false; return s },
            effects: [.persist, .rebuildMenu]),
        Row("launch at login during a job", .setLaunchAtLogin(false, origin: .page(.general)), gate: jobActive,
            refusal: .dictationInProgress),
        Row("typed insertion", .setTypedInsertionEnabled(false, origin: .page(.recording)),
            state: { var s = $0; s.typedInsertionEnabled = false; return s },
            effects: [.applyDerivedSettings, .persist, .rebuildMenu]),
        Row("typed insertion during a job", .setTypedInsertionEnabled(false, origin: .page(.recording)), gate: jobActive,
            refusal: .dictationInProgress),
        Row("free memory opt-in", .setFreeModelMemoryUnderCriticalPressure(true, origin: .page(.general)),
            state: { var s = $0; s.freeModelMemoryUnderCriticalPressure = true; return s },
            effects: [.persist, .rebuildMenu]),
        Row("free memory opt-in during a job", .setFreeModelMemoryUnderCriticalPressure(true, origin: .page(.general)),
            gate: jobActive, refusal: .dictationInProgress),
        Row("language from page (picker already offered the relaunch)",
            .setInterfaceLanguage(.simplifiedChinese, origin: .page(.general)),
            state: { var s = $0; s.interfaceLanguage = .simplifiedChinese; return s },
            effects: [.persist, .rebuildMenu]),
        Row("language from another door offers the relaunch",
            .setInterfaceLanguage(.simplifiedChinese, origin: .appIntent),
            state: { var s = $0; s.interfaceLanguage = .simplifiedChinese; return s },
            effects: [.offerRelaunch(.simplifiedChinese), .persist, .rebuildMenu]),
        Row("unchanged language from another door offers nothing",
            .setInterfaceLanguage(.system, origin: .appIntent),
            effects: [.persist, .rebuildMenu]),
        Row("language during a job", .setInterfaceLanguage(.english, origin: .page(.general)), gate: jobActive,
            refusal: .dictationInProgress),

        // Triggers and recording options: idle-gated, the control snaps back.
        Row("triggers from page", .setTriggers(triggersSnapshot, origin: .page(.recording)),
            state: { var s = $0; triggersSnapshot.apply(to: &s); return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("triggers from another door", .setTriggers(triggersSnapshot, origin: .appIntent),
            state: { var s = $0; triggersSnapshot.apply(to: &s); return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("triggers during a job", .setTriggers(triggersSnapshot, origin: .page(.recording)), gate: jobActive,
            refusal: .dictationInProgress),

        // Audio input: not idle-gated (the capture service is configured per job).
        Row("audio input during a job applies",
            .setAudioInput(AudioInputSettings(mode: .systemDefault), origin: .page(.audioInput)), gate: jobActive,
            state: { var s = $0; s.audioInput = AudioInputSettings(mode: .systemDefault); return s },
            effects: [.persist, .rebuildMenu]),
        Row("audio input from the menu",
            .setAudioInput(AudioInputSettings(mode: .systemDefault), origin: .statusMenu),
            state: { var s = $0; s.audioInput = AudioInputSettings(mode: .systemDefault); return s },
            effects: [.persist, .rebuildMenu]),
        Row("audio input before load", .setAudioInput(AudioInputSettings(), origin: .page(.audioInput)), gate: notLoaded,
            refusal: .notLoaded),

        // AI: not idle-gated; both view models are projections and need no
        // hydrate whatever the origin.
        Row("AI from page", .setAI(aiOn, origin: .page(.aiActions)),
            state: { var s = $0; s.ai = aiOn; return s },
            effects: [.persist, .rebuildMenu]),
        Row("AI from the page during a job applies", .setAI(aiOn, origin: .page(.aiActions)), gate: jobActive,
            state: { var s = $0; s.ai = aiOn; return s },
            effects: [.persist, .rebuildMenu]),
        Row("AI from the menu", .setAI(aiOn, origin: .statusMenu),
            state: { var s = $0; s.ai = aiOn; return s },
            effects: [.persist, .rebuildMenu]),
        Row("AI from the menu during a job is refused", .setAI(aiOn, origin: .statusMenu), gate: jobActive,
            refusal: .dictationInProgress),
        Row("AI while terminating", .setAI(aiOn, origin: .statusMenu), gate: terminating, refusal: .terminating),
        Row("secrets never touch the state", .setSecrets(SecretSettings(apiKey: "k"), origin: .page(.aiActions)),
            effects: [.saveSecrets(SecretSettings(apiKey: "k"))]),
        Row("secrets before load", .setSecrets(SecretSettings(apiKey: "k"), origin: .page(.aiActions)), gate: notLoaded,
            refusal: .notLoaded),

        // Dictionary: idle-gated with the note the section shows.
        Row("dictionary from page", .setDictionary(DictionarySettings(terms: ["WhisperKit"]), origin: .page(.dictionary)),
            state: { var s = $0; s.dictionary = DictionarySettings(terms: ["WhisperKit"]); return s },
            effects: [.persist]),
        Row("dictionary during a job carries the note",
            .setDictionary(DictionarySettings(terms: ["WhisperKit"]), origin: .page(.dictionary)), gate: jobActive,
            refusal: .dictationInProgress, note: .dictionaryKeepsListDuringDictation),
        Row("dictionary from another door",
            .setDictionary(DictionarySettings(terms: ["WhisperKit"]), origin: .appIntent),
            state: { var s = $0; s.dictionary = DictionarySettings(terms: ["WhisperKit"]); return s },
            effects: [.persist]),

        // History and data: not idle-gated. `HistoryViewModel` is a
        // projection (slice 7 part B): no door needs a hydrate any more.
        Row("history enabled during a job applies", .setHistoryEnabled(false, origin: .page(.history)), gate: jobActive,
            state: { var s = $0; s.historyEnabled = false; return s },
            effects: [.persist, .applyDerivedSettings]),
        Row("history enabled from another door needs no hydrate", .setHistoryEnabled(false, origin: .statusMenu),
            state: { var s = $0; s.historyEnabled = false; return s },
            effects: [.persist, .applyDerivedSettings]),
        Row("data privacy", .setDataPrivacy(
                historyRetention: HistoryRetentionSettings(), audioStorage: AudioStorageSettings(keepRecordings: true),
                export: ExportSettings(), origin: .page(.dataPrivacy)),
            state: { var s = $0; s.audioStorage = AudioStorageSettings(keepRecordings: true); return s },
            effects: [.persist]),

        // Speech models: loaded-only, no-op when unchanged (updateSpeechModelSettings' shape).
        Row("default model", .setDefaultSpeechModel("parakeet", origin: .shell),
            state: { var s = $0; s.defaultSpeechModelID = "parakeet"; return s },
            effects: [.persist, .refreshCatalogLimit, .rebuildMenu]),
        Row("default model during a blocked HUD still records the library's choice",
            .setDefaultSpeechModel("parakeet", origin: .shell), gate: jobActive,
            state: { var s = $0; s.defaultSpeechModelID = "parakeet"; return s },
            effects: [.persist, .refreshCatalogLimit, .rebuildMenu]),
        Row("model mode", .setSpeechModelMode("whisper", .streaming, origin: .page(.models)),
            state: { var s = $0; s.speechModelModes["whisper"] = .streaming; return s },
            effects: [.persist, .refreshCatalogLimit]),
        Row("model mode unchanged is a no-op", .setSpeechModelMode("whisper", .batch, origin: .page(.models))),
        Row("language", .setTranscriptionLanguage("de", origin: .statusMenu),
            state: { var s = $0; s.transcriptionLanguage = "de"; return s },
            effects: [.persist, .refreshCatalogLimit, .rebuildMenu]),
        Row("language unchanged is a no-op", .setTranscriptionLanguage(nil, origin: .statusMenu)),
        Row("VAD", .setVoiceActivityDetection(false, origin: .page(.models)),
            state: { var s = $0; s.voiceActivityDetectionEnabled = false; return s },
            effects: [.persist, .refreshCatalogLimit]),
        Row("compute units after the reload", .setSpeechComputeUnits(.cpuOnly, origin: .page(.models)),
            state: { var s = $0; s.speechComputeUnits = .cpuOnly; return s },
            effects: [.persist, .refreshCatalogLimit]),
        Row("compute units unchanged is a no-op", .setSpeechComputeUnits(.default, origin: .page(.models))),
        Row("compute units before load", .setSpeechComputeUnits(.cpuOnly, origin: .page(.models)), gate: notLoaded,
            refusal: .notLoaded),
        Row("selected model", .setSelectedModel(managedReference, origin: .shell),
            state: { var s = $0; s.selectedModel = managedReference; return s }, effects: [.persist]),
        Row("selected model unchanged is a no-op", .setSelectedModel(nil, origin: .shell)),

        // Local app state: `LocalStateReducerTests` (ADR-022 slice 5).

        // Reset to default (ADR-022 slice 5): the row's own block of effects.
        Row("reset the recording length", .resetToDefault(.maxRecordingSeconds, origin: .page(.recording)),
            state: { var s = $0; s.maxRecordingSeconds = 600; return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("reset the feedback block", .resetToDefault(.recordingFeedback, origin: .page(.recording)),
            state: { var s = $0; s.recordingFeedback = RecordingFeedbackSettings(); return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("reset the recorder style", .resetToDefault(.recorderStyle, origin: .page(.recording)),
            state: { var s = $0; s.recorderStyle = .mini; return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("reset the triggers", .resetToDefault(.triggers, origin: .page(.shortcuts)),
            state: { var s = $0; s.triggers = TriggerSettings(); return s },
            effects: [.applyTriggerSettings, .persist, .rebuildMenu]),
        Row("reset typed insertion", .resetToDefault(.typedInsertionEnabled, origin: .page(.recording)),
            state: { var s = $0; s.typedInsertionEnabled = true; return s },
            effects: [.applyDerivedSettings, .persist, .rebuildMenu]),
        Row("reset the memory opt-in", .resetToDefault(.freeModelMemoryUnderCriticalPressure, origin: .page(.general)),
            state: { var s = $0; s.freeModelMemoryUnderCriticalPressure = false; return s },
            effects: [.persist, .rebuildMenu]),
        Row("reset an already-default row is a no-op", .resetToDefault(.addSpaceAfterInsertion, origin: .page(.recording))),
        Row("reset during a job", .resetToDefault(.maxRecordingSeconds, origin: .page(.recording)), gate: jobActive,
            refusal: .dictationInProgress),
        Row("reset before load", .resetToDefault(.recorderStyle, origin: .page(.recording)), gate: notLoaded,
            refusal: .notLoaded),

        // Whole-blob writes.
        Row("import replaces everything and offers the relaunch", .replaceAll(importedSettings, origin: .import),
            state: { _ in importedSettings },
            effects: [
                .offerRelaunch(.simplifiedChinese), .refreshCatalogLimit,
                .applyActivationPolicy, .registerShortcut, .applyTriggerSettings, .applyDerivedSettings,
                .restoreSelectedModel, .persist, .rebuildMenu
            ]),
        Row("restore with the same language offers no relaunch",
            .replaceAll(sameLanguageImport, origin: .restore),
            state: { _ in sameLanguageImport },
            effects: [
                .refreshCatalogLimit,
                .applyActivationPolicy, .registerShortcut, .applyTriggerSettings, .applyDerivedSettings,
                .restoreSelectedModel, .persist, .rebuildMenu
            ]),
        Row("import during a job", .replaceAll(importedSettings, origin: .import), gate: jobActive, refusal: .dictationInProgress),
        Row("reset preferences unregisters the login item it had",
            .resetPreferences(origin: .page(.general)),
            state: { s in
                var r = s
                let d = AppSettings()
                r.showDockIcon = d.showDockIcon; r.launchAtLogin = d.launchAtLogin
                r.typedInsertionEnabled = d.typedInsertionEnabled; r.historyEnabled = d.historyEnabled
                r.maxRecordingSeconds = d.maxRecordingSeconds; r.recordingFeedback = d.recordingFeedback
                r.freeModelMemoryUnderCriticalPressure = d.freeModelMemoryUnderCriticalPressure
                return r
            },
            effects: [
                .unregisterLoginItem,
                .applyActivationPolicy, .applyTriggerSettings, .applyDerivedSettings,
                .persist, .resetMainWindowFrame, .rebuildMenu
            ]),
        Row("reset preferences during a job", .resetPreferences(origin: .page(.general)), gate: jobActive,
            refusal: .dictationInProgress)
    ]

    private static let managedReference = ModelReference.managed(modelID: "whisper", revision: "abc")

    private static var aiOn: AIEndpointSettings {
        var ai = AIEndpointSettings()
        ai.isEnabled = true
        ai.baseURL = URL(string: "https://example.com/v1")
        ai.modelID = "gpt"
        return ai
    }

    private static var sameLanguageImport: AppSettings {
        var settings = importedSettings
        settings.interfaceLanguage = base.interfaceLanguage
        return settings
    }

    func testEveryRow() {
        for row in Self.rows {
            let base = Self.base
            let result = SettingsReducer.reduce(state: base, intent: row.intent, gate: row.gate)
            if let refusal = row.refusal {
                XCTAssertEqual(result.refusal?.reason, refusal, row.name)
                XCTAssertEqual(result.refusal?.note, row.note, row.name)
                XCTAssertEqual(result.refusal?.intent, row.intent.name, row.name)
                XCTAssertEqual(result.state, base, "\(row.name): a refusal must leave the state untouched")
                XCTAssertEqual(result.effects, [], "\(row.name): a refusal runs no effect")
            } else {
                XCTAssertNil(result.refusal, row.name)
                XCTAssertEqual(result.state, row.expectedState(base), row.name)
                XCTAssertEqual(result.effects, row.effects, row.name)
            }
        }
    }

    func testResetPreferencesWithoutALoginItemSkipsTheUnregister() {
        var state = Self.base
        state.launchAtLogin = false
        let result = SettingsReducer.reduce(state: state, intent: .resetPreferences(origin: .page(.general)), gate: .idle)
        XCTAssertFalse(result.effects.contains(.unregisterLoginItem))
    }

    func testResetPreferencesKeepsWhatItPromisesToKeep() {
        var state = Self.base
        state.shortcut = Self.shortcut
        state.ai = Self.aiOn
        state.selectedModel = Self.managedReference
        state.showDockIcon = true
        let result = SettingsReducer.reduce(state: state, intent: .resetPreferences(origin: .page(.general)), gate: .idle)
        XCTAssertEqual(result.state.shortcut, Self.shortcut)
        XCTAssertEqual(result.state.ai, Self.aiOn)
        XCTAssertEqual(result.state.selectedModel, Self.managedReference)
        XCTAssertFalse(result.state.showDockIcon)
        // Onboarding completion and the sidebar section are `LocalState`
        // now — this reducer cannot touch them by construction.
        XCTAssertFalse(result.effects.contains(.persistLocalState))
    }

    func testEveryIntentNamesItsOrigin() {
        let origins: [SettingsOrigin] = [.page(.general), .statusMenu, .wizard, .hotkeyRecorder, .appIntent, .import, .restore, .shell]
        for origin in origins {
            XCTAssertEqual(SettingsIntent.setShortcut(nil, origin: origin).origin, origin)
            XCTAssertFalse(origin.name.isEmpty)
        }
        XCTAssertEqual(SettingsOrigin.page(.aiActions).name, "page.aiActions")
    }

    func testIntentNamesAreDistinct() {
        let intents: [SettingsIntent] = [
            .setShortcut(nil, origin: .shell), .setRecordingInteraction(.toggle, origin: .shell),
            .setShowDockIcon(true, origin: .shell), .setLaunchAtLogin(true, origin: .shell),
            .setTypedInsertionEnabled(true, origin: .shell), .setFreeModelMemoryUnderCriticalPressure(true, origin: .shell),
            .setInterfaceLanguage(.system, origin: .shell), .setTriggers(TriggerSettingsSnapshot(), origin: .shell),
            .setAudioInput(AudioInputSettings(), origin: .shell), .setAI(AIEndpointSettings(), origin: .shell),
            .setSecrets(SecretSettings(), origin: .shell), .setDictionary(DictionarySettings(), origin: .shell),
            .setHistoryEnabled(true, origin: .shell),
            .setDataPrivacy(historyRetention: .init(), audioStorage: .init(), export: .init(), origin: .shell),
            .setDefaultSpeechModel("x", origin: .shell), .setSpeechModelMode("x", .batch, origin: .shell),
            .setTranscriptionLanguage(nil, origin: .shell), .setVoiceActivityDetection(true, origin: .shell),
            .setSpeechComputeUnits(.default, origin: .shell), .setSelectedModel(nil, origin: .shell),
            .resetToDefault(.triggers, origin: .shell),
            .replaceAll(AppSettings(), origin: .shell), .resetPreferences(origin: .shell)
        ]
        XCTAssertEqual(Set(intents.map(\.name)).count, intents.count)
    }
}
