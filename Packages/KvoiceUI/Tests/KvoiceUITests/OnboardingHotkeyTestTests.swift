import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// Later waves: onboarding hotkey test — the shortcut page's Try It
/// indicator since the six-step wizard (P-W1, 2026-09-16; it was its own
/// step before). `OnboardingViewModel` never touches
/// real time or a real global shortcut here — `reportHotkeyTestKeyDown()/Up()`
/// and `tickHotkeyTest()` all take an explicit `now:`, standing in for the
/// shell forwarding real `ShortcutEvent`s through the onboarding-scoped hook
/// (`AppDelegate.onboardingHotkeyTestHook`, `AppDelegate+Settings.receiveShortcut`).
@MainActor
final class OnboardingHotkeyTestTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    /// The indicator exists only once a shortcut is registered, so every
    /// model here starts on the shortcut page with one.
    private let registered = GeneralSettingsViewModel.recommendedShortcut

    // MARK: Hook lifecycle

    func testHookIsInstalledOnlyBetweenBeginAndEnd() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered, onIntent: { intents.append($0) })

        XCTAssertFalse(model.hotkeyTestHookInstalled)
        // A report arriving before the hook is installed must be inert.
        model.reportHotkeyTestKeyDown(at: epoch)
        XCTAssertFalse(model.hotkeyTestSnapshot.isDown)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 0)

        model.beginHotkeyTest()
        XCTAssertTrue(model.hotkeyTestHookInstalled)
        XCTAssertEqual(intents, [.beginHotkeyTest])
        // A fresh test each time the step is (re-)entered.
        XCTAssertEqual(model.hotkeyTestSnapshot, HotkeyTestSnapshot())

        model.endHotkeyTest()
        XCTAssertFalse(model.hotkeyTestHookInstalled)
        XCTAssertEqual(intents, [.beginHotkeyTest, .endHotkeyTest])

        // Reports after the hook is removed (leaving the step) never resume
        // dictation and never mark the test done.
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(1))
        XCTAssertFalse(model.hotkeyTestSnapshot.isDone)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 0)
    }

    func testBeginHotkeyTestIsIdempotentAndDoesNotReemit() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered, onIntent: { intents.append($0) })

        model.beginHotkeyTest()
        model.beginHotkeyTest()
        XCTAssertEqual(intents, [.beginHotkeyTest], "a second begin while already installed must not re-emit")

        model.endHotkeyTest()
        model.endHotkeyTest()
        XCTAssertEqual(intents, [.beginHotkeyTest, .endHotkeyTest], "a second end while already removed must not re-emit")
    }

    // MARK: Push-to-talk and hybrid: one full press/release finishes it

    func testPushToTalkFinishesOnKeyUpAndTracksHeldDuration() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .pushToTalk, shortcut: registered)
        model.beginHotkeyTest()

        model.reportHotkeyTestKeyDown(at: epoch)
        XCTAssertTrue(model.hotkeyTestSnapshot.isDown)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 1)
        XCTAssertFalse(model.hotkeyTestSnapshot.isDone)

        model.tickHotkeyTest(now: epoch.addingTimeInterval(0.8))
        XCTAssertEqual(model.hotkeyTestSnapshot.heldSeconds ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(model.hotkeyTestStatusDescription, "Held for 0.8 s")

        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(1.2))
        XCTAssertFalse(model.hotkeyTestSnapshot.isDown)
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
        XCTAssertEqual(model.hotkeyTestSnapshot.heldSeconds ?? -1, 1.2, accuracy: 0.001)
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
    }

    func testHybridAlsoFinishesOnOneFullPressRelease() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .hybrid, shortcut: registered)
        model.beginHotkeyTest()

        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.1))
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
    }

    func testPushToTalkStatusBeforeAnyPress() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .pushToTalk, shortcut: registered)
        model.beginHotkeyTest()
        XCTAssertEqual(model.hotkeyTestStatusDescription, "Press and hold your shortcut now.")
    }

    // MARK: Toggle: two key-downs, key-up has no lifecycle meaning

    func testToggleIgnoresKeyUpAndFinishesOnTheSecondKeyDown() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .toggle, shortcut: registered)
        model.beginHotkeyTest()

        model.reportHotkeyTestKeyDown(at: epoch)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 1)
        XCTAssertFalse(model.hotkeyTestSnapshot.isDone)
        XCTAssertEqual(model.hotkeyTestStatusDescription, "Press it again to stop.")

        // Toggle mode: a key-up must not finish the test or reset the count.
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.05))
        XCTAssertFalse(model.hotkeyTestSnapshot.isDone)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 1)

        model.reportHotkeyTestKeyDown(at: epoch.addingTimeInterval(2))
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 2)
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
        XCTAssertFalse(model.hotkeyTestSnapshot.isDown, "the toggle stop edge is not a held state")
    }

    func testToggleStatusBeforeAnyPress() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .toggle, shortcut: registered)
        model.beginHotkeyTest()
        XCTAssertEqual(model.hotkeyTestStatusDescription, "Press your shortcut to start.")
    }

    func testDoneReportsAreIgnored() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .pushToTalk, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.5))
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)

        // Pressing the (now-registered) shortcut again after success must not
        // change the recorded press count or held duration.
        model.reportHotkeyTestKeyDown(at: epoch.addingTimeInterval(5))
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 1)
    }

    // MARK: Action bar and navigation

    func testActionBarIsDisabledUntilDoneAndOffersSkip() {
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered)
        XCTAssertTrue(model.hotkeyTestIsAvailable)
        XCTAssertFalse(model.actionBar.primaryIsEnabled)
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Press your shortcut to continue.")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip")

        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.3))
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
    }

    /// The indicator is on the shortcut page only while a shortcut is
    /// registered: no shortcut, nothing to detect, no hook.
    func testIndicatorIsAvailableOnlyOnTheShortcutPageWithARegisteredShortcut() {
        XCTAssertFalse(OnboardingViewModel(stage: .shortcut).hotkeyTestIsAvailable, "no shortcut yet")
        XCTAssertFalse(OnboardingViewModel(stage: .ready, shortcut: registered).hotkeyTestIsAvailable, "wrong page")
        XCTAssertFalse(OnboardingViewModel(stage: .accessibility, shortcut: registered).hotkeyTestIsAvailable)

        let model = OnboardingViewModel(stage: .shortcut)
        XCTAssertEqual(model.actionBar.primaryTitle, "Record Shortcut…")
        _ = model.setShortcut(registered)
        XCTAssertTrue(model.hotkeyTestIsAvailable, "recording the shortcut brings the indicator up on the same page")

        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed))
        XCTAssertFalse(model.hotkeyTestIsAvailable, "a failed registration takes the indicator (and the hook) away")
    }

    func testAdvanceAndSkipBothLeaveForReadyRegardlessOfCompletion() {
        let notDone = OnboardingViewModel(stage: .shortcut, shortcut: registered)
        notDone.performSkipAction()
        XCTAssertEqual(notDone.stage, .ready)
        XCTAssertEqual(notDone.readiness.shortcut, .ready, "Skip on a registered shortcut skips only the check")

        let done = OnboardingViewModel(stage: .shortcut, shortcut: registered)
        done.beginHotkeyTest()
        done.reportHotkeyTestKeyDown(at: epoch)
        done.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.3))
        done.advance()
        XCTAssertEqual(done.stage, .ready)
    }

    /// A shortcut recorded mid-step ("Choose Another Shortcut…") must not
    /// carry over a stale press count from the shortcut it replaced.
    func testChoosingAnotherShortcutMidStepResetsTheTest() {
        let model = OnboardingViewModel(stage: .shortcut, recordingInteraction: .toggle, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        XCTAssertEqual(model.hotkeyTestSnapshot.pressCount, 1)

        _ = model.setShortcut(ShortcutDefinition(key: "j", modifiers: ["command", "shift"]))
        XCTAssertEqual(model.hotkeyTestSnapshot, HotkeyTestSnapshot())
    }

    func testTickOnlyAdvancesWhileHeld() {
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered)
        model.beginHotkeyTest()
        // No key down yet: ticking must not fabricate a held duration.
        model.tickHotkeyTest(now: epoch)
        XCTAssertNil(model.hotkeyTestSnapshot.heldSeconds)

        model.reportHotkeyTestKeyDown(at: epoch)
        model.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.4))
        let heldAtRelease = model.hotkeyTestSnapshot.heldSeconds
        // Ticking after release must not keep advancing a frozen reading.
        model.tickHotkeyTest(now: epoch.addingTimeInterval(10))
        XCTAssertEqual(model.hotkeyTestSnapshot.heldSeconds, heldAtRelease)
    }

    func testRestartClearsTheHotkeyTest() {
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown(at: epoch)
        model.restart()
        XCTAssertEqual(model.hotkeyTestSnapshot, HotkeyTestSnapshot())
        XCTAssertFalse(model.hotkeyTestHookInstalled)
    }

    /// Reset Onboarding calls `restart()` directly; it does not wait for the
    /// view's `.task(id: stage)` to notice `stage` changed and cancel. If
    /// `restart()` merely reset the flag instead of calling `endHotkeyTest()`,
    /// the shell's `AppDelegate.onboardingHotkeyTestHook` would stay
    /// installed and swallow every shortcut press until relaunch.
    func testRestartWhileHotkeyTestIsActiveEmitsEndHotkeyTest() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, shortcut: registered, onIntent: { intents.append($0) })
        model.beginHotkeyTest()
        XCTAssertEqual(intents, [.beginHotkeyTest])

        model.restart()

        XCTAssertEqual(intents, [.beginHotkeyTest, .endHotkeyTest], "the shell must be told to remove its hook")
        XCTAssertFalse(model.hotkeyTestHookInstalled)

        // A stray report after restart (e.g. a late key-up arriving before
        // the shell finishes removing the hook) must stay inert.
        model.reportHotkeyTestKeyUp(at: epoch)
        XCTAssertEqual(intents, [.beginHotkeyTest, .endHotkeyTest])
    }

    /// A `restart()` with no hotkey test in progress must not emit a
    /// spurious `.endHotkeyTest` — `endHotkeyTest()` stays idempotent.
    func testRestartWithNoHotkeyTestInProgressEmitsNothing() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(onIntent: { intents.append($0) })
        model.restart()
        XCTAssertTrue(intents.isEmpty)
    }
}
