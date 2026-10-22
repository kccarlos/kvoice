import Foundation
import KvoiceDomain

/// UI v2 wave 3: what the restyled setup wizard shows, derived from the same
/// state the flow already keeps, so every rule the design states is testable
/// without a view — the step bar's four states, the status chip on each
/// step's card, and the Ready checklist's detail lines.

/// One dot of the labelled step bar at the top of every screen. The design
/// rule: after Welcome every step can be skipped, and a skipped step stays
/// visible as an amber dashed circle.
public enum OnboardingStepState: String, Sendable, Equatable, CaseIterable {
    /// Walked through (blue dot with a check).
    case done
    /// The screen on show (ink dot with its number).
    case current
    /// Skipped, or left blocked: amber dashed circle, amber label.
    case skipped
    /// Not reached yet (grey outline with its number).
    case todo
}

/// The status chip on a step's card (and the shortcut box): a soft capsule
/// with a dot and words in one tone. Never colour alone.
public struct OnboardingStatusChip: Sendable, Equatable {
    public let title: String
    public let tone: KVTone

    public init(_ title: String, tone: KVTone) {
        self.title = title
        self.tone = tone
    }
}

public extension OnboardingStage {
    /// The prerequisite this screen sets up, or nil for Welcome and Ready.
    var readinessItem: OnboardingReadinessItem? {
        switch self {
        case .welcome, .ready: return nil
        case .speechModel: return .model
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .shortcut: return .shortcut
        }
    }

    /// The step bar's short label ("Model", not "Speech Model").
    var stepBarTitle: String {
        switch self {
        case .speechModel: return String(localized: "Model", bundle: .module)
        default: return title
        }
    }
}

public extension OnboardingViewModel {
    // MARK: Step bar

    /// The step bar's state for one stage. The current screen is always
    /// `current`. A prerequisite the user skipped is `skipped` wherever it
    /// sits, so jumping back with Fix… still shows what is open; one that
    /// went blocked behind the user (a microphone denied after the step) is
    /// `skipped` too. A model still downloading, verifying or optimizing is
    /// `done`: the download does not block (the Ready checklist shows its
    /// progress). A step ahead of the current one is `done` only when its
    /// prerequisite is already ready (the user went Back), else `todo`.
    func stepState(for stage: OnboardingStage) -> OnboardingStepState {
        if stage == self.stage { return .current }
        let isBehind = stage.ordinal < self.stage.ordinal
        if let item = stage.readinessItem {
            let status = readiness[item]
            if status == .deferred { return .skipped }
            if status == .blocked, isBehind { return .skipped }
            if isBehind { return .done }
            return status.isReady ? .done : .todo
        }
        return isBehind ? .done : .todo
    }

    /// The step bar left to right, in `OnboardingStage.allCases` order.
    var stepStates: [OnboardingStepState] {
        OnboardingStage.allCases.map(stepState(for:))
    }

    /// VoiceOver's reading of one step bar dot: "Accessibility, skipped".
    func stepAccessibilityLabel(for stage: OnboardingStage) -> String {
        let name = stage.stepBarTitle
        switch stepState(for: stage) {
        case .done: return String(localized: "\(name), done", bundle: .module)
        case .current: return String(localized: "\(name), current step", bundle: .module)
        case .skipped: return String(localized: "\(name), skipped", bundle: .module)
        case .todo: return String(localized: "\(name), not started", bundle: .module)
        }
    }

    // MARK: Status chips

    /// The model card's chip. Progress is cursor (text is on its way), a
    /// pause asks something of the user (warn), a failure is err.
    var modelChip: OnboardingStatusChip {
        switch modelState {
        case .ready, .inference:
            return OnboardingStatusChip(String(localized: "Ready", bundle: .module), tone: .ok)
        case .downloading:
            return OnboardingStatusChip(String(localized: "Downloading", bundle: .module), tone: .cursor)
        case .verifying:
            return OnboardingStatusChip(String(localized: "Verifying", bundle: .module), tone: .cursor)
        case .installing:
            return OnboardingStatusChip(String(localized: "Installing", bundle: .module), tone: .cursor)
        case .validatingExternal:
            return OnboardingStatusChip(String(localized: "Checking", bundle: .module), tone: .cursor)
        case .loading:
            return OnboardingStatusChip(String(localized: "Loading", bundle: .module), tone: .cursor)
        case .optimizing:
            return OnboardingStatusChip(String(localized: "Optimizing", bundle: .module), tone: .cursor)
        case .deleting:
            return OnboardingStatusChip(String(localized: "Removing", bundle: .module), tone: .cursor)
        case .downloadPaused:
            return OnboardingStatusChip(String(localized: "Paused", bundle: .module), tone: .warn)
        case .corrupt, .error:
            return OnboardingStatusChip(String(localized: "Failed", bundle: .module), tone: .err)
        case .incompatible:
            return OnboardingStatusChip(String(localized: "Not compatible", bundle: .module), tone: .err)
        case .unavailable:
            return OnboardingStatusChip(String(localized: "Unavailable", bundle: .module), tone: .warn)
        case .absent:
            if modelEntry?.isSystemManaged == true {
                return OnboardingStatusChip(String(localized: "Recommended for this Mac", bundle: .module), tone: .cursor)
            }
            return OnboardingStatusChip(String(localized: "Not installed", bundle: .module), tone: .neutral)
        }
    }

    /// True when the model card has a problem the user must see: its edge
    /// turns err.
    var modelCardIsFailed: Bool {
        switch modelState {
        case .corrupt, .incompatible, .error: return true
        default: return false
        }
    }

    /// True when the shell measured the download and it does not fit. The
    /// Download primary is disabled with a reason (the manager would refuse
    /// it anyway); Skip and the alternative model stay available.
    var modelDownloadLacksSpace: Bool {
        guard case .absent = modelState, modelEntry?.isSystemManaged != true else { return false }
        return modelSpaceEstimate?.isSufficient == false
    }

    /// The microphone card's chip. The OS prompt open is cursor ("Waiting");
    /// a denial asks the user to act, so it is warn, not err.
    func microphoneChip(now: Date = Date()) -> OnboardingStatusChip {
        if isRequestingMicrophonePermission {
            return OnboardingStatusChip(String(localized: "Waiting", bundle: .module), tone: .cursor)
        }
        switch microphonePermissionCard.presentedState(now: now) {
        case .granted: return OnboardingStatusChip(String(localized: "Allowed", bundle: .module), tone: .ok)
        case .notRequested: return OnboardingStatusChip(String(localized: "Not requested", bundle: .module), tone: .neutral)
        case .denied: return OnboardingStatusChip(String(localized: "Denied", bundle: .module), tone: .warn)
        case .restricted: return OnboardingStatusChip(String(localized: "Restricted", bundle: .module), tone: .warn)
        case .unknown: return OnboardingStatusChip(String(localized: "Checking…", bundle: .module), tone: .neutral)
        }
    }

    /// True while the Accessibility step waits for the user to switch KVoice
    /// on in System Settings: after the prompt, trust reads as not granted
    /// although nothing was refused (Accessibility has no deny). The card
    /// says amber "Not enabled yet", never "Denied".
    var accessibilityIsWaitingForUser: Bool {
        accessibilityStatus != .granted && (isAwaitingAccessibilityGrant || accessibilityStatus == .denied)
    }

    func accessibilityChip(now: Date = Date()) -> OnboardingStatusChip {
        if isRequestingAccessibilityPermission {
            return OnboardingStatusChip(String(localized: "Waiting", bundle: .module), tone: .cursor)
        }
        if accessibilityIsWaitingForUser {
            return OnboardingStatusChip(String(localized: "Not enabled yet", bundle: .module), tone: .warn)
        }
        switch accessibilityPermissionCard.presentedState(now: now) {
        case .granted: return OnboardingStatusChip(String(localized: "Allowed", bundle: .module), tone: .ok)
        case .notRequested: return OnboardingStatusChip(String(localized: "Not requested", bundle: .module), tone: .neutral)
        case .denied, .restricted: return OnboardingStatusChip(String(localized: "Not enabled yet", bundle: .module), tone: .warn)
        case .unknown: return OnboardingStatusChip(String(localized: "Checking…", bundle: .module), tone: .neutral)
        }
    }

    /// The shortcut box's chip.
    var shortcutChip: OnboardingStatusChip {
        if shortcutRecorderIsOpen {
            return OnboardingStatusChip(String(localized: "Recording", bundle: .module), tone: .cursor)
        }
        if case .failed = shortcutRegistrationState, shortcutIsTaken {
            return OnboardingStatusChip(String(localized: "Taken", bundle: .module), tone: .err)
        }
        switch shortcutRegistrationState {
        case .registered(let registered) where registered == shortcut:
            return OnboardingStatusChip(String(localized: "Registered", bundle: .module), tone: .ok)
        case .failed:
            return OnboardingStatusChip(String(localized: "Not registered", bundle: .module), tone: .err)
        case .registered, .unregistered:
            return shortcut == nil
                ? OnboardingStatusChip(String(localized: "Not set", bundle: .module), tone: .neutral)
                : OnboardingStatusChip(String(localized: "Not registered", bundle: .module), tone: .warn)
        }
    }

    /// The recorded shortcut as keycaps ("⌃", "⇧", "Space"); empty when none.
    var shortcutKeyCaps: [String] {
        guard let shortcut else { return [] }
        return StatusPanelState.keyCaps(GeneralSettingsViewModel.glyphs(for: shortcut))
    }

    /// The keycaps the Welcome hero shows: the recorded shortcut, else the
    /// recommended one (the hero illustrates, it claims nothing).
    var heroKeyCaps: [String] {
        let caps = shortcutKeyCaps
        return caps.isEmpty
            ? StatusPanelState.keyCaps(GeneralSettingsViewModel.glyphs(for: GeneralSettingsViewModel.recommendedShortcut))
            : caps
    }

    // MARK: Ready checklist

    /// True while the model row shows progress instead of Fix…: the work is
    /// already under way and the user has nothing to fix.
    var modelIsInProgress: Bool {
        switch modelState {
        case .validatingExternal, .downloading, .verifying, .installing, .loading, .optimizing, .deleting:
            return true
        default:
            return false
        }
    }

    /// Whether a checklist row offers Fix…: anything not ready, except a
    /// model whose download or first load is running.
    func checklistOffersFix(for item: OnboardingReadinessItem) -> Bool {
        if readiness[item].isReady { return false }
        if item == .model, modelIsInProgress, readiness.model != .deferred { return false }
        return true
    }

    /// The Ready checklist's second line for one prerequisite: what is set
    /// up, or why it is open.
    func checklistDetail(for item: OnboardingReadinessItem) -> String {
        let status = readiness[item]
        switch item {
        case .model:
            if status == .deferred { return String(localized: "Skipped", bundle: .module) }
            if status.isReady { return modelDisplayName }
            if modelIsInProgress, let activity = modelActivityDescription { return activity }
            if status == .blocked { return String(localized: "Needs attention on the Model step", bundle: .module) }
            if case .downloadPaused = modelState { return String(localized: "Download paused", bundle: .module) }
            return String(localized: "Not installed", bundle: .module)
        case .microphone:
            if status == .deferred { return String(localized: "Skipped", bundle: .module) }
            if status == .blocked { return String(localized: "Denied in System Settings", bundle: .module) }
            if status.isReady {
                if let device = currentInputDeviceName {
                    return String(localized: "\(device) · tested", bundle: .module)
                }
                return String(localized: "Tested", bundle: .module)
            }
            if microphoneAuthorization == .granted {
                return String(localized: "Allowed · level test not run", bundle: .module)
            }
            return String(localized: "Not requested", bundle: .module)
        case .accessibility:
            // Both editions fall back to the clipboard without the grant
            // (AX tiers or typed events alike, ADR-016 / ADR-026).
            if status == .deferred { return String(localized: "Skipped — text will be copied to the clipboard", bundle: .module) }
            if status.isReady {
                return edition == .appStore
                    ? String(localized: "KVoice types the text into your app", bundle: .module)
                    : String(localized: "Text goes straight to your cursor", bundle: .module)
            }
            if accessibilityIsWaitingForUser { return String(localized: "Not enabled yet", bundle: .module) }
            return String(localized: "Not requested", bundle: .module)
        case .shortcut:
            if status == .deferred { return String(localized: "Skipped", bundle: .module) }
            if status == .blocked { return String(localized: "Could not register this shortcut", bundle: .module) }
            if status.isReady, let shortcut {
                return String(localized: "\(GeneralSettingsViewModel.glyphs(for: shortcut)) · \(recordingInteractionName)", bundle: .module)
            }
            return String(localized: "No shortcut yet", bundle: .module)
        }
    }

    /// The trigger mode's name alone ("Push-to-Talk").
    var recordingInteractionName: String {
        Self.name(for: recordingInteraction)
    }

    nonisolated static func name(for interaction: RecordingInteraction) -> String {
        switch interaction {
        case .pushToTalk: return String(localized: "Push-to-Talk", bundle: .module)
        case .toggle: return String(localized: "Toggle", bundle: .module)
        case .hybrid: return String(localized: "Hybrid", bundle: .module)
        }
    }

    /// The mode card's one-line description.
    nonisolated static func summary(for interaction: RecordingInteraction) -> String {
        switch interaction {
        case .pushToTalk: return String(localized: "Hold to record, release to stop", bundle: .module)
        case .toggle: return String(localized: "Press to start, press again to stop", bundle: .module)
        case .hybrid: return String(localized: "Tap to toggle, or hold to talk", bundle: .module)
        }
    }

    // MARK: Welcome

    /// Welcome's "Privacy details" link: the main window on Data & Privacy,
    /// where what KVoice keeps on this Mac is listed and controlled. The
    /// wizard stays open behind it, as with the Ready links.
    func openPrivacyDetails() {
        guard !isFinished else { return }
        openMainWindowHandler?(.dataPrivacy)
    }
}

// MARK: - UI v2 fidelity F4 (Wizard.dc's per-state copy)

extension OnboardingViewModel {
    /// The model card's sentence for its state, and whether it is set in
    /// the primary text colour (the design's "keep going" lines are).
    var modelCardLine: (text: String, emphasized: Bool)? {
        switch modelState {
        case .ready, .inference:
            return (String(localized: "Installed, verified and loaded. Dictation will use it.", bundle: .module), false)
        case .downloading:
            return (String(localized: "The download keeps going while you finish the remaining steps.", bundle: .module), true)
        case .verifying:
            return (String(localized: "Every file is checked against the manifest bundled with this release.", bundle: .module), false)
        case .optimizing, .installing, .loading, .validatingExternal, .deleting:
            return (String(localized: "You can continue setup meanwhile.", bundle: .module), true)
        case .downloadPaused:
            return (String(localized: "Resume to continue where it stopped.", bundle: .module), false)
        case .absent:
            return (modelSourceNote, false)
        case .corrupt, .incompatible, .error, .unavailable:
            return nil
        }
    }

    /// The quiet sentence under the model card, per state; nil for the
    /// states the design draws without one.
    var modelStepNote: String? {
        switch modelState {
        case .absent:
            if modelEntry?.isSystemManaged == true {
                return String(localized: "Choose a different model any time in Settings › Speech Models.", bundle: .module)
            }
            return String(localized: "You can keep going while it downloads. Other models live in Settings › Speech Models.", bundle: .module)
        case .downloading:
            return String(localized: "Continue now — the Ready step shows its progress, and dictation unlocks the moment it finishes.", bundle: .module)
        default:
            return nil
        }
    }

    /// The card's foot (download size, free space, Choose Existing…) is
    /// drawn only while nothing runs: Not installed, Ready, Paused, Failed.
    var modelShowsFoot: Bool {
        guard !modelIsInProgress, !modelActionPending, !isDeterminingModel else { return false }
        return modelEntry?.isSystemManaged != true
    }

    /// A paused download's bar: how much is kept of the catalog's size.
    var modelPausedProgress: (fraction: Double?, label: String, trailing: String?)? {
        guard case .downloadPaused(let kept) = modelState else { return nil }
        guard let kept, kept > 0 else {
            return (nil, String(localized: "Download paused.", bundle: .module), nil)
        }
        let label = String(localized: "Download paused with \(Self.formatBytes(kept)) kept.", bundle: .module)
        guard let total = modelEntry?.downloadBytes, total > 0 else { return (nil, label, nil) }
        let fraction = min(1, max(0, Double(kept) / Double(total)))
        return (fraction, label, "\(Int((fraction * 100).rounded(.down)))%")
    }

    /// The no-space alert with both sizes, when the shell measured them.
    var modelNoSpaceMessage: String? {
        guard modelDownloadLacksSpace, let estimate = modelSpaceEstimate else { return nil }
        guard let available = estimate.availableBytes else {
            return String(localized: "Not enough free space for the download. Free some space, then retry.", bundle: .module)
        }
        let needs = ModelSettingsViewModel.formatBytes(estimate.requiredBytes)
        let free = ModelSettingsViewModel.formatBytes(available)
        return String(localized: "Not enough free space for the download (needs about \(needs), \(free) free). Free some space, then retry.", bundle: .module)
    }

    /// Why Ready's test button is off: "Waiting on Model. It unlocks when
    /// the download finishes." while only the model is still coming, else
    /// every open prerequisite named ("Waiting on Microphone and
    /// Shortcut. Use Fix… above."). Nil when the test can run.
    var dictationTestWaitingText: String? {
        let open = [OnboardingReadinessItem.model, .microphone, .shortcut].filter { !readiness[$0].isReady }
        guard !open.isEmpty else { return nil }
        if open == [.model], modelIsInProgress, readiness.model != .deferred {
            return String(localized: "Waiting on Model. It unlocks when the download finishes.", bundle: .module)
        }
        let names = ListFormatter.localizedString(byJoining: open.map(\.title))
        return String(localized: "Waiting on \(names). Use Fix… above.", bundle: .module)
    }

    /// True when any prerequisite is still open.
    var readinessHasOpenItems: Bool {
        OnboardingReadinessItem.allCases.contains { !readiness[$0].isReady }
    }

    /// Ready's "You can still finish" note (Wizard.dc's Blocked state): the
    /// test waits on something the user has to fix, not only on a model
    /// that is still arriving.
    var readinessNeedsFinishNote: Bool {
        let open = [OnboardingReadinessItem.model, .microphone, .shortcut].filter { !readiness[$0].isReady }
        guard !open.isEmpty else { return false }
        return !(open == [.model] && modelIsInProgress && readiness.model != .deferred)
    }
}

extension OnboardingViewModel {
    /// The microphone card's sentence (Wizard.dc).
    var microphoneCardLine: String {
        String(localized: "Audio is transcribed on this Mac and never uploaded. The level test below is not saved.", bundle: .module)
    }

    /// The Accessibility card's sentence: the edition's own (ADR-026).
    var accessibilityCardLine: String {
        if edition == .appStore {
            return String(localized: "KVoice types the finished text into the app you are dictating into. macOS asks for this under Accessibility; this edition only sends keystrokes to that app and never reads its text.", bundle: .module)
        }
        return accessibilityPermissionCard.rationale
    }

    /// The level test's status line (Wizard.dc), wizard copy over the
    /// shared test's state.
    var microphoneLevelStatus: String {
        switch microphoneTestState {
        case .notStarted, .skipped:
            return String(localized: "Press Run Level Test and speak for a moment to confirm the right input is selected.", bundle: .module)
        case .running:
            return String(localized: "Listening… say a few words.", bundle: .module)
        case .completed(let result):
            let peak = Int(Double(result.peakLevelDBFS).rounded())
            let text = peak < 0 ? "\u{2212}\(-peak)" : "\(peak)"
            return String(localized: "Level test complete (peak \(text) dBFS). Sounds good.", bundle: .module)
        case .failed(let message):
            return message
        }
    }

    /// The input the level test and dictation use: the shell's resolver
    /// reading when installed, else the system default the test reports.
    var currentInputDeviceName: String? {
        inputDeviceNameProvider?() ?? microphoneTest.inputDeviceName
    }
}

extension OnboardingViewModel {
    /// The Ready summary's "(hold)": how the mode uses the keys.
    var recordingInteractionVerb: String {
        switch recordingInteraction {
        case .pushToTalk: return String(localized: "hold", bundle: .module)
        case .toggle: return String(localized: "press to start and stop", bundle: .module)
        case .hybrid: return String(localized: "tap or hold", bundle: .module)
        }
    }
}
