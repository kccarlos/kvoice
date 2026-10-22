import Foundation
import KvoiceDomain
import Observation

/// The screens in the first-run setup, in order (spec C.2 as amended
/// 2026-09-16, design review P-W1). Six steps: the four prerequisites
/// (model, microphone, accessibility, shortcut) between a Welcome that
/// carries the privacy copy and a Ready page that carries the readiness
/// list, the first dictation test, the setup summary and Finish. The
/// shortcut page includes the live "Try It" indicator (it was its own
/// step until 2026-09-16); the Quick Tour and AI Actions setup are offered
/// from Ready as optional links and remain reachable from Help › Quick Tour
/// and Settings › AI Actions, so shortening the flow removed no feature.
/// All screens after Welcome can be skipped; skipping a prerequisite
/// leaves it visible as Skipped on Ready.
public enum OnboardingStage: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    case welcome
    case speechModel
    case microphone
    case accessibility
    /// Recording mode, the recorder, and — once a shortcut is registered —
    /// the press-your-shortcut-now check (Later waves: onboarding hotkey
    /// test). While the check is visible the app shell reports the global
    /// shortcut's edges to the wizard instead of starting a dictation; see
    /// `OnboardingViewModel.beginHotkeyTest()`.
    case shortcut
    /// Readiness list, first dictation test, setup summary, the two
    /// optional links (Quick Tour, AI Actions) and Finish.
    case ready

    public var id: Self { self }

    public var title: String {
        switch self {
        case .welcome: return String(localized: "Welcome", bundle: .module)
        case .speechModel: return String(localized: "Speech Model", bundle: .module)
        case .microphone: return String(localized: "Microphone", bundle: .module)
        case .accessibility: return String(localized: "Accessibility", bundle: .module)
        case .shortcut: return String(localized: "Shortcut", bundle: .module)
        case .ready: return String(localized: "Ready", bundle: .module)
        }
    }

    public var isSkippable: Bool {
        self != .welcome
    }

    /// One sentence under the title saying what the screen is for. The
    /// body copy explains how; this says why the screen exists.
    public var purpose: String {
        switch self {
        case .welcome: return String(localized: "What KVoice does with your voice, and what never leaves this Mac.", bundle: .module)
        case .speechModel: return String(localized: "Speech is transcribed by a local model, so one has to be installed.", bundle: .module)
        case .microphone: return String(localized: "KVoice needs to hear you, and only while you are dictating.", bundle: .module)
        case .accessibility: return String(localized: "Lets KVoice place finished text at your cursor in other apps.", bundle: .module)
        case .shortcut: return String(localized: "Pick the key that starts and stops dictation, then try it.", bundle: .module)
        case .ready: return String(localized: "Check what is set up, try a short dictation, then finish.", bundle: .module)
        }
    }

    /// 1-based position, so the progress label reads "Step 3 of 6".
    public var ordinal: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    public var next: OnboardingStage? {
        guard let index = Self.allCases.firstIndex(of: self),
              index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }
}

/// What the first dictation test produced (FR-ONB-007). The app shell runs
/// the production recorder and transcription path and reports here; the
/// view model only renders the outcome.
public enum DictationTestResult: Equatable, Sendable {
    case transcript(String)
    /// `fixes` names the setup screen that resolves the failure when the
    /// shell knows it (a microphone error → `.microphone`). It defaults to
    /// nil so existing callers compile; the view then falls back to whichever
    /// prerequisite readiness currently reports as not ready.
    case failed(message: String, fixes: OnboardingReadinessItem? = nil)
}

/// The bottom bar every setup screen shares: Back on the left, Skip and the
/// primary action on the right, always in the same places. Derived from view
/// model state so the mapping is testable without a view.
public struct OnboardingActionBar: Equatable, Sendable {
    /// The default button. Its title says what pressing it does.
    public let primaryTitle: String
    public let primaryIsEnabled: Bool
    /// True while the primary's work is in flight (a permission prompt, the
    /// level test); the button is disabled and shows a spinner.
    public let primaryIsBusy: Bool
    /// Shown beside a disabled primary so the user knows what to do first.
    public let primaryDisabledReason: String?
    /// The secondary "continue without this" action, or nil when the screen
    /// has nothing to skip.
    public let skipTitle: String?
    /// What VoiceOver reads for Skip: "Skip this step", or the step's own
    /// phrase where Skip is narrower ("Skip the shortcut check", Q2b).
    public let skipAccessibilityLabel: String?
    public let skipIsEnabled: Bool
    public let canGoBack: Bool

    public init(
        primaryTitle: String,
        primaryIsEnabled: Bool = true,
        primaryIsBusy: Bool = false,
        primaryDisabledReason: String? = nil,
        skipTitle: String? = nil,
        skipAccessibilityLabel: String? = nil,
        skipIsEnabled: Bool = true,
        canGoBack: Bool = true
    ) {
        self.primaryTitle = primaryTitle
        self.primaryIsEnabled = primaryIsEnabled && !primaryIsBusy
        self.primaryIsBusy = primaryIsBusy
        self.primaryDisabledReason = primaryDisabledReason
        self.skipTitle = skipTitle
        self.skipAccessibilityLabel = skipTitle.map { title in
            skipAccessibilityLabel ?? String(localized: "\(title) this step", bundle: .module)
        }
        self.skipIsEnabled = skipIsEnabled
        self.canGoBack = canGoBack
    }
}

/// Model operations are intents only.  The onboarding UI does not own model
/// downloads, validation, or folder selection; the app shell handles these
/// intents and feeds lifecycle updates back through `setModelState(_:)`.
public enum OnboardingModelAction: String, Sendable, Equatable, CaseIterable {
    case download
    case chooseExisting
    case skip
    case cancel
    case retry
}

/// Side-effect requests emitted by onboarding.  They are deliberately small
/// and Sendable so an app coordinator can route them to the owning service.
public enum OnboardingIntent: Sendable, Equatable {
    case downloadModel
    case chooseExistingModel
    case skipModel
    case cancelModelDownload
    case retryModel
    /// 2026-09-29: the model card's "Use … Instead" — make this catalog
    /// entry the default and, when it is not installed, start its install
    /// (one click; the card's note said what that downloads).
    case useSpeechModel(ModelID)
    case requestMicrophonePermission
    case runMicrophoneTest
    case skipMicrophone
    case requestAccessibilityPermission
    case openAccessibilitySettings
    case refreshAccessibilityStatus
    case skipAccessibility
    case recordShortcut
    case setRecordingInteraction(RecordingInteraction)
    case shortcutRecorded(ShortcutDefinition)
    case shortcutRegistrationState(ShortcutRegistrationState)
    case skipShortcut
    /// While active, the shell reports the primary global shortcut's edges to
    /// `OnboardingViewModel.reportHotkeyTestKeyDown()/Up()` instead of
    /// starting a dictation. Emitted only while the shortcut page shows its
    /// Try It indicator (`OnboardingViewModel.hotkeyTestIsAvailable`).
    case beginHotkeyTest
    case endHotkeyTest
    case runDictationTest
    case stopDictationTest
    /// The "Recording keys" box's Cancel (UI v2 fidelity F4): the shell
    /// closes the recorder window without changing the shortcut.
    case cancelShortcutRecording
    case finish
}

/// Why a shortcut could not be registered, as far as the shell can tell
/// (UI v2 fidelity F4). The hotkey adapter's reasons, without its types; the
/// wizard turns them into a localized sentence instead of an error code.
public enum ShortcutRegistrationProblem: Sendable, Equatable {
    /// macOS reserves the combination (Spotlight, input sources, …).
    case takenBySystem
    /// One of KVoice's own menu commands uses it.
    case takenByMenu
    /// A lone modifier key without Accessibility.
    case needsAccessibility
    /// The App Store edition cannot watch a lone modifier key.
    case unavailableInEdition
    /// A dictation was running.
    case busy
    case other

    /// The owner of a system shortcut whose owner is fixed in macOS; nil for
    /// any other combination, which is then called "used by macOS".
    public enum SystemOwner: Sendable, Equatable {
        case spotlight
        case finderSearch
        case inputSources

        var localizedName: String {
            switch self {
            case .spotlight: return String(localized: "Spotlight", bundle: .module)
            case .finderSearch: return String(localized: "Finder search", bundle: .module)
            case .inputSources: return String(localized: "Switching input sources", bundle: .module)
            }
        }
    }

    public static func knownSystemOwner(of shortcut: ShortcutDefinition) -> SystemOwner? {
        guard shortcut.key.lowercased() == "space" || shortcut.key == " " else { return nil }
        let modifiers = Set(shortcut.modifiers.map { $0.lowercased() })
        if modifiers == ["command"] { return .spotlight }
        if modifiers == ["command", "option"] { return .finderSearch }
        if modifiers == ["control"] || modifiers == ["control", "option"] { return .inputSources }
        return nil
    }
}

/// The dictation test's live level for Ready's recording box (Motion
/// § 4·6): a smoothed 0…1 level the shell feeds at the HUD's rate. Its own
/// observable object, so a 20 Hz update re-renders the meter only.
@Observable
@MainActor
public final class OnboardingLiveLevel {
    public private(set) var level: Double = 0
    private var follower = KVLevelFollower()

    public init() {}

    /// One reading (0…1) arriving `elapsed` seconds after the previous one.
    public func apply(raw: Double, elapsed: Double = 0.05) {
        level = follower.step(raw: raw, elapsed: elapsed)
    }

    public func reset() {
        follower = KVLevelFollower()
        level = 0
    }
}

/// Compatibility spelling for clients that call an emitted intent an action.
public typealias OnboardingAction = OnboardingIntent

public enum AccessibilityPermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case unknown

    public var displayName: String {
        switch self {
        case .notDetermined: return String(localized: "Not Requested", bundle: .module)
        case .granted: return String(localized: "Granted", bundle: .module)
        case .denied: return String(localized: "Not Granted", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }
}

public enum OnboardingReadinessStatus: String, Sendable, Equatable, CaseIterable {
    case ready
    case notReady
    case deferred
    case blocked

    public var displayName: String {
        switch self {
        case .ready: return String(localized: "Ready", bundle: .module)
        case .notReady: return String(localized: "Not Ready", bundle: .module)
        case .deferred: return String(localized: "Skipped", bundle: .module)
        case .blocked: return String(localized: "Blocked", bundle: .module)
        }
    }

    public var isReady: Bool {
        self == .ready
    }
}

public enum OnboardingReadinessItem: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    case model
    case microphone
    case accessibility
    case shortcut

    public var id: Self { self }

    public var title: String {
        switch self {
        case .model: return String(localized: "Model", bundle: .module)
        case .microphone: return String(localized: "Microphone", bundle: .module)
        case .accessibility: return String(localized: "Accessibility", bundle: .module)
        case .shortcut: return String(localized: "Shortcut", bundle: .module)
        }
    }

    /// The setup screen that resolves this prerequisite.
    public var stage: OnboardingStage {
        switch self {
        case .model: return .speechModel
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .shortcut: return .shortcut
        }
    }
}

public struct OnboardingReadiness: Sendable, Equatable {
    public let model: OnboardingReadinessStatus
    public let microphone: OnboardingReadinessStatus
    public let accessibility: OnboardingReadinessStatus
    public let shortcut: OnboardingReadinessStatus

    public init(
        model: OnboardingReadinessStatus,
        microphone: OnboardingReadinessStatus,
        accessibility: OnboardingReadinessStatus,
        shortcut: OnboardingReadinessStatus
    ) {
        self.model = model
        self.microphone = microphone
        self.accessibility = accessibility
        self.shortcut = shortcut
    }

    public var isReady: Bool {
        model.isReady && microphone.isReady && accessibility.isReady && shortcut.isReady
    }

    /// The first dictation test needs the recorder, the model, and a way to
    /// start it. Accessibility may stay deferred because the result is shown
    /// in an in-app field, not inserted elsewhere (spec C.2 step 9).
    public var isReadyForDictationTest: Bool {
        model.isReady && microphone.isReady && shortcut.isReady
    }

    /// The first prerequisite the dictation test is still waiting on, in
    /// setup order, or nil when the test can run.
    public var firstItemBlockingDictationTest: OnboardingReadinessItem? {
        [OnboardingReadinessItem.model, .microphone, .shortcut].first { !self[$0].isReady }
    }

    public subscript(_ item: OnboardingReadinessItem) -> OnboardingReadinessStatus {
        switch item {
        case .model: return model
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .shortcut: return shortcut
        }
    }
}

/// Live state for the shortcut page's Try It indicator (Later waves:
/// onboarding hotkey test; its own step until 2026-09-16). Driven only by `OnboardingViewModel.reportHotkeyTestKeyDown()/Up()`
/// and `tickHotkeyTest(now:)`, which the shell and the view call from the
/// onboarding-scoped shortcut hook — never from real dictation.
///
/// Success is one full press/release for push-to-talk and hybrid, or two
/// key-down edges (press to start, press to stop) for toggle, matching
/// `RecordingInteraction`'s real semantics so the test proves what the user
/// will actually feel.
public struct HotkeyTestSnapshot: Sendable, Equatable {
    public var isDown = false
    public var downAt: Date?
    /// Live while held (updated by `tickHotkeyTest`); frozen at release. A
    /// plain `TimeInterval` rather than `Duration` because it is always
    /// derived from a `Date` difference and only ever formatted to one
    /// decimal place.
    public var heldSeconds: TimeInterval?
    /// Count of key-down edges seen. Toggle mode needs two to finish.
    public var pressCount = 0
    public var isDone = false
    /// Motion § 11: the last push-to-talk release came before 0.6 s; the
    /// orb drains and the box asks for a longer hold.
    public var wasTooShort = false

    public init(
        isDown: Bool = false,
        downAt: Date? = nil,
        heldSeconds: TimeInterval? = nil,
        pressCount: Int = 0,
        isDone: Bool = false
    ) {
        self.isDown = isDown
        self.downAt = downAt
        self.heldSeconds = heldSeconds
        self.pressCount = pressCount
        self.isDone = isDone
    }
}

public enum MicrophoneTestState: Sendable, Equatable {
    case notStarted
    case running
    case completed(MicrophoneTestResult)
    case failed(String)
    case skipped

    public var isSuccessful: Bool {
        if case .completed = self { return true }
        return false
    }
}

public extension PermissionAuthorization {
    var displayName: String {
        switch self {
        case .notDetermined: return String(localized: "Not Requested", bundle: .module)
        case .granted: return String(localized: "Granted", bundle: .module)
        case .denied: return String(localized: "Denied", bundle: .module)
        case .restricted: return String(localized: "Restricted", bundle: .module)
        @unknown default: return String(localized: "Unknown", bundle: .module)
        }
    }
}
