import Foundation
import KvoiceDomain

/// The Keyboard Shortcut card on the Permissions section: the same shape as
/// the two permission cards (why, status, last checked, one action) for the
/// prerequisite that is not a TCC permission but blocks dictation just the
/// same. State is derived, not stored, so it can be tested without a view.
public struct ShortcutCard: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// No shortcut confirmed; the recommended one can be confirmed in one press.
        case notConfigured
        /// Confirmed and registered with macOS; the readout names it.
        case registered
        /// Confirmed but not (yet) registered — normally a transient state
        /// while a settings change is applied.
        case notRegistered
        /// macOS refused the registration (a conflict or a missing entitlement).
        case unavailable

        public var displayName: String {
            switch self {
            case .notConfigured: return String(localized: "Not Configured", bundle: .module)
            case .registered: return String(localized: "Registered", bundle: .module)
            case .notRegistered: return String(localized: "Not Registered", bundle: .module)
            case .unavailable: return String(localized: "Unavailable", bundle: .module)
            }
        }
    }

    /// The single action offered for the status.
    public enum Action: Sendable, Equatable {
        case confirmRecommended
        case chooseAnother

        public var title: String {
            switch self {
            case .confirmRecommended: return String(localized: "Use Recommended Shortcut", bundle: .module)
            case .chooseAnother: return String(localized: "Choose Another Shortcut…", bundle: .module)
            }
        }
    }

    public static let title = String(localized: "Keyboard Shortcut", bundle: .module)
    public static let symbolName = "keyboard"
    public static let rationale = String(localized: "The global key that starts and stops dictation. KVoice listens for this one key and nothing else.", bundle: .module)

    public let status: Status
    /// The human-readable key readout, or nil when nothing is confirmed.
    public let readout: String?
    /// The registration failure, when `status` is `.unavailable`.
    public let failureDescription: String?
    public let lastChecked: Date?

    public init(
        confirmed: ShortcutDefinition?,
        registration: ShortcutRegistrationState,
        lastChecked: Date?
    ) {
        readout = confirmed.map(GeneralSettingsViewModel.displayName(for:))
        self.lastChecked = lastChecked
        guard confirmed != nil else {
            status = .notConfigured
            failureDescription = nil
            return
        }
        switch registration {
        case .registered:
            status = .registered
            failureDescription = nil
        case .unregistered:
            status = .notRegistered
            failureDescription = nil
        case .failed(let code):
            status = .unavailable
            failureDescription = "macOS did not accept the shortcut (\(code.rawValue)). Choose another one."
        }
    }

    public var action: Action {
        status == .notConfigured ? .confirmRecommended : .chooseAnother
    }
}
