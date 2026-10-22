import KvoiceDomain
@testable import KvoiceUI
import XCTest

/// UI v2 wave 3: the setup wizard's design rules as state — the step bar
/// (skipped steps stay visible), the status chips (Accessibility waiting is
/// amber, never "Denied"), the Ready checklist's detail lines and Fix…,
/// and the action-bar copy the design changed.
@MainActor
final class OnboardingPresentationTests: XCTestCase {
    private let shortcut = GeneralSettingsViewModel.recommendedShortcut
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let readyModel = ModelLifecycleState.ready(InstalledModelSummary(
        modelID: "whisper", revision: "r", ownership: .managedByKvoice
    ))

    // MARK: Step bar

    func testStepBarMarksPassedStepsDoneAndTheCurrentOne() {
        let model = OnboardingViewModel()
        XCTAssertEqual(model.stepStates, [.current, .todo, .todo, .todo, .todo, .todo])
        model.advance()
        XCTAssertEqual(model.stepStates, [.done, .current, .todo, .todo, .todo, .todo])
    }

    func testASkippedStepIsAmberWhereverItSits() {
        let model = OnboardingViewModel(stage: .accessibility)
        model.skipAccessibility()
        XCTAssertEqual(model.stage, .shortcut)
        XCTAssertEqual(model.stepState(for: .accessibility), .skipped)
        // Fix… back to the model step: Accessibility is ahead and still skipped.
        model.goToStep(for: .model)
        XCTAssertEqual(model.stepState(for: .accessibility), .skipped)
        XCTAssertEqual(model.stepState(for: .speechModel), .current)
    }

    func testADownloadingModelIsDoneNotSkipped() {
        let model = OnboardingViewModel(stage: .speechModel, modelState: .downloading(completed: 10, total: 100))
        model.advance()
        XCTAssertEqual(model.stage, .microphone)
        XCTAssertEqual(model.stepState(for: .speechModel), .done, "the download does not block")
    }

    func testABlockedStepBehindIsSkippedAndAReadyStepAheadIsDone() {
        let model = OnboardingViewModel(stage: .ready, microphoneAuthorization: .denied)
        XCTAssertEqual(model.stepState(for: .microphone), .skipped)
        let back = OnboardingViewModel(stage: .speechModel, accessibilityStatus: .granted)
        XCTAssertEqual(back.stepState(for: .accessibility), .done, "already set up, the user went back")
        XCTAssertEqual(back.stepState(for: .shortcut), .todo)
    }

    func testSkipCheckLeavesTheShortcutStepDone() {
        let model = OnboardingViewModel(stage: .shortcut, shortcut: shortcut)
        model.performSkipAction()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.stepState(for: .shortcut), .done)
    }

    func testStepBarLabelsReadForVoiceOver() {
        let model = OnboardingViewModel(stage: .microphone)
        XCTAssertEqual(model.stepAccessibilityLabel(for: .speechModel), "Model, done")
        XCTAssertEqual(model.stepAccessibilityLabel(for: .microphone), "Microphone, current step")
        XCTAssertEqual(model.stepAccessibilityLabel(for: .ready), "Ready, not started")
    }

    // MARK: Chips

    func testModelChipFollowsTheLifecycle() {
        let model = OnboardingViewModel(stage: .speechModel)
        XCTAssertEqual(model.modelChip, OnboardingStatusChip("Not installed", tone: .neutral))
        model.setModelState(.downloading(completed: 1, total: 2))
        XCTAssertEqual(model.modelChip, OnboardingStatusChip("Downloading", tone: .cursor))
        model.setModelState(.downloadPaused(resumableBytes: 5))
        XCTAssertEqual(model.modelChip.tone, .warn)
        model.setModelState(.corrupt(ModelFailure(code: "modelCorrupt", message: "x")))
        XCTAssertEqual(model.modelChip, OnboardingStatusChip("Failed", tone: .err))
        XCTAssertTrue(model.modelCardIsFailed)
        model.setModelState(readyModel)
        XCTAssertEqual(model.modelChip, OnboardingStatusChip("Ready", tone: .ok))
    }

    func testMicrophoneChipSaysAllowedOnlyFromAFreshReading() async {
        let model = OnboardingViewModel(stage: .microphone, microphoneAuthorization: .granted, microphonePermission: StubMicrophone(.granted))
        XCTAssertEqual(model.microphoneChip().title, "Checking…", "never read: not shown as granted")
        await model.refreshPermissions()
        XCTAssertEqual(model.microphoneChip(), OnboardingStatusChip("Allowed", tone: .ok))
        XCTAssertEqual(model.microphoneChip(now: Date().addingTimeInterval(10)).title, "Checking…", "a stale grant is not green")

        let denied = OnboardingViewModel(stage: .microphone, microphonePermission: StubMicrophone(.denied))
        await denied.refreshPermissions()
        XCTAssertEqual(denied.microphoneChip(), OnboardingStatusChip("Denied", tone: .warn))
    }

    func testAccessibilityWaitingIsAmberNotEnabledYetNeverDenied() async {
        let stub = StubAccessibility(trusted: false)
        let model = OnboardingViewModel(stage: .accessibility, accessibilityPermission: stub)
        await model.refreshPermissions()
        XCTAssertEqual(model.accessibilityChip(), OnboardingStatusChip("Not requested", tone: .neutral))
        await model.requestAccessibilityPermission()
        XCTAssertEqual(model.accessibilityStatus, .denied, "the trust read after the prompt")
        XCTAssertTrue(model.accessibilityIsWaitingForUser)
        XCTAssertEqual(model.accessibilityChip(), OnboardingStatusChip("Not enabled yet", tone: .warn))
        XCTAssertEqual(model.checklistDetail(for: .accessibility), "Not enabled yet")
        stub.trusted = true
        await model.pollAccessibilityStatus()
        XCTAssertEqual(model.accessibilityChip(), OnboardingStatusChip("Allowed", tone: .ok))
        XCTAssertFalse(model.accessibilityIsWaitingForUser)
    }

    func testShortcutChip() {
        XCTAssertEqual(OnboardingViewModel(stage: .shortcut).shortcutChip, OnboardingStatusChip("Not set", tone: .neutral))
        let model = OnboardingViewModel(stage: .shortcut, shortcut: shortcut)
        XCTAssertEqual(model.shortcutChip, OnboardingStatusChip("Registered", tone: .ok))
        XCTAssertEqual(model.shortcutKeyCaps, ["⌃", "⇧", "Space"])
        model.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed))
        XCTAssertEqual(model.shortcutChip.tone, .err)
    }

    func testHeroShowsTheRecommendedShortcutUntilOneIsRecorded() {
        XCTAssertEqual(OnboardingViewModel().heroKeyCaps, ["⌃", "⇧", "Space"])
    }

    // MARK: Ready checklist

    func testChecklistDetailsWhenEverythingIsReady() async {
        let model = OnboardingViewModel(
            stage: .ready, modelState: readyModel,
            microphoneAuthorization: .granted, accessibilityStatus: .granted,
            microphoneTestState: .completed(MicrophoneTestResult(duration: .seconds(3), peakLevelDBFS: -12, capturedSamples: 48_000)),
            shortcut: shortcut
        )
        XCTAssertEqual(model.checklistDetail(for: .model), "Speech model")
        XCTAssertEqual(model.checklistDetail(for: .microphone), "Tested")
        XCTAssertEqual(model.checklistDetail(for: .accessibility), "Text goes straight to your cursor")
        XCTAssertEqual(model.checklistDetail(for: .shortcut), "⌃⇧Space · Push-to-Talk")
        for item in OnboardingReadinessItem.allCases {
            XCTAssertFalse(model.checklistOffersFix(for: item), "\(item)")
        }
    }

    func testTheAppStoreEditionSaysItTypesTheText() {
        let model = OnboardingViewModel(stage: .ready, accessibilityStatus: .granted, edition: .appStore)
        XCTAssertEqual(model.checklistDetail(for: .accessibility), "KVoice types the text into your app")
    }

    func testOpenItemsOfferFixExceptAModelThatIsDownloading() {
        let model = OnboardingViewModel(stage: .accessibility, modelState: .downloading(completed: 64, total: 100))
        model.skipAccessibility()
        model.skipShortcut()
        XCTAssertFalse(model.checklistOffersFix(for: .model), "progress, not Fix…")
        XCTAssertTrue(model.checklistDetail(for: .model).hasPrefix("Downloading"), model.checklistDetail(for: .model))
        XCTAssertTrue(model.checklistOffersFix(for: .accessibility))
        XCTAssertEqual(model.checklistDetail(for: .accessibility), "Skipped — text will be copied to the clipboard")
        XCTAssertEqual(model.checklistDetail(for: .shortcut), "Skipped")
        XCTAssertEqual(model.checklistDetail(for: .microphone), "Not requested")
    }

    // MARK: Action bar copy

    func testWelcomeSaysGetStartedWithNoSkipOrBack() {
        let bar = OnboardingViewModel().actionBar
        XCTAssertEqual(bar.primaryTitle, "Get Started")
        XCTAssertNil(bar.skipTitle)
        XCTAssertFalse(bar.canGoBack)
    }

    func testTheShortcutReasonFollowsTheLiveCheck() {
        let hold = OnboardingViewModel(stage: .shortcut, shortcut: shortcut)
        hold.beginHotkeyTest()
        hold.reportHotkeyTestKeyDown(at: epoch)
        XCTAssertEqual(hold.actionBar.primaryDisabledReason, "Release to finish the check.")
        XCTAssertEqual(hold.actionBar.skipTitle, "Skip Check")
        // Q2b: VoiceOver heard "Skip Check this step".
        XCTAssertEqual(hold.actionBar.skipAccessibilityLabel, "Skip the shortcut check")
        XCTAssertEqual(
            OnboardingViewModel(stage: .microphone).actionBar.skipAccessibilityLabel, "Skip this step",
            "every other Skip says what it skips"
        )
        XCTAssertNil(OnboardingViewModel().actionBar.skipAccessibilityLabel, "no Skip, no label")

        let toggle = OnboardingViewModel(stage: .shortcut, recordingInteraction: .toggle, shortcut: shortcut)
        toggle.beginHotkeyTest()
        toggle.reportHotkeyTestKeyDown(at: epoch)
        toggle.reportHotkeyTestKeyUp(at: epoch.addingTimeInterval(0.2))
        XCTAssertEqual(toggle.actionBar.primaryDisabledReason, "Press again to finish the check.")
    }

    func testDownloadIsDisabledWhenTheModelDoesNotFit() async {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 410_000_000)
        XCTAssertTrue(model.modelDownloadLacksSpace)
        XCTAssertEqual(model.actionBar.primaryTitle, "Download Model")
        XCTAssertFalse(model.actionBar.primaryIsEnabled)
        XCTAssertEqual(model.actionBar.primaryDisabledReason, "Not enough space")
        XCTAssertEqual(model.actionBar.skipTitle, "Skip", "the step can still be skipped")
        await model.performPrimaryAction()
        XCTAssertFalse(model.modelActionPending, "a disabled primary does nothing")

        model.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 120_000_000_000)
        XCTAssertTrue(model.actionBar.primaryIsEnabled)
    }

    func testPrivacyDetailsOpensDataAndPrivacy() {
        var opened: [MainWindowSection] = []
        let model = OnboardingViewModel()
        model.openMainWindowHandler = { opened.append($0) }
        model.openPrivacyDetails()
        XCTAssertEqual(opened, [.dataPrivacy])
        XCTAssertEqual(model.stage, .welcome, "the wizard stays where it is")
    }

    func testModeCopy() {
        XCTAssertEqual(OnboardingViewModel.name(for: .hybrid), "Hybrid")
        XCTAssertEqual(OnboardingViewModel.summary(for: .pushToTalk), "Hold to record, release to stop")
        XCTAssertEqual(OnboardingStage.speechModel.stepBarTitle, "Model")
    }
}

private struct StubMicrophone: MicrophonePermissionProviding {
    let value: PermissionAuthorization
    init(_ value: PermissionAuthorization) { self.value = value }
    func authorization() async -> PermissionAuthorization { value }
    func requestAccess() async -> PermissionAuthorization { value }
}

private final class StubAccessibility: AccessibilityPermissionProviding, @unchecked Sendable {
    var trusted: Bool
    init(trusted: Bool) { self.trusted = trusted }
    func isTrusted(prompt: Bool) async -> Bool { trusted }
}
