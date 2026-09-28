import Foundation
import KvoiceDomain

/// The narrow seam between `AppleIntelligenceProcessingClient` and Apple's
/// Foundation Models framework (ADR-024, ADR-027). `FoundationModelsRuntime`
/// (the on-device model) and `PrivateCloudComputeRuntime` (Apple's server
/// model) are the only implementations that touch the framework — both in
/// the only file in kvoice that imports it (`AppleIntelligenceBoundaryTests`)
/// — so every other test runs the client against a fake. No framework type
/// appears here.
public protocol AppleIntelligenceRuntime: Sendable {
    /// Which transport this runtime serves: `.appleIntelligence` (on this
    /// Mac) or `.privateCloudCompute` (network I/O to Apple). The client
    /// takes its routing check and its diagnostics class from it.
    var transport: AIProviderTransport { get }

    /// The model's `availability` as the domain value. Cheap; the shell
    /// reads it on the slow poll (for Private Cloud Compute only while AI is
    /// on and such a configuration is saved — ADR-027).
    func availability() -> AIProviderAvailability

    /// The model's context window in tokens (`SystemLanguageModel.contextSize`,
    /// 4,096 on macOS 26; `PrivateCloudComputeLanguageModel.contextSize`,
    /// asynchronous, 32,768 per Apple), or nil when the framework is absent
    /// or cannot say.
    func contextSize() async -> Int?

    /// The exact token count of the instructions plus the prompt
    /// (`SystemLanguageModel.tokenCount(for:)`, macOS 26.4+), or nil when the
    /// running system cannot count — the client then falls back to
    /// `AppleIntelligenceContextBudget.estimateTokens`. Private Cloud
    /// Compute has no counting API and always returns nil.
    func tokenCount(instructions: String, prompt: String) async throws -> Int?

    /// The languages the model reports (`supportedLanguages`) as BCP-47
    /// identifiers, sorted; empty when the framework is absent. Read for the
    /// live check and the ADR's fact list, never on the request path.
    func supportedLanguageIdentifiers() async -> [String]

    /// ADR-027: the user's standing against the daily request limit, or nil
    /// for a model without one (the on-device model) or when unknown.
    func quota() -> AIProviderQuota?

    /// ADR-027: presents the system's own "raise your limit" UI (an iCloud+
    /// upgrade) when the framework offers one; does nothing otherwise.
    @MainActor
    func showQuotaIncreaseOptions()

    /// One `LanguageModelSession` per call, one `respond(to:)`, the reply's
    /// text. Throws `AppleIntelligenceRuntimeError` only; honours task
    /// cancellation.
    func respond(instructions: String, prompt: String, maximumResponseTokens: Int?) async throws -> String
}

public extension AppleIntelligenceRuntime {
    /// The on-device model has no quota.
    func quota() -> AIProviderQuota? { nil }

    @MainActor
    func showQuotaIncreaseOptions() {}
}

/// What the framework can tell the client, with every vendor detail already
/// removed (rule 3: nothing here can carry a prompt or a reply, and no
/// framework `debugDescription` is kept).
public enum AppleIntelligenceRuntimeError: Error, Equatable, Sendable {
    /// The model cannot take a request (`availability` at the time of the
    /// call, the framework's assets-unavailable error, or Private Cloud
    /// Compute's `serviceUnavailable`).
    case unavailable(AIProviderUnavailableReason)
    /// The framework refused the prompt for its size
    /// (`exceededContextWindowSize` / `contextSizeExceeded`).
    case exceededContextWindow
    /// The guardrails or the model refused the content.
    case refused
    /// The prompt's language is not one the model supports.
    case unsupportedLanguage
    /// The framework is busy (concurrent requests on one session, or rate
    /// limited).
    case busy
    /// ADR-027: Private Cloud Compute could not be reached
    /// (`PrivateCloudComputeLanguageModel.Error.networkFailure`).
    case networkFailure
    /// ADR-027: the user's daily Private Cloud Compute allotment is used up
    /// (`quotaLimitReached`).
    case quotaExhausted
    /// Any other generation failure.
    case generationFailed
}
