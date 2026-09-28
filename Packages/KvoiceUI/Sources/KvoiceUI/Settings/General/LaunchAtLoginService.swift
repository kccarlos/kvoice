import Foundation
import ServiceManagement

/// The login-item registration state as `SMAppService` reports it.
///
/// Mirrors `SMAppService.Status` one-to-one so the General tab can show the
/// real state (FR-APP-005: "State matches `SMAppService.status`") rather than
/// the last thing the user asked for.
public enum LaunchAtLoginStatus: String, Sendable, Equatable, CaseIterable {
    /// Not registered as a login item.
    case notRegistered
    /// Registered and approved.
    case enabled
    /// Registered, but the user must approve it in System Settings › General ›
    /// Login Items before it takes effect. macOS surfaces this once; the app
    /// must not keep re-registering hoping for a different answer.
    case requiresApproval
    /// The service cannot be found — typically a bundle that is not installed
    /// in a location launchd can start from.
    case notFound
    /// The service is unavailable in this process (tests, previews).
    case unknown

    public var displayName: String {
        switch self {
        case .notRegistered: return String(localized: "Off", bundle: .module)
        case .enabled: return String(localized: "On", bundle: .module)
        case .requiresApproval: return String(localized: "Approval required in System Settings › Login Items", bundle: .module)
        case .notFound: return String(localized: "Unavailable for this app location", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }

    /// What the toggle should show for this status. Registration that is still
    /// awaiting approval counts as "on" from the user's point of view: they
    /// asked for it and the remaining step is theirs to take.
    public var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound, .unknown: return false
        }
    }
}

/// Seam over `SMAppService.mainApp` so the General tab can be unit-tested
/// without touching launchd, and so the view model never imports
/// ServiceManagement itself.
@MainActor
public protocol LaunchAtLoginService {
    func status() -> LaunchAtLoginStatus
    func register() throws
    func unregister() throws
    /// Opens System Settings › General › Login Items. Best-effort; returns
    /// false when the system offers no such route.
    @discardableResult
    func openLoginItemsSettings() -> Bool
}

/// The production adapter over `SMAppService.mainApp`.
public struct SystemLaunchAtLoginService: LaunchAtLoginService {
    public init() {}

    public func status() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    @discardableResult
    public func openLoginItemsSettings() -> Bool {
        SMAppService.openSystemSettingsLoginItems()
        return true
    }
}

/// Default for contexts with no launchd (previews, the standalone view, unit
/// tests that do not care about login items). Reports `.unknown` and refuses
/// to register so nothing pretends to have succeeded.
public struct UnavailableLaunchAtLoginService: LaunchAtLoginService {
    public struct Unavailable: Error, LocalizedError {
        public var errorDescription: String? {
            String(localized: "Launch at Login is unavailable in this session.", bundle: .module)
        }
    }

    public init() {}

    public func status() -> LaunchAtLoginStatus { .unknown }
    public func register() throws { throw Unavailable() }
    public func unregister() throws { throw Unavailable() }
    @discardableResult
    public func openLoginItemsSettings() -> Bool { false }
}
