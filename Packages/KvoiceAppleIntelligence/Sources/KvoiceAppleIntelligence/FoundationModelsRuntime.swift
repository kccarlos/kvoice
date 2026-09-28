import Foundation
import FoundationModels
import KvoiceDomain

/// The one file in kvoice that speaks to Apple's Foundation Models framework
/// (ADR-024; ADR-027 adds `PrivateCloudComputeRuntime` below it, in the same
/// file, so the rule-1 import count stays one). Everything the framework returns is reduced to a domain value
/// or an `AppleIntelligenceRuntimeError` before it leaves this file, so no
/// `FoundationModels` type crosses a `KvoiceDomain` protocol (rule 1).
///
/// The framework exists from macOS 26; kvoice's deployment target is macOS 15,
/// so every use sits behind `#available(macOS 26, *)` and an older system
/// simply reports `.unavailable(.requiresNewerMacOS)`. The framework is
/// weak-linked for the same reason (see `Package.swift`).
///
/// SDK facts this file relies on (read from the macOS 27.0 SDK's
/// `FoundationModels.swiftinterface`, 2026-09-16):
/// - `SystemLanguageModel.default.availability` is `.available` or
///   `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled |
///   .modelNotReady)`; the reason enum is not frozen.
/// - `SystemLanguageModel.contextSize` (macOS 26.0, back-deployed) returns
///   4,096 before macOS 27 and the model's real window from 27 on — and 0
///   on 27.0 while the model is not ready (observed).
/// - `SystemLanguageModel.tokenCount(for:)` counts a prompt or instructions
///   from macOS 26.4.
/// - `LanguageModelSession(instructions: String?)` and
///   `respond(to: String, options:)` return `Response<String>` whose
///   `content` is the reply. `GenerationOptions(samplingMode: .greedy)` makes
///   the cleanup deterministic.
/// - Errors: `LanguageModelSession.GenerationError` on macOS 26 (deprecated
///   on 27 in favour of `LanguageModelError`, `SystemLanguageModel.Error`
///   and `LanguageModelSession.Error`); both families are mapped.
public struct FoundationModelsRuntime: AppleIntelligenceRuntime {
    public init() {}

    public var transport: AIProviderTransport { .appleIntelligence }

    public func availability() -> AIProviderAvailability {
        guard #available(macOS 26, *) else { return .unavailable(.requiresNewerMacOS) }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                // A reason this build does not know; the honest reading is
                // "not now", and the framework will say why on a newer build.
                return .unavailable(.unknown)
            }
        }
    }

    public func contextSize() -> Int? {
        guard #available(macOS 26, *) else { return nil }
        // Observed on macOS 27.0 (2026-09-16): 0 while the model reports
        // `.modelNotReady`. Anything that is not a real window is "unknown",
        // and the budget then assumes the documented 4,096.
        let size = SystemLanguageModel.default.contextSize
        return size > 0 ? size : nil
    }

    public func tokenCount(instructions: String, prompt: String) async throws -> Int? {
        guard #available(macOS 26.4, *) else { return nil }
        let model = SystemLanguageModel.default
        let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
        let promptTokens = try await model.tokenCount(for: prompt)
        return instructionTokens + promptTokens
    }

    public func supportedLanguageIdentifiers() -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return SystemLanguageModel.default.supportedLanguages
            .map(\.minimalIdentifier)
            .sorted()
    }

    public func respond(instructions: String, prompt: String, maximumResponseTokens: Int?) async throws -> String {
        guard #available(macOS 26, *) else {
            throw AppleIntelligenceRuntimeError.unavailable(.requiresNewerMacOS)
        }
        if case .unavailable(let reason) = availability() {
            throw AppleIntelligenceRuntimeError.unavailable(reason)
        }
        // One session per request: the actions are stateless and a shared
        // transcript would only eat the context window.
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapped(error)
        }
    }

    @available(macOS 26, *)
    fileprivate static func mapped(_ error: any Error) -> AppleIntelligenceRuntimeError {
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded:
                    return .exceededContextWindow
                case .rateLimited:
                    return .busy
                case .guardrailViolation, .refusal:
                    return .refused
                case .unsupportedLanguageOrLocale:
                    return .unsupportedLanguage
                case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide, .timeout:
                    return .generationFailed
                @unknown default:
                    return .generationFailed
                }
            }
            if let error = error as? SystemLanguageModel.Error {
                switch error {
                case .assetsUnavailable:
                    return .unavailable(.modelNotReady)
                @unknown default:
                    return .generationFailed
                }
            }
            if let error = error as? LanguageModelSession.Error {
                switch error {
                case .concurrentRequests:
                    return .busy
                case .transcriptMutationWhileResponding:
                    return .generationFailed
                @unknown default:
                    return .generationFailed
                }
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return .exceededContextWindow
            case .assetsUnavailable:
                return .unavailable(.modelNotReady)
            case .guardrailViolation, .refusal:
                return .refused
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .rateLimited, .concurrentRequests:
                return .busy
            case .unsupportedGuide, .decodingFailure:
                return .generationFailed
            @unknown default:
                return .generationFailed
            }
        }
        return .generationFailed
    }
}

/// ADR-027: Apple's server model on Private Cloud Compute, through the same
/// framework and the same session API as the on-device model
/// (`LanguageModelSession(model: PrivateCloudComputeLanguageModel(), …)`).
///
/// **This is network I/O to Apple.** Nothing here opens a socket itself —
/// the framework does, with the OS's own attestation and relay — but the
/// transcript and the action's instructions leave this Mac. The client and
/// the shell keep it opt-in: it runs only for an active Private Cloud
/// Compute configuration, never while AI is Off, never as a fallback for
/// the on-device model.
///
/// SDK facts this type relies on (macOS 27.0 SDK, `FoundationModels`
/// swiftinterface, read 2026-09-27):
/// - `PrivateCloudComputeLanguageModel` is `@available(macOS 27.0)`, a
///   `final class` conforming to `LanguageModel`, created with `init()`.
/// - `availability` is `@frozen` `.available | .unavailable(UnavailableReason)`;
///   the reason enum is **not** frozen: `.deviceNotEligible`,
///   `.systemNotReady`.
/// - `quotaUsage: QuotaUsage` — `status` (`.belowLimit(BelowLimit{isApproachingLimit})`
///   | `.limitReached`, not frozen), `resetDate: Date?`,
///   `limitIncreaseSuggestion: LimitIncreaseSuggestion?` with `show()`.
/// - `contextSize` and `supportedLanguages` are `async throws` (unlike the
///   system model's); there is no `tokenCount(for:)`.
/// - Errors: `PrivateCloudComputeLanguageModel.Error` — `.networkFailure`,
///   `.quotaLimitReached(QuotaLimitReached{resetDate, limitIncreaseSuggestion})`,
///   `.serviceUnavailable` (not frozen) — beside the shared macOS 27
///   `LanguageModelError` family `FoundationModelsRuntime.mapped` already maps.
public struct PrivateCloudComputeRuntime: AppleIntelligenceRuntime {
    public init() {}

    public var transport: AIProviderTransport { .privateCloudCompute }

    public func availability() -> AIProviderAvailability {
        guard #available(macOS 27, *) else { return .unavailable(.requiresMacOS27) }
        return Self.mapped(PrivateCloudComputeLanguageModel().availability)
    }

    @available(macOS 27, *)
    private static func mapped(_ availability: PrivateCloudComputeLanguageModel.Availability) -> AIProviderAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .systemNotReady:
                return .unavailable(.systemNotReady)
            @unknown default:
                return .unavailable(.unknown)
            }
        }
    }

    public func contextSize() async -> Int? {
        guard #available(macOS 27, *) else { return nil }
        // Asynchronous and throwing on this model; a failure is "unknown"
        // and the budget assumes Apple's documented 32,768.
        guard let size = try? await PrivateCloudComputeLanguageModel().contextSize, size > 0 else { return nil }
        return size
    }

    public func tokenCount(instructions: String, prompt: String) async throws -> Int? {
        guard #available(macOS 27, *) else { return nil }
        // The server model has no counting API; the client estimates.
        return nil
    }

    public func supportedLanguageIdentifiers() async -> [String] {
        guard #available(macOS 27, *) else { return [] }
        guard let languages = try? await PrivateCloudComputeLanguageModel().supportedLanguages else { return [] }
        return languages.map(\.minimalIdentifier).sorted()
    }

    public func quota() -> AIProviderQuota? {
        guard #available(macOS 27, *) else { return nil }
        let usage = PrivateCloudComputeLanguageModel().quotaUsage
        let status: AIProviderQuota.Status
        switch usage.status {
        case .belowLimit(let info):
            status = info.isApproachingLimit ? .approachingLimit : .belowLimit
        case .limitReached:
            status = .limitReached
        @unknown default:
            return nil
        }
        return AIProviderQuota(
            status: status,
            resetDate: usage.resetDate,
            canRequestIncrease: usage.limitIncreaseSuggestion != nil
        )
    }

    @MainActor
    public func showQuotaIncreaseOptions() {
        guard #available(macOS 27, *) else { return }
        PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show()
    }

    public func respond(instructions: String, prompt: String, maximumResponseTokens: Int?) async throws -> String {
        guard #available(macOS 27, *) else {
            throw AppleIntelligenceRuntimeError.unavailable(.requiresMacOS27)
        }
        // One model instance for the check and the session.
        let model = PrivateCloudComputeLanguageModel()
        if case .unavailable(let reason) = Self.mapped(model.availability) {
            throw AppleIntelligenceRuntimeError.unavailable(reason)
        }
        // One session per request, as on-device. Default sampling: whether
        // the server model honours `.greedy` is not documented, and a
        // cleanup does not need determinism badly enough to risk an
        // `unsupportedCapability` refusal (ADR-027, needs-human-test).
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapped(error)
        }
    }

    @available(macOS 27, *)
    private static func mapped(_ error: any Error) -> AppleIntelligenceRuntimeError {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure:
                return .networkFailure
            case .quotaLimitReached:
                return .quotaExhausted
            case .serviceUnavailable:
                return .unavailable(.unknown)
            @unknown default:
                return .generationFailed
            }
        }
        return FoundationModelsRuntime.mapped(error)
    }
}
