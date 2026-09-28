import XCTest
@testable import KvoiceDomain

/// The `Triggers and audio` block of `AppSettings` (product decisions #5 and
/// #10): trigger options, recording feedback, the input-device preference,
/// the duration-limit picker, and the pure device resolver.
final class TriggerAndAudioSettingsTests: XCTestCase {
    func testTriggersAndAudioBlockRoundTripsAndDefaultsWhenAbsent() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.triggers, TriggerSettings())
        XCTAssertEqual(settings.recordingFeedback, RecordingFeedbackSettings())
        XCTAssertEqual(settings.audioInput, AudioInputSettings())
        XCTAssertEqual(settings.recordingDurationLimit, .tenMinutes)
        XCTAssertNil(settings.triggers.cancelShortcut)
        XCTAssertFalse(settings.triggers.autoSendEnabled)
        XCTAssertFalse(settings.triggers.middleMouseToggleEnabled)
        XCTAssertTrue(settings.recordingFeedback.soundFeedbackEnabled)
        XCTAssertEqual(settings.recordingFeedback.cueSet, .kvoice)
        XCTAssertFalse(settings.recordingFeedback.muteSystemAudioDuringRecording)
        XCTAssertFalse(settings.recordingFeedback.preserveTranscriptInClipboard)
        XCTAssertEqual(settings.audioInput.mode, .systemDefault)

        settings.triggers = TriggerSettings(
            cancelShortcut: ShortcutDefinition(key: "escape", modifiers: ["command"]),
            autoSendEnabled: true,
            middleMouseToggleEnabled: true,
            middleMouseActivationDelayMilliseconds: 750
        )
        settings.recordingFeedback = RecordingFeedbackSettings(
            soundFeedbackEnabled: false,
            cueSet: .system(name: "Glass"),
            muteSystemAudioDuringRecording: true,
            preserveTranscriptInClipboard: true
        )
        settings.audioInput = AudioInputSettings(
            mode: .prioritized,
            customDeviceUID: "BuiltInMicrophoneDevice",
            prioritizedDeviceUIDs: ["usb-1", "bt-2", "usb-1", ""]
        )
        settings.recordingDurationLimit = .oneHour
        XCTAssertEqual(settings.maxRecordingSeconds, 3_600)
        XCTAssertEqual(settings.audioInput.prioritizedDeviceUIDs, ["usb-1", "bt-2"], "duplicates and blanks are dropped")
        XCTAssertEqual(settings.triggers.middleMouseActivationDelay, .milliseconds(750))

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)

        // A settings file written before this block existed has none of the keys.
        let legacy = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: legacy), AppSettings())
    }

    /// The cue set (2026-09-16) is one string in the file. A file written
    /// before it existed decodes to the kvoice tones — not to the alert
    /// sounds it used to play, which is the point of the change — and an
    /// unknown value never fails the whole load.
    func testCueSetRoundTripsAsOneStringAndDefaultsToKvoice() throws {
        let cases: [(RecordingFeedbackCueSet, String)] = [
            (.kvoice, "kvoice"),
            (.systemClassic, "systemClassic"),
            (.system(name: "Glass"), "system:Glass")
        ]
        for (set, raw) in cases {
            let encoded = try JSONEncoder().encode(RecordingFeedbackSettings(cueSet: set))
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"cueSet\":\"\(raw)\""))
            XCTAssertEqual(try JSONDecoder().decode(RecordingFeedbackSettings.self, from: encoded).cueSet, set)
            XCTAssertEqual(RecordingFeedbackCueSet(rawValue: raw), set)
            XCTAssertEqual(set.rawValue, raw)
        }

        let legacy = Data(#"{"soundFeedbackEnabled":true,"muteSystemAudioDuringRecording":true}"#.utf8)
        let decoded = try JSONDecoder().decode(RecordingFeedbackSettings.self, from: legacy)
        XCTAssertEqual(decoded.cueSet, .kvoice, "absent: the new default, whatever the file used to play")
        XCTAssertTrue(decoded.muteSystemAudioDuringRecording, "the other keys still load")

        let unknown = Data(#"{"cueSet":"chimes"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RecordingFeedbackSettings.self, from: unknown).cueSet, .kvoice)
        XCTAssertEqual(RecordingFeedbackCueSet(rawValue: "system:"), .kvoice, "a system sound needs a name")

        var settings = AppSettings()
        settings.recordingFeedback.cueSet = .systemClassic
        let whole = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(whole.recordingFeedback.cueSet, .systemClassic)
    }

    /// The Append shortcut was removed on 2026-09-13; a settings file written
    /// while it existed still decodes, and the stale key is dropped rather
    /// than failing the whole load (which would reset every setting).
    func testAppendShortcutKeyFromAnOlderSettingsFileIsIgnored() throws {
        let blob = Data(#"{"schemaVersion":1,"triggers":{"cancelShortcut":{"key":"escape","modifiers":["command"]},"appendShortcut":{"key":"rightCommand","modifiers":[]},"autoSendEnabled":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: blob)
        XCTAssertEqual(decoded.triggers, TriggerSettings(
            cancelShortcut: ShortcutDefinition(key: "escape", modifiers: ["command"]),
            autoSendEnabled: true
        ))
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("appendShortcut"), "the stale key is not written back")
    }

    func testMiddleMouseDelayIsClampedAndUnknownInputModeFallsBack() throws {
        XCTAssertEqual(TriggerSettings(middleMouseActivationDelayMilliseconds: -5).middleMouseActivationDelayMilliseconds, 0)
        XCTAssertEqual(TriggerSettings(middleMouseActivationDelayMilliseconds: 9_999).middleMouseActivationDelayMilliseconds, 2_000)
        XCTAssertEqual(TriggerSettings().middleMouseActivationDelayMilliseconds, TriggerSettings.defaultMiddleMouseActivationDelayMilliseconds)

        let json = Data(#"{"mode":"telepathy","prioritizedDeviceUIDs":["x","x","y"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioInputSettings.self, from: json)
        XCTAssertEqual(decoded.mode, .systemDefault)
        XCTAssertEqual(decoded.prioritizedDeviceUIDs, ["x", "y"])
        XCTAssertNil(decoded.customDeviceUID)

        let partial = Data(#"{"autoSendEnabled":true}"#.utf8)
        let triggers = try JSONDecoder().decode(TriggerSettings.self, from: partial)
        XCTAssertTrue(triggers.autoSendEnabled)
        XCTAssertEqual(triggers.middleMouseActivationDelayMilliseconds, 300)
    }

    func testRecordingDurationLimitMapsStoredSecondsAndBoundsDecoding() throws {
        XCTAssertEqual(RecordingDurationLimit(seconds: 600), .tenMinutes)
        XCTAssertEqual(RecordingDurationLimit(seconds: 45), .tenMinutes, "nearest case at or above the stored value")
        XCTAssertEqual(RecordingDurationLimit(seconds: 601), .thirtyMinutes)
        XCTAssertEqual(RecordingDurationLimit(seconds: 3_600), .oneHour)
        XCTAssertEqual(RecordingDurationLimit(seconds: 14_400), .noLimit)
        XCTAssertEqual(RecordingDurationLimit(seconds: 99_999), .noLimit)
        XCTAssertTrue(RecordingDurationLimit.noLimit.isUnlimited)
        XCTAssertFalse(RecordingDurationLimit.oneHour.isUnlimited)
        XCTAssertEqual(RecordingDurationLimit.default, .tenMinutes)
        XCTAssertEqual(
            RecordingDurationLimit.allCases.map(\.displayName),
            ["10 minutes", "30 minutes", "1 hour", "No limit"]
        )

        // The stored field accepts the technical ceiling and rejects beyond it.
        let ceiling = Data(#"{"schemaVersion":1,"maxRecordingSeconds":14400}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: ceiling).maxRecordingSeconds, 14_400)
        let beyond = Data(#"{"schemaVersion":1,"maxRecordingSeconds":14401}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: beyond))
        let zero = Data(#"{"schemaVersion":1,"maxRecordingSeconds":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: zero))

        // The cap copy follows the chosen limit instead of hard-coding ten minutes.
        XCTAssertEqual(CompletionSummary.limitDescription(seconds: 600), "10-minute")
        XCTAssertEqual(CompletionSummary.limitDescription(seconds: 1_800), "30-minute")
        XCTAssertEqual(CompletionSummary.limitDescription(seconds: 3_600), "1-hour")
        XCTAssertEqual(CompletionSummary.limitDescription(seconds: 14_400), "4-hour")
        XCTAssertEqual(CompletionSummary.limitDescription(seconds: 45), "45-second")
        let summary = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: nil, durationCapReached: true, maxRecordingSeconds: 1_800)
        XCTAssertEqual(summary.warningMessage, "Recording stopped at the 30-minute limit.")
        XCTAssertTrue(summary.durationCapReached)
    }

    func testAudioInputResolverPrefersConnectedPreferenceThenSystemDefault() {
        let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
        let usb = AudioInputDevice(uid: "usb", name: "USB Microphone")
        let unplugged = AudioInputDevice(uid: "bt", name: "AirPods", isAvailable: false)
        let available = [builtIn, usb, unplugged]

        let system = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .systemDefault, customDeviceUID: "usb"),
            available: available,
            systemDefault: builtIn
        )
        XCTAssertEqual(system, AudioInputSelection(device: builtIn, reason: .systemDefault))
        XCTAssertTrue(system.usesSystemDefault)
        XCTAssertNil(system.pinnedDeviceUID)

        let custom = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .customDevice, customDeviceUID: "usb"),
            available: available,
            systemDefault: builtIn
        )
        XCTAssertEqual(custom, AudioInputSelection(device: usb, reason: .customDevice))
        XCTAssertTrue(custom.pinsDevice)
        XCTAssertEqual(custom.pinnedDeviceUID, "usb")

        let customGone = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .customDevice, customDeviceUID: "bt"),
            available: available,
            systemDefault: builtIn
        )
        XCTAssertEqual(customGone, AudioInputSelection(device: builtIn, reason: .customDeviceUnavailable))
        XCTAssertFalse(customGone.pinsDevice, "an unplugged custom device falls back to the system default")

        let prioritized = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .prioritized, prioritizedDeviceUIDs: ["bt", "usb", "builtin"]),
            available: available,
            systemDefault: builtIn
        )
        XCTAssertEqual(prioritized, AudioInputSelection(device: usb, reason: .prioritizedDevice))
        XCTAssertEqual(prioritized.pinnedDeviceUID, "usb")

        let noneLeft = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .prioritized, prioritizedDeviceUIDs: ["bt", "nope"]),
            available: available,
            systemDefault: builtIn
        )
        XCTAssertEqual(noneLeft, AudioInputSelection(device: builtIn, reason: .noPrioritizedDeviceAvailable))
        XCTAssertTrue(noneLeft.usesSystemDefault)

        let nothing = AudioInputDeviceResolver.resolve(
            settings: AudioInputSettings(mode: .prioritized),
            available: [],
            systemDefault: nil
        )
        XCTAssertNil(nothing.device)
        XCTAssertEqual(nothing.reason, .noPrioritizedDeviceAvailable)
        XCTAssertNil(nothing.pinnedDeviceUID)
    }

    func testStartOptionsArmAutoSendOnly() {
        var job = DictationJob(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            target: nil,
            modeSnapshot: .off,
            translationTargetSnapshot: nil,
            modelIDSnapshot: "fixture"
        )
        XCTAssertEqual(job.options, DictationStartOptions())
        XCTAssertFalse(job.options.autoSend)
        job.armAutoSend()
        XCTAssertTrue(job.options.autoSend)
        XCTAssertEqual(job.options, DictationStartOptions(autoSend: true))
    }

    func testHybridInteractionAndModifierOnlyShortcutsPersistByName() throws {
        XCTAssertEqual(RecordingInteraction.hybrid.displayName, "Hybrid")
        XCTAssertEqual(RecordingInteraction.allCases, [.pushToTalk, .toggle, .hybrid])
        let data = try JSONEncoder().encode(AppSettings(recordingInteraction: .hybrid, shortcut: .rightOption))
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""recordingInteraction":"hybrid""#))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.recordingInteraction, .hybrid)
        XCTAssertEqual(decoded.shortcut?.modifierOnlyKey, .rightOption)
        XCTAssertTrue(decoded.shortcut?.isStructurallyValid ?? false)

        XCTAssertEqual(ShortcutDefinition(key: "RightOption", modifiers: []).modifierOnlyKey, .rightOption)
        XCTAssertNil(ShortcutDefinition(key: "rightOption", modifiers: ["command"]).modifierOnlyKey, "a modifier-only key with modifiers is a combination")
        XCTAssertNil(ShortcutDefinition(key: "space", modifiers: []).modifierOnlyKey)
        XCTAssertFalse(ShortcutDefinition(key: "space", modifiers: []).isStructurallyValid)
        XCTAssertEqual(ShortcutDefinition.ModifierOnlyKey.allCases.map(\.displayName),
                       ["Right Option", "Right Command", "Right Control", "Right Shift", "Fn"])
    }
}
