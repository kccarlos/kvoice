import Foundation
import KvoiceTestSupport
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F4 (setup wizard, Wizard.dc + Motion § 9–12): the new
/// seams — page direction, the 0.6 s hold rule and the orb's fill, the
/// conflict sentence, the recorder-open state, the test's clock and level,
/// and the per-state copy the design draws.
@MainActor
final class OnboardingFidelityF4Tests: XCTestCase {
    private let registered = GeneralSettingsViewModel.recommendedShortcut
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: § 9 page direction

    func testPagesKnowWhichWayTheyMoved() async {
        let model = OnboardingViewModel(stage: .welcome)
        XCTAssertTrue(model.navigatesForward)
        await model.performPrimaryAction()
        XCTAssertEqual(model.stage, .speechModel)
        XCTAssertTrue(model.navigatesForward, "Continue moves forward")
        model.goBack()
        XCTAssertFalse(model.navigatesForward, "Back moves back")

        let ready = OnboardingViewModel(stage: .ready)
        ready.goToStep(for: .microphone)
        XCTAssertEqual(ready.stage, .microphone)
        XCTAssertFalse(ready.navigatesForward, "Fix… on Ready goes back")
    }

    // MARK: § 11 shortcut check

    func testAShortPushToTalkPressDrainsAndAsksForALongerHold() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .pushToTalk, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.tickHotkeyTest(now: epoch.addingTimeInterval(0.3))
        XCTAssertEqual(model.hotkeyTestHoldProgress, 0.25, accuracy: 0.001, "fills over 1.2 s")
        XCTAssertTrue(model.hotkeyTestIsLive)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.4))

        XCTAssertFalse(model.hotkeyTestSnapshot.isDone)
        XCTAssertTrue(model.hotkeyTestSnapshot.wasTooShort)
        XCTAssertEqual(model.hotkeyTestHoldProgress, 0, "the orb drains")
        XCTAssertEqual(model.hotkeyTestTitle, "A little longer")
        XCTAssertEqual(model.hotkeyTestDetail, "Hold for at least half a second.")
        XCTAssertFalse(model.actionBar.primaryIsEnabled)

        model.reportHotkeyTestKeyDown(at: epoch.addingTimeInterval(2))
        XCTAssertFalse(model.hotkeyTestSnapshot.wasTooShort, "a new press clears the hint")
        model.tickHotkeyTest(now: epoch.addingTimeInterval(4))
        XCTAssertEqual(model.hotkeyTestHoldProgress, 1, "full at 1.2 s")
        XCTAssertEqual(model.hotkeyTestTitle, "Held for 2.0 s")
        XCTAssertEqual(model.hotkeyTestDetail, "Keep holding… then let go.")
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(4))
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
        XCTAssertEqual(model.hotkeyTestTitle, "Shortcut detected")
        XCTAssertEqual(model.hotkeyTestDetail, "You’re set.")
        XCTAssertEqual(model.hotkeyTestHoldProgress, 1)
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
    }

    func testTheHoldThresholdIsExactlySixTenths() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .pushToTalk, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(OnboardingViewModel.hotkeyTestMinimumHold))
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
    }

    func testAHybridTapStillCounts() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .hybrid, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.1))
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone, "a short tap is hybrid's toggle start")
    }

    func testToggleSaysStartedAfterTheFirstPress() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .toggle, shortcut: registered)
        model.beginHotkeyTest()
        XCTAssertEqual(model.hotkeyTestTitle, "Try it")
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.1))
        XCTAssertEqual(model.hotkeyTestTitle, "Started")
        XCTAssertEqual(model.hotkeyTestDetail, "Press it again to stop.")
        XCTAssertTrue(model.hotkeyTestIsLive)
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Press again to finish the check.")
    }

    // MARK: Conflict sentence

    func testATakenShortcutNamesItsOwnerInsteadOfAnErrorCode() {
        let spotlight = ShortcutDefinition(key: "space", modifiers: ["command"])
        let model = OnboardingViewModel(stage: .shortcut, shortcut: spotlight)
        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed), problem: .takenBySystem)

        XCTAssertEqual(model.shortcutChip.title, "Taken")
        XCTAssertEqual(model.shortcutChip.tone, .err)
        XCTAssertTrue(model.shortcutIsTaken)
        XCTAssertEqual(model.shortcutError, "Spotlight already uses ⌘Space. Choose another shortcut.")

        model.setShortcutRegistrationState(.registered(spotlight))
        XCTAssertNil(model.shortcutError)
        XCTAssertNil(model.shortcutRegistrationProblem)
    }

    func testOtherFailuresGetPlainSentencesNeverACode() {
        let other = ShortcutDefinition(key: "k", modifiers: ["command", "shift"])
        let model = OnboardingViewModel(stage: .shortcut, shortcut: other)
        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed), problem: .takenBySystem)
        XCTAssertEqual(model.shortcutError, "macOS already uses ⇧⌘K. Choose another shortcut.")
        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed), problem: .takenByMenu)
        XCTAssertEqual(model.shortcutError, "A KVoice menu command already uses ⇧⌘K. Choose another shortcut.")
        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed))
        XCTAssertEqual(model.shortcutError, "KVoice could not register ⇧⌘K. Choose another shortcut.")
        XCTAssertFalse(model.shortcutIsTaken)
        XCTAssertEqual(model.shortcutChip.title, "Not registered")
        XCTAssertFalse(model.shortcutError?.contains("HOTKEY") ?? true)
    }

    func testKnownSystemOwners() {
        XCTAssertEqual(ShortcutRegistrationProblem.knownSystemOwner(of: .init(key: "space", modifiers: ["command"])), .spotlight)
        XCTAssertEqual(ShortcutRegistrationProblem.knownSystemOwner(of: .init(key: "space", modifiers: ["option", "command"])), .finderSearch)
        XCTAssertEqual(ShortcutRegistrationProblem.knownSystemOwner(of: .init(key: "space", modifiers: ["control"])), .inputSources)
        XCTAssertNil(ShortcutRegistrationProblem.knownSystemOwner(of: .init(key: "space", modifiers: ["control", "shift"])))
        XCTAssertNil(ShortcutRegistrationProblem.knownSystemOwner(of: .init(key: "k", modifiers: ["command"])))
    }

    // MARK: Recording keys

    func testTheRecorderWindowDrivesTheRecordingState() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, onIntent: { intents.append($0) })
        model.cancelShortcutRecording()
        XCTAssertTrue(intents.isEmpty, "nothing to cancel while the recorder is closed")

        model.setShortcutRecorderOpen(true)
        XCTAssertEqual(model.shortcutChip.title, "Recording")
        XCTAssertEqual(model.shortcutChip.tone, .cursor)
        XCTAssertTrue(model.actionBar.primaryIsBusy)
        XCTAssertFalse(model.actionBar.skipIsEnabled)

        model.cancelShortcutRecording()
        XCTAssertEqual(intents, [.cancelShortcutRecording])
        model.setShortcutRecorderOpen(false)
        XCTAssertEqual(model.shortcutChip.title, "Not set")
        XCTAssertFalse(model.actionBar.primaryIsBusy)
    }

    // MARK: Ready's test box

    func testTheTestBoxHasAClockAndTimesTheTranscription() {
        let clock = ManualClock()
        let model = OnboardingViewModel(stage: .ready, clock: clock)
        model.setDictationTestRecording(true)
        clock.advance(by: .seconds(4))
        XCTAssertEqual(model.dictationTestElapsedDescription(), "0:04")
        clock.advance(by: .seconds(60))
        XCTAssertEqual(model.dictationTestElapsedDescription(), "1:04")

        model.setDictationTestRecording(false)
        clock.advance(by: .milliseconds(400))
        model.setDictationTestResult(.transcript("Testing one two three"))
        XCTAssertEqual(model.dictationTestTranscriptionTime, .milliseconds(400))
        XCTAssertEqual(model.dictationTestResultCaption, "Transcribed on this Mac in 0.4 s. Not inserted anywhere.")

        model.setDictationTestResult(.failed(message: "No audio"))
        XCTAssertNil(model.dictationTestTranscriptionTime)
    }

    func testTheLiveLevelRisesFastAndResets() {
        let level = OnboardingLiveLevel()
        level.apply(raw: 1, elapsed: 0.05)
        XCTAssertGreaterThan(level.level, 0.9, "≈ 50 ms attack")
        level.apply(raw: 0, elapsed: 0.05)
        XCTAssertGreaterThan(level.level, 0.3, "slower release")
        level.reset()
        XCTAssertEqual(level.level, 0)

        let model = OnboardingViewModel(stage: .ready)
        model.dictationTestLevel.apply(raw: 1)
        model.setDictationTestRecording(true)
        XCTAssertEqual(model.dictationTestLevel.level, 0, "a new recording starts silent")
    }

    func testTheWaitingLineNamesWhatIsOpen() {
        let model = OnboardingViewModel(stage: .ready, modelState: .downloading(completed: 64, total: 100), microphoneAuthorization: .granted,
                                        microphoneTestState: .completed(MicrophoneTestResult(duration: .seconds(3), peakLevelDBFS: -12, capturedSamples: 1)),
                                        shortcut: registered)
        XCTAssertEqual(model.dictationTestWaitingText, "Waiting on Model. It unlocks when the download finishes.")
        XCTAssertFalse(model.readinessNeedsFinishNote, "a model on its way needs nothing from the user")

        let blocked = OnboardingViewModel(stage: .ready, modelState: .absent)
        XCTAssertEqual(blocked.dictationTestWaitingText, "Waiting on Model, Microphone, and Shortcut. Use Fix… above.")
        XCTAssertTrue(blocked.readinessHasOpenItems)
        XCTAssertTrue(blocked.readinessNeedsFinishNote)
    }

    // MARK: Model card copy

    func testThePausedCardShowsWhatIsKept() {
        let entry = SpeechModelCatalogEntry(
            id: "w", displayName: "Whisper", variantName: "", family: "whisper", runtime: .whisperKitCoreML,
            hosting: .onDevice, supportsStreaming: true, supportsBatch: true, downloadBytes: 1_000,
            languageSummary: "", summary: "", isRecommended: true, revision: "r", manifestResource: "w", manifestSHA256: "x"
        )
        let model = OnboardingViewModel(stage: .speechModel, modelState: .downloadPaused(resumableBytes: 420), modelEntry: entry)
        let paused = model.modelPausedProgress
        XCTAssertEqual(paused?.fraction ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(paused?.trailing, "42%")
        XCTAssertEqual(model.modelCardLine?.text, "Resume to continue where it stopped.")
        XCTAssertTrue(model.modelShowsFoot)
        XCTAssertNil(model.modelStepNote)

        model.setModelState(.downloading(completed: 1, total: 2))
        XCTAssertFalse(model.modelShowsFoot, "Choose Existing… is hidden while a download runs")
        XCTAssertEqual(model.modelStepNote, "Continue now — the Ready step shows its progress, and dictation unlocks the moment it finishes.")
        XCTAssertEqual(model.modelCardLine?.emphasized, true)
    }

    func testTheNoSpaceAlertNamesBothSizes() {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 410_000_000)
        let message = model.modelNoSpaceMessage ?? ""
        XCTAssertTrue(message.hasPrefix("Not enough free space for the download (needs about "), message)
        XCTAssertTrue(message.contains(ModelSettingsViewModel.formatBytes(410_000_000)), message)
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Not enough space")
    }

    // MARK: Microphone

    func testPickingAnotherInputAsksForTheLevelTestAgain() {
        let passed = MicrophoneTestState.completed(MicrophoneTestResult(duration: .seconds(3), peakLevelDBFS: -12.4, capturedSamples: 1))
        let model = OnboardingViewModel(stage: .microphone, microphoneAuthorization: .granted, microphoneTestState: passed)
        XCTAssertEqual(model.microphoneLevelStatus, "Level test complete (peak \u{2212}12 dBFS). Sounds good.")
        model.inputDeviceNameProvider = { "Studio Mic" }
        XCTAssertEqual(model.checklistDetail(for: .microphone), "Studio Mic · tested")

        model.microphoneInputChanged()
        XCTAssertEqual(model.microphoneTestState, .notStarted)
        XCTAssertEqual(model.actionBar.primaryTitle, "Run Level Test")
    }

    // MARK: Ready's AI line

    func testTheAILineNamesTheActionAndTheConfiguration() {
        let configuration = AIConfiguration(name: "Local Ollama", kind: .ollama)
        let action = PromptMode(name: "Clean Up", behavior: .polish, prompt: "p")
        var settings = AppSettings()
        settings.ai.configurations = [configuration]
        settings.ai.activeConfigurationID = configuration.id
        settings.ai.promptModes = [action]
        settings.ai.activePromptModeID = action.id
        let ai = AISettingsViewModel(host: .detached(settings: settings))
        XCTAssertEqual(ai.activeActionName, "Clean Up")
        XCTAssertEqual(ai.activeConfigurationName, "Local Ollama")
        XCTAssertNil(AISettingsViewModel().activeActionName)
    }
}
