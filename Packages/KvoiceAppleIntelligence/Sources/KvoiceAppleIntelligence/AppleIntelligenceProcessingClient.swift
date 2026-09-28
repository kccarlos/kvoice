import Foundation
import KvoiceDomain

/// Actor-backed `AIProcessingClient` over an Apple model: the on-device
/// model (ADR-024) or, with a `PrivateCloudComputeRuntime`, Apple's server
/// model on Private Cloud Compute (ADR-027). One actor, two instances — the
/// runtime decides the transport the client answers to.
///
/// Same contract as the OpenAI-compatible client, minus everything of ours
/// that is network: no base URL, no model id, no credential (it is *not* a
/// `CredentialInjectingAIProcessingClient`, so `SecretSettings` never learns
/// it exists), no `URLSession` anywhere in this package (a test greps; the
/// Private Cloud Compute runtime's network I/O is the framework's own). The
/// prompt is `AIPromptComposer`'s — byte-identical to what the endpoint
/// client sends — with the system prompt as the session's instructions and
/// the transcript envelope as the one prompt. Every failure is a
/// `KVoiceError` with an existing AI code, so the job runner's raw-transcript
/// fallback and the `ai.fallback.used` line need no new path; the two codes
/// this provider adds are `.aiProviderUnavailable` and `.aiInputTooLong`.
///
/// Rule 3: nothing here logs. The only scalars this client hands out are
/// the error code, `endpointClass` (`.onDevice` / `.privateCloudCompute`),
/// and — on `.aiInputTooLong` — the input token count as `tokenCount`.
///
/// ADR-027 privacy invariants this type holds (the router and the shell
/// hold the rest): a request whose mode is Off is refused before the
/// runtime is asked anything; a client whose `staticRefusal` is set (the
/// Developer ID edition, an unentitled build) never asks the runtime
/// anything at all; and a failure is always an error for the ordinary
/// raw-transcript fallback — never a retry on another transport.
public actor AppleIntelligenceProcessingClient: AIProcessingClient {
    /// Maximum UTF-8 bytes accepted for one transcript, matching the
    /// endpoint client's ceiling so the two providers refuse the same input.
    public static let maximumUTF8Bytes = 64 * 1024
    /// Twice the endpoint client's 15 s. Generation itself takes seconds,
    /// but the first request after launch (or after the system unloaded the
    /// model) also pays a cold model load, which the framework does not
    /// expose separately; 30 s covers that on Apple silicon without leaving
    /// a real stall to be waited out (ADR-024).
    public static let defaultRequestTimeout: Duration = .seconds(30)

    private let runtime: any AppleIntelligenceRuntime
    /// ADR-027: the reason the runtime is never asked, when there is one —
    /// readable without touching the framework, which is what the shell
    /// copies while it may not query Private Cloud Compute.
    public nonisolated let staticRefusal: AIProviderUnavailableReason?
    private let requestTimeout: Duration
    private var activeRequests: [JobID: Task<String, Error>] = [:]

    /// The transport this client serves (the runtime's).
    public nonisolated let transport: AIProviderTransport

    /// - Parameter staticRefusal: ADR-027. A reason the runtime must not
    ///   even be asked (`DistributionEdition.privateCloudComputeRefusal`):
    ///   `availability()` reports it, `quota()` is nil, and every request
    ///   fails `.aiProviderUnavailable` without touching the framework.
    public init(
        runtime: any AppleIntelligenceRuntime = FoundationModelsRuntime(),
        staticRefusal: AIProviderUnavailableReason? = nil,
        requestTimeout: Duration = AppleIntelligenceProcessingClient.defaultRequestTimeout
    ) {
        self.runtime = runtime
        self.staticRefusal = staticRefusal
        self.requestTimeout = requestTimeout
        self.transport = runtime.transport
    }

    /// ADR-027: the Private Cloud Compute client the composition root holds.
    public static func privateCloudCompute(
        staticRefusal: AIProviderUnavailableReason?
    ) -> AppleIntelligenceProcessingClient {
        AppleIntelligenceProcessingClient(runtime: PrivateCloudComputeRuntime(), staticRefusal: staticRefusal)
    }

    /// The observed fact the shell copies into
    /// `EnvironmentProfile.appleIntelligenceAvailability` (or
    /// `.privateCloudComputeAvailability`).
    public func availability() -> AIProviderAvailability {
        if let staticRefusal { return .unavailable(staticRefusal) }
        return runtime.availability()
    }

    /// ADR-027: the daily-limit standing, or nil (no quota, unknown, or
    /// refused before the framework is asked).
    public func quota() -> AIProviderQuota? {
        guard staticRefusal == nil else { return nil }
        return runtime.quota()
    }

    /// ADR-027: the system's "raise your limit" UI, when offered.
    public func showQuotaIncreaseOptions() async {
        guard staticRefusal == nil else { return }
        await runtime.showQuotaIncreaseOptions()
    }

    /// The model's reported languages, for the live check and the ADR.
    public func supportedLanguageIdentifiers() async -> [String] {
        guard staticRefusal == nil else { return [] }
        return await runtime.supportedLanguageIdentifiers()
    }

    public func validateConfiguration(_ settings: AIEndpointSettings) throws {
        // Off is a valid configuration for any provider.
        guard settings.mode != .off else { return }
        // Another transport is another client's; reaching this one with it
        // is a routing error.
        guard settings.provider == transport else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
    }

    public func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings
    ) async throws -> AIProcessResult {
        try Task.checkCancellation()
        try validateConfiguration(settings)
        guard request.mode != .off, request.mode == settings.mode else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        guard !request.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false)
        }
        try Self.validateInput(request)

        if case .unavailable = availability() {
            throw KVoiceError(code: .aiProviderUnavailable, retryable: false, metadata: metadata())
        }

        let messages = try AIPromptComposer.compose(request: request, settings: settings)
        let plan = try await contextPlan(messages: messages, transcript: request.rawTranscript)

        let startedAt = ContinuousClock().now
        let timeoutMetadata = metadata()
        let runtime = self.runtime
        let requestTimeout = self.requestTimeout
        let requestTask = Task<String, Error> {
            try await runtime.respond(
                instructions: messages.systemPrompt,
                prompt: messages.userMessage,
                maximumResponseTokens: plan.maximumResponseTokens
            )
        }
        activeRequests[request.jobID] = requestTask
        defer { activeRequests.removeValue(forKey: request.jobID) }

        do {
            let reply: String
            do {
                reply = try await withThrowingTaskGroup(of: String.self) { group -> String in
                    group.addTask {
                        // `Task.value` is not cancellation-aware; the handler
                        // is what lets Escape (the pipeline cancelling its AI
                        // task) reach the generation itself.
                        try await withTaskCancellationHandler {
                            try await requestTask.value
                        } onCancel: {
                            requestTask.cancel()
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: requestTimeout)
                        throw KVoiceError(code: .aiTimeout, retryable: false, metadata: timeoutMetadata)
                    }
                    // `cancelAll` reaches the generation through the handler
                    // above, so the group never waits a stall out.
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch {
                requestTask.cancel()
                throw error
            }
            try Task.checkCancellation()
            let text = try Self.normalizedReply(reply, metadata: metadata())
            return AIProcessResult(
                text: text,
                requestDuration: startedAt.duration(to: ContinuousClock().now),
                responseID: nil
            )
        } catch is CancellationError {
            throw KVoiceError(code: .aiCancelled, retryable: false)
        } catch let error as KVoiceError {
            throw error
        } catch let error as AppleIntelligenceRuntimeError {
            throw Self.mapped(error, inputTokens: plan.inputTokens, transport: transport)
        } catch {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false, metadata: metadata())
        }
    }

    /// "Test Active Configuration" / "Verify & Save": the availability check
    /// and one short round trip with the shared connection-test marker.
    public func testConfiguration(_ settings: AIEndpointSettings) async throws {
        var testSettings = settings
        testSettings.activePromptModeID = nil
        testSettings.mode = .polish
        try validateConfiguration(testSettings)
        if case .unavailable = availability() {
            throw KVoiceError(code: .aiProviderUnavailable, retryable: false, metadata: metadata())
        }
        let request = AIProcessRequest(
            jobID: UUID(),
            mode: .polish,
            rawTranscript: ConnectionTest.marker,
            modelID: "",
            targetLanguage: nil,
            polishPrompt: ConnectionTest.systemPrompt
        )
        let result = try await process(request, settings: testSettings)
        guard ConnectionTest.accepts(result.text) else {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false, metadata: metadata())
        }
    }

    public func cancel(jobID: JobID) async {
        activeRequests[jobID]?.cancel()
    }

    // MARK: Context window

    /// The exact count when the running system can count (macOS 26.4+), the
    /// documented estimate otherwise (always, for Private Cloud Compute);
    /// then the budget rule. A count the framework refuses to give (it
    /// throws) falls back to the estimate too.
    private func contextPlan(messages: AIPromptMessages, transcript: String) async throws -> AppleIntelligenceContextBudget.Plan {
        let exact = try? await runtime.tokenCount(instructions: messages.systemPrompt, prompt: messages.userMessage)
        let inputTokens = exact
            ?? (AppleIntelligenceContextBudget.estimateTokens(in: messages.systemPrompt)
                + AppleIntelligenceContextBudget.estimateTokens(in: messages.userMessage))
        let transcriptTokens = AppleIntelligenceContextBudget.estimateTokens(in: transcript)
        guard let plan = AppleIntelligenceContextBudget.plan(
            inputTokens: inputTokens,
            transcriptTokens: transcriptTokens,
            contextSize: await runtime.contextSize(),
            defaultContextSize: AppleIntelligenceContextBudget.defaultContextSize(for: transport)
        ) else {
            throw KVoiceError(code: .aiInputTooLong, retryable: false, metadata: metadata(tokenCount: inputTokens))
        }
        return plan
    }

    // MARK: Validation and mapping

    private static func validateInput(_ request: AIProcessRequest) throws {
        guard request.rawTranscript.utf8.count <= maximumUTF8Bytes else {
            throw KVoiceError(code: .aiOversizedResponse, retryable: false)
        }
        for block in [request.context.userProfile, request.context.clipboardText, request.context.selectedText] {
            guard (block?.utf8.count ?? 0) <= maximumUTF8Bytes else {
                throw KVoiceError(code: .aiOversizedResponse, retryable: false)
            }
        }
        let prompt = request.polishPrompt
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32 * 1024 else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        if request.mode == .translate {
            guard let language = request.targetLanguage,
                  !language.bcp47.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !language.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
            }
        }
    }

    /// The same acceptance rule as the endpoint client's response parser:
    /// trimmed, canonically composed, non-empty, bounded, no control
    /// characters beyond tab and newlines.
    static func normalizedReply(_ reply: String, metadata: DiagnosticAttributes = onDevice()) throws -> String {
        let normalized = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false, metadata: metadata)
        }
        guard normalized.utf8.count <= maximumUTF8Bytes else {
            throw KVoiceError(code: .aiOversizedResponse, retryable: false, metadata: metadata)
        }
        let hasControlCharacter = normalized.unicodeScalars.contains { scalar in
            let value = scalar.value
            if value == 9 || value == 10 || value == 13 { return false }
            return value <= 31 || (value >= 127 && value <= 159)
        }
        guard !hasControlCharacter else {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false, metadata: metadata)
        }
        return normalized
    }

    static func mapped(
        _ error: AppleIntelligenceRuntimeError,
        inputTokens: Int,
        transport: AIProviderTransport = .appleIntelligence
    ) -> KVoiceError {
        let scalars = attributes(for: transport)
        switch error {
        case .unavailable:
            return KVoiceError(code: .aiProviderUnavailable, retryable: false, metadata: scalars)
        case .exceededContextWindow:
            return KVoiceError(code: .aiInputTooLong, retryable: false, metadata: attributes(for: transport, tokenCount: inputTokens))
        case .refused, .unsupportedLanguage, .generationFailed:
            return KVoiceError(code: .aiMalformedResponse, retryable: false, metadata: scalars)
        case .busy:
            return KVoiceError(code: .aiRateLimited, retryable: true, metadata: scalars)
        case .networkFailure:
            // ADR-027: not retried here and never re-routed on-device; the
            // job inserts the raw transcript like any unreachable endpoint.
            return KVoiceError(code: .aiUnreachable, retryable: false, metadata: scalars)
        case .quotaExhausted:
            return KVoiceError(code: .aiQuotaExhausted, retryable: false, metadata: scalars)
        }
    }

    private func metadata(tokenCount: Int? = nil) -> DiagnosticAttributes {
        Self.attributes(for: transport, tokenCount: tokenCount)
    }

    static func onDevice(tokenCount: Int? = nil) -> DiagnosticAttributes {
        attributes(for: .appleIntelligence, tokenCount: tokenCount)
    }

    private static func attributes(for transport: AIProviderTransport, tokenCount: Int? = nil) -> DiagnosticAttributes {
        var attributes = DiagnosticAttributes()
        attributes.endpointClass = transport.fixedEndpointClass
        attributes.tokenCount = tokenCount
        return attributes
    }
}
