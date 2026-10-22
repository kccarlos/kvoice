import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceInsertion
import KvoiceUI

/// The setup window and the onboarding intent router.
///
/// `OnboardingViewModel` owns the step sequence and its own local state; this
/// extension only performs the effects it cannot: opening panels, touching
/// system settings, starting the model or dictation operations, and closing
/// the window. Since ADR-022 slice 7 the wizard's settings writes (trigger
/// mode, shortcut, completion) are its own `SettingsIntent`s through the
/// projection host the shell installs (`AppDelegate.init`); the intents it
/// still emits for them are notifications, routed to nothing here.
extension AppDelegate {
    func showSetup() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(
                viewModel: composition.onboardingViewModel,
                appDelegate: self
            )
        }
        // Setup Guide… after Finish starts the guide over instead of showing
        // the finished Ready page, where every control is inert (owner
        // report 2026-10-21). A guide left mid-way keeps its place.
        composition.onboardingViewModel.prepareForPresentation()
        onboardingWindow?.show()
    }

    /// Reachable from the status item, so it cannot be file-private.
    @objc func openSetup() {
        guard !terminationInProgress else { return }
        showSetup()
    }

    func handleOnboardingIntent(_ intent: OnboardingIntent) {
        guard !terminationInProgress else { return }
        switch intent {
        case .downloadModel:
            downloadModel()
        case .chooseExistingModel:
            chooseExistingModel()
        case .skipModel:
            // Skip is deliberately local state only. No package is activated.
            break
        case .cancelModelDownload:
            cancelModelDownload()
        case .retryModel:
            retryModel()
        case .useSpeechModel(let id):
            useSetupModel(id)
        case .requestMicrophonePermission, .runMicrophoneTest, .skipMicrophone:
            break
        case .requestAccessibilityPermission, .refreshAccessibilityStatus, .skipAccessibility:
            break
        case .openAccessibilitySettings:
            if let url = SystemAccessibilityPermissionAdapter.accessibilitySettingsURL {
                NSWorkspace.shared.open(url)
            }
        case .recordShortcut:
            // Presents the real recorder. This used to install the recommended
            // shortcut on first click and otherwise open Settings, because
            // presentRecorder() was a no-op and no alternate could be chosen.
            composition.shortcutAdapter.presentRecorder()
        case .cancelShortcutRecording:
            composition.shortcutAdapter.dismissRecorder()
        case .setRecordingInteraction, .shortcutRecorded:
            // Already written by the wizard through its projection host
            // (origin `.wizard`); nothing to route.
            break
        case .shortcutRegistrationState(_):
            break
        case .skipShortcut:
            break
        case .beginHotkeyTest:
            // Installed only while the shortcut page's Try It indicator is
            // visible (`OnboardingViewModel.hotkeyTestIsAvailable`); every
            // key edge arriving through `receiveShortcut` while this is set
            // is reported to the wizard and never starts a dictation. See
            // `AppDelegate+Settings.receiveShortcut`.
            onboardingHotkeyTestHook = { [weak self] event in
                guard let self else { return }
                switch event {
                case .keyDown: self.composition.onboardingViewModel.reportHotkeyTestKeyDown()
                case .keyUp: self.composition.onboardingViewModel.reportHotkeyTestKeyUp()
                }
            }
        case .endHotkeyTest:
            onboardingHotkeyTestHook = nil
        case .runDictationTest:
            guard composition.onboardingViewModel.canRunDictationTest,
                  latestState.kind == .idle,
                  inAppTestJobID == nil,
                  modelReady else { return }
            inAppTestRequester = .onboarding
            // C.2 step 9: the production recorder/STT path, but the result is
            // shown in the setup window rather than inserted anywhere.
            Task { [weak self] in
                guard let self else { return }
                let state = await self.composition.dictationController.startRecording(delivery: .inApp)
                if case .recording(let recording) = state {
                    self.inAppTestJobID = recording.jobID
                }
            }
        case .stopDictationTest:
            guard latestState.kind == .recording else { return }
            Task { [weak self] in
                guard let self else { return }
                _ = await self.composition.dictationController.stopRecording()
            }
        case .finish:
            // Completion (`LocalStateIntent.completeOnboarding`) was sent by
            // the wizard itself. Finish is the end of the guide: the window
            // goes away and nothing reopens it on the next activation (only
            // the settings load and Reset Onboarding show it).
            onboardingWindow?.close()
        }
    }

    /// Routes the in-app test's terminal state to the onboarding field. The
    /// controller keeps the text only for `.inApp` jobs.
    func deliverInAppTestResultIfNeeded(state: DictationState, delivered: InAppDeliveredText?) {
        guard let jobID = inAppTestJobID else { return }
        switch state {
        case .completed(let completedID, _) where completedID == jobID:
            guard let delivered, delivered.jobID == jobID else { return }
            inAppTestJobID = nil
            onboardingDictationTestFinished(.transcript(delivered.text))
        case .failed(let failedID, let failure) where failedID == jobID:
            inAppTestJobID = nil
            onboardingDictationTestFinished(
                .failed(message: failure.message, fixes: Self.onboardingItem(fixing: failure.code))
            )
        case .idle:
            // Escape during the test discards it without a result.
            inAppTestJobID = nil
            onboardingDictationTestFinished(nil)
        default:
            break
        }
    }

    /// Maps a failure code to the setup step that resolves it, so the test's
    /// failure links to the right screen (C.2 step 9 "Failure links directly
    /// to the failing setting").
    private static func onboardingItem(fixing code: String) -> OnboardingReadinessItem? {
        guard let errorCode = KVoiceErrorCode(rawValue: code) else { return nil }
        switch errorCode.subsystemPrefix {
        case "PERM" where code.hasPrefix("PERM-MIC"): return .microphone
        case "AUD": return .microphone
        case "MODEL", "STT": return .model
        case "HOTKEY": return .shortcut
        default: return nil
        }
    }

    private func onboardingDictationTestFinished(_ outcome: DictationTestResult?) {
        switch inAppTestRequester {
        case .onboarding:
            composition.onboardingViewModel.setDictationTestResult(outcome)
        case .home:
            homeTestDictation.finish(outcome)
            inAppTestRequester = .onboarding
        }
    }
}

/// The surface that started the in-app dictation test.
enum InAppTestRequester {
    case onboarding
    case home
}

/// UI v2 fidelity F2: Home's Try a Test Dictation. The same in-app path as
/// the setup wizard's first dictation test (C.2 step 9): the production
/// recorder and model with `delivery: .inApp`, so the text is shown in the
/// Home sheet and never inserted into another app or put on the pasteboard
/// (FR-AX-001 / FR-AX-009 untouched). Like the wizard's test, the dictation
/// is saved to history when history is on.
extension AppDelegate {
    /// Hooks the sheet's buttons to the dictation controller; idempotent.
    func configureHomeTestDictation() {
        homeTestDictation.onStart = { [weak self] in
            self?.startHomeTestDictation() ?? false
        }
        homeTestDictation.onStop = { [weak self] in
            guard let self, self.inAppTestRequester == .home else { return }
            let jobID = self.inAppTestJobID
            Task { _ = await self.composition.dictationController.stopRecording(for: jobID) }
        }
        homeTestDictation.onCancel = { [weak self] in
            guard let self, self.inAppTestRequester == .home else { return }
            let jobID = self.inAppTestJobID
            Task { _ = await self.composition.dictationController.cancel(for: jobID) }
        }
    }

    private func startHomeTestDictation() -> Bool {
        guard latestState.kind == .idle, inAppTestJobID == nil, modelReady else { return false }
        inAppTestRequester = .home
        Task { [weak self] in
            guard let self else { return }
            let state = await self.composition.dictationController.startRecording(delivery: .inApp)
            if case .recording(let recording) = state {
                self.inAppTestJobID = recording.jobID
                self.homeTestDictation.setRecording(true)
            } else {
                self.inAppTestRequester = .onboarding
                self.homeTestDictation.startDidFail()
            }
        }
        return true
    }

    /// Home's figures and newest rows follow a finished dictation while the
    /// page has been shown (its summary is loaded), so the numbers roll.
    func refreshHomeFiguresIfShown(after state: DictationState) {
        switch state.kind {
        case .completed, .idle:
            guard historyViewModel.home != nil else { return }
            Task { [weak self] in await self?.historyViewModel.refreshHome() }
        default:
            break
        }
    }
}
