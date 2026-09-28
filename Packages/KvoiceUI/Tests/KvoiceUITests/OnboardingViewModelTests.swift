import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    /// P-W1 (2026-09-16): six steps. Try It lives on Shortcut, the summary
    /// and Finish on Ready, and the Quick Tour and AI Actions are links.
    func testSixStagesInOrderAndWelcomeIsTheOnlyNonSkippableOne() {
        XCTAssertEqual(OnboardingStage.allCases.count, 6)
        XCTAssertEqual(
            OnboardingStage.allCases,
            [.welcome, .speechModel, .microphone, .accessibility, .shortcut, .ready]
        )
        XCTAssertFalse(OnboardingStage.welcome.isSkippable)
        XCTAssertTrue(OnboardingStage.speechModel.isSkippable)
        XCTAssertTrue(OnboardingStage.ready.isSkippable)
        XCTAssertEqual(OnboardingStage.ready.ordinal, 6)
        XCTAssertNil(OnboardingStage.ready.next)
        XCTAssertEqual(OnboardingStage.shortcut.next, .ready)
        XCTAssertEqual(OnboardingStage.speechModel.title, "Speech Model")
        XCTAssertEqual(OnboardingStage.shortcut.title, "Shortcut")

        let model = OnboardingViewModel()
        XCTAssertEqual(model.progressLabel, "Step 1 of 6")
        model.advance()
        XCTAssertEqual(model.stage, .speechModel)
        XCTAssertEqual(model.progressLabel, "Step 2 of 6")
        XCTAssertTrue(model.welcomeAcknowledged)
        XCTAssertEqual(OnboardingViewModel(stage: .ready).progressLabel, "Step 6 of 6")
    }

    /// Every readiness item still maps to one of the six pages (Fix… on
    /// Ready and the failed-test link depend on it).
    func testEveryReadinessItemResolvesOnAStage() {
        XCTAssertEqual(OnboardingReadinessItem.model.stage, .speechModel)
        XCTAssertEqual(OnboardingReadinessItem.microphone.stage, .microphone)
        XCTAssertEqual(OnboardingReadinessItem.accessibility.stage, .accessibility)
        XCTAssertEqual(OnboardingReadinessItem.shortcut.stage, .shortcut)
    }

    /// The version stayed at 1 through the six-step restructure on purpose:
    /// a user who finished the ten-step wizard walked the same four
    /// prerequisites and must not be shown the wizard again.
    func testExistingCompletedUserIsNotReshownTheSixStepWizard() {
        XCTAssertEqual(OnboardingViewModel.currentOnboardingVersion, 1, "bump only when every existing user must see a new step")
        XCTAssertFalse(OnboardingViewModel.shouldPresentSetup(completedVersion: 1))
        XCTAssertFalse(OnboardingViewModel.shouldPresentSetup(completedVersion: 2), "a newer completion never replays")
        XCTAssertTrue(OnboardingViewModel.shouldPresentSetup(completedVersion: nil), "a fresh Mac")
        XCTAssertTrue(OnboardingViewModel.shouldPresentSetup(completedVersion: 0))
    }

    /// Reset Onboarding: `restart()` returns to Welcome from anywhere,
    /// keeps what is still true, and clears navigation-only state.
    func testResetOnboardingStartsAtWelcomeAndKeepsTheFacts() {
        let readyModel = ModelLifecycleState.ready(InstalledModelSummary(modelID: "m", revision: "r", ownership: .managedByKvoice))
        let model = OnboardingViewModel(
            stage: .ready, modelState: readyModel, microphoneAuthorization: .granted,
            shortcut: GeneralSettingsViewModel.recommendedShortcut
        )
        model.setDictationTestResult(.transcript("hello"))
        model.finishOnboarding()
        XCTAssertTrue(model.isFinished)

        model.restart()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertEqual(model.progressLabel, "Step 1 of 6")
        XCTAssertFalse(model.isFinished)
        XCTAssertFalse(model.welcomeAcknowledged)
        XCTAssertNil(model.dictationTestResult)
        XCTAssertEqual(model.readiness.model, .ready, "an installed model is still installed")
        XCTAssertEqual(model.readiness.shortcut, .ready, "a registered shortcut is still registered")
        XCTAssertFalse(model.canGoBack)
    }

    func testModelChoicesEmitIntentsAndContinueWithoutOwningModelManager() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(onIntent: { intents.append($0) })

        model.advance()
        model.handleModelAction(.download)

        // Download stays on the model screen so the user sees it start; a
        // second press while the request is pending is ignored.
        XCTAssertEqual(model.stage, .speechModel)
        XCTAssertTrue(model.modelActionPending)
        XCTAssertTrue(model.modelIsBusy)
        XCTAssertEqual(model.actionBar.primaryTitle, "Download Model")
        XCTAssertTrue(model.actionBar.primaryIsBusy)
        XCTAssertFalse(model.actionBar.primaryIsEnabled)
        model.handleModelAction(.download)
        XCTAssertEqual(intents, [.downloadModel])
        XCTAssertEqual(model.readiness.model, .notReady)

        // The shell's poll re-reports the same state: still pending.
        model.setModelState(.absent)
        XCTAssertTrue(model.modelActionPending)
        model.setModelState(.downloading(completed: 10, total: 100))
        XCTAssertFalse(model.modelActionPending, "the first state change ends the pending gap")
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
        XCTAssertNil(model.actionBar.skipTitle, "leaving while a download runs is not a skip")

        model.advance()
        XCTAssertEqual(model.stage, .microphone)
        XCTAssertEqual(model.readiness.model, .notReady, "continuing during a download must not mark the model Deferred")

        model.setModelState(
            .ready(InstalledModelSummary(
                modelID: "whisper-large-v3-turbo",
                revision: "test-revision",
                ownership: .externalReadOnly
            ))
        )
        XCTAssertEqual(model.readiness.model, .ready)
    }

    func testModelPendingGapTimesOutWhenTheShellNeverAnswers() async throws {
        let model = OnboardingViewModel()
        model.advance()
        model.handleModelAction(.download)
        XCTAssertTrue(model.modelActionPending)
        try await Task.sleep(for: OnboardingViewModel.modelActionPendingTimeout + .milliseconds(300))
        XCTAssertFalse(model.modelActionPending)
        XCTAssertEqual(model.actionBar.primaryTitle, "Download Model")
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
    }

    /// ADR-025: a model this Mac cannot run has nothing to retry — the
    /// primary action moves on like Skip does, with the reason on the card.
    func testAnUnavailableModelOffersNoRetryAndContinueSkipsIt() async {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .speechModel, onIntent: { intents.append($0) })
        let failure = SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure
        model.setModelState(.unavailable(failure))
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip")
        XCTAssertNil(model.modelPrimaryAction, "no Retry that can only be refused")
        XCTAssertEqual(model.modelFailureMessage, "Requires macOS 26 or later. Choose another model in Speech Models.")
        XCTAssertEqual(model.readiness.model, .blocked)

        await model.performPrimaryAction()
        XCTAssertEqual(model.stage, .microphone)
        XCTAssertEqual(intents, [.skipModel], "the skip path, not a retry intent")
        XCTAssertFalse(model.modelActionPending)
    }

    func testModelFailureStatesOfferRetryWithAMessage() {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelState(.error(ModelFailure(code: "MODEL-DISK-FULL", message: "Not enough free space.")))
        XCTAssertEqual(model.actionBar.primaryTitle, "Retry")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip")
        XCTAssertEqual(model.modelFailureMessage, "Not enough free space. Retry when the problem is fixed.")
        XCTAssertEqual(model.readiness.model, .blocked)

        model.setModelState(.downloadPaused(resumableBytes: 1_000_000))
        XCTAssertEqual(model.actionBar.primaryTitle, "Resume Download")
        XCTAssertTrue(model.modelFailureMessage?.contains("paused") ?? false)

        var intents: [OnboardingIntent] = []
        let retrying = OnboardingViewModel(stage: .speechModel, modelState: .downloadPaused(resumableBytes: nil), onIntent: { intents.append($0) })
        retrying.handleModelAction(.retry)
        XCTAssertEqual(intents, [.retryModel])
        XCTAssertTrue(retrying.modelActionPending)
        XCTAssertEqual(retrying.stage, .speechModel)
    }

    // MARK: Action bar

    func testActionBarPrimaryIsTheStepActionUntilTheStepIsResolved() async {
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: false)
        let audio = FakeAudioCapture()
        let model = OnboardingViewModel(
            microphonePermission: microphone,
            audioCapture: audio,
            accessibilityPermission: accessibility
        )

        XCTAssertEqual(model.actionBar, OnboardingActionBar(primaryTitle: "Continue", canGoBack: false))

        model.advance()
        XCTAssertEqual(model.actionBar.primaryTitle, "Download Model")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip")
        XCTAssertTrue(model.actionBar.canGoBack)

        model.performSkipAction()
        XCTAssertEqual(model.stage, .microphone)
        XCTAssertEqual(model.actionBar.primaryTitle, "Allow Microphone")

        await model.performPrimaryAction()
        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(model.actionBar.primaryTitle, "Run Level Test")

        await model.performPrimaryAction()
        let runCount = await audio.currentRunCount()
        XCTAssertEqual(runCount, 1)
        XCTAssertTrue(model.microphoneTestState.isSuccessful)
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
        XCTAssertNil(model.actionBar.skipTitle)

        await model.performPrimaryAction()
        XCTAssertEqual(model.stage, .accessibility)
        XCTAssertEqual(model.actionBar.primaryTitle, "Allow Accessibility")

        await model.performPrimaryAction()
        XCTAssertEqual(accessibility.prompts, [true])
        XCTAssertTrue(model.isAwaitingAccessibilityGrant)
        XCTAssertEqual(model.actionBar.primaryTitle, "Open System Settings", "after the prompt the remedy is the settings pane, not another prompt")

        model.setAccessibilityTrusted(true)
        XCTAssertFalse(model.isAwaitingAccessibilityGrant)
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")

        await model.performPrimaryAction()
        XCTAssertEqual(model.stage, .shortcut)
        XCTAssertEqual(model.actionBar.primaryTitle, "Record Shortcut…")
        XCTAssertFalse(model.hotkeyTestIsAvailable, "nothing to try before a shortcut is registered")
        model.useRecommendedShortcut()

        // Same page: the Try It indicator appears under the recorder and
        // Continue waits for one press/release (Skip carries on regardless).
        XCTAssertEqual(model.stage, .shortcut)
        XCTAssertTrue(model.hotkeyTestIsAvailable)
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
        XCTAssertFalse(model.actionBar.primaryIsEnabled, "Continue waits for one press/release")
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Press your shortcut to continue.")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip")
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown()
        model.reportHotkeyTestKeyUp()
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
        XCTAssertNil(model.actionBar.skipTitle)
        model.endHotkeyTest()

        await model.performPrimaryAction()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.actionBar.primaryTitle, "Finish")
        XCTAssertNil(model.actionBar.skipTitle)
        model.setDictationTestRecording(true)
        XCTAssertFalse(model.actionBar.primaryIsEnabled)
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Stop the dictation test first.")
        XCTAssertFalse(model.actionBar.canGoBack)
        model.setDictationTestRecording(false)
        XCTAssertTrue(model.actionBar.canGoBack)

        await model.performPrimaryAction()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.stage, .ready, "Finish is Ready's own action; there is no page after it")
    }

    /// P-W3: the wizard's radio group offers the same three modes as the
    /// Shortcuts page, and each choice is one `.setRecordingInteraction`
    /// with origin `.wizard` through the projection host.
    func testHybridIsSelectableAndPersistsThroughTheWizardOrigin() {
        let harness = SettingsProjectionTestHarness()
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .shortcut, settings: harness.host, onIntent: { intents.append($0) })
        XCTAssertEqual(model.recordingInteraction, .pushToTalk)

        model.setRecordingInteraction(.hybrid)
        XCTAssertEqual(model.recordingInteraction, .hybrid)
        XCTAssertEqual(harness.settings.recordingInteraction, .hybrid)
        XCTAssertEqual(harness.sent, [.setRecordingInteraction(.hybrid, origin: .wizard)])
        XCTAssertEqual(intents, [.setRecordingInteraction(.hybrid)])
        XCTAssertEqual(model.recordingInteractionSummary, "Hybrid (tap to toggle, hold to talk)")

        // Hybrid's Try It check finishes on one press/release, like push-to-talk.
        _ = model.setShortcut(GeneralSettingsViewModel.recommendedShortcut)
        model.beginHotkeyTest()
        model.reportHotkeyTestKeyDown()
        model.reportHotkeyTestKeyUp()
        XCTAssertTrue(model.hotkeyTestSnapshot.isDone)

        model.setRecordingInteraction(.toggle)
        XCTAssertEqual(model.recordingInteractionSummary, "Toggle (press to start and stop)")
        model.setRecordingInteraction(.pushToTalk)
        XCTAssertEqual(model.recordingInteractionSummary, "Push-to-Talk (hold)")
    }

    /// Ready's two optional links call the shell's hooks and nothing else:
    /// no stage change, no intent, no completion — Finish stays available.
    func testReadyLinksCallTheirHooksWithoutChangingTheWizard() {
        var intents: [OnboardingIntent] = []
        var tours = 0
        var sections: [MainWindowSection] = []
        let model = OnboardingViewModel(stage: .ready, onIntent: { intents.append($0) })
        model.openTutorialHandler = { tours += 1 }
        model.openMainWindowHandler = { sections.append($0) }

        model.openQuickTour()
        XCTAssertEqual(tours, 1)
        model.openAIActionsSetup()
        XCTAssertEqual(sections, [.aiActions])
        XCTAssertEqual(model.stage, .ready)
        XCTAssertTrue(intents.isEmpty, "the links are hooks, not wizard intents; nothing is sent")
        XCTAssertFalse(model.isFinished)
        XCTAssertEqual(model.actionBar.primaryTitle, "Finish")
        XCTAssertTrue(model.actionBar.primaryIsEnabled, "neither link blocks Finish")

        // Without hooks (tests, previews) the links are inert.
        let bare = OnboardingViewModel(stage: .ready)
        bare.openQuickTour()
        bare.openAIActionsSetup()
        XCTAssertEqual(bare.stage, .ready)

        // Once finished the window is closing; the links do nothing.
        model.finishOnboarding()
        model.openQuickTour()
        model.openAIActionsSetup()
        XCTAssertEqual(tours, 1)
        XCTAssertEqual(sections, [.aiActions])
    }

    func testDeniedMicrophonePrimaryOpensSystemSettings() async {
        var opened: [PermissionKind] = []
        let model = OnboardingViewModel(
            stage: .microphone,
            microphonePermission: FakeMicrophonePermission(authorization: .denied)
        )
        model.openSystemSettingsHandler = { kind in
            opened.append(kind)
            return true
        }
        await model.refreshMicrophoneStatus()
        XCTAssertEqual(model.actionBar.primaryTitle, "Open System Settings")
        await model.performPrimaryAction()
        XCTAssertEqual(opened, [.microphone])
    }

    func testPermissionRequestsAreSingleFlightAndBusyInTheBar() async {
        let microphone = SlowMicrophonePermission()
        let model = OnboardingViewModel(stage: .microphone, microphonePermission: microphone)

        let first = Task { await model.requestMicrophonePermission() }
        await microphone.waitUntilRequested()
        XCTAssertTrue(model.isRequestingMicrophonePermission)
        XCTAssertTrue(model.actionBar.primaryIsBusy)
        XCTAssertFalse(model.actionBar.primaryIsEnabled)
        XCTAssertFalse(model.actionBar.skipIsEnabled)

        await model.requestMicrophonePermission()   // ignored while in flight
        await microphone.finish()
        await first.value
        XCTAssertFalse(model.isRequestingMicrophonePermission)
        let requestCount = await microphone.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(model.microphoneAuthorization, .granted)
    }

    func testFailedDictationTestLinksToTheFixingStep() {
        let model = OnboardingViewModel(stage: .ready)
        model.setDictationTestResult(.failed(message: "The input device went away.", fixes: .microphone))
        XCTAssertEqual(model.dictationTestFixStep, .microphone)

        model.setDictationTestResult(.failed(message: "Something else."))
        XCTAssertEqual(model.dictationTestFixStep, .model, "without a named step, the first unready prerequisite is offered")

        model.setDictationTestResult(.transcript("fine"))
        XCTAssertNil(model.dictationTestFixStep)
    }

    func testEveryStageHasAPurposeLineAndTheBarNeverOffersSkipOnTheEnds() {
        for stage in OnboardingStage.allCases {
            XCTAssertFalse(stage.purpose.isEmpty, "\(stage) needs a purpose line")
            XCTAssertFalse(stage.title.isEmpty, "\(stage) needs a title")
        }
        XCTAssertNil(OnboardingViewModel(stage: .welcome).actionBar.skipTitle)
        XCTAssertNil(OnboardingViewModel(stage: .ready).actionBar.skipTitle)
        XCTAssertEqual(OnboardingViewModel(stage: .ready).actionBar.primaryTitle, "Finish")
        XCTAssertFalse(OnboardingViewModel(stage: .welcome).actionBar.canGoBack)
        for stage in OnboardingStage.allCases where stage != .welcome && stage != .ready {
            XCTAssertEqual(OnboardingViewModel(stage: stage).actionBar.skipTitle, "Skip", "\(stage) is skippable")
        }
    }

    func testPermissionRequestIsExplicitAndRefreshNeverPrompts() async {
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: true)
        let model = OnboardingViewModel(
            microphonePermission: microphone,
            accessibilityPermission: accessibility
        )

        await model.refreshPermissions()
        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(accessibility.prompts, [false])
        XCTAssertEqual(model.accessibilityStatus, .notDetermined)

        await model.requestAccessibilityPermission()
        XCTAssertEqual(accessibility.prompts, [false, true])
        XCTAssertEqual(model.accessibilityStatus, .granted)
    }

    func testDeniedMicrophoneBlocksRecordingAndLevelTestDoesNotRun() async {
        let microphone = FakeMicrophonePermission(authorization: .denied)
        let audio = FakeAudioCapture()
        let model = OnboardingViewModel(
            microphonePermission: microphone,
            audioCapture: audio
        )

        await model.requestMicrophonePermission()
        await model.runMicrophoneTest()

        XCTAssertEqual(model.microphoneAuthorization, .denied)
        XCTAssertEqual(model.readiness.microphone, .blocked)
        let runCount = await audio.currentRunCount()
        XCTAssertEqual(runCount, 0)
        guard case .failed = model.microphoneTestState else {
            return XCTFail("A level test must fail closed when permission is denied")
        }
    }

    func testReadyEnablesDictationOnceModelMicrophoneAndShortcutAreReady() async {
        var intents: [OnboardingIntent] = []
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: true)
        let audio = FakeAudioCapture()
        let model = OnboardingViewModel(
            microphonePermission: microphone,
            audioCapture: audio,
            accessibilityPermission: accessibility,
            onIntent: { intents.append($0) }
        )

        model.advance()
        model.handleModelAction(.skip)
        await model.requestMicrophonePermission()
        await model.runMicrophoneTest(duration: .seconds(1))
        model.advance()
        // Accessibility stays deferred: the test shows its result in-app.
        model.skipAccessibility()
        XCTAssertEqual(model.stage, .shortcut)
        XCTAssertFalse(model.canRunDictationTest)

        _ = model.setShortcut(ShortcutDefinition(key: "space", modifiers: ["control", "shift"]))
        model.advance()   // the Try It check is not attempted here; advancing carries on
        XCTAssertEqual(model.stage, .ready)
        XCTAssertFalse(model.canRunDictationTest, "Skipped model remains deferred and cannot enable the test")
        XCTAssertEqual(model.dictationTestBlockedBy, .model)

        model.setModelState(
            .ready(InstalledModelSummary(
                modelID: "whisper-large-v3-turbo",
                revision: "test-revision",
                ownership: .managedByKvoice
            ))
        )
        XCTAssertEqual(model.readiness.accessibility, .deferred)
        XCTAssertFalse(model.readiness.isReady)
        XCTAssertTrue(model.readiness.isReadyForDictationTest)
        XCTAssertTrue(model.canRunDictationTest)
        XCTAssertNil(model.dictationTestBlockedBy)
        model.requestDictationTest()
        XCTAssertTrue(model.dictationTestRequested)
        XCTAssertEqual(intents.last, .runDictationTest)
    }

    func testDictationTestResultIsRenderedAndClearedOnRetry() {
        let model = OnboardingViewModel()
        XCTAssertNil(model.dictationTestResult)

        model.setDictationTestRecording(true)
        model.setDictationTestResult(.transcript("hello world"))
        XCTAssertEqual(model.dictationTestResult, .transcript("hello world"))
        XCTAssertFalse(model.dictationTestIsRecording, "a delivered result ends the recording state")

        model.setDictationTestResult(.failed(message: "Microphone unavailable"))
        XCTAssertEqual(model.dictationTestResult, .failed(message: "Microphone unavailable"))

        model.setDictationTestResult(nil)
        XCTAssertNil(model.dictationTestResult)
    }

    func testFailureLinkReturnsToTheBlockingStep() {
        let model = OnboardingViewModel()
        model.advance()                     // welcome -> model
        model.skipModel()
        model.skipMicrophone()
        model.skipAccessibility()
        model.skipShortcut()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.dictationTestBlockedBy, .model)

        model.goToStep(for: .microphone)
        XCTAssertEqual(model.stage, .microphone)
        XCTAssertEqual(OnboardingReadinessItem.shortcut.stage, .shortcut)
    }

    /// 2026-09-16: the model card's title follows the current model's
    /// catalog entry, which the shell reports next to the model state; it
    /// is no longer a literal "Whisper large-v3-turbo".
    func testModelCardNamesTheCurrentModel() {
        let model = OnboardingViewModel()
        XCTAssertEqual(model.modelDisplayName, "Speech model", "no catalog entry yet: a generic title, never a specific model's")
        XCTAssertNil(model.modelDetailLine)

        let whisper = SpeechModelCatalogEntry(
            id: "whisper-large-v3-turbo-coreml-uncompressed", displayName: "Whisper large-v3-turbo", variantName: "Standard",
            family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 1_640_000_000,
            languageSummary: "99 languages", summary: "The recommended model.", isRecommended: true,
            revision: "04e5c42d", manifestResource: "whisper", manifestSHA256: String(repeating: "a", count: 64)
        )
        let parakeet = SpeechModelCatalogEntry(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", variantName: "",
            family: "parakeet-tdt", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
            supportsStreaming: false, supportsBatch: true, downloadBytes: 650_000_000,
            languageSummary: "25 European languages", summary: "Faster on short clips.", isRecommended: false,
            revision: "v3", manifestResource: "parakeet", manifestSHA256: String(repeating: "b", count: 64)
        )

        model.setModelEntry(whisper)
        XCTAssertEqual(model.modelDisplayName, whisper.fullDisplayName, "the same name the Speech Models page shows")
        XCTAssertEqual(model.modelDisplayName, "Whisper large-v3-turbo — Standard")
        XCTAssertEqual(model.modelDetailLine, "WhisperKit (CoreML) · \(ModelSettingsViewModel.formatBytes(1_640_000_000))")

        // The user picks Parakeet in Speech Models; the shell's next refresh
        // reports that entry and the card follows.
        model.setModelEntry(parakeet)
        XCTAssertEqual(model.modelDisplayName, "Parakeet TDT 0.6B v3")
        XCTAssertEqual(model.modelDetailLine, "FluidAudio (CoreML) · \(ModelSettingsViewModel.formatBytes(650_000_000))")

        // Once the shell has measured the download, the "Download size"
        // line shows the size (with the free space); the detail line then
        // carries the runtime only, so the size is never shown twice.
        model.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 120_000_000_000)
        XCTAssertEqual(model.modelDetailLine, "FluidAudio (CoreML)")
        XCTAssertNotNil(model.modelSpaceEstimateDescription)
        model.setModelSpaceEstimate(requiredBytes: nil, availableBytes: nil)
        XCTAssertEqual(model.modelDetailLine, "FluidAudio (CoreML) · \(ModelSettingsViewModel.formatBytes(650_000_000))")

        // No library (a trust failure): back to the generic title.
        model.setModelEntry(nil)
        XCTAssertEqual(model.modelDisplayName, "Speech model")
        XCTAssertNil(model.modelDetailLine)

        // The initializer seeds it too (previews, the gallery).
        XCTAssertEqual(OnboardingViewModel(stage: .speechModel, modelEntry: parakeet).modelDisplayName, "Parakeet TDT 0.6B v3")
    }

    func testModelSpaceEstimateRendersOnlyWhenKnown() {
        let model = OnboardingViewModel()
        XCTAssertNil(model.modelSpaceEstimateDescription)

        model.setModelSpaceEstimate(requiredBytes: 1_600_000_000, availableBytes: 120_000_000_000)
        let description = model.modelSpaceEstimateDescription ?? ""
        XCTAssertTrue(description.hasPrefix("about "), description)
        XCTAssertTrue(description.contains(" · "), description)
        XCTAssertTrue(description.hasSuffix(" free"), description)
        XCTAssertEqual(model.modelSpaceEstimate?.isSufficient, true)

        model.setModelSpaceEstimate(requiredBytes: 1_600_000_000, availableBytes: nil)
        XCTAssertFalse(model.modelSpaceEstimateDescription?.contains("free") ?? true)
        XCTAssertNil(model.modelSpaceEstimate?.isSufficient)

        model.setModelSpaceEstimate(requiredBytes: 1_600_000_000, availableBytes: 10)
        XCTAssertEqual(model.modelSpaceEstimate?.isSufficient, false)

        model.setModelSpaceEstimate(requiredBytes: nil, availableBytes: 10)
        XCTAssertNil(model.modelSpaceEstimateDescription)
    }

    /// Each page's contribution to the readiness list, and that Skip
    /// (versus a real result) reads as Skipped on Ready.
    func testEachPageContributesItsReadinessItem() async {
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: true)
        let audio = FakeAudioCapture()
        let model = OnboardingViewModel(
            microphonePermission: microphone,
            audioCapture: audio,
            accessibilityPermission: accessibility
        )
        XCTAssertEqual(model.readiness, OnboardingReadiness(model: .notReady, microphone: .notReady, accessibility: .notReady, shortcut: .notReady))

        model.advance()                                            // Speech Model
        model.setModelState(.ready(InstalledModelSummary(modelID: "m", revision: "r", ownership: .managedByKvoice)))
        XCTAssertEqual(model.readiness.model, .ready)
        await model.performPrimaryAction()                         // Microphone
        XCTAssertEqual(model.stage, .microphone)
        await model.performPrimaryAction()                         // Allow
        await model.performPrimaryAction()                         // Level test
        XCTAssertEqual(model.readiness.microphone, .ready)
        await model.performPrimaryAction()                         // Accessibility
        XCTAssertEqual(model.stage, .accessibility)
        model.performSkipAction()
        XCTAssertEqual(model.readiness.accessibility, .deferred, "Skip reads as Skipped on Ready")
        XCTAssertEqual(model.readiness.accessibility.displayName, "Skipped")
        XCTAssertEqual(model.stage, .shortcut)
        model.performSkipAction()
        XCTAssertEqual(model.readiness.shortcut, .deferred)
        XCTAssertEqual(model.stage, .ready)
        XCTAssertFalse(model.readiness.isReady)
        XCTAssertFalse(model.canRunDictationTest, "the test needs the shortcut")
        XCTAssertEqual(model.dictationTestBlockedBy, .shortcut)

        model.goToStep(for: .shortcut)
        _ = model.setShortcut(GeneralSettingsViewModel.recommendedShortcut)
        XCTAssertEqual(model.readiness.shortcut, .ready)
        model.performSkipAction()                                  // skips only the Try It check
        XCTAssertEqual(model.stage, .ready)
        XCTAssertTrue(model.canRunDictationTest, "Accessibility may stay Skipped: the result is shown in-app")
    }

    /// Finish is Ready's primary; there is no page after it. Completion is
    /// the one local-state write and closes the window through `.finish`.
    func testFinishOnReadyPersistsAndEmitsFinish() {
        var intents: [OnboardingIntent] = []
        var finished = false
        let model = OnboardingViewModel(
            onIntent: { intents.append($0) },
            onFinished: { finished = true }
        )
        model.advance()
        model.skipModel()
        model.skipMicrophone()
        model.skipAccessibility()
        model.skipShortcut()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertFalse(model.isFinished)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.progressLabel, "Step 6 of 6")
        XCTAssertEqual(model.actionBar.primaryTitle, "Finish")

        model.advance()
        XCTAssertTrue(model.isFinished)
        XCTAssertTrue(finished)
        XCTAssertEqual(intents.last, .finish)
        XCTAssertEqual(model.onboardingVersionCompleted, OnboardingViewModel.currentOnboardingVersion)
        XCTAssertFalse(model.canGoBack)

        // Finish belongs to Ready only.
        let early = OnboardingViewModel(stage: .shortcut)
        early.finishOnboarding()
        XCTAssertFalse(early.isFinished)
    }

    func testAccessibilityPollIsNonPromptingAndSilent() async {
        var intents: [OnboardingIntent] = []
        let accessibility = FakeAccessibilityPermission(refreshValue: true, promptValue: true)
        let model = OnboardingViewModel(
            accessibilityPermission: accessibility,
            onIntent: { intents.append($0) }
        )

        await model.pollAccessibilityStatus()
        XCTAssertEqual(accessibility.prompts, [false])
        XCTAssertEqual(model.accessibilityStatus, .granted)
        XCTAssertTrue(intents.isEmpty)
        XCTAssertNotNil(model.permissionsLastChecked)
        XCTAssertEqual(model.accessibilityPermissionCard.presentedState(), .granted)
    }

    func testMicrophoneDeepLinkFallsBackToWrittenPath() {
        let model = OnboardingViewModel()
        // No handler installed: the written path is the only route.
        model.openSystemSettings(for: .microphone)
        XCTAssertEqual(model.systemSettingsOpenFailed, .microphone)

        model.openSystemSettingsHandler = { _ in true }
        model.openSystemSettings(for: .microphone)
        XCTAssertNil(model.systemSettingsOpenFailed)
    }

    func testFinishCompletesEvenWhenPrerequisitesAreDeferred() {
        let model = OnboardingViewModel()

        model.advance() // Welcome -> Model
        model.skipModel()
        model.skipMicrophone()
        model.skipAccessibility()
        model.skipShortcut()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertFalse(model.readiness.isReady)

        model.finishOnboarding()

        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.onboardingVersionCompleted, OnboardingViewModel.currentOnboardingVersion)
    }

    func testShortcutDefaultsToPushToTalkAndRejectsUnmodifiedCandidate() {
        let model = OnboardingViewModel()

        XCTAssertEqual(model.recordingInteraction, .pushToTalk)
        XCTAssertFalse(model.setShortcut(ShortcutDefinition(key: "space", modifiers: [])))
        XCTAssertNil(model.shortcut)
        XCTAssertNotNil(model.shortcutError)
        XCTAssertTrue(model.setShortcut(ShortcutDefinition(key: "space", modifiers: ["control"])))
        XCTAssertEqual(model.shortcut?.key, "space")
    }

    func testViewCanBeConstructedWithoutPromptingPermissions() {
        let view = OnboardingView(viewModel: OnboardingViewModel())
        XCTAssertNotNil(view)
    }

    // MARK: Setup-guide P1s (2026-09-13 manual test)

    /// The TCC prompt leaves the setup window behind other windows; the shell
    /// is told when each request returns so it can bring the window back.
    func testPermissionRequestsReportTheirReturnSoTheShellCanRestoreFocus() async {
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: false)
        let model = OnboardingViewModel(
            stage: .microphone,
            microphonePermission: microphone,
            accessibilityPermission: accessibility
        )
        var returned: [PermissionKind] = []
        model.permissionRequestDidReturn = { returned.append($0) }

        await model.requestMicrophonePermission()
        XCTAssertEqual(returned, [.microphone], "reported once, after the request resolves")
        XCTAssertEqual(microphone.requestCount, 1)

        await model.requestAccessibilityPermission()
        XCTAssertEqual(returned, [.microphone, .accessibility])

        // Non-prompting reads never fire it.
        await model.refreshPermissions()
        await model.pollPermissions()
        XCTAssertEqual(returned, [.microphone, .accessibility])
    }

    /// The model card carries its own primary control (Download / Resume /
    /// Retry) beside Choose Existing, and Cancel only while downloading.
    func testModelCardOffersAVisiblePrimaryActionForEveryIdleState() {
        let model = OnboardingViewModel(stage: .speechModel)
        XCTAssertEqual(model.modelPrimaryAction, .download)
        XCTAssertEqual(model.modelPrimaryActionTitle, "Download Model")
        XCTAssertFalse(model.modelCanCancel)

        model.setModelState(.downloading(completed: 400_000_000, total: 1_600_000_000))
        XCTAssertNil(model.modelPrimaryAction, "no second start while a download runs")
        XCTAssertTrue(model.modelCanCancel)
        XCTAssertEqual(model.modelProgress, 0.25)
        XCTAssertEqual(model.modelProgressPercentDescription, "25%")
        XCTAssertTrue(model.modelActivityDescription?.contains("of") ?? false, "byte counts are shown")

        model.setModelState(.downloadPaused(resumableBytes: 400_000_000))
        XCTAssertEqual(model.modelPrimaryAction, .retry)
        XCTAssertEqual(model.modelPrimaryActionTitle, "Resume Download")
        XCTAssertFalse(model.modelCanCancel)

        model.setModelState(.error(ModelFailure(code: "MODEL-DOWNLOAD-FAILED", message: "The connection dropped.")))
        XCTAssertEqual(model.modelPrimaryAction, .retry)
        XCTAssertEqual(model.modelPrimaryActionTitle, "Retry")

        model.setModelState(.loading)
        XCTAssertNil(model.modelPrimaryAction)
        XCTAssertNil(model.modelProgressPercentDescription, "loading reports no counted work")

        model.setModelState(.ready(InstalledModelSummary(modelID: "m", revision: "r", ownership: .managedByKvoice)))
        XCTAssertNil(model.modelPrimaryAction, "a ready model needs no download control")

        // Pressing the card's button is the same intent as the action bar's.
        var intents: [OnboardingIntent] = []
        let fresh = OnboardingViewModel(stage: .speechModel, onIntent: { intents.append($0) })
        fresh.handleModelAction(fresh.modelPrimaryAction!)
        XCTAssertEqual(intents, [.downloadModel])
        XCTAssertNil(fresh.modelPrimaryAction, "hidden while the press is pending")
    }
}

private final class FakeMicrophonePermission: MicrophonePermissionProviding, @unchecked Sendable {
    let authorizationValue: PermissionAuthorization
    private(set) var requestCount = 0

    init(authorization: PermissionAuthorization) {
        authorizationValue = authorization
    }

    func authorization() async -> PermissionAuthorization {
        authorizationValue
    }

    func requestAccess() async -> PermissionAuthorization {
        requestCount += 1
        return authorizationValue
    }
}

/// A permission request that stays open until the test releases it, standing
/// in for the OS prompt the user has not answered yet.
/// An actor, not an `@unchecked Sendable` class: `waitUntilRequested()` runs on
/// the test's task and `requestAccess()` on the view model's, and the
/// unsynchronized version could store the "requested" continuation *after*
/// `requestAccess` had already tried to resume it — a lost continuation that
/// hung the whole suite about one run in three (2026-09-13).
private actor SlowMicrophonePermission: MicrophonePermissionProviding {
    private(set) var requestCount = 0
    private var requested: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var requestedAlready = false
    private var releasedAlready = false

    func authorization() async -> PermissionAuthorization { .notDetermined }

    func requestAccess() async -> PermissionAuthorization {
        requestCount += 1
        requestedAlready = true
        requested?.resume()
        requested = nil
        if !releasedAlready {
            await withCheckedContinuation { release = $0 }
        }
        return .granted
    }

    func waitUntilRequested() async {
        if requestedAlready { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish() {
        releasedAlready = true
        release?.resume()
        release = nil
    }
}

private final class FakeAccessibilityPermission: AccessibilityPermissionProviding, @unchecked Sendable {
    let refreshValue: Bool
    let promptValue: Bool
    private(set) var prompts: [Bool] = []

    init(refreshValue: Bool, promptValue: Bool) {
        self.refreshValue = refreshValue
        self.promptValue = promptValue
    }

    func isTrusted(prompt: Bool) async -> Bool {
        prompts.append(prompt)
        return prompt ? promptValue : refreshValue
    }
}

private actor FakeAudioCapture: AudioCaptureService {
    private(set) var runCount = 0

    func currentRunCount() -> Int {
        runCount
    }

    nonisolated var isRecording: Bool { false }

    func start(
        jobID: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {}

    func stop(jobID: JobID) async throws -> AudioRecording {
        AudioRecording(
            samples: [],
            duration: .zero,
            peakLevelDBFS: -.infinity,
            clippedFrameCount: 0
        )
    }

    func cancel(jobID: JobID) async {}

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        runCount += 1
        return MicrophoneTestResult(
            duration: duration,
            peakLevelDBFS: -12,
            capturedSamples: 16_000
        )
    }
}
