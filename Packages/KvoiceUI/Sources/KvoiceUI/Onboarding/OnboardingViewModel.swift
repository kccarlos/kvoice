import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Main-actor state machine for the first-run flow (spec C.2, six steps
/// since the 2026-09-16 design review's P-W1: Welcome → Speech Model →
/// Microphone → Accessibility → Shortcut, with the live Try It indicator →
/// Ready, with Finish). The Quick Tour and AI Actions setup are optional
/// links on Ready (`openQuickTour()`, `openAIActionsSetup()`), not stages.
///
/// This type owns presentation state and emits intents; it deliberately does
/// not own a model manager, shortcut registrar, or app-window router.  The
/// application shell can therefore use the same deterministic state machine
/// with production services or test doubles.
///
/// ADR-022 slice 7: the wizard's three settings writes — the trigger mode,
/// the recorded shortcut, and completion — go through `settings`
/// (`SettingsProjectionHost`) as `SettingsIntent` / `LocalStateIntent` with
/// origin `.wizard`, the same door every page uses; the `OnboardingIntent`s
/// it still emits for them are notifications the shell uses for window
/// work only. The trigger mode is read from the host, so the wizard and the
/// Shortcuts page can never disagree about it.
@Observable
@MainActor
public final class OnboardingViewModel {
    /// Bumping this replays the wizard for everyone who completed an older
    /// version (`shouldPresentSetup(completedVersion:)`). It stayed at 1
    /// through the 2026-09-16 six-step restructure on purpose: "completed"
    /// still means the same four prerequisites were walked, so a user who
    /// finished the ten-step wizard must not be shown the six-step one.
    /// Bump it only when a new step is something every existing user must
    /// see.
    public static let currentOnboardingVersion = 1

    /// The launch gate (`AppDelegate+Settings`): the wizard opens when no
    /// completion is recorded or the recorded one predates
    /// `currentOnboardingVersion` (FR-ONB-009).
    public static func shouldPresentSetup(completedVersion: Int?) -> Bool {
        (completedVersion ?? 0) < currentOnboardingVersion
    }

    public private(set) var stage: OnboardingStage
    public private(set) var welcomeAcknowledged = false
    public private(set) var isFinished = false

    public private(set) var modelState: ModelLifecycleState
    /// True between a Download/Retry press and the first lifecycle state
    /// that reflects it. The shell reports model state on its poll, so the
    /// press would otherwise look ignored for up to a poll interval; it
    /// also clears itself after `modelActionPendingTimeout` in case the
    /// shell refused the request without changing state.
    public private(set) var modelActionPending = false
    public static let modelActionPendingTimeout: Duration = .seconds(3)
    /// Download size and free space for the model step, when the shell has
    /// measured them. Nil renders nothing.
    public private(set) var modelSpaceEstimate: ModelSpaceEstimate?
    /// The catalog entry of the current model (2026-09-16). The wizard's
    /// state already followed the current model — the shell reports the
    /// library's `state` on every refresh and Download / Retry act on it —
    /// but the card's title was a literal "Whisper large-v3-turbo", so a
    /// user who had chosen Parakeet in Speech Models read the wrong name.
    /// Fed by the shell on the same refresh path as `setModelState`
    /// (`AppDelegate+Model.refreshModelState`, `library.defaultEntry`).
    /// Nil (no library, tests, previews) falls back to a generic title.
    public private(set) var modelEntry: SpeechModelCatalogEntry?
    public private(set) var microphoneAuthorization: PermissionAuthorization
    public private(set) var accessibilityStatus: AccessibilityPermissionStatus = .notDetermined
    /// True while the OS microphone prompt is up. The trigger is disabled so
    /// a second press cannot queue a second request.
    public private(set) var isRequestingMicrophonePermission = false
    /// True while `AXIsProcessTrustedWithOptions(prompt:)` is being called.
    /// Brief, because the call returns before the user answers the prompt.
    public private(set) var isRequestingAccessibilityPermission = false
    /// The last time a permission state was read. Drives the "checked at"
    /// line on the permission cards.
    public private(set) var permissionsLastChecked: Date?
    /// The meter-only microphone test, shared with the Dictation tab's
    /// implementation. Exposed so the view can render the meter directly.
    public let microphoneTest: MicrophoneTestViewModel
    public private(set) var shortcut: ShortcutDefinition?
    public private(set) var shortcutRegistrationState: ShortcutRegistrationState
    public private(set) var shortcutError: String?
    /// Live state for the shortcut page's Try It indicator. See
    /// `HotkeyTestSnapshot`.
    public private(set) var hotkeyTestSnapshot = HotkeyTestSnapshot()
    /// True only while the Try It indicator is visible
    /// (`hotkeyTestIsAvailable`) and the shell has installed the
    /// onboarding-scoped shortcut hook in response to `.beginHotkeyTest`.
    /// `reportHotkeyTestKeyDown()/Up()` are no-ops otherwise, so a stray
    /// report after the page closes cannot mark it done.
    public private(set) var hotkeyTestHookInstalled = false
    public private(set) var dictationTestRequested = false
    public private(set) var dictationTestIsRecording = false
    public private(set) var dictationTestResult: DictationTestResult?
    /// Set when a System Settings deep link could not be opened, so the view
    /// leads with the written path instead.
    public private(set) var systemSettingsOpenFailed: PermissionKind?

    /// The stored trigger mode (a projection; `setRecordingInteraction`
    /// writes it through the host).
    public var recordingInteraction: RecordingInteraction {
        settings.settings.recordingInteraction
    }

    /// ADR-022 slice 7: the settings door. The composition builds the wizard
    /// before the shell's coordinator exists, so the shell assigns the real
    /// host after construction (`AppDelegate.init`); until then — and in
    /// tests and previews — a detached host accepts every write.
    @ObservationIgnored public var settings: SettingsProjectionHost

    /// Best-effort System Settings deep link for the microphone step. The
    /// accessibility step keeps its `.openAccessibilitySettings` intent. The
    /// app shell assigns this after construction; nil means "no deep link
    /// available", and the written path is shown on its own.
    public var openSystemSettingsHandler: (@MainActor (PermissionKind) -> Bool)?

    /// Called after a permission request returns — the microphone prompt was
    /// answered, or the Accessibility prompt was shown. The TCC dialog steals
    /// activation and leaves the setup window behind other windows; the app
    /// shell assigns this to re-activate and bring the window front. Nil
    /// (tests, previews) does nothing.
    public var permissionRequestDidReturn: (@MainActor (PermissionKind) -> Void)?

    /// "Set up AI Actions" on the Ready page opens the main window on that
    /// section (`openAIActionsSetup()`); the wizard stays open behind it.
    /// The app shell assigns this to `openMainWindow(section:)`; nil
    /// (tests, previews) does nothing.
    public var openMainWindowHandler: (@MainActor (MainWindowSection) -> Void)?

    /// "Take the Quick Tour" on the Ready page opens the standalone tutorial
    /// window exactly as Help › Quick Tour does (`openQuickTour()`). The app
    /// shell assigns this to `showTutorial()`; nil (tests, previews) does
    /// nothing.
    public var openTutorialHandler: (@MainActor () -> Void)?

    private let microphonePermission: any MicrophonePermissionProviding
    private let accessibilityPermission: any AccessibilityPermissionProviding
    private let onIntent: @MainActor (OnboardingIntent) -> Void
    private let onFinished: @MainActor () -> Void

    private var modelWasSkipped = false
    private var microphoneWasSkipped = false
    private var accessibilityWasSkipped = false
    private var shortcutWasSkipped = false
    private var accessibilityPromptWasRequested = false
    private var modelActionPendingTask: Task<Void, Never>?

    /// ADR-026: which distribution this is — the Accessibility step and the
    /// shortcut help describe what the edition's permission does.
    public let edition: DistributionEdition

    /// ADR-026 (2026-09-28 amendment): the shortcut help's pointer to the
    /// full edition — nil outside the App Store edition and when
    /// `HelpLinks.offersFullEditionLink` is off.
    public var fullEditionLink: URL? {
        SettingsAvailabilityModel.fullEditionLink(for: edition)
    }

    public init(
        stage: OnboardingStage = .welcome,
        modelState: ModelLifecycleState = .absent,
        modelEntry: SpeechModelCatalogEntry? = nil,
        microphoneAuthorization: PermissionAuthorization = .notDetermined,
        accessibilityStatus: AccessibilityPermissionStatus = .notDetermined,
        microphoneTestState: MicrophoneTestState = .notStarted,
        recordingInteraction: RecordingInteraction = .pushToTalk,
        settings: SettingsProjectionHost? = nil,
        shortcut: ShortcutDefinition? = nil,
        shortcutRegistrationState: ShortcutRegistrationState? = nil,
        microphonePermission: any MicrophonePermissionProviding = UnavailableMicrophonePermissionProvider(),
        audioCapture: (any AudioCaptureService)? = nil,
        accessibilityPermission: any AccessibilityPermissionProviding = UnavailableAccessibilityPermissionProvider(),
        edition: DistributionEdition = .developerID,
        onIntent: @escaping @MainActor (OnboardingIntent) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.stage = stage
        self.modelState = modelState
        self.modelEntry = modelEntry
        self.microphoneAuthorization = microphoneAuthorization
        self.accessibilityStatus = accessibilityStatus
        self.microphoneTest = MicrophoneTestViewModel(
            audioCapture: audioCapture,
            state: microphoneTestState
        )
        // `recordingInteraction` seeds a detached host only; a real host
        // carries the stored value and the parameter is ignored.
        self.settings = settings ?? .detached(settings: AppSettings(recordingInteraction: recordingInteraction))
        self.shortcut = shortcut
        self.shortcutRegistrationState = shortcutRegistrationState
            ?? (shortcut.map(ShortcutRegistrationState.registered) ?? .unregistered)
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.edition = edition
        self.onIntent = onIntent
        self.onFinished = onFinished
    }

    // MARK: Derived state

    public var progressLabel: String {
        String(localized: "Step \(stage.ordinal) of \(OnboardingStage.allCases.count)", bundle: .module)
    }

    public var microphoneTestState: MicrophoneTestState {
        microphoneTest.state
    }

    public var microphoneLevelDBFS: Float {
        microphoneTest.levelDBFS
    }

    /// "about 1.6 GB · 120 GB free", or nil when the shell has not measured.
    public var modelSpaceEstimateDescription: String? {
        ModelSettingsViewModel.describe(modelSpaceEstimate)
    }

    /// The model card's title: the current model's catalog name, the same
    /// `fullDisplayName` the Speech Models page shows ("Parakeet TDT 0.6B
    /// v3 — Standard"), or a generic title while no catalog entry is known.
    public var modelDisplayName: String {
        modelEntry?.fullDisplayName ?? String(localized: "Speech model", bundle: .module)
    }

    /// "FluidAudio (CoreML) · 650 MB" — the runtime and the catalog's
    /// download size, both cheap; nil without an entry. The runtime name is
    /// domain copy, localized the way the Speech Models badges are. Once
    /// the shell has measured the download (`modelSpaceEstimate`, shown on
    /// its own "Download size" line with the free space) the size is left
    /// to that line and this one carries the runtime only.
    public var modelDetailLine: String? {
        guard let modelEntry else { return nil }
        let runtime = DomainCopy.localized(modelEntry.runtime.displayName)
        guard modelSpaceEstimate == nil else { return runtime }
        return "\(runtime) · \(ModelSettingsViewModel.formatBytes(modelEntry.downloadBytes))"
    }

    /// The prerequisite the dictation test is waiting on, or nil.
    public var dictationTestBlockedBy: OnboardingReadinessItem? {
        readiness.firstItemBlockingDictationTest
    }

    /// Where a failed dictation test should send the user: the step the
    /// shell named, else whichever prerequisite is no longer ready (a device
    /// that went away shows up as Microphone not ready on the next poll).
    public var dictationTestFixStep: OnboardingReadinessItem? {
        guard case .failed(_, let fixes) = dictationTestResult else { return nil }
        return fixes ?? readiness.firstItemBlockingDictationTest
    }

    /// True after the Accessibility prompt was requested and trust has not
    /// been granted yet. `AXIsProcessTrustedWithOptions` returns the current
    /// state, so right after the prompt the status reads as not granted even
    /// though the user has not refused anything; the view says "waiting"
    /// rather than "denied" while the poll watches for the toggle.
    public var isAwaitingAccessibilityGrant: Bool {
        accessibilityPromptWasRequested && accessibilityStatus != .granted
    }

    /// The model step's inline problem statement for a failed lifecycle
    /// state, following D.10: what happened and what to do next.
    public var modelFailureMessage: String? {
        switch modelState {
        case .corrupt(let failure):
            return String(localized: "The installed model failed verification. \(DomainCopy.localized(failure.message)) Retry to download it again.", bundle: .module)
        case .incompatible(let failure):
            return String(localized: "This model is not compatible with this Mac. \(DomainCopy.localized(failure.message))", bundle: .module)
        case .unavailable(let failure):
            // ADR-025: the wizard's default is never a system-managed entry
            // this Mac cannot run, but the state is total: say why and point
            // at Speech Models, where another model can be chosen.
            return String(localized: "\(DomainCopy.localized(failure.message)) Choose another model in Speech Models.", bundle: .module)
        case .error(let failure):
            return String(localized: "\(DomainCopy.localized(failure.message)) Retry when the problem is fixed.", bundle: .module)
        case .downloadPaused(let resumableBytes):
            if let resumableBytes, resumableBytes > 0 {
                return String(localized: "Download paused with \(Self.formatBytes(resumableBytes)) kept. Resume to continue where it stopped.", bundle: .module)
            }
            return String(localized: "Download paused. Resume to continue.", bundle: .module)
        case .absent, .validatingExternal, .downloading, .verifying, .installing,
             .loading, .ready, .inference, .deleting:
            return nil
        }
    }

    // MARK: Action bar

    /// The Back / Skip / primary triple for the current screen. The primary
    /// is the step's own next action while the step is unresolved and
    /// "Continue" once it is, so Return always does the obvious thing.
    public var actionBar: OnboardingActionBar {
        let back = canGoBack
        switch stage {
        case .welcome:
            return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)

        case .speechModel:
            let title: String
            switch modelState {
            case .ready, .inference:
                return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)
            case .validatingExternal, .downloading, .verifying, .installing, .loading, .deleting:
                // The operation keeps running on later screens (C.2 step 3).
                return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)
            case .downloadPaused:
                title = String(localized: "Resume Download", bundle: .module)
            case .corrupt, .incompatible, .error:
                title = String(localized: "Retry", bundle: .module)
            case .unavailable:
                // ADR-025: nothing to retry on this Mac; the message says
                // "Choose another model", so the primary action moves on
                // (the skip path) rather than offering a Retry that can
                // only be refused.
                return OnboardingActionBar(
                    primaryTitle: String(localized: "Continue", bundle: .module),
                    skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back
                )
            case .absent:
                title = String(localized: "Download Model", bundle: .module)
            }
            // Same title while the press is pending, so the button does not
            // re-label itself under the pointer; only the spinner appears.
            return OnboardingActionBar(
                primaryTitle: title, primaryIsBusy: modelActionPending,
                skipTitle: String(localized: "Skip", bundle: .module), skipIsEnabled: !modelActionPending, canGoBack: back
            )

        case .microphone:
            if isRequestingMicrophonePermission {
                return OnboardingActionBar(
                    primaryTitle: String(localized: "Allow Microphone", bundle: .module), primaryIsBusy: true,
                    skipTitle: String(localized: "Skip", bundle: .module), skipIsEnabled: false, canGoBack: back
                )
            }
            switch microphoneAuthorization {
            case .notDetermined:
                return OnboardingActionBar(primaryTitle: String(localized: "Allow Microphone", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
            case .granted:
                switch microphoneTestState {
                case .completed:
                    return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)
                case .running:
                    return OnboardingActionBar(
                        primaryTitle: String(localized: "Run Level Test", bundle: .module), primaryIsBusy: true,
                        skipTitle: String(localized: "Skip", bundle: .module), skipIsEnabled: false, canGoBack: back
                    )
                case .notStarted, .failed, .skipped:
                    return OnboardingActionBar(primaryTitle: String(localized: "Run Level Test", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
                }
            case .denied, .restricted:
                return OnboardingActionBar(primaryTitle: String(localized: "Open System Settings", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
            @unknown default:
                return OnboardingActionBar(primaryTitle: String(localized: "Check Again", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
            }

        case .accessibility:
            if accessibilityStatus == .granted {
                return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)
            }
            if isRequestingAccessibilityPermission {
                return OnboardingActionBar(
                    primaryTitle: String(localized: "Allow Accessibility", bundle: .module), primaryIsBusy: true,
                    skipTitle: String(localized: "Skip", bundle: .module), skipIsEnabled: false, canGoBack: back
                )
            }
            if isAwaitingAccessibilityGrant || accessibilityStatus == .denied {
                return OnboardingActionBar(primaryTitle: String(localized: "Open System Settings", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
            }
            return OnboardingActionBar(primaryTitle: String(localized: "Allow Accessibility", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)

        case .shortcut:
            guard readiness.shortcut.isReady else {
                return OnboardingActionBar(primaryTitle: String(localized: "Record Shortcut…", bundle: .module), skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back)
            }
            // The registered shortcut is proven by the Try It indicator on
            // the same page: Continue waits for one press (Skip carries on
            // with the shortcut still Ready — only the check is skipped).
            if hotkeyTestSnapshot.isDone {
                return OnboardingActionBar(primaryTitle: String(localized: "Continue", bundle: .module), canGoBack: back)
            }
            return OnboardingActionBar(
                primaryTitle: String(localized: "Continue", bundle: .module), primaryIsEnabled: false,
                primaryDisabledReason: String(localized: "Press your shortcut to continue.", bundle: .module),
                skipTitle: String(localized: "Skip", bundle: .module), canGoBack: back
            )

        case .ready:
            if dictationTestIsRecording {
                return OnboardingActionBar(
                    primaryTitle: String(localized: "Finish", bundle: .module), primaryIsEnabled: false,
                    primaryDisabledReason: String(localized: "Stop the dictation test first.", bundle: .module),
                    canGoBack: false
                )
            }
            return OnboardingActionBar(primaryTitle: String(localized: "Finish", bundle: .module), canGoBack: back)
        }
    }

    /// Runs the action bar's primary button for the current screen. Async
    /// because the permission requests and the level test suspend; the
    /// synchronous cases return immediately.
    public func performPrimaryAction() async {
        guard actionBar.primaryIsEnabled else { return }
        switch stage {
        case .welcome:
            advance()
        case .speechModel:
            switch modelState {
            case .ready, .inference:
                move(to: .microphone)
            case .validatingExternal, .downloading, .verifying, .installing, .loading, .deleting:
                continueWithModelInProgress()
            case .downloadPaused, .corrupt, .incompatible, .error:
                handleModelAction(.retry)
            case .unavailable:
                skipModel()
            case .absent:
                handleModelAction(.download)
            }
        case .microphone:
            switch microphoneAuthorization {
            case .notDetermined:
                await requestMicrophonePermission()
            case .granted:
                if microphoneTestState.isSuccessful {
                    advance()
                } else {
                    await runMicrophoneTest()
                }
            case .denied, .restricted:
                openSystemSettings(for: .microphone)
            @unknown default:
                await refreshMicrophoneStatus()
            }
        case .accessibility:
            if accessibilityStatus == .granted {
                advance()
            } else if isAwaitingAccessibilityGrant || accessibilityStatus == .denied {
                openSystemSettings(for: .accessibility)
            } else {
                await requestAccessibilityPermission()
            }
        case .shortcut:
            if readiness.shortcut.isReady {
                advance()
            } else {
                requestShortcutRecording()
            }
        case .ready:
            finishOnboarding()
        }
    }

    /// Runs the action bar's Skip button. A no-op on screens without one.
    public func performSkipAction() {
        guard let _ = actionBar.skipTitle, actionBar.skipIsEnabled else { return }
        switch stage {
        case .speechModel: skipModel()
        case .microphone: skipMicrophone()
        case .accessibility: skipAccessibility()
        // A registered shortcut is kept; only its Try It check is skipped.
        case .shortcut: readiness.shortcut.isReady ? skipHotkeyTest() : skipShortcut()
        case .welcome, .ready: break
        }
    }

    /// D.9 cards for the two permission steps, built from the same state the
    /// rest of the flow uses.
    public var microphonePermissionCard: PermissionCard {
        PermissionCard(
            kind: .microphone,
            state: PermissionCardState(microphoneAuthorization),
            lastChecked: permissionsLastChecked
        )
    }

    public var accessibilityPermissionCard: PermissionCard {
        PermissionCard(
            kind: .accessibility,
            state: PermissionCardState(accessibilityStatus),
            lastChecked: permissionsLastChecked,
            edition: edition
        )
    }

    private static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Determinate progress, when the lifecycle reports counted work. Download
    /// counts bytes and verification counts files; loading the CoreML runtime
    /// reports nothing, so it deliberately returns nil and the view falls back
    /// to an indeterminate indicator.
    public var modelProgress: Double? {
        switch modelState {
        case .downloading(let completed, let total) where total > 0:
            return min(max(Double(completed) / Double(total), 0), 1)
        case .verifying(let completedFiles, let totalFiles) where totalFiles > 0:
            return min(max(Double(completedFiles) / Double(totalFiles), 0), 1)
        default:
            return nil
        }
    }

    /// "40%" for a determinate operation, nil otherwise. Shown beside the bar
    /// so the download reads as moving even between byte-count updates.
    public var modelProgressPercentDescription: String? {
        modelProgress.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }

    /// The model step's own primary control (spec FR-ONB-002: Download,
    /// Choose Existing, or Skip must all be visible). Nil while an operation
    /// runs or once the model is ready, when the card shows progress or the
    /// ready badge instead.
    public var modelPrimaryAction: OnboardingModelAction? {
        if modelActionPending { return nil }
        switch modelState {
        case .absent: return .download
        case .downloadPaused: return .retry
        case .corrupt, .incompatible, .error: return .retry
        case .validatingExternal, .downloading, .verifying, .installing, .loading, .deleting,
             .ready, .inference, .unavailable:
            return nil
        }
    }

    /// The title for `modelPrimaryAction`.
    public var modelPrimaryActionTitle: String? {
        switch modelPrimaryAction {
        case .download: return String(localized: "Download Model", bundle: .module)
        case .retry:
            if case .downloadPaused = modelState { return String(localized: "Resume Download", bundle: .module) }
            return String(localized: "Retry", bundle: .module)
        case .chooseExisting, .skip, .cancel, nil: return nil
        }
    }

    /// True while a download can be cancelled from the card.
    public var modelCanCancel: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    /// True while a model operation is in flight. The model step uses this to
    /// show activity and to stop the user from starting a second operation.
    public var modelIsBusy: Bool {
        if modelActionPending { return true }
        switch modelState {
        case .validatingExternal, .downloading, .verifying, .installing,
             .loading, .deleting:
            return true
        case .ready, .inference, .absent, .downloadPaused, .corrupt,
             .incompatible, .error, .unavailable:
            return false
        }
    }

    /// Human-readable description of the in-flight model operation. First-time
    /// loading compiles the CoreML model for the Neural Engine and can take
    /// well over a minute, so the copy says so rather than looking stalled.
    public var modelActivityDescription: String? {
        if modelActionPending {
            return String(localized: "Starting…", bundle: .module)
        }
        switch modelState {
        case .validatingExternal:
            return String(localized: "Checking the selected folder…", bundle: .module)
        case .downloading(let completed, let total):
            // These are byte counts, not file counts.
            return total > 0
                ? String(localized: "Downloading model — \(Self.formatBytes(completed)) of \(Self.formatBytes(total))…", bundle: .module)
                : String(localized: "Downloading model…", bundle: .module)
        case .verifying(let completedFiles, let totalFiles):
            return totalFiles > 0
                ? String(localized: "Verifying model — \(completedFiles) of \(totalFiles) files…", bundle: .module)
                : String(localized: "Verifying model…", bundle: .module)
        case .installing:
            return String(localized: "Installing model…", bundle: .module)
        case .loading:
            return String(localized: "Loading model into the Neural Engine. The first load compiles the model and can take a few minutes.", bundle: .module)
        case .deleting:
            return String(localized: "Removing model…", bundle: .module)
        case .ready, .inference, .absent, .downloadPaused, .corrupt,
             .incompatible, .error, .unavailable:
            return nil
        }
    }

    public var readiness: OnboardingReadiness {
        OnboardingReadiness(
            model: modelReadiness,
            microphone: microphoneReadiness,
            accessibility: accessibilityReadiness,
            shortcut: shortcutReadiness
        )
    }

    /// Model, Microphone, and Shortcut only. Accessibility may remain deferred
    /// because the test shows its result in-app (spec C.2 step 9).
    public var canRunDictationTest: Bool {
        readiness.isReadyForDictationTest && !isFinished
    }

    public var onboardingVersionCompleted: Int? {
        isFinished ? Self.currentOnboardingVersion : nil
    }

    private var modelReadiness: OnboardingReadinessStatus {
        if modelWasSkipped { return .deferred }
        switch modelState {
        case .ready, .inference:
            return .ready
        case .corrupt, .incompatible, .error, .unavailable:
            return .blocked
        case .absent, .validatingExternal, .downloading, .downloadPaused,
             .verifying, .installing, .loading, .deleting:
            return .notReady
        }
    }

    private var microphoneReadiness: OnboardingReadinessStatus {
        if microphoneWasSkipped { return .deferred }
        switch microphoneAuthorization {
        case .granted:
            return microphoneTestState.isSuccessful ? .ready : .notReady
        case .denied, .restricted:
            return .blocked
        case .notDetermined:
            return .notReady
        @unknown default:
            return .blocked
        }
    }

    private var accessibilityReadiness: OnboardingReadinessStatus {
        if accessibilityWasSkipped { return .deferred }
        switch accessibilityStatus {
        case .granted: return .ready
        case .denied: return .blocked
        case .notDetermined, .unknown: return .notReady
        }
    }

    private var shortcutReadiness: OnboardingReadinessStatus {
        if shortcutWasSkipped { return .deferred }
        switch shortcutRegistrationState {
        case .registered(let registeredShortcut):
            return shortcut == registeredShortcut ? .ready : .notReady
        case .failed:
            return .blocked
        case .unregistered:
            return .notReady
        }
    }

    // MARK: Stage navigation

    /// Advances the current screen.  A screen after Welcome is always
    /// skippable, including when its prerequisite has not been attempted.
    public func advance() {
        switch stage {
        case .welcome:
            welcomeAcknowledged = true
            move(to: .speechModel)
        case .speechModel:
            // A ready or in-progress model is not "skipped": marking it
            // deferred here would show Deferred on the Ready screen until the
            // shell's next state report cleared it.
            switch modelState {
            case .ready, .inference:
                move(to: .microphone)
            case .validatingExternal, .downloading, .verifying, .installing, .loading, .deleting:
                continueWithModelInProgress()
            case .absent, .downloadPaused, .corrupt, .incompatible, .error, .unavailable:
                skipModel()
            }
        case .microphone:
            if microphoneAuthorization == .granted, microphoneTestState.isSuccessful {
                move(to: .accessibility)
            } else {
                skipMicrophone()
            }
        case .accessibility:
            if accessibilityStatus == .granted {
                move(to: .shortcut)
            } else {
                skipAccessibility()
            }
        case .shortcut:
            if readiness.shortcut.isReady {
                // Whether or not the Try It check was done: the shortcut is
                // registered, and the check is advice, not a prerequisite.
                move(to: .ready)
            } else {
                skipShortcut()
            }
        case .ready:
            finishOnboarding()
        }
    }

    /// Alias used by window routers that describe the button as Continue.
    public func continueFromCurrentStage() {
        advance()
    }

    /// Replays the education flow from Welcome (FR-ONB-010). Facts the flow
    /// observed — model state, permissions, shortcut registration — are kept
    /// because they are still true; only navigation, skip choices, and the
    /// dictation test outcome are cleared.
    public func restart() {
        stage = .welcome
        welcomeAcknowledged = false
        isFinished = false
        modelWasSkipped = false
        microphoneWasSkipped = false
        accessibilityWasSkipped = false
        shortcutWasSkipped = false
        // Must run before the flag/snapshot reset below: `restart()` can be
        // called (Reset Onboarding) while the Try It indicator is on screen,
        // and setting `stage` above does not synchronously cancel the view's
        // `.task(id:)` — its eventual `endHotkeyTest()` would then be a
        // no-op against an already-false flag and never emit `.endHotkeyTest`,
        // leaving `AppDelegate.onboardingHotkeyTestHook` installed and every
        // shortcut press swallowed until relaunch. Calling the idempotent
        // `endHotkeyTest()` here emits it unconditionally instead.
        endHotkeyTest()
        hotkeyTestSnapshot = HotkeyTestSnapshot()
        dictationTestRequested = false
        dictationTestResult = nil
        systemSettingsOpenFailed = nil
        if microphoneTestState == .skipped {
            microphoneTest.reset()
        }
    }

    /// Ready's Finish. Completes regardless of readiness: what was skipped
    /// stays visible as Not Ready in the menu and in Settings (FR-ONB-009).
    public func finishOnboarding() {
        guard stage == .ready else { return }
        guard !isFinished else { return }
        isFinished = true
        // Completion plus `tutorialSeen` — `LocalStateReducer`'s row, through
        // the same door as every other write. The tour was offered once, as
        // Ready's "Take the Quick Tour" link; whether it was taken or not,
        // the existing-user banner (`shouldOfferTutorialBanner`) is for
        // users who completed setup before the tour existed, and Help ›
        // Quick Tour stays available. The shell's `.finish` handling is the
        // window only.
        settings.send(.completeOnboarding(version: Self.currentOnboardingVersion, origin: .wizard))
        emit(.finish)
        onFinished()
    }

    // MARK: Model intents

    /// Download, Retry, and Choose Existing stay on the model screen so the
    /// user sees the operation start; "Continue" then carries on while it
    /// runs (C.2 step 3). The flow used to jump to the microphone screen the
    /// moment Download was pressed, which read as the press being ignored.
    public func handleModelAction(_ action: OnboardingModelAction) {
        switch action {
        case .download:
            guard !modelIsBusy else { return }
            modelWasSkipped = false
            beginPendingModelAction()
            emit(.downloadModel)
        case .chooseExisting:
            guard !modelIsBusy else { return }
            modelWasSkipped = false
            // No pending flag: the folder chooser is its own visible
            // feedback, and cancelling it changes no lifecycle state.
            emit(.chooseExistingModel)
        case .skip:
            skipModel()
        case .cancel:
            emit(.cancelModelDownload)
        case .retry:
            guard !modelIsBusy else { return }
            modelWasSkipped = false
            beginPendingModelAction()
            emit(.retryModel)
        }
    }

    public func setModelState(_ state: ModelLifecycleState) {
        if modelActionPending, state != modelState {
            endPendingModelAction()
        }
        modelState = state
        if case .ready = state {
            modelWasSkipped = false
        } else if case .inference = state {
            modelWasSkipped = false
        }
    }

    /// The shell reports the current model's catalog entry alongside its
    /// state; nil when there is no library (a trust failure).
    public func setModelEntry(_ entry: SpeechModelCatalogEntry?) {
        modelEntry = entry
    }

    public func skipModel() {
        modelWasSkipped = true
        emit(.skipModel)
        move(to: .microphone)
    }

    /// Leaves the model screen while a download, verification, or load keeps
    /// running. Not a skip: the model stays Not Ready, not Deferred, and
    /// flips to Ready on its own when the shell reports it.
    public func continueWithModelInProgress() {
        move(to: .microphone)
    }

    private func beginPendingModelAction() {
        modelActionPending = true
        modelActionPendingTask?.cancel()
        modelActionPendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.modelActionPendingTimeout)
            } catch {
                return
            }
            self?.endPendingModelAction()
        }
    }

    private func endPendingModelAction() {
        modelActionPendingTask?.cancel()
        modelActionPendingTask = nil
        modelActionPending = false
    }

    /// The shell measures the download requirement and free space; either
    /// may be unknown. Passing nil for the requirement clears the estimate.
    public func setModelSpaceEstimate(requiredBytes: Int64?, availableBytes: Int64?) {
        guard let requiredBytes else {
            modelSpaceEstimate = nil
            return
        }
        modelSpaceEstimate = ModelSpaceEstimate(
            requiredBytes: requiredBytes,
            availableBytes: availableBytes
        )
    }

    // MARK: Microphone intents

    /// Reads both permission states without requesting either permission.
    /// Calling this from app activation is safe because `prompt` is never used
    /// on this path.
    public func refreshPermissions() async {
        microphoneAuthorization = await microphonePermission.authorization()
        let trusted = await accessibilityPermission.isTrusted(prompt: false)
        updateAccessibilityStatus(trusted: trusted)
        permissionsLastChecked = Date()
        if microphoneAuthorization == .granted, microphoneTestState == .skipped {
            microphoneTest.reset()
            microphoneWasSkipped = false
        }
    }

    /// The periodic, non-prompting, non-emitting read the setup window runs
    /// while it is visible, so a permission changed in System Settings shows
    /// up on its own and a Granted card never goes stale (D.9).
    public func pollPermissions() async {
        await refreshPermissions()
    }

    /// Re-reads the microphone state only, without prompting. The microphone
    /// step's Retry Status button uses it after a denial.
    public func refreshMicrophoneStatus() async {
        microphoneAuthorization = await microphonePermission.authorization()
        permissionsLastChecked = Date()
        if microphoneAuthorization == .granted, microphoneTestState == .skipped {
            microphoneTest.reset()
            microphoneWasSkipped = false
        }
    }

    /// Best-effort deep link into the permission's System Settings pane. On
    /// failure the written path is promoted in the view (FR-PERM-004).
    public func openSystemSettings(for kind: PermissionKind) {
        if kind == .accessibility {
            // Routed through the intent so the shell's existing handler runs.
            emit(.openAccessibilitySettings)
        }
        let opened = openSystemSettingsHandler?(kind) ?? (kind == .accessibility)
        if opened {
            if systemSettingsOpenFailed == kind {
                systemSettingsOpenFailed = nil
            }
        } else {
            systemSettingsOpenFailed = kind
        }
    }

    public func appDidBecomeActive() async {
        await refreshPermissions()
    }

    /// The only path that asks TCC for microphone access.  The view calls this
    /// only from an explicit Allow button after showing its explanation.
    public func requestMicrophonePermission() async {
        guard !isRequestingMicrophonePermission else { return }
        isRequestingMicrophonePermission = true
        defer { isRequestingMicrophonePermission = false }
        emit(.requestMicrophonePermission)
        let authorization = await microphonePermission.requestAccess()
        microphoneAuthorization = authorization
        permissionsLastChecked = Date()
        if authorization == .granted, microphoneTestState == .skipped {
            microphoneTest.reset()
            microphoneWasSkipped = false
        }
        permissionRequestDidReturn?(.microphone)
    }

    /// The level test is a separate action from the permission request
    /// (FR-ONB-004) and cannot start before the grant.
    public func runMicrophoneTest(duration: Duration = .seconds(3)) async {
        guard microphoneAuthorization == .granted else {
            await microphoneTest.run(authorization: microphoneAuthorization, duration: duration)
            return
        }

        microphoneWasSkipped = false
        emit(.runMicrophoneTest)
        await microphoneTest.run(authorization: .granted, duration: duration)
    }

    /// Production audio adapters can feed meter samples while a test is
    /// running.  The domain AudioCaptureService result remains the only data
    /// retained after the test, and no audio samples are stored here.
    public func updateMicrophoneLevel(rmsDBFS: Float, peakDBFS: Float) {
        microphoneTest.updateLevel(rmsDBFS: rmsDBFS, peakDBFS: peakDBFS)
    }

    public func skipMicrophone() {
        microphoneWasSkipped = true
        microphoneTest.markSkipped()
        emit(.skipMicrophone)
        move(to: .accessibility)
    }

    // MARK: Accessibility intents

    /// Requests Accessibility trust only from an explicit user action.  A
    /// returned `false` is retained as Denied; a prompt being shown is never
    /// treated as proof of grant.
    public func requestAccessibilityPermission() async {
        guard !isRequestingAccessibilityPermission else { return }
        isRequestingAccessibilityPermission = true
        defer { isRequestingAccessibilityPermission = false }
        accessibilityPromptWasRequested = true
        emit(.requestAccessibilityPermission)
        let trusted = await accessibilityPermission.isTrusted(prompt: true)
        updateAccessibilityStatus(trusted: trusted)
        permissionsLastChecked = Date()
        permissionRequestDidReturn?(.accessibility)
    }

    public func refreshAccessibilityStatus() async {
        emit(.refreshAccessibilityStatus)
        await pollAccessibilityStatus()
    }

    /// Non-prompting, non-emitting trust read. The accessibility step runs
    /// this every second while it is visible (FR-PERM-005) so a grant made in
    /// System Settings shows up without a relaunch.
    public func pollAccessibilityStatus() async {
        let trusted = await accessibilityPermission.isTrusted(prompt: false)
        updateAccessibilityStatus(trusted: trusted)
        permissionsLastChecked = Date()
    }

    public func openAccessibilitySettings() {
        emit(.openAccessibilitySettings)
    }

    public func setAccessibilityTrusted(_ trusted: Bool) {
        updateAccessibilityStatus(trusted: trusted)
    }

    public func skipAccessibility() {
        accessibilityWasSkipped = true
        emit(.skipAccessibility)
        move(to: .shortcut)
    }

    // MARK: Shortcut intents

    public func requestShortcutRecording() {
        emit(.recordShortcut)
    }

    /// Accepts the documented recommendation without opening the recorder.
    @discardableResult
    public func useRecommendedShortcut() -> Bool {
        setShortcut(GeneralSettingsViewModel.recommendedShortcut)
    }

    /// Records a shortcut the wizard's recorder returned: validates it, sends
    /// `SettingsIntent.setShortcut` (origin `.wizard`) and, on acceptance,
    /// shows it as registered until the shell reports the real registration
    /// state. The presentation state is set *before* the send because the
    /// shell's `.registerShortcut` effect runs inside it and reports the
    /// outcome through `setShortcutRegistrationState`, which must win. A
    /// refusal (a job in flight) puts the previous state back and shows the
    /// reducer's note as the step's error.
    @discardableResult
    public func setShortcut(_ candidate: ShortcutDefinition) -> Bool {
        guard Self.isUsableShortcut(candidate) else {
            shortcutError = String(localized: "Choose a lone modifier key such as Right Option, or a key with at least one supported modifier.", bundle: .module)
            return false
        }
        let previous = (shortcut, shortcutRegistrationState, shortcutWasSkipped)
        shortcutError = nil
        shortcut = candidate
        shortcutRegistrationState = .registered(candidate)
        shortcutWasSkipped = false
        // A shortcut recorded while the Try It indicator is up ("Choose
        // Another Shortcut…") must not inherit the previous shortcut's
        // press/release count.
        if stage == .shortcut {
            resetHotkeyTest()
        }
        if let refusal = settings.send(.setShortcut(candidate, origin: .wizard)) {
            (shortcut, shortcutRegistrationState, shortcutWasSkipped) = previous
            shortcutError = SettingsProjectionHost.note(for: refusal)
            return false
        }
        emit(.shortcutRecorded(candidate))
        return true
    }

    /// Updates registration feedback from the owning hotkey service.  A
    /// recorded candidate is not Ready after a conflict or registration
    /// failure, even though it remains available for retry in the UI.
    public func setShortcutRegistrationState(_ state: ShortcutRegistrationState) {
        shortcutRegistrationState = state
        switch state {
        case .registered(let registeredShortcut):
            shortcut = registeredShortcut
            shortcutError = nil
            shortcutWasSkipped = false
        case .failed(let code):
            shortcutError = "Shortcut registration failed (\(code.rawValue))."
        case .unregistered:
            shortcutError = nil
        }
        emit(.shortcutRegistrationState(state))
    }

    /// The trigger-mode picker on the shortcut step: one `SettingsIntent`
    /// with origin `.wizard`. A refusal leaves the stored mode — and so the
    /// picker — where it was.
    public func setRecordingInteraction(_ interaction: RecordingInteraction) {
        guard interaction != recordingInteraction else { return }
        guard settings.send(.setRecordingInteraction(interaction, origin: .wizard)) == nil else { return }
        emit(.setRecordingInteraction(interaction))
    }

    public func skipShortcut() {
        shortcutWasSkipped = true
        emit(.skipShortcut)
        move(to: .ready)
    }

    // MARK: Hotkey test (the shortcut page's Try It indicator)

    /// True while the shortcut page shows its Try It indicator: a shortcut
    /// is registered, so there is an edge to detect. The view keys its hook
    /// task on this, so recording the first shortcut installs the hook and
    /// leaving the page (or losing the registration) removes it.
    public var hotkeyTestIsAvailable: Bool {
        stage == .shortcut && readiness.shortcut.isReady && !isFinished
    }

    /// Installs the onboarding-scoped shortcut hook (Later waves: onboarding
    /// hotkey test). While installed, the shell reports the primary global
    /// shortcut's key-down/up to `reportHotkeyTestKeyDown()/Up()` instead of
    /// starting a dictation — see `AppDelegate.receiveShortcut`. The view
    /// calls this when `hotkeyTestIsAvailable` becomes true and
    /// `endHotkeyTest()` as soon as it turns false or the window goes away,
    /// via a `.task(id:)` whose cancellation always runs the matching
    /// `endHotkeyTest()`, so the hook is never left installed.
    public func beginHotkeyTest() {
        guard !hotkeyTestHookInstalled else { return }
        hotkeyTestHookInstalled = true
        hotkeyTestSnapshot = HotkeyTestSnapshot()
        emit(.beginHotkeyTest)
    }

    public func endHotkeyTest() {
        guard hotkeyTestHookInstalled else { return }
        hotkeyTestHookInstalled = false
        emit(.endHotkeyTest)
    }

    /// Clears a stale result after the user records a different shortcut
    /// mid-step (`setShortcut` calls this automatically).
    public func resetHotkeyTest() {
        hotkeyTestSnapshot = HotkeyTestSnapshot()
    }

    /// The shell forwards the primary shortcut's key-down here while the
    /// hook is installed. Toggle needs a second key-down to finish (press to
    /// start, press to stop); push-to-talk and hybrid finish on the matching
    /// key-up, matching `RecordingInteraction`'s real dictation semantics so
    /// the test proves what the user will actually feel.
    public func reportHotkeyTestKeyDown(at now: Date = Date()) {
        guard hotkeyTestHookInstalled, !hotkeyTestSnapshot.isDone else { return }
        hotkeyTestSnapshot.isDown = true
        hotkeyTestSnapshot.downAt = now
        hotkeyTestSnapshot.heldSeconds = 0
        hotkeyTestSnapshot.pressCount += 1
        if recordingInteraction == .toggle, hotkeyTestSnapshot.pressCount >= 2 {
            hotkeyTestSnapshot.isDown = false
            hotkeyTestSnapshot.isDone = true
        }
    }

    public func reportHotkeyTestKeyUp(at now: Date = Date()) {
        guard hotkeyTestHookInstalled, hotkeyTestSnapshot.isDown else { return }
        hotkeyTestSnapshot.isDown = false
        if let downAt = hotkeyTestSnapshot.downAt {
            hotkeyTestSnapshot.heldSeconds = max(0, now.timeIntervalSince(downAt))
        }
        if recordingInteraction != .toggle {
            hotkeyTestSnapshot.isDone = true
        }
    }

    /// Advances the live "Held for 0.8 s" reading while push-to-talk or
    /// hybrid is held. The view calls this on a short repeating timer with
    /// the wall clock in production; tests pass an explicit `now` instead of
    /// waiting on real time.
    public func tickHotkeyTest(now: Date = Date()) {
        guard hotkeyTestSnapshot.isDown, let downAt = hotkeyTestSnapshot.downAt else { return }
        hotkeyTestSnapshot.heldSeconds = max(0, now.timeIntervalSince(downAt))
    }

    /// Skip on the shortcut page while a shortcut is registered: the
    /// shortcut stays Ready; only the Try It check is left undone.
    public func skipHotkeyTest() {
        move(to: .ready)
    }

    /// The Try It card's status line, following the trigger mode chosen
    /// above it on the same page.
    public var hotkeyTestStatusDescription: String {
        if hotkeyTestSnapshot.isDone {
            return String(localized: "Shortcut detected. You're set.", bundle: .module)
        }
        switch recordingInteraction {
        case .pushToTalk, .hybrid:
            if hotkeyTestSnapshot.isDown, let heldSeconds = hotkeyTestSnapshot.heldSeconds {
                return String(localized: "Held for \(Self.formatHeldSeconds(heldSeconds)) s", bundle: .module)
            }
            return String(localized: "Press and hold your shortcut now.", bundle: .module)
        case .toggle:
            return hotkeyTestSnapshot.pressCount == 0
                ? String(localized: "Press your shortcut to start.", bundle: .module)
                : String(localized: "Press it again to stop.", bundle: .module)
        }
    }

    /// One decimal place, locale-independent (`0.8`, never `0,8`), because
    /// this is a live status line updated several times a second.
    private static func formatHeldSeconds(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    // MARK: Ready links

    /// "Take the Quick Tour" on Ready: the standalone tutorial window,
    /// exactly as Help › Quick Tour opens it. Optional — it neither blocks
    /// Finish nor changes the wizard's state. Inert once finished, because
    /// the window is closing.
    public func openQuickTour() {
        guard !isFinished else { return }
        openTutorialHandler?()
    }

    /// "Set up AI Actions" on Ready: the main window on AI Actions, the same
    /// page Settings opens. AI stays Off unless the user turns it on there
    /// (FR-ONB-008: nothing is sent from the wizard). Optional, like the
    /// tour.
    public func openAIActionsSetup() {
        guard !isFinished else { return }
        openMainWindowHandler?(.aiActions)
    }

    /// The Ready summary's line for the trigger mode (was the Complete
    /// page's; merged into Ready 2026-09-16).
    public var recordingInteractionSummary: String {
        switch recordingInteraction {
        case .pushToTalk: return String(localized: "Push-to-Talk (hold)", bundle: .module)
        case .toggle: return String(localized: "Toggle (press to start and stop)", bundle: .module)
        case .hybrid: return String(localized: "Hybrid (tap to toggle, hold to talk)", bundle: .module)
        }
    }

    // MARK: Readiness / dictation intent

    public func requestDictationTest() {
        guard canRunDictationTest else { return }
        dictationTestRequested = true
        dictationTestIsRecording = true
        dictationTestResult = nil
        emit(.runDictationTest)
    }

    /// The shell delivers the outcome of the production recorder/STT run.
    /// A transcript is shown in the in-app field; it is not inserted anywhere
    /// and not retained beyond this screen's state.
    public func setDictationTestResult(_ result: DictationTestResult?) {
        dictationTestResult = result
        if result != nil {
            dictationTestIsRecording = false
        }
    }

    /// Returns to the screen that resolves a prerequisite (used by the
    /// failure link on the Ready screen).
    public func goToStep(for item: OnboardingReadinessItem) {
        guard !isFinished else { return }
        stage = item.stage
    }

    /// Stops a running dictation test. The test previously had no stop control
    /// at all: it began recording and the only ways out were the global
    /// shortcut or the recorder's duration cap.
    public func stopDictationTest() {
        guard dictationTestIsRecording else { return }
        emit(.stopDictationTest)
    }

    /// The coordinator owns the real dictation lifecycle, so it reports when
    /// the test recording actually ends (stopped, cancelled, or completed).
    public func setDictationTestRecording(_ isRecording: Bool) {
        dictationTestIsRecording = isRecording
    }

    /// Dispatches synchronous intents for coordinators that prefer one entry
    /// point.  Permission and microphone-test requests have explicit async
    /// methods above so this method cannot accidentally prompt during a pure
    /// state transition test.
    public func send(_ intent: OnboardingIntent) {
        switch intent {
        case .downloadModel: handleModelAction(.download)
        case .chooseExistingModel: handleModelAction(.chooseExisting)
        case .skipModel: skipModel()
        case .cancelModelDownload: emit(.cancelModelDownload)
        case .retryModel: emit(.retryModel)
        case .requestMicrophonePermission: emit(.requestMicrophonePermission)
        case .runMicrophoneTest: emit(.runMicrophoneTest)
        case .skipMicrophone: skipMicrophone()
        case .requestAccessibilityPermission: emit(.requestAccessibilityPermission)
        case .openAccessibilitySettings: openAccessibilitySettings()
        case .refreshAccessibilityStatus: emit(.refreshAccessibilityStatus)
        case .skipAccessibility: skipAccessibility()
        case .recordShortcut: requestShortcutRecording()
        case .setRecordingInteraction(let interaction): setRecordingInteraction(interaction)
        case .shortcutRecorded(let shortcut): _ = setShortcut(shortcut)
        case .shortcutRegistrationState(let state): setShortcutRegistrationState(state)
        case .skipShortcut: skipShortcut()
        case .beginHotkeyTest: beginHotkeyTest()
        case .endHotkeyTest: endHotkeyTest()
        case .runDictationTest: requestDictationTest()
        case .stopDictationTest: stopDictationTest()
        case .finish: finishOnboarding()
        }
    }

    /// Async counterpart for callers that want one intent routing API while
    /// preserving explicit permission/test suspension points.
    public func perform(_ intent: OnboardingIntent) async {
        switch intent {
        case .requestMicrophonePermission:
            await requestMicrophonePermission()
        case .runMicrophoneTest:
            await runMicrophoneTest()
        case .requestAccessibilityPermission:
            await requestAccessibilityPermission()
        case .refreshAccessibilityStatus:
            await refreshAccessibilityStatus()
        default:
            send(intent)
        }
    }

    // MARK: Private helpers

    /// True when there is an earlier stage to return to.
    public var canGoBack: Bool {
        !isFinished && stage != OnboardingStage.allCases[0]
    }

    /// Returns to the previous stage.
    ///
    /// The flow was forward-only, so a user who passed the model step — for
    /// example because a long verify looked like a failure — had no way back to
    /// re-select a model and had to reach it from Settings instead.
    public func goBack() {
        guard canGoBack else { return }
        guard let index = OnboardingStage.allCases.firstIndex(of: stage),
              index > 0 else { return }
        stage = OnboardingStage.allCases[index - 1]
    }

    private func move(to destination: OnboardingStage) {
        guard !isFinished else { return }
        stage = destination
    }

    private func emit(_ intent: OnboardingIntent) {
        onIntent(intent)
    }

    private func updateAccessibilityStatus(trusted: Bool) {
        accessibilityStatus = trusted
            ? .granted
            : (accessibilityPromptWasRequested ? .denied : .notDetermined)
        if trusted {
            accessibilityWasSkipped = false
        }
    }

    /// Same rule as `GeneralSettingsViewModel.confirmShortcut`: a lone
    /// modifier key (Right Option) or a key with supported modifiers.
    private static func isUsableShortcut(_ shortcut: ShortcutDefinition) -> Bool {
        shortcut.isStructurallyValid
    }
}

public struct UnavailableMicrophonePermissionProvider: MicrophonePermissionProviding {
    public init() {}

    public func authorization() async -> PermissionAuthorization { .notDetermined }
    public func requestAccess() async -> PermissionAuthorization { .notDetermined }
}

public struct UnavailableAccessibilityPermissionProvider: AccessibilityPermissionProviding {
    public init() {}

    public func isTrusted(prompt: Bool) async -> Bool { false }
}
