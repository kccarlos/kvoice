import AppKit
@preconcurrency import ApplicationServices
import KvoiceDomain

/// Concrete Accessibility/TCC adapter used by onboarding and insertion
/// recovery.  The prompt flag is passed through only when the user has
/// explicitly selected an Allow action; status refreshes always use a
/// non-prompting check.
public struct SystemAccessibilityPermissionAdapter: AccessibilityPermissionProviding, Sendable {
    private let trustCheck: @Sendable (Bool) -> Bool

    public init() {
        trustCheck = Self.systemTrustCheck(prompt:)
    }

    /// Dependency-injected initializer for deterministic tests.  The test
    /// closure is never invoked by initialization, so constructing this type
    /// cannot trigger a TCC prompt.
    public init(trustCheck: @escaping @Sendable (Bool) -> Bool) {
        self.trustCheck = trustCheck
    }

    public func isTrusted(prompt: Bool) async -> Bool {
        trustCheck(prompt)
    }

    /// Opens the documented System Settings area when the current macOS
    /// release accepts the best-effort deep link.  The caller should retain a
    /// generic System Settings fallback and display the written navigation
    /// path because this URL is not a stable public API.
    @MainActor
    @discardableResult
    public func openSystemSettings() -> Bool {
        guard let url = Self.accessibilitySettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    private static func systemTrustCheck(prompt: Bool) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }
}

/// The App Store edition's permission adapter (ADR-026): the card and the
/// onboarding step called "Accessibility" ask for the PostEvent privilege —
/// the part of Accessibility a sandboxed app can hold, listed in the same
/// System Settings pane. `prompt: true` calls `CGRequestPostEventAccess`,
/// which shows the system's alert once; every refresh is the non-prompting
/// preflight. The settings deep link is the Accessibility pane's.
public struct EventPostingPermissionAdapter: AccessibilityPermissionProviding, Sendable {
    private let access: any EventPostingAccessProviding

    public init(access: any EventPostingAccessProviding = SystemEventPostingAccess()) {
        self.access = access
    }

    public func isTrusted(prompt: Bool) async -> Bool {
        prompt ? access.request() : access.isGranted()
    }
}

/// Naming alias for callers that use the domain's `Providing` terminology.
public typealias SystemAccessibilityPermissionProvider = SystemAccessibilityPermissionAdapter
