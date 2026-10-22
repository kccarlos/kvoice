import Foundation
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI
import XCTest

/// Q2b (UI v2 regression audit): the settings the UI v2 pages edit through
/// the drawn controls — load → change through the page's own binding →
/// persist (the backup file is the full `AppSettings` blob, the same Codable
/// the store writes) → reload into fresh view models, which must show what
/// was chosen. One test per page, each through the page's view model or
/// binding, never by assigning `AppSettings` directly.
@MainActor
final class SettingsUIRoundTripTests: XCTestCase {
    /// Persists `settings` as Export Settings… does and reads it back as a
    /// relaunch / Import Settings… would.
    private func reload(_ settings: AppSettings) throws -> SettingsProjectionTestHarness {
        let envelope = SettingsBackupEnvelope(appVersion: "test", exportedAt: Date(timeIntervalSince1970: 0), settings: settings)
        let decoded = try SettingsBackupCoding.decode(SettingsBackupCoding.encode(envelope))
        return SettingsProjectionTestHarness(settings: decoded.settings)
    }

    func testShortcutsAndRecordingPagesRoundTrip() throws {
        let harness = SettingsProjectionTestHarness()
        let general = GeneralSettingsViewModel(host: harness.host)
        let triggers = TriggerSettingsViewModel(host: harness.host)
        // Shortcuts: the trigger-mode segments, the extras.
        general.recordingInteraction = .hybrid
        triggers.triggerOptionBindings.autoSend?.wrappedValue = true
        triggers.triggerOptionBindings.middleMouseToggle?.wrappedValue = true
        // Recording: the recorder cards, Sound select, length select, switches.
        let options = triggers.recordingOptionBindings
        options.recorderStyle?.wrappedValue = .notch
        options.cueSet?.wrappedValue = .systemClassic
        options.maxRecordingSeconds?.wrappedValue = nil
        options.muteSystemAudio?.wrappedValue = true
        options.preserveClipboard?.wrappedValue = true
        general.typedInsertionEnabled = false
        XCTAssertFalse(harness.sent.isEmpty, "the bindings write through the host")

        let reloaded = try reload(harness.settings)
        let general2 = GeneralSettingsViewModel(host: reloaded.host)
        let triggers2 = TriggerSettingsViewModel(host: reloaded.host)
        XCTAssertEqual(general2.recordingInteraction, .hybrid)
        XCTAssertEqual(triggers2.triggerOptionBindings.autoSend?.wrappedValue, true)
        XCTAssertEqual(triggers2.triggerOptionBindings.middleMouseToggle?.wrappedValue, true)
        let options2 = triggers2.recordingOptionBindings
        XCTAssertEqual(options2.recorderStyle?.wrappedValue, .notch)
        XCTAssertEqual(options2.cueSet?.wrappedValue, .systemClassic)
        XCTAssertEqual(options2.maxRecordingSeconds?.wrappedValue, .some(nil), "No limit stays No limit")
        XCTAssertEqual(options2.muteSystemAudio?.wrappedValue, true)
        XCTAssertEqual(options2.preserveClipboard?.wrappedValue, true)
        XCTAssertFalse(general2.typedInsertionEnabled)
        XCTAssertEqual(reloaded.sent, [], "reading the reloaded settings writes nothing")
    }

    func testGeneralAndDataPrivacyPagesRoundTrip() throws {
        let harness = SettingsProjectionTestHarness()
        let general = GeneralSettingsViewModel(host: harness.host, applyLanguageOverride: { _ in })
        let data = DataPrivacyViewModel(host: harness.host)
        general.interfaceLanguage = .simplifiedChinese
        general.freeModelMemoryUnderCriticalPressure = true
        data.autoDeleteEnabled = true
        data.textRetentionDays = 30
        data.keepRecordings = true
        data.audioRetentionDays = 7

        let reloaded = try reload(harness.settings)
        let general2 = GeneralSettingsViewModel(host: reloaded.host, applyLanguageOverride: { _ in })
        let data2 = DataPrivacyViewModel(host: reloaded.host)
        XCTAssertEqual(general2.interfaceLanguage, .simplifiedChinese)
        XCTAssertTrue(general2.freeModelMemoryUnderCriticalPressure)
        XCTAssertTrue(data2.autoDeleteEnabled)
        XCTAssertEqual(data2.textRetentionDays, 30)
        XCTAssertTrue(data2.keepRecordings)
        XCTAssertEqual(data2.audioRetentionDays, 7)
    }

    func testMicrophoneAndDictionaryPagesRoundTrip() async throws {
        let harness = SettingsProjectionTestHarness()
        let input = AudioInputViewModel(host: harness.host)
        input.mode = .prioritized
        input.addToPriority(uid: "usb-mic")
        let dictionary = DictionaryViewModel(host: harness.host)
        _ = await dictionary.add("KVoice")
        _ = await dictionary.add("WhisperKit")
        // F3b: a chip edited in place commits through the same update.
        let first = try XCTUnwrap(dictionary.entries.first)
        dictionary.beginEditing(first.id)
        dictionary.editingText = "KVoice Pro"
        let committed = await dictionary.commitEditing()
        XCTAssertTrue(committed)

        let reloaded = try reload(harness.settings)
        let input2 = AudioInputViewModel(host: reloaded.host)
        XCTAssertEqual(input2.mode, .prioritized)
        XCTAssertEqual(input2.settings.prioritizedDeviceUIDs, ["usb-mic"])
        let dictionary2 = DictionaryViewModel(host: reloaded.host)
        XCTAssertEqual(dictionary2.entries.map(\.term), ["KVoice Pro", "WhisperKit"])
    }

    func testAIActionsPageRoundTrips() throws {
        var seeded = AppSettings()
        seeded.ai = AIEndpointSettings(baseURL: URL(string: "http://localhost:11434/v1"), modelID: "gemma4:latest")
        seeded.ai.seedBuiltInPromptModesIfNeeded()
        let harness = SettingsProjectionTestHarness(settings: seeded)
        let modes = PromptModeSettingsViewModel(host: harness.host)
        let translate = try XCTUnwrap(modes.modes.first { $0.behavior == .translate })
        modes.selectMode(id: translate.id)
        modes.setEnabled(true)

        let reloaded = try reload(harness.settings)
        let modes2 = PromptModeSettingsViewModel(host: reloaded.host)
        let ai2 = AISettingsViewModel(host: reloaded.host)
        XCTAssertTrue(modes2.isEnabled)
        XCTAssertEqual(modes2.activeModeID, translate.id)
        XCTAssertEqual(ai2.activeActionName, translate.name, "the page header names the reloaded action")
    }
}
