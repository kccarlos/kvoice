import Foundation
import KvoiceDomain

/// The two permissions kvoice asks for (FR-PERM-001).
public enum PermissionKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case microphone
    case accessibility

    public var id: Self { self }

    public var title: String {
        switch self {
        case .microphone: return String(localized: "Microphone", bundle: .module)
        case .accessibility: return String(localized: "Accessibility", bundle: .module)
        }
    }

    /// Why kvoice needs it, in one sentence (spec D.9).
    public var rationale: String {
        switch self {
        case .microphone:
            return String(localized: "Captures your speech only while you hold or toggle the shortcut. Audio is transcribed on this Mac and never uploaded.", bundle: .module)
        case .accessibility:
            return String(localized: "Writes the finished text at the cursor of the app you are dictating into. KVoice does not read documents or watch keystrokes.", bundle: .module)
        }
    }

    /// ADR-026: the App Store edition asks for the part of Accessibility a
    /// sandboxed app can hold — posting keystrokes — and says so; System
    /// Settings still lists it under Accessibility.
    public func rationale(for edition: DistributionEdition) -> String {
        switch (self, edition) {
        case (.accessibility, .appStore):
            return String(localized: "Lets KVoice type the finished text into the app you are dictating into. macOS lists this under Accessibility; this edition only sends keystrokes and cannot read other apps' text.", bundle: .module)
        default:
            return rationale
        }
    }

    /// The written System Settings path, shown next to the deep link because
    /// the `x-apple.systempreferences:` URL is undocumented and may break
    /// (FR-PERM-004).
    public var systemSettingsPath: String {
        switch self {
        case .microphone: return String(localized: "System Settings › Privacy & Security › Microphone", bundle: .module)
        case .accessibility: return String(localized: "System Settings › Privacy & Security › Accessibility", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "accessibility"
        }
    }
}

/// The five states a permission card may show (spec D.9). There is no sixth;
/// anything the OS reports that does not map onto one of these is `unknown`.
public enum PermissionCardState: String, Sendable, Equatable, CaseIterable {
    case notRequested
    case granted
    case denied
    case restricted
    case unknown

    public var displayName: String {
        switch self {
        case .notRequested: return String(localized: "Not Requested", bundle: .module)
        case .granted: return String(localized: "Granted", bundle: .module)
        case .denied: return String(localized: "Denied", bundle: .module)
        case .restricted: return String(localized: "Restricted", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }

    public init(_ authorization: PermissionAuthorization) {
        switch authorization {
        case .notDetermined: self = .notRequested
        case .granted: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    public init(_ status: AccessibilityPermissionStatus) {
        switch status {
        case .notDetermined: self = .notRequested
        case .granted: self = .granted
        case .denied: self = .denied
        case .unknown: self = .unknown
        }
    }
}

/// The one action a card offers for its current state (spec D.9: "one
/// relevant action").
public enum PermissionCardAction: String, Sendable, Equatable {
    /// Ask macOS for the permission. Only shown before the first request.
    case request
    /// Open System Settings at the permission pane. Shown once the OS has
    /// answered No, because asking again would not show a prompt.
    case openSystemSettings
    /// Read the state again. Shown when there is nothing else to do.
    case refresh

    public var title: String {
        switch self {
        case .request: return String(localized: "Request Access", bundle: .module)
        case .openSystemSettings: return String(localized: "Open System Settings", bundle: .module)
        case .refresh: return String(localized: "Refresh Status", bundle: .module)
        }
    }
}

/// One permission card: what the OS said, when it said it, and what to offer.
///
/// `state` is the raw last reading. `presentedState(now:)` is what a view must
/// show, and it downgrades a stale Granted to Unknown so a green badge can
/// never come from a cached value the user may have revoked since (D.9).
public struct PermissionCard: Sendable, Equatable {
    /// A Granted reading older than this is not shown as Granted. One second
    /// matches the FR-PERM-005 polling interval with a little slack for a
    /// paused poll.
    public static let staleAfter: TimeInterval = 3

    public let kind: PermissionKind
    public let state: PermissionCardState
    public let lastChecked: Date?
    /// ADR-026: decides the rationale sentence.
    public let edition: DistributionEdition

    public init(kind: PermissionKind, state: PermissionCardState, lastChecked: Date?, edition: DistributionEdition = .developerID) {
        self.kind = kind
        self.state = state
        self.lastChecked = lastChecked
        self.edition = edition
    }

    /// The one-sentence reason shown on the card, for this edition.
    public var rationale: String {
        kind.rationale(for: edition)
    }

    /// A card that has never been read.
    public static func unchecked(_ kind: PermissionKind) -> PermissionCard {
        PermissionCard(kind: kind, state: .unknown, lastChecked: nil)
    }

    /// The state a view is allowed to show at `now`.
    public func presentedState(now: Date = Date(), staleAfter: TimeInterval = PermissionCard.staleAfter) -> PermissionCardState {
        guard state == .granted else { return state }
        guard let lastChecked, now.timeIntervalSince(lastChecked) <= staleAfter else {
            return .unknown
        }
        return .granted
    }

    public func isStale(now: Date = Date(), staleAfter: TimeInterval = PermissionCard.staleAfter) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) > staleAfter
    }

    /// The single action offered for the presented state.
    public func action(now: Date = Date()) -> PermissionCardAction {
        switch presentedState(now: now) {
        case .notRequested: return .request
        case .denied, .restricted: return .openSystemSettings
        case .granted, .unknown: return .refresh
        }
    }

    /// True when the card should carry the written System Settings path. That
    /// is whenever the deep link is the offered action, so a broken link still
    /// leaves actionable instructions (FR-PERM-004).
    public func showsSystemSettingsPath(now: Date = Date()) -> Bool {
        action(now: now) == .openSystemSettings
    }
}
