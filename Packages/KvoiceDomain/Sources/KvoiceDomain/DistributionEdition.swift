import Foundation

/// ADR-026: which of the two distributions this process is.
///
/// One codebase ships twice: the **Developer ID** edition (the notarized
/// DMG, unsandboxed, ADR-009) and the **App Store** edition (sandboxed; a
/// sandboxed app cannot drive another app through Accessibility). The value
/// is decided once, by the composition root, from the bundle's
/// `KvoiceDistributionEdition` Info.plist key (set by the build
/// configuration), and then *injected*: the packages ask the capability
/// properties below, never `#if`, so both editions' behaviour is testable
/// from one test run.
public enum DistributionEdition: String, Codable, Sendable, CaseIterable {
    case developerID
    case appStore

    /// The Info.plist key the build configuration fills.
    public static let infoDictionaryKey = "KvoiceDistributionEdition"

    /// The edition an Info.plist declares. A missing, unexpanded or unknown
    /// value is the Developer ID edition: that is what every build before
    /// ADR-026 was, and it is the edition whose behaviour is unchanged.
    public init(infoDictionary: [String: Any]?) {
        guard let raw = infoDictionary?[Self.infoDictionaryKey] as? String,
              let edition = DistributionEdition(rawValue: raw)
        else {
            self = .developerID
            return
        }
        self = edition
    }

    /// The edition this process must behave as: the App Store edition
    /// whenever the process actually runs sandboxed
    /// (`APP_SANDBOX_CONTAINER_ID` is set), whatever the bundle declares —
    /// a sandboxed process cannot do what the Developer ID edition does, so
    /// the sandbox wins; otherwise the declaration. A mismatch is still
    /// logged (`launchDiagnostic(infoDictionary:environment:)`).
    public init(infoDictionary: [String: Any]?, environment: [String: String]) {
        if environment[Self.sandboxEnvironmentKey] != nil {
            self = .appStore
        } else {
            self.init(infoDictionary: infoDictionary)
        }
    }

    /// The App Sandbox is on.
    public var isSandboxed: Bool {
        self == .appStore
    }

    /// Insertion may resolve and write the focused element of another app
    /// through `AXUIElement` (FR-AX-001 tiers 1 and 2), and read its
    /// selection. Not in the sandbox: "a sandboxed app cannot control
    /// another app" (ADR-009).
    public var canControlOtherAppsThroughAccessibility: Bool {
        self == .developerID
    }

    /// Where insertion starts. The App Store edition types (the ADR-016
    /// tier, promoted to the only tier) under the PostEvent privilege.
    public var insertionStrategy: InsertionStrategy {
        switch self {
        case .developerID: return .accessibilityThenTyped
        case .appStore: return .typedOnly
        }
    }

    /// The Selection Action and the "selected text" AI context read another
    /// app's selection through Accessibility.
    public var canReadSelectionInOtherApps: Bool {
        canControlOtherAppsThroughAccessibility
    }

    /// `NSEvent` global monitors (a modifier-only shortcut, the middle mouse
    /// trigger, Escape and the in-recording AI controls while another app is
    /// frontmost) deliver only to an Accessibility-trusted process, which a
    /// sandboxed app cannot be. A listen-only event tap under Input
    /// Monitoring is the sandbox-compatible replacement — not built yet
    /// (KNOWN_ISSUES "Mac App Store edition").
    public var hasGlobalInputMonitors: Bool {
        self == .developerID
    }

    /// The one-time copy of the pre-2026-09-27 `com.kccarlos.kvoice`
    /// defaults domain. A sandboxed process reads only its container's
    /// preferences, and the privacy manifest's CA92.1 forbids reading
    /// another identifier's domain; existing users are not migrated into
    /// the container.
    public var migratesLegacyDefaultsDomain: Bool {
        self == .developerID
    }

    /// ADR-027: Apple offers Private Cloud Compute to eligible developers'
    /// "apps distributed on the App Store" (tested through TestFlight or ad
    /// hoc distribution); Developer ID distribution is not named, so that
    /// edition reports the engine unavailable and never touches it.
    public var offersPrivateCloudCompute: Bool {
        self == .appStore
    }

    /// ADR-027: the refusal that holds before the framework is asked
    /// anything — the edition first, then the signature — or nil when the
    /// running build may try. `isEntitled` is the shell's reading of its
    /// own signature (the managed entitlement plus an embedded provisioning
    /// profile); an OS too old is the adapter's to say.
    public func privateCloudComputeRefusal(isEntitled: Bool) -> AIProviderUnavailableReason? {
        guard offersPrivateCloudCompute else { return .notInThisEdition }
        guard isEntitled else { return .buildNotEntitled }
        return nil
    }
}

public extension DistributionEdition {
    /// The environment variable the App Sandbox sets in every sandboxed
    /// process.
    static let sandboxEnvironmentKey = "APP_SANDBOX_CONTAINER_ID"

    /// The launch line (`app.edition`): the edition in effect
    /// (`init(infoDictionary:environment:)`) and whether the process
    /// actually runs sandboxed. A mismatch between the bundle's declaration
    /// and the sandbox — `appStore` without the sandbox entitlement, or a
    /// sandboxed bundle declaring `developerID` — is a warning.
    static func launchDiagnostic(infoDictionary: [String: Any]?, environment: [String: String]) -> DiagnosticEvent {
        let declared = DistributionEdition(infoDictionary: infoDictionary)
        let effective = DistributionEdition(infoDictionary: infoDictionary, environment: environment)
        let runsSandboxed = environment[sandboxEnvironmentKey] != nil
        return DiagnosticEvent(
            name: .appEdition,
            result: runsSandboxed == declared.isSandboxed ? .success : .warning,
            attributes: DiagnosticAttributes(
                reason: effective.rawValue,
                site: runsSandboxed ? "sandboxed" : "unsandboxed"
            )
        )
    }
}

/// How the finished text reaches the focused app (ADR-016, ADR-026).
public enum InsertionStrategy: String, Sendable, Equatable {
    /// The Developer ID edition: `AXSelectedText`, the TextEdit value splice,
    /// then typed Unicode events for an allow-listed read-only text role;
    /// the clipboard only when every tier is unavailable.
    case accessibilityThenTyped
    /// The App Store edition: typed Unicode events addressed to the target
    /// process after the frontmost-application check; the clipboard only
    /// when typing is unavailable (no PostEvent grant, target changed,
    /// secure input on, typing switched off).
    case typedOnly
}
