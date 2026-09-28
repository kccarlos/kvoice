import SwiftUI
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// The Settings › Shortcuts and Audio Input surfaces (product decisions #5 and
/// #10): modifier-only shortcuts through the General view model, the trigger
/// and recording bindings, the HUD's duration hint, and the input-device model
/// — each a projection over the settings coordinator (ADR-022 slice 7).
@MainActor
final class TriggerSettingsUITests: XCTestCase {
    // MARK: Modifier-only shortcuts

    func testGeneralModelAcceptsAModifierOnlyShortcutAndNamesIt() {
        let model = GeneralSettingsViewModel()
        model.confirmShortcut(.rightOption)
        XCTAssertEqual(model.confirmedShortcut, .rightOption)
        XCTAssertEqual(model.shortcutDescription, "Right Option")
        XCTAssertEqual(GeneralSettingsViewModel.displayName(for: ShortcutDefinition(modifierOnly: .fn)), "Fn")

        // A bare non-modifier key is still refused.
        model.confirmShortcut(ShortcutDefinition(key: "space", modifiers: []))
        XCTAssertEqual(model.confirmedShortcut, .rightOption)
        model.confirmShortcut(ShortcutDefinition(key: "space", modifiers: ["control", "shift"]))
        XCTAssertEqual(model.shortcutDescription, "Control-Shift-Space")
    }

    /// D7a/N10: the menu title's glyph form — `displayName(for:)` stays the
    /// settings pages' spelled-out form ("Control-Shift-Space"); `glyphs(for:)`
    /// is the same shortcut right-aligned the way every menu on the Mac
    /// draws a key equivalent.
    func testGeneralModelSpellsShortcutsAsGlyphsForTheMenuTitle() {
        XCTAssertEqual(
            GeneralSettingsViewModel.glyphs(for: ShortcutDefinition(key: "space", modifiers: ["control", "shift"])),
            "⌃⇧Space"
        )
        XCTAssertEqual(
            GeneralSettingsViewModel.glyphs(for: GeneralSettingsViewModel.recommendedShortcut),
            "⌃⇧Space"
        )
        // Apple's fixed on-screen order (Control, Option, Shift, Command)
        // regardless of the order the modifiers were stored in.
        XCTAssertEqual(
            GeneralSettingsViewModel.glyphs(for: ShortcutDefinition(key: "k", modifiers: ["command", "control"])),
            "⌃⌘K"
        )
        // A modifier-only shortcut has no separate key to append.
        XCTAssertEqual(GeneralSettingsViewModel.glyphs(for: .rightOption), "Right Option")
        XCTAssertEqual(GeneralSettingsViewModel.glyphs(for: ShortcutDefinition(modifierOnly: .fn)), "Fn")
    }

    func testOnboardingAcceptsAModifierOnlyShortcut() {
        let model = OnboardingViewModel()
        XCTAssertTrue(model.setShortcut(.rightOption))
        XCTAssertEqual(model.shortcut, .rightOption)
        XCTAssertFalse(model.setShortcut(ShortcutDefinition(key: "x", modifiers: [])))
        XCTAssertNotNil(model.shortcutError)
    }

    // MARK: Section views

    func testShortcutSectionConstructsWithAndWithoutTriggerBindings() {
        XCTAssertNotNil(ShortcutsSectionView())
        var autoSend = false
        var delay = 300
        var enabled = true
        let bindings = TriggerOptionBindings(
            cancelShortcut: AuxiliaryShortcutBinding(
                shortcut: ShortcutDefinition(key: "escape", modifiers: ["command"]),
                error: "That shortcut is already in use."
            ),
            autoSend: Binding(get: { autoSend }, set: { autoSend = $0 }),
            middleMouseToggle: Binding(get: { enabled }, set: { enabled = $0 }),
            middleMouseActivationDelayMilliseconds: Binding(get: { delay }, set: { delay = $0 })
        )
        XCTAssertTrue(bindings.isBound)
        XCTAssertFalse(TriggerOptionBindings().isBound)
        XCTAssertNotNil(ShortcutsSectionView(triggers: bindings))
        XCTAssertEqual(RecordingInteraction.allCases.count, 3, "the picker offers every mode")
    }

    // MARK: HUD duration hint

    func testRecordingHintFollowsTheConfiguredLimit() {
        let jobID = UUID()
        func detail(at seconds: Int, limit: Duration?) -> String? {
            HUDViewState(
                dictationState: .recording(RecordingState(jobID: jobID, elapsed: .seconds(seconds))),
                maximumRecordingDuration: limit
            ).detail
        }
        // H5: appended to the release instruction, never replacing it.
        XCTAssertEqual(detail(at: 300, limit: .seconds(600)), "Release to stop · Long dictation — recording stops automatically at 10:00.")
        XCTAssertEqual(detail(at: 300, limit: .seconds(1_800)), "Release to stop · Long dictation — recording stops automatically at 30:00.")
        XCTAssertEqual(detail(at: 300, limit: .seconds(3_600)), "Release to stop · Long dictation — recording stops automatically at 60:00.")
        XCTAssertEqual(detail(at: 300, limit: nil), "Release to stop · Long dictation — KVoice works best with shorter input.",
                       "No limit: the clock line is omitted")
        XCTAssertEqual(detail(at: 10, limit: nil), "Release to stop")
    }

    // MARK: Audio input model

    func testAudioInputModelReportsTheResolvedDeviceAndEditsTheList() {
        let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
        let usb = AudioInputDevice(uid: "usb", name: "USB Microphone")
        let provider = ScriptedDevices(available: [builtIn, usb], systemDefault: builtIn)
        let harness = SettingsProjectionTestHarness()
        let model = AudioInputViewModel(host: harness.host, deviceProvider: provider)

        XCTAssertEqual(model.devices, [builtIn, usb])
        XCTAssertEqual(model.currentDeviceName, "MacBook Pro Microphone")
        XCTAssertNil(model.selectionNote)
        XCTAssertTrue(harness.sent.isEmpty, "reading never persists")

        model.mode = .customDevice
        model.customDeviceUID = "usb"
        XCTAssertEqual(model.currentDeviceName, "USB Microphone")
        XCTAssertEqual(model.selection.pinnedDeviceUID, "usb")
        XCTAssertEqual(model.selectionNote, "Overrides the system default while recording.")
        XCTAssertEqual(harness.sent.count, 2)
        XCTAssertEqual(
            harness.sent.last,
            .setAudioInput(AudioInputSettings(mode: .customDevice, customDeviceUID: "usb"), origin: .page(.audioInput))
        )
        XCTAssertEqual(harness.settings.audioInput.customDeviceUID, "usb")

        // The device leaves: the card explains the fallback.
        provider.available = [builtIn]
        model.refresh()
        XCTAssertEqual(model.currentDeviceName, "MacBook Pro Microphone")
        XCTAssertEqual(model.selection.reason, .customDeviceUnavailable)
        XCTAssertNotNil(model.selectionNote)

        // Prioritized list editing.
        provider.available = [builtIn, usb]
        model.refresh()
        model.mode = .prioritized
        XCTAssertEqual(model.selection.reason, .noPrioritizedDeviceAvailable)
        model.addToPriority(uid: "usb")
        model.addToPriority(uid: "builtin")
        model.addToPriority(uid: "usb")
        XCTAssertEqual(model.settings.prioritizedDeviceUIDs, ["usb", "builtin"])
        XCTAssertEqual(model.devicesAvailableToAdd, [])
        model.movePriority(uid: "builtin", by: -1)
        XCTAssertEqual(model.settings.prioritizedDeviceUIDs, ["builtin", "usb"])
        model.movePriority(uid: "builtin", by: -1)
        XCTAssertEqual(model.settings.prioritizedDeviceUIDs, ["builtin", "usb"], "out-of-range moves are ignored")
        XCTAssertEqual(model.currentDeviceName, "MacBook Pro Microphone")
        model.removeFromPriority(uid: "builtin")
        XCTAssertEqual(model.currentDeviceName, "USB Microphone")

        // A listed device that is unplugged keeps a readable row.
        provider.available = [builtIn]
        model.refresh()
        XCTAssertEqual(model.prioritizedDevices.first?.isAvailable, false)
        XCTAssertTrue(model.prioritizedDevices.first?.name.hasPrefix("Disconnected device") ?? false)

        // The status menu's one-click path names its door; a change from
        // another door shows without hydration.
        let before = harness.sent.count
        model.selectDevice(uid: "builtin", origin: .statusMenu)
        XCTAssertEqual(model.mode, .customDevice)
        XCTAssertEqual(model.customDeviceUID, "builtin")
        XCTAssertEqual(harness.sent.last?.origin, .statusMenu)
        model.selectDevice(uid: nil)
        XCTAssertEqual(model.mode, .systemDefault)
        XCTAssertEqual(harness.sent.last?.origin, .page(.audioInput))
        XCTAssertEqual(harness.sent.count, before + 2)
        harness.commitFromElsewhere(.setAudioInput(AudioInputSettings(mode: .prioritized, prioritizedDeviceUIDs: ["usb"]), origin: .import))
        XCTAssertEqual(model.mode, .prioritized)
        XCTAssertEqual(model.settings.prioritizedDeviceUIDs, ["usb"])
        XCTAssertEqual(harness.sent.count, before + 2)

        XCTAssertNotNil(AudioInputSectionView(inputSelection: model))
        XCTAssertNotNil(AudioInputSectionView())
    }

    /// `.setAudioInput` is loaded-gated, not idle-gated: a running job keeps
    /// the device it started with per job, so the page keeps working. Before
    /// the settings file is read, though, the write is refused and the
    /// control stays put with the note.
    func testAudioInputRefusalBeforeLoadSnapsBackWithTheNote() {
        let provider = ScriptedDevices(available: [], systemDefault: nil)
        let harness = SettingsProjectionTestHarness()
        let model = AudioInputViewModel(host: harness.host, deviceProvider: provider)

        harness.startJob()
        model.mode = .prioritized
        XCTAssertEqual(model.mode, .prioritized, "a job does not gate the input device")
        XCTAssertNil(model.refusalNote)

        harness.gate = SettingsGate(settingsLoaded: false)
        model.mode = .customDevice
        XCTAssertEqual(model.mode, .prioritized)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
        XCTAssertEqual(harness.sent.last, .setAudioInput(AudioInputSettings(mode: .customDevice), origin: .page(.audioInput)))
    }

    /// The Bluetooth start-latency note (2026-09-16) follows the device the
    /// next recording would use, whichever way it was chosen, and never
    /// appears for a wired or built-in microphone.
    func testBluetoothNoteFollowsTheResolvedInputDevice() {
        let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
        let airPods = AudioInputDevice(uid: "bt", name: "AirPods Pro", isBluetooth: true)
        let provider = ScriptedDevices(available: [builtIn, airPods], systemDefault: builtIn)
        let model = AudioInputViewModel(deviceProvider: provider)
        XCTAssertNil(model.bluetoothInputNote, "system default is the built-in mic")

        model.selectDevice(uid: "bt")
        XCTAssertEqual(
            model.bluetoothInputNote,
            "Bluetooth microphones can take a few seconds to start; wait for the start cue before speaking, or use the built-in or a wired microphone."
        )

        // Unplugged: the fallback is the built-in mic, so no note.
        provider.available = [builtIn]
        model.refresh()
        XCTAssertNil(model.bluetoothInputNote)

        // The system default itself is the headset.
        let headsetDefault = ScriptedDevices(available: [builtIn, airPods], systemDefault: airPods)
        let following = AudioInputViewModel(deviceProvider: headsetDefault)
        XCTAssertNotNil(following.bluetoothInputNote)

        XCTAssertNotNil(RecordingSectionView(inputSelection: following))
        XCTAssertNotNil(RecordingSectionView())
    }
}

private final class ScriptedDevices: AudioInputDeviceProviding, @unchecked Sendable {
    var available: [AudioInputDevice]
    let systemDefault: AudioInputDevice?

    init(available: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        self.available = available
        self.systemDefault = systemDefault
    }

    func availableInputDevices() -> [AudioInputDevice] { available }
    func systemDefaultInputDevice() -> AudioInputDevice? { systemDefault }
}

@MainActor
final class TriggerSettingsViewModelTests: XCTestCase {
    func testBindingsWriteThroughAsOneIntentPerEdit() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        let recording = model.recordingOptionBindings
        let triggers = model.triggerOptionBindings

        recording.soundFeedback?.wrappedValue = false
        recording.cueSet?.wrappedValue = .system(name: "Glass")
        recording.muteSystemAudio?.wrappedValue = true
        recording.preserveClipboard?.wrappedValue = true
        triggers.autoSend?.wrappedValue = true
        triggers.middleMouseToggle?.wrappedValue = true
        triggers.middleMouseActivationDelayMilliseconds?.wrappedValue = 5_000
        XCTAssertEqual(harness.sent.count, 7)
        XCTAssertFalse(model.snapshot.recordingFeedback.soundFeedbackEnabled)
        XCTAssertEqual(model.snapshot.recordingFeedback.cueSet, .system(name: "Glass"))
        XCTAssertTrue(model.snapshot.recordingFeedback.muteSystemAudioDuringRecording)
        XCTAssertTrue(model.snapshot.recordingFeedback.preserveTranscriptInClipboard)
        XCTAssertTrue(model.snapshot.triggers.autoSendEnabled)
        XCTAssertTrue(model.snapshot.triggers.middleMouseToggleEnabled)
        XCTAssertEqual(model.snapshot.triggers.middleMouseActivationDelayMilliseconds, 2_000, "clamped to the supported range")

        // Every edit is `.setTriggers` with the whole snapshot, from the page
        // the control lives on.
        let origins = harness.sent.map(\.origin)
        XCTAssertEqual(origins, [
            .page(.recording), .page(.recording), .page(.recording), .page(.recording),
            .page(.shortcuts), .page(.shortcuts), .page(.shortcuts)
        ])
        guard case .setTriggers(let snapshot, _) = harness.sent[1] else { return XCTFail("expected setTriggers") }
        XCTAssertEqual(snapshot.recordingFeedback.cueSet, .system(name: "Glass"), "the cue set travels in the same snapshot, behind the same idle gate")
        XCTAssertEqual(harness.settings.recordingFeedback.cueSet, .system(name: "Glass"))
        XCTAssertEqual(harness.effects.suffix(3), [.applyTriggerSettings, .persist, .rebuildMenu])

        // Writing the same value again is not a change.
        triggers.autoSend?.wrappedValue = true
        XCTAssertEqual(harness.sent.count, 7)
    }

    /// The trigger and recording controls are disabled while a job runs
    /// (the availability table), but the reducer is the last word: an edit
    /// that reaches it mid-job is refused, the binding reads the stored
    /// value, and both pages' bindings carry the note.
    func testARefusalSnapsTheBindingBackAndCarriesTheNote() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        harness.startJob()

        model.recordingOptionBindings.muteSystemAudio?.wrappedValue = true

        XCTAssertEqual(model.recordingOptionBindings.muteSystemAudio?.wrappedValue, false)
        XCTAssertFalse(harness.settings.recordingFeedback.muteSystemAudioDuringRecording)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
        XCTAssertEqual(model.recordingOptionBindings.refusalNote?(), "Finish the current dictation first.")
        XCTAssertEqual(model.triggerOptionBindings.refusalNote?(), "Finish the current dictation first.")
        XCTAssertTrue(harness.effects.isEmpty)

        harness.endJob()
        model.recordingOptionBindings.muteSystemAudio?.wrappedValue = true
        XCTAssertTrue(harness.settings.recordingFeedback.muteSystemAudioDuringRecording)
        XCTAssertNil(model.recordingOptionBindings.refusalNote?())
    }

    func testAChangeFromAnotherDoorShowsWithoutHydration() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        let binding = model.recordingOptionBindings.recorderStyle
        XCTAssertEqual(binding?.wrappedValue, .mini)

        harness.commitFromElsewhere(.resetToDefault(.recorderStyle, origin: .page(.recording)))
        XCTAssertEqual(binding?.wrappedValue, .mini, "already default: a no-op")
        var imported = AppSettings()
        imported.recorderStyle = .notch
        imported.maxRecordingSeconds = 1_800
        harness.commitFromElsewhere(.replaceAll(imported, origin: .import))

        XCTAssertEqual(binding?.wrappedValue, .notch)
        XCTAssertEqual(model.recordingOptionBindings.maxRecordingSeconds?.wrappedValue, 1_800)
        XCTAssertTrue(harness.sent.isEmpty)

        // Reset to Default from the page's row is a shell-sent intent the
        // projection simply reflects (slice 5 needed a hydrate for this).
        harness.clearRecords()
        harness.commitFromElsewhere(.resetToDefault(.recorderStyle, origin: .page(.recording)))
        XCTAssertEqual(binding?.wrappedValue, .mini)
        XCTAssertEqual(harness.effects, [.applyTriggerSettings, .persist, .rebuildMenu])
    }

    /// The Preview button is the shell's player behind a hook: absent, the
    /// bindings carry no preview (the page disables the button); installed,
    /// it receives the set the picker shows, committed or not.
    func testPreviewCueHookIsHandedToTheBindingsOnlyWhenInstalled() {
        let model = TriggerSettingsViewModel()
        XCTAssertNil(model.recordingOptionBindings.previewCue)

        var previewed: [RecordingFeedbackCueSet] = []
        model.previewCue = { previewed.append($0) }
        model.recordingOptionBindings.previewCue?(.systemClassic)
        XCTAssertEqual(previewed, [.systemClassic])
        XCTAssertEqual(model.snapshot.recordingFeedback.cueSet, .kvoice, "a preview commits nothing")
    }

    /// ADR-021: the recorder style travels in the same snapshot as the other
    /// recording settings, so it sits behind the same idle gate.
    func testRecorderStyleRoundTripsThroughTheSnapshotAndBinding() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        let binding = model.recordingOptionBindings.recorderStyle
        XCTAssertEqual(binding?.wrappedValue, .mini)

        binding?.wrappedValue = .notch
        XCTAssertEqual(model.snapshot.recorderStyle, .notch)
        XCTAssertEqual(harness.settings.recorderStyle, .notch)
        guard case .setTriggers(let snapshot, let origin) = harness.sent.last else { return XCTFail("expected setTriggers") }
        XCTAssertEqual(snapshot.recorderStyle, .notch)
        XCTAssertEqual(origin, .page(.recording))
        XCTAssertEqual(TriggerSettingsSnapshot(settings: harness.settings).recorderStyle, .notch)
    }

    func testDurationLimitMapsNoLimitToTheTechnicalCeiling() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        let binding = model.recordingOptionBindings.maxRecordingSeconds
        XCTAssertEqual(binding?.wrappedValue, 600)

        binding?.wrappedValue = nil
        XCTAssertEqual(model.snapshot.maxRecordingSeconds, RecordingDurationLimit.technicalCeilingSeconds)
        XCTAssertEqual(model.recordingDurationLimit, .noLimit)
        XCTAssertNil(binding?.wrappedValue)

        binding?.wrappedValue = 1_800
        XCTAssertEqual(model.snapshot.maxRecordingSeconds, 1_800)
        XCTAssertEqual(harness.settings.maxRecordingSeconds, 1_800)

        // A hand-edited value maps to the picker case at or above it.
        var edited = harness.settings
        edited.maxRecordingSeconds = 45
        harness.commitFromElsewhere(.replaceAll(edited, origin: .import))
        XCTAssertEqual(binding?.wrappedValue, 600)
        XCTAssertEqual(harness.sent.count, 2, "a change from elsewhere is not an edit")
    }

    func testSecondaryShortcutsRecordClearAndCarryErrors() {
        let harness = SettingsProjectionTestHarness()
        let model = TriggerSettingsViewModel(host: harness.host)
        var recorded: [String] = []
        model.recordCancelShortcut = { recorded.append("cancel") }

        model.triggerOptionBindings.cancelShortcut?.record()
        XCTAssertEqual(recorded, ["cancel"])

        let cancel = ShortcutDefinition(key: "escape", modifiers: ["command"])
        model.cancelShortcutError = "That shortcut is already used by macOS."
        model.setCancelShortcut(cancel)
        XCTAssertEqual(model.snapshot.triggers.cancelShortcut, cancel)
        XCTAssertNil(model.cancelShortcutError, "a new recording clears the old error")
        model.setCancelShortcut(ShortcutDefinition(key: "x", modifiers: []))
        XCTAssertEqual(model.snapshot.triggers.cancelShortcut, cancel, "a bare key is refused")
        model.setCancelShortcut(.rightOption)
        XCTAssertEqual(model.snapshot.triggers.cancelShortcut, .rightOption, "a lone modifier is accepted")

        model.triggerOptionBindings.cancelShortcut?.clear()
        XCTAssertNil(model.snapshot.triggers.cancelShortcut)
        XCTAssertEqual(harness.sent.count, 3)
        XCTAssertEqual(harness.sent.map(\.origin), Array(repeating: .page(.shortcuts), count: 3))
        XCTAssertNil(harness.settings.triggers.cancelShortcut)
        XCTAssertTrue(model.triggerOptionBindings.isBound)
    }
}
