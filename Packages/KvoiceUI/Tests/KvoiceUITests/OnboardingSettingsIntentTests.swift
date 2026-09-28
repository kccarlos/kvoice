import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 slice 7: the wizard writes its settings through the same
/// `SettingsProjectionHost` as every page — trigger mode and shortcut as
/// `SettingsIntent`s with origin `.wizard`, completion as the
/// `LocalStateIntent` — and reads the trigger mode back from the host, so
/// the wizard and the Shortcuts page can never disagree.
@MainActor
final class OnboardingSettingsIntentTests: XCTestCase {
    func testTheTriggerModeIsSentWithTheWizardOriginAndReadBackFromTheHost() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host, onIntent: { intents.append($0) })
        XCTAssertEqual(model.recordingInteraction, .pushToTalk)

        model.setRecordingInteraction(.toggle)

        XCTAssertEqual(harness.sent, [.setRecordingInteraction(.toggle, origin: .wizard)])
        XCTAssertEqual(harness.settings.recordingInteraction, .toggle)
        XCTAssertEqual(model.recordingInteraction, .toggle)
        XCTAssertEqual(harness.effects, [.persist, .rebuildMenu], "the same row as the page's edit; no hydrate")
        XCTAssertEqual(intents, [.setRecordingInteraction(.toggle)], "the notification still reaches the shell")

        model.setRecordingInteraction(.toggle)
        XCTAssertEqual(harness.sent.count, 1, "an equal pick sends nothing")

        // The stored mode is the wizard's mode: a change from the page shows
        // in the wizard with nothing re-applied.
        harness.commitFromElsewhere(.setRecordingInteraction(.hybrid, origin: .page(.shortcuts)))
        XCTAssertEqual(model.recordingInteraction, .hybrid)
    }

    func testARefusedTriggerModeLeavesThePickerOnTheStoredValue() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host, onIntent: { intents.append($0) })
        harness.startJob()

        model.setRecordingInteraction(.toggle)

        XCTAssertEqual(model.recordingInteraction, .pushToTalk)
        XCTAssertEqual(harness.settings.recordingInteraction, .pushToTalk)
        XCTAssertTrue(intents.isEmpty, "a refused write is not announced")
        XCTAssertTrue(harness.effects.isEmpty)
    }

    func testARecordedShortcutIsSentWithTheWizardOrigin() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host, onIntent: { intents.append($0) })
        let shortcut = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])

        XCTAssertTrue(model.setShortcut(shortcut))

        XCTAssertEqual(harness.sent, [.setShortcut(shortcut, origin: .wizard)])
        XCTAssertEqual(harness.settings.shortcut, shortcut)
        XCTAssertEqual(harness.effects, [.registerShortcut, .persist, .rebuildMenu])
        XCTAssertEqual(model.shortcut, shortcut)
        XCTAssertEqual(model.shortcutRegistrationState, .registered(shortcut))
        XCTAssertNil(model.shortcutError)
        XCTAssertEqual(intents, [.shortcutRecorded(shortcut)])
    }

    /// The shell's `.registerShortcut` effect runs inside the send and
    /// reports the real registration state back; the wizard must not
    /// overwrite that report with its own optimistic one.
    func testTheRegistrationReportFromInsideTheSendWins() {
        let harness = SettingsProjectionTestHarness()
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host)
        let shortcut = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])
        // Stand in for `AppDelegate.registerShortcut(from:)`: the effect
        // runner is the harness, so the report is made from a send wrapper.
        let reporting = SettingsProjectionHost(
            coordinator: harness.coordinator,
            send: { intent in
                let refusal = harness.coordinator.send(intent)
                if refusal == nil { model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed)) }
                return refusal
            }
        )
        model.settings = reporting

        XCTAssertTrue(model.setShortcut(shortcut))

        XCTAssertEqual(model.shortcutRegistrationState, .failed(.hotkeyRegistrationFailed))
        XCTAssertNotNil(model.shortcutError)
        XCTAssertEqual(harness.settings.shortcut, shortcut, "the preference is stored; registration feedback is separate")
    }

    func testARefusedShortcutPutsThePreviousStateBackWithTheNote() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host, onIntent: { intents.append($0) })
        let shortcut = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])
        harness.startJob()

        XCTAssertFalse(model.setShortcut(shortcut))

        XCTAssertNil(model.shortcut)
        XCTAssertEqual(model.shortcutRegistrationState, .unregistered)
        XCTAssertEqual(model.shortcutError, "Finish the current dictation first.")
        XCTAssertNil(harness.settings.shortcut)
        XCTAssertTrue(intents.isEmpty)
    }

    func testAnUnusableShortcutNeverReachesTheCoordinator() {
        let harness = SettingsProjectionTestHarness()
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host)
        XCTAssertFalse(model.setShortcut(ShortcutDefinition(key: "a", modifiers: [])))
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertNotNil(model.shortcutError)
    }

    func testFinishSendsCompletionAsLocalState() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        // Ready carries Finish since the six-step wizard (P-W1, 2026-09-16);
        // the Complete page it used to sit on is gone.
        let model = OnboardingViewModel(stage: .ready, settings: harness.host, onIntent: { intents.append($0) })
        XCTAssertNil(harness.localState.onboardingVersionCompleted)

        model.finishOnboarding()

        XCTAssertEqual(
            harness.sentLocalState,
            [.completeOnboarding(version: OnboardingViewModel.currentOnboardingVersion, origin: .wizard)]
        )
        XCTAssertEqual(harness.localState.onboardingVersionCompleted, OnboardingViewModel.currentOnboardingVersion)
        XCTAssertTrue(harness.localState.tutorialSeen, "completion marks the tour seen — the reducer's row; Ready offered it as a link")
        XCTAssertEqual(harness.effects, [.persistLocalState])
        XCTAssertTrue(harness.sent.isEmpty, "completion is local state, never a preference")
        XCTAssertEqual(intents, [.finish], "the shell still closes the window on the notification")
        XCTAssertTrue(model.isFinished)

        model.finishOnboarding()
        XCTAssertEqual(harness.sentLocalState.count, 1, "finishing twice sends once")
    }

    func testTheSeededTriggerModeIsOnlyForADetachedHost() {
        let detached = OnboardingViewModel(recordingInteraction: .toggle)
        XCTAssertEqual(detached.recordingInteraction, .toggle)

        let harness = SettingsProjectionTestHarness(settings: AppSettings(recordingInteraction: .hybrid))
        let hosted = OnboardingViewModel(recordingInteraction: .toggle, settings: harness.host)
        XCTAssertEqual(hosted.recordingInteraction, .hybrid, "a real host carries the stored value")
    }
}
