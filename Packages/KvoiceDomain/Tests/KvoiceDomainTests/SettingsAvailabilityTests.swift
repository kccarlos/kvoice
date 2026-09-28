import XCTest
@testable import KvoiceDomain

/// ADR-022 item 3: one row per availability rule, plus the gate's shape.
final class SettingsAvailabilityTests: XCTestCase {
    private struct Row {
        let name: String
        let key: SettingKey
        let settings: AppSettings
        let environment: EnvironmentProfile
        let gate: SettingsGate
        let expected: SettingAvailability
    }

    private static let jobActive = SettingsGate(dictation: .jobActive)
    private static let reloading = SettingsGate(model: .reloadingUnits)
    private static let testing = SettingsGate(model: .testing)
    private static let modelOperation = SettingsGate(model: .downloading("model"))
    private static let transcribingFile = SettingsGate(model: .transcribingFile)
    private static let loaded = EnvironmentProfile(hasNotch: true, enginePromptTokenLimit: .tokens(111), residentModelID: "whisper")

    private static func aiSettings(enabled: Bool, configured: Bool) -> AppSettings {
        var settings = AppSettings()
        settings.ai.isEnabled = enabled
        if configured {
            settings.ai.baseURL = URL(string: "https://example.com/v1")
            settings.ai.modelID = "gpt"
        }
        return settings
    }

    private static let rows: [Row] = [
        // AI action settings while the master switch is off / no endpoint.
        Row(name: "AI settings, switch off", key: .aiActionSettings, settings: aiSettings(enabled: false, configured: true),
            environment: loaded, gate: .idle, expected: .disabled(reason: SettingAvailabilityReason.aiActionsOff.message)),
        Row(name: "AI settings, no endpoint", key: .aiActionSettings, settings: aiSettings(enabled: true, configured: false),
            environment: loaded, gate: .idle, expected: .disabled(reason: SettingAvailabilityReason.noAIEndpoint.message)),
        Row(name: "AI settings, on and configured", key: .aiActionSettings, settings: aiSettings(enabled: true, configured: true),
            environment: loaded, gate: .idle, expected: .enabled),
        Row(name: "AI settings ignore the job", key: .aiActionSettings, settings: aiSettings(enabled: true, configured: true),
            environment: loaded, gate: jobActive, expected: .enabled),

        // Dictionary while the resident model takes no prompt.
        Row(name: "dictionary, model takes no prompt", key: .dictionary, settings: AppSettings(),
            environment: EnvironmentProfile(enginePromptTokenLimit: .unsupported), gate: .idle,
            expected: .disabled(reason: SettingAvailabilityReason.modelTakesNoPrompt.message)),
        Row(name: "dictionary, model takes a prompt", key: .dictionary, settings: AppSettings(),
            environment: EnvironmentProfile(enginePromptTokenLimit: .tokens(111)), gate: .idle, expected: .enabled),
        Row(name: "dictionary, nothing resident (estimate stands)", key: .dictionary, settings: AppSettings(),
            environment: EnvironmentProfile(enginePromptTokenLimit: nil), gate: .idle, expected: .enabled),

        // Notch style on a display without a housing.
        Row(name: "notch, no housing", key: .recorderStyleNotch, settings: AppSettings(),
            environment: EnvironmentProfile(hasNotch: false), gate: .idle,
            expected: .disabled(reason: SettingAvailabilityReason.noCameraHousing.message)),
        Row(name: "notch, housing", key: .recorderStyleNotch, settings: AppSettings(),
            environment: EnvironmentProfile(hasNotch: true), gate: .idle, expected: .enabled),
        Row(name: "notch, unknown display", key: .recorderStyleNotch, settings: AppSettings(),
            environment: EnvironmentProfile(hasNotch: nil), gate: .idle, expected: .enabled),
        Row(name: "notch, job first", key: .recorderStyleNotch, settings: AppSettings(),
            environment: EnvironmentProfile(hasNotch: false), gate: jobActive,
            expected: .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)),

        // Compute-unit picker during a reload (and anything else holding the engine).
        Row(name: "compute units, reloading", key: .speechComputeUnits, settings: AppSettings(),
            environment: loaded, gate: reloading, expected: .disabled(reason: SettingAvailabilityReason.reloadingComputeUnits.message)),
        Row(name: "compute units, performance test", key: .speechComputeUnits, settings: AppSettings(),
            environment: loaded, gate: testing, expected: .disabled(reason: SettingAvailabilityReason.performanceTestRunning.message)),
        Row(name: "compute units, job", key: .speechComputeUnits, settings: AppSettings(),
            environment: loaded, gate: jobActive, expected: .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)),
        Row(name: "compute units, file", key: .speechComputeUnits, settings: AppSettings(),
            environment: loaded, gate: transcribingFile, expected: .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)),
        Row(name: "compute units, nothing loaded", key: .speechComputeUnits, settings: AppSettings(),
            environment: EnvironmentProfile(residentModelID: nil), gate: .idle,
            expected: .disabled(reason: SettingAvailabilityReason.noModelLoaded.message)),
        Row(name: "compute units, free", key: .speechComputeUnits, settings: AppSettings(),
            environment: loaded, gate: .idle, expected: .enabled),
        // ADR-025: Apple Speech resident — no compute-unit choice to make.
        Row(name: "compute units, Apple Speech resident", key: .speechComputeUnits, settings: AppSettings(),
            environment: EnvironmentProfile(residentModelID: "apple-speech", runtime: .appleSpeech), gate: .idle,
            expected: .disabled(reason: SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message)),
        Row(name: "compute units, Core ML runtime resident", key: .speechComputeUnits, settings: AppSettings(),
            environment: EnvironmentProfile(residentModelID: "parakeet", runtime: .fluidAudioParakeetTDT), gate: .idle,
            expected: .enabled),

        // Transcribe File while a job or test runs.
        Row(name: "transcribe file, job", key: .transcribeFile, settings: AppSettings(),
            environment: loaded, gate: jobActive, expected: .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)),
        Row(name: "transcribe file, test", key: .transcribeFile, settings: AppSettings(),
            environment: loaded, gate: testing, expected: .disabled(reason: SettingAvailabilityReason.performanceTestRunning.message)),
        Row(name: "transcribe file, already transcribing", key: .transcribeFile, settings: AppSettings(),
            environment: loaded, gate: transcribingFile, expected: .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)),
        Row(name: "transcribe file, free", key: .transcribeFile, settings: AppSettings(),
            environment: loaded, gate: .idle, expected: .enabled),

        // Unload Model while anything holds the engine.
        Row(name: "unload, job", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: jobActive, expected: .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)),
        Row(name: "unload, reload", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: reloading, expected: .disabled(reason: SettingAvailabilityReason.reloadingComputeUnits.message)),
        Row(name: "unload, model operation", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: modelOperation, expected: .disabled(reason: SettingAvailabilityReason.modelOperationInProgress.message)),
        Row(name: "unload, unloading", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: SettingsGate(model: .unloading), expected: .disabled(reason: SettingAvailabilityReason.modelOperationInProgress.message)),
        Row(name: "unload, loading", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: SettingsGate(model: .loading("model")), expected: .disabled(reason: SettingAvailabilityReason.modelOperationInProgress.message)),
        Row(name: "transcribe file, installing", key: .transcribeFile, settings: AppSettings(),
            environment: loaded, gate: SettingsGate(model: .installing("model")), expected: .disabled(reason: SettingAvailabilityReason.modelOperationInProgress.message)),
        Row(name: "unload, file", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: transcribingFile, expected: .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)),
        Row(name: "unload, free", key: .unloadModel, settings: AppSettings(),
            environment: loaded, gate: .idle, expected: .enabled)
    ]

    func testEveryRuleRow() {
        for row in Self.rows {
            let actual = SettingsAvailability.availability(
                key: row.key, settings: row.settings, environment: row.environment, gate: row.gate
            )
            XCTAssertEqual(actual, row.expected, row.name)
        }
    }

    func testEveryRecordingSettingIsRefusedWhileAJobRuns() {
        for key in SettingKey.recordingSettings {
            let actual = SettingsAvailability.availability(
                key: key, settings: AppSettings(), environment: Self.loaded, gate: Self.jobActive
            )
            XCTAssertEqual(actual, .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message), key.rawValue)
            XCTAssertEqual(
                SettingsAvailability.availability(key: key, settings: AppSettings(), environment: Self.loaded, gate: .idle),
                .enabled, key.rawValue
            )
        }
    }

    func testTheTableCoversEveryKey() {
        let table = SettingsAvailability.table(settings: AppSettings(), environment: Self.loaded, gate: .idle)
        XCTAssertEqual(Set(table.keys), Set(SettingKey.allCases))
    }

    func testEveryReasonIsInTheDomainCopyInventory() {
        for reason in SettingAvailabilityReason.allCases {
            XCTAssertTrue(DomainUserFacingCopy.messages.contains(reason.message), reason.rawValue)
        }
    }

    func testGateShape() {
        XCTAssertFalse(SettingsGate.idle.engineIsHeld)
        XCTAssertTrue(Self.jobActive.engineIsHeld)
        XCTAssertTrue(Self.reloading.engineIsHeld)
        XCTAssertTrue(Self.transcribingFile.engineIsHeld)
        XCTAssertTrue(Self.transcribingFile.transcribingFile)
        XCTAssertFalse(Self.testing.transcribingFile)
        // ADR-022 item 5: every non-idle activity holds the engine for the
        // gate; the rules give each its own reason.
        for activity in ModelActivityTransition.representativeActivities() where activity != .idle {
            XCTAssertTrue(SettingsGate(model: activity).engineIsHeld, activity.name)
        }
        XCTAssertEqual(SettingAvailability.disabled(reason: "x").disabledReason, "x")
        XCTAssertNil(SettingAvailability.enabled.disabledReason)
        XCTAssertFalse(SettingAvailability.hidden.isEnabled)
    }
}
