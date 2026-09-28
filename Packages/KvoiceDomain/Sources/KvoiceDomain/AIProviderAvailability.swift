import Foundation

/// How an AI request leaves the app (ADR-024).
///
/// `AIEndpointSettings.provider` carries this so the request path — the
/// routing client, validation, the job's settings snapshot — reads one scalar
/// instead of learning about configurations. Every `AIProviderKind` maps to
/// exactly one transport (`AIProviderKind.transport`).
public enum AIProviderTransport: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Chat Completions over HTTP(S) to the configured base URL — every
    /// endpoint preset and `custom`.
    case openAICompatible
    /// Apple's Foundation Models framework on this Mac. No base URL, no
    /// model id, no key, and no network I/O in either AI-On or AI-Off.
    case appleIntelligence
    /// ADR-027: Apple's server model on Private Cloud Compute, through the
    /// same framework. No base URL, model id or key either — but it **is**
    /// network I/O to Apple, so it is a transport of its own: never chosen
    /// implicitly, never a fallback for the on-device model, and never
    /// reached while AI is Off.
    case privateCloudCompute

    /// The transport sends a request to a URL the user configured and
    /// therefore needs the endpoint fields (base URL, model id). The two
    /// Apple transports need neither.
    public var needsEndpointFields: Bool {
        self == .openAICompatible
    }

    /// The request leaves this Mac. True for an endpoint (even a loopback
    /// Ollama is a socket) and for Private Cloud Compute; false only for the
    /// on-device model.
    public var leavesThisMac: Bool {
        self != .appleIntelligence
    }

    /// The diagnostics scalar a failure on this transport carries when the
    /// client knows no finer class (the endpoint client classifies its URL
    /// itself: loopback / remoteHTTPS).
    public var fixedEndpointClass: EndpointClass? {
        switch self {
        case .openAICompatible: return nil
        case .appleIntelligence: return .onDevice
        case .privateCloudCompute: return .privateCloudCompute
        }
    }
}

/// Whether an on-device provider can take a request right now (ADR-024).
///
/// An observed fact, not a setting: the shell reads it from the adapter
/// (`SystemLanguageModel.default.availability` behind the
/// `KvoiceAppleIntelligence` boundary) into
/// `EnvironmentProfile.appleIntelligenceAvailability`, and the availability
/// projection turns it into the configuration row's subtitle and the
/// "Set as Active" gate. The reasons are the framework's three plus the one
/// this build adds for a Mac older than macOS 26, where the framework does
/// not exist. ADR-027 reuses the type for Private Cloud Compute
/// (`EnvironmentProfile.privateCloudComputeAvailability`) with the reasons
/// that model adds.
public enum AIProviderAvailability: Sendable, Equatable, Hashable {
    case available
    case unavailable(AIProviderUnavailableReason)

    public var isAvailable: Bool {
        self == .available
    }

    /// The reason's user-facing sentence, or nil when available.
    public var unavailableMessage: String? {
        if case .unavailable(let reason) = self { return reason.message }
        return nil
    }
}

/// Why an Apple model (on-device, ADR-024, or Private Cloud Compute,
/// ADR-027) cannot take a request. Each `message` is the
/// English sentence the UI shows (a `DomainCopy` key — the translation is in
/// `DomainCopy.xcstrings`, and `DomainCopyTests` checks it is there).
public enum AIProviderUnavailableReason: String, Sendable, Equatable, Hashable, CaseIterable {
    /// The hardware cannot run the model (`.deviceNotEligible`).
    case deviceNotEligible
    /// The user has not turned Apple Intelligence on in System Settings
    /// (`.appleIntelligenceNotEnabled`).
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is on but the model assets are still arriving
    /// (`.modelNotReady`).
    case modelNotReady
    /// This build runs on a macOS older than 26; the framework is absent.
    case requiresNewerMacOS
    /// The framework gave a reason this build does not know (its reason
    /// enum is not frozen); a newer build will name it.
    case unknown
    /// ADR-027: Private Cloud Compute exists from macOS 27.
    case requiresMacOS27
    /// ADR-027: `PrivateCloudComputeLanguageModel.Availability
    /// .UnavailableReason.systemNotReady` — "The system is not yet ready to
    /// serve PCC requests."
    case systemNotReady
    /// ADR-027: Apple offers Private Cloud Compute to apps distributed on
    /// the App Store (and their TestFlight / ad hoc test builds); the
    /// Developer ID edition is not one of them.
    case notInThisEdition
    /// ADR-027: this bundle is not signed with the managed
    /// `com.apple.developer.private-cloud-compute` entitlement and a
    /// provisioning profile that grants it (every local build).
    case buildNotEntitled

    public var message: String {
        switch self {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings."
        case .modelNotReady:
            return "The model is still downloading."
        case .requiresNewerMacOS:
            return "Requires macOS 26 or later."
        case .unknown:
            return "Apple Intelligence isn't available right now."
        case .requiresMacOS27:
            return "Private Cloud Compute requires macOS 27 or later."
        case .systemNotReady:
            return "Private Cloud Compute isn't ready yet. Try again in a moment."
        case .notInThisEdition:
            return "Private Cloud Compute is available only in the Mac App Store edition of KVoice."
        case .buildNotEntitled:
            return "This build of KVoice isn't signed for Private Cloud Compute."
        }
    }
}

/// ADR-027: where the user stands against Private Cloud Compute's per-user
/// daily request limit (`PrivateCloudComputeLanguageModel.quotaUsage`),
/// with every framework type removed. Apple: "Quotas are orthogonal to a
/// model's availability — a model can be available even after its usage
/// limit has been reached", so this is a second fact beside the
/// availability, never folded into it.
public struct AIProviderQuota: Sendable, Equatable, Hashable {
    public enum Status: String, Sendable, Equatable, Hashable, CaseIterable {
        case belowLimit
        /// `.belowLimit(info)` with `info.isApproachingLimit`.
        case approachingLimit
        case limitReached
    }

    public var status: Status
    /// When the allotment refreshes; Apple leaves it empty "when the reset
    /// date isn't known or when the person is well below their limit".
    public var resetDate: Date?
    /// The framework offers system UI to raise the limit (an iCloud+
    /// upgrade): `limitIncreaseSuggestion` is non-nil.
    public var canRequestIncrease: Bool

    public init(status: Status, resetDate: Date? = nil, canRequestIncrease: Bool = false) {
        self.status = status
        self.resetDate = resetDate
        self.canRequestIncrease = canRequestIncrease
    }

    /// The English line the configuration row and the sheet show, or nil
    /// when there is nothing worth saying (well below the limit). A
    /// `DomainCopy` key.
    public var message: String? {
        switch status {
        case .belowLimit: return nil
        case .approachingLimit: return Self.approachingLimitMessage
        case .limitReached: return Self.limitReachedMessage
        }
    }

    public static let approachingLimitMessage = "Nearing today's Private Cloud Compute limit."
    public static let limitReachedMessage = "Today's Private Cloud Compute limit is reached. AI actions insert the plain transcript until it resets."
}
