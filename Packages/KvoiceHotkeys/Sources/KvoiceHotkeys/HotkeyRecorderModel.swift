import Combine
import Foundation
import KvoiceDomain

public enum HotkeyRecorderFeedback: Equatable, Sendable {
    case none
    case ready
    case conflict
    case cleared
    case failed
}

public enum HotkeyRegistrationResult: Equatable, Sendable {
    case registered(ShortcutDefinition)
    case cleared
    case rejected(HotkeyAdapterError)
}

/// Pure semantic edge actions consumed by the dictation coordinator.
public enum HotkeySemanticAction: Equatable, Sendable {
    case start
    case stop
    case ignored(HotkeyIgnoreReason)
}

public enum HotkeyIgnoreReason: String, Equatable, Sendable {
    case repeatedKeyDown
    case unmatchedKeyUp
    case toggleKeyUp
    /// Hybrid: the release came within the tap window, so the recording
    /// stays running hands-free.
    case hybridTap
}

/// Converts the adapter's key edges into recording actions.  The physical
/// hold bit is kept here rather than inferred from recording state, so a lost
/// key-up can be reset by the watchdog before the next press.
///
/// Hybrid needs the hold length on release: `heldFor` is how long the key was
/// down. A hold within `TriggerSettings.hybridTapWindow` is a tap.
public struct HotkeyEdgeReducer: Equatable, Sendable {
    public private(set) var isPhysicalKeyDown = false
    /// Whether the current Hybrid press started the recording (its release
    /// decides tap vs hold) or stopped it (its release is inert).
    private var hybridPressStartedRecording = false

    public init() {}

    public mutating func consume(
        _ event: ShortcutEvent,
        mode: RecordingInteraction,
        isRecording: Bool,
        heldFor: Duration = .zero,
        hybridTapWindow: Duration = TriggerSettings.hybridTapWindow
    ) -> HotkeySemanticAction {
        switch event {
        case .keyDown:
            guard !isPhysicalKeyDown else {
                return .ignored(.repeatedKeyDown)
            }
            isPhysicalKeyDown = true

            switch mode {
            case .pushToTalk:
                return .start
            case .toggle:
                return isRecording ? .stop : .start
            case .hybrid:
                hybridPressStartedRecording = !isRecording
                return isRecording ? .stop : .start
            }

        case .keyUp:
            guard isPhysicalKeyDown else {
                return .ignored(.unmatchedKeyUp)
            }
            isPhysicalKeyDown = false

            switch mode {
            case .pushToTalk:
                return .stop
            case .toggle:
                return .ignored(.toggleKeyUp)
            case .hybrid:
                guard hybridPressStartedRecording else {
                    return .ignored(.toggleKeyUp)
                }
                hybridPressStartedRecording = false
                return heldFor <= hybridTapWindow ? .ignored(.hybridTap) : .stop
            }
        }
    }

    /// Used by `KeyStateWatchdog` after it synthesizes the matching release.
    public mutating func reset() {
        isPhysicalKeyDown = false
        hybridPressStartedRecording = false
    }
}

/// Settings-facing model that owns shortcut registration and persistence.
/// Failed changes preserve the last valid shortcut when the backend can restore
/// it; otherwise both the persisted and in-memory shortcut are cleared.
@MainActor
public final class HotkeyRecorderModel: ObservableObject {
    @Published public private(set) var shortcut: ShortcutDefinition?
    @Published public private(set) var registrationState: ShortcutRegistrationState
    @Published public private(set) var feedback: HotkeyRecorderFeedback = .none
    @Published public private(set) var isBusy = false

    /// The app core receives semantic edges here.  No raw NSEvent or key code
    /// crosses the package boundary.
    public var onShortcutEvent: (@MainActor (ShortcutEvent) -> Void)?

    private let service: any GlobalShortcutService
    private let persist: @MainActor (ShortcutDefinition?) -> Void

    public init(
        service: any GlobalShortcutService,
        initialShortcut: ShortcutDefinition? = nil,
        persist: @escaping @MainActor (ShortcutDefinition?) -> Void = { _ in }
    ) {
        self.service = service
        self.shortcut = initialShortcut
        self.persist = persist
        self.registrationState = initialShortcut.map(ShortcutRegistrationState.registered)
            ?? .unregistered
    }

    /// Applies a recorder selection.  Passing `nil` explicitly clears the
    /// shortcut and leaves the app in a safe menu-command-only state.
    @discardableResult
    public func setShortcut(_ candidate: ShortcutDefinition?) -> HotkeyRegistrationResult {
        let previousShortcut = shortcut

        guard !isBusy else {
            feedback = .failed
            return .rejected(.busy)
        }

        guard let candidate else {
            service.unregister()
            shortcut = nil
            registrationState = .unregistered
            feedback = .cleared
            persist(nil)
            return .cleared
        }

        do {
            try service.register(candidate) { [weak self] event in
                self?.onShortcutEvent?(event)
            }
            shortcut = candidate
            registrationState = .registered(candidate)
            feedback = .ready
            persist(candidate)
            return .registered(candidate)
        } catch let error as HotkeyAdapterError {
            restoreStateAfterFailure(previousShortcut: previousShortcut)
            feedback = error == .systemConflict || error == .applicationConflict
                ? .conflict
                : .failed
            return .rejected(error)
        } catch {
            restoreStateAfterFailure(previousShortcut: previousShortcut)
            feedback = .failed
            return .rejected(.registrationFailed)
        }
    }

    public func clearShortcut() {
        _ = setShortcut(nil)
    }

    public func presentRecorder() {
        service.presentRecorder()
    }

    /// Settings can disable shortcut editing while a dictation job is active.
    /// The existing registration remains active until the coordinator reaches
    /// Idle; no deferred or concurrent registration is queued.
    public func setJobActive(_ active: Bool) {
        isBusy = active
    }

    private func restoreStateAfterFailure(previousShortcut: ShortcutDefinition?) {
        if let registered = service.registrationState.registeredShortcut {
            shortcut = registered
            registrationState = .registered(registered)
            return
        }

        shortcut = previousShortcut
        if let previousShortcut {
            // A conforming service should perform this rollback itself.  This
            // second attempt protects simpler test/dry-run backends and makes
            // the model's persistence guarantee explicit.
            do {
                try service.register(previousShortcut) { [weak self] event in
                    self?.onShortcutEvent?(event)
                }
                shortcut = previousShortcut
                registrationState = .registered(previousShortcut)
                return
            } catch {
                service.unregister()
            }
        }

        shortcut = nil
        registrationState = .unregistered
        persist(nil)
    }
}

private extension ShortcutRegistrationState {
    var registeredShortcut: ShortcutDefinition? {
        guard case .registered(let shortcut) = self else { return nil }
        return shortcut
    }
}
