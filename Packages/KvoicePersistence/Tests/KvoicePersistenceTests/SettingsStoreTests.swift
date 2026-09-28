import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

final class SettingsStoreTests: XCTestCase {
    private func makeSuiteName() -> String {
        "kvoice.settings.tests.\(UUID().uuidString)"
    }

    func testFreshStoreUsesSafeDefaults() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)

        let settings = try await store.load()

        XCTAssertEqual(settings, AppSettings())
        XCTAssertNil(defaults.object(forKey: SettingsStore.appSettingsKey))
    }

    /// The 2026-09-13 P0: the store used to persist a hand-picked subset and
    /// every other field came back as its default on the next launch. Every
    /// field of `AppSettings` must round-trip.
    func testEveryAppSettingsFieldRoundTrips() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        let input = AppSettings(
            showDockIcon: true,
            launchAtLogin: true,
            recordingInteraction: .toggle,
            shortcut: ShortcutDefinition(key: "s", modifiers: ["command", "shift"]),
            selectedModel: .external(
                path: "/Volumes/Models/whisper",
                expectedModelID: "whisper-large-v3-turbo-coreml-uncompressed",
                expectedRevision: "abc123"
            ),
            ai: {
                // ADR-024: the on-device transport with its configuration
                // active (the decoder resets a transport with no matching
                // active configuration, so the fixture carries both).
                let onDevice = AIConfiguration(
                    id: UUID(uuidString: "0A0A0A0A-0A0A-4A0A-8A0A-0A0A0A0A0A0A")!,
                    name: "On this Mac",
                    kind: .appleIntelligence
                )
                return AIEndpointSettings(
                    mode: .polish,
                    baseURL: URL(string: "https://example.invalid/v1"),
                    modelID: "local-polisher",
                    configurations: [onDevice],
                    activeConfigurationID: onDevice.id,
                    provider: .appleIntelligence
                )
            }(),
            historyEnabled: false,
            maxRecordingSeconds: 45,
            typedInsertionEnabled: false,
            // MARK: Recorder
            recorderStyle: .notch,
            // MARK: Runtime
            speechComputeUnits: .cpuOnly,
            // MARK: Memory
            freeModelMemoryUnderCriticalPressure: true,
            // MARK: App shell
            interfaceLanguage: .simplifiedChinese,
            // MARK: Triggers and audio
            triggers: TriggerSettings(
                cancelShortcut: ShortcutDefinition(key: "escape", modifiers: ["command"]),
                autoSendEnabled: true,
                middleMouseToggleEnabled: true,
                middleMouseActivationDelayMilliseconds: 450
            ),
            recordingFeedback: RecordingFeedbackSettings(
                soundFeedbackEnabled: false,
                cueSet: .systemClassic,
                muteSystemAudioDuringRecording: true,
                preserveTranscriptInClipboard: true
            ),
            audioInput: AudioInputSettings(
                mode: .prioritized,
                customDeviceUID: "usb-mic",
                prioritizedDeviceUIDs: ["usb-mic", "builtin"]
            ),
            // MARK: History and data
            historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 90),
            audioStorage: AudioStorageSettings(keepRecordings: true, retentionDays: 3),
            export: ExportSettings(autoDailyExportEnabled: true),
            // MARK: Dictionary
            dictionary: DictionarySettings(terms: ["kvoice", "WhisperKit", "Cosima"])
        )
        XCTAssertNotEqual(input, AppSettings(), "the fixture must differ from defaults in every field")
        XCTAssertEqual(input.ai.provider, .appleIntelligence)
        XCTAssertNotEqual(input.dictionary, AppSettings().dictionary)
        XCTAssertNotEqual(input.triggers, AppSettings().triggers)
        XCTAssertNotEqual(input.recordingFeedback, AppSettings().recordingFeedback)
        XCTAssertNotEqual(input.audioInput, AppSettings().audioInput)

        try await store.save(input)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, input)
        XCTAssertNotNil(defaults.data(forKey: SettingsStore.appSettingsKey))
        // The legacy split keys are never written again.
        XCTAssertNil(defaults.object(forKey: SettingsStore.generalSettingsKey))
        XCTAssertNil(defaults.object(forKey: SettingsStore.aiSettingsKey))
        XCTAssertNil(defaults.object(forKey: SettingsStore.historyEnabledKey))
    }

    func testSaveIsDeterministicAndContainsNoSecrets() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        let input = AppSettings(
            recordingInteraction: .toggle,
            shortcut: ShortcutDefinition(key: "space", modifiers: ["control", "shift"])
        )

        try await store.save(input)
        let first = try XCTUnwrap(defaults.data(forKey: SettingsStore.appSettingsKey))
        try await store.save(try await store.load())
        let second = try XCTUnwrap(defaults.data(forKey: SettingsStore.appSettingsKey))

        XCTAssertEqual(first, second)
        let encoded = String(decoding: first, as: UTF8.self)
        XCTAssertFalse(encoded.lowercased().contains("apikey"))
        XCTAssertFalse(encoded.contains("openAICompatibleAPIKey"))
    }

    func testLegacySplitKeysMigrateOnceAndAreRemoved() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        defaults.set(
            Data(#"{"recordingInteraction":"toggle","schemaVersion":1,"shortcut":{"key":"space","modifiers":["control","shift"]},"showDockIcon":true}"#.utf8),
            forKey: SettingsStore.generalSettingsKey
        )
        defaults.set(
            Data(#"{"mode":"polish","baseURL":"http://127.0.0.1:11434/v1","modelID":"qwen3:0.6b"}"#.utf8),
            forKey: SettingsStore.aiSettingsKey
        )
        defaults.set(false, forKey: SettingsStore.historyEnabledKey)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.recordingInteraction, .toggle)
        XCTAssertEqual(loaded.shortcut, ShortcutDefinition(key: "space", modifiers: ["control", "shift"]))
        XCTAssertTrue(loaded.showDockIcon)
        XCTAssertEqual(loaded.ai.mode, .polish)
        XCTAssertEqual(loaded.ai.modelID, "qwen3:0.6b")
        XCTAssertFalse(loaded.historyEnabled)
        // Migrated into the blob and the old keys are gone.
        XCTAssertNotNil(defaults.data(forKey: SettingsStore.appSettingsKey))
        XCTAssertNil(defaults.object(forKey: SettingsStore.generalSettingsKey))
        XCTAssertNil(defaults.object(forKey: SettingsStore.aiSettingsKey))
        XCTAssertNil(defaults.object(forKey: SettingsStore.historyEnabledKey))
    }

    func testOneBadLegacyKeyDoesNotDiscardTheOthers() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        defaults.set(Data("not json".utf8), forKey: SettingsStore.generalSettingsKey)
        defaults.set(false, forKey: SettingsStore.historyEnabledKey)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.recordingInteraction, .pushToTalk)
        XCTAssertFalse(loaded.historyEnabled)
    }

    func testMalformedBlobFallsBackToDefaultsAndIsRemoved() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        defaults.set(Data(#"{"schemaVersion":99}"#.utf8), forKey: SettingsStore.appSettingsKey)

        let loaded = try await store.load()

        XCTAssertEqual(loaded, AppSettings())
        XCTAssertNil(defaults.object(forKey: SettingsStore.appSettingsKey))
    }

    /// A field added by a later build must not break an older file: the
    /// decoder defaults anything missing.
    func testOlderBlobWithoutNewerFieldsLoadsWithDefaults() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        defaults.set(
            Data(#"{"schemaVersion":1,"showDockIcon":true,"recordingInteraction":"toggle"}"#.utf8),
            forKey: SettingsStore.appSettingsKey
        )

        let loaded = try await store.load()

        XCTAssertTrue(loaded.showDockIcon)
        XCTAssertEqual(loaded.recordingInteraction, .toggle)
        XCTAssertTrue(loaded.typedInsertionEnabled)
        XCTAssertNil(loaded.selectedModel)
        XCTAssertEqual(loaded.speechComputeUnits, .neuralEngineAndCPU)
        XCTAssertFalse(loaded.freeModelMemoryUnderCriticalPressure)
        XCTAssertEqual(loaded.interfaceLanguage, .system)
        XCTAssertEqual(loaded.recorderStyle, .mini, "ADR-021: a file from before recorder styles keeps the floating pill")
    }

    /// ADR-021: the recorder style is one stored string, so a build that
    /// removes a style must map it rather than fail the whole file.
    func testRecorderStyleDecodesByRawValue() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        defaults.set(
            Data(#"{"schemaVersion":1,"recorderStyle":"notch"}"#.utf8),
            forKey: SettingsStore.appSettingsKey
        )

        let loaded = try await store.load()

        XCTAssertEqual(loaded.recorderStyle, .notch)
        XCTAssertEqual(HUDStyle.allCases.map(\.rawValue), ["mini", "notch"])
    }

    func testResetClearsEverything() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(suiteName: suite)
        try await store.save(AppSettings(showDockIcon: true))

        await store.reset()

        XCTAssertNil(defaults.object(forKey: SettingsStore.appSettingsKey))
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, AppSettings())
    }
}
