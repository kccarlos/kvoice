import Foundation
import KvoiceDomain

/// ADR-022 slice 5: every write to `LocalState`, one case each, mirroring
/// `SettingsIntent` for the machine-local blob. The cases moved here from
/// `SettingsIntent` when the fields moved from `AppSettings` to
/// `LocalState`; their gating (loaded, never idle-gated — none affects a
/// running job) and their no-op rules are unchanged, in
/// `LocalStateReducer`.
///
/// Adding a local fact: a field on `LocalState`, a case here, a row in
/// `LocalStateReducer.reduce`, a row in `LocalStateReducerTests`.
public enum LocalStateIntent: Equatable, Sendable {
    /// The main window's sidebar selection (`MainWindowSection.rawValue`).
    case setMainWindowSection(String, origin: SettingsOrigin)
    /// The one-time tutorial offer has been made (opened, or "Not now").
    case markTutorialSeen(origin: SettingsOrigin)
    /// The wizard's Finish: completion version plus `tutorialSeen`.
    case completeOnboarding(version: Int, origin: SettingsOrigin)
    /// FR-ONB-010: clears completion so the wizard replays.
    case resetOnboarding(origin: SettingsOrigin)
    /// Data & Privacy: the Auto Daily Export folder this Mac granted; nil
    /// clears it (the toggle is `SettingsIntent.setDataPrivacy`'s).
    case setExportFolder(ExportFolderGrant?, origin: SettingsOrigin)

    public var origin: SettingsOrigin {
        switch self {
        case .setMainWindowSection(_, let origin), .markTutorialSeen(let origin),
             .completeOnboarding(_, let origin), .resetOnboarding(let origin),
             .setExportFolder(_, let origin):
            return origin
        }
    }

    /// A scalar name for diagnostics.
    public var name: String {
        switch self {
        case .setMainWindowSection: return "setMainWindowSection"
        case .markTutorialSeen: return "markTutorialSeen"
        case .completeOnboarding: return "completeOnboarding"
        case .resetOnboarding: return "resetOnboarding"
        case .setExportFolder: return "setExportFolder"
        }
    }
}

/// The pure decision behind every `LocalState` write. Same shape as
/// `SettingsReducer`: no I/O, a typed refusal leaves the state untouched with
/// no effect. Every accepted, changing intent produces exactly
/// `[.persistLocalState]`; an unchanged value is a no-op with no effect.
///
/// | Intent | Gate | Effects |
/// | --- | --- | --- |
/// | setMainWindowSection | loaded, no-op if unchanged | persistLocalState |
/// | markTutorialSeen | loaded, no-op if seen | persistLocalState |
/// | completeOnboarding | loaded (also sets tutorialSeen) | persistLocalState |
/// | resetOnboarding | loaded | persistLocalState |
/// | setExportFolder | loaded, no-op if unchanged | persistLocalState |
///
/// "loaded" means `settingsLoaded && !terminationInProgress`. Nothing here
/// is idle-gated: no local fact travels in a job's settings snapshot.
public enum LocalStateReducer {
    public struct Result: Equatable, Sendable {
        public var state: LocalState
        public var effects: [SettingsEffect]
        public var refusal: SettingsRefusal?

        public init(state: LocalState, effects: [SettingsEffect] = [], refusal: SettingsRefusal? = nil) {
            self.state = state
            self.effects = effects
            self.refusal = refusal
        }
    }

    public static func reduce(state: LocalState, intent: LocalStateIntent, gate: SettingsGate) -> Result {
        if !gate.settingsLoaded {
            return Result(state: state, refusal: SettingsRefusal(intent: intent.name, reason: .notLoaded))
        }
        if gate.terminationInProgress {
            return Result(state: state, refusal: SettingsRefusal(intent: intent.name, reason: .terminating))
        }

        var next = state
        switch intent {
        case .setMainWindowSection(let section, _):
            guard section != state.mainWindowSection else { return Result(state: state) }
            next.mainWindowSection = section

        case .markTutorialSeen:
            guard !state.tutorialSeen else { return Result(state: state) }
            next.tutorialSeen = true

        case .completeOnboarding(let version, _):
            next.onboardingVersionCompleted = version
            // The wizard's own `.tutorial` stage just ran (or was skipped),
            // so the standalone tour and the banner have nothing to offer.
            next.tutorialSeen = true

        case .resetOnboarding:
            next.onboardingVersionCompleted = nil

        case .setExportFolder(let grant, _):
            guard grant != state.exportFolder else { return Result(state: state) }
            next.exportFolder = grant
        }
        return Result(state: next, effects: [.persistLocalState])
    }
}
