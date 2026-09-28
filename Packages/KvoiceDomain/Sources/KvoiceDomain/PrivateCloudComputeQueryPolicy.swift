import Foundation

/// ADR-027 item 6: when the shell may ask the Private Cloud Compute
/// framework for its availability and quota, as a pure rule.
///
/// The framework is asked only when the user has opted in — AI Actions on
/// and a Private Cloud Compute configuration saved — and then only as much
/// as the moment needs: on app activation the availability (the inactive
/// row's "Set as Active" gate reads it) plus the quota when the engine is
/// the active one; on the one-second slow poll the availability alone and
/// only while the engine is active; after a request or a connection test on
/// this transport both. Whether these reads talk to Apple is undocumented
/// (needs-human-test), so they stay rare. A static refusal (edition,
/// signature) is known without the framework and always wins; a closed gate
/// clears the facts so nothing stale survives turning AI off or deleting
/// the last configuration.
public enum PrivateCloudComputeQueryPolicy {
    public enum Trigger: Sendable, Equatable, CaseIterable {
        case activation
        case slowPoll
        case afterRequest
    }

    public enum Decision: Sendable, Equatable {
        /// The static refusal is the fact; the framework is not asked.
        case staticRefusal(AIProviderUnavailableReason)
        /// The gate is closed: forget both facts, ask nothing.
        case clear
        /// Nothing to do now; keep what was last observed.
        case keep
        /// Ask the framework for the availability, and the quota if set.
        case read(includeQuota: Bool)
    }

    public static func decide(
        trigger: Trigger,
        staticRefusal: AIProviderUnavailableReason?,
        aiEnabled: Bool,
        configurations: [AIConfiguration],
        activeTransport: AIProviderTransport
    ) -> Decision {
        if let staticRefusal { return .staticRefusal(staticRefusal) }
        let hasConfiguration = configurations.contains { $0.kind.transport == .privateCloudCompute }
        guard aiEnabled, hasConfiguration else { return .clear }
        let isActive = activeTransport == .privateCloudCompute
        switch trigger {
        case .activation:
            return .read(includeQuota: isActive)
        case .slowPoll:
            return isActive ? .read(includeQuota: false) : .keep
        case .afterRequest:
            return isActive ? .read(includeQuota: true) : .keep
        }
    }

    /// Convenience over the settings value.
    public static func decide(
        trigger: Trigger,
        staticRefusal: AIProviderUnavailableReason?,
        settings: AIEndpointSettings
    ) -> Decision {
        decide(
            trigger: trigger,
            staticRefusal: staticRefusal,
            aiEnabled: settings.isEnabled,
            configurations: settings.configurations,
            activeTransport: settings.provider
        )
    }
}
