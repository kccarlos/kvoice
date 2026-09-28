import Foundation
import KvoiceDomain

/// One `AIProcessingClient` for the shell to hold, routing each call by the
/// settings' transport (ADR-024, ADR-027): `.openAICompatible` to the
/// endpoint client, `.appleIntelligence` to the on-device client,
/// `.privateCloudCompute` to the Private Cloud Compute client. Nothing else
/// in the app learns there are three providers — the job runner, the
/// selection-action runner, the prompt preview and the configuration test
/// all keep calling one client.
///
/// It is a `CredentialInjectingAIProcessingClient` so the runners' existing
/// credential path is unchanged: a key travels to the endpoint client as
/// before, and is *dropped* for both Apple transports, which have nothing
/// to authenticate (rule 2 has nothing to protect there, and no key ever
/// reaches the framework). The AI-Off rule is untouched: a request in Off
/// is refused by whichever client receives it, exactly as before.
///
/// ADR-027: routing is by the stored transport and nothing else. A failure
/// on one transport is returned as that transport's error — the router
/// never retries on another, so the on-device model is never silently
/// swapped for Private Cloud Compute (a network path) or the other way
/// round.
public actor AIProviderRoutingClient: CredentialInjectingAIProcessingClient {
    private let endpoint: any CredentialInjectingAIProcessingClient
    private let onDevice: any AIProcessingClient
    private let privateCloudCompute: any AIProcessingClient
    private var privateCloudComputeObserver: (@Sendable () -> Void)?

    public init(
        endpoint: any CredentialInjectingAIProcessingClient,
        onDevice: any AIProcessingClient,
        privateCloudCompute: any AIProcessingClient
    ) {
        self.endpoint = endpoint
        self.onDevice = onDevice
        self.privateCloudCompute = privateCloudCompute
    }

    /// ADR-027: called after every Private Cloud Compute request or
    /// connection test finishes, success or failure, so the shell can
    /// re-read the quota the request may have spent
    /// (`PrivateCloudComputeQueryPolicy`, trigger `.afterRequest`). Never
    /// called for the other transports.
    public func setPrivateCloudComputeObserver(_ observer: (@Sendable () -> Void)?) {
        privateCloudComputeObserver = observer
    }

    /// The client that owns the rule validates: the endpoint client's URL
    /// rules (`aiURLInvalid`, `aiInsecureRemoteURL`) surface unchanged.
    public func validateConfiguration(_ settings: AIEndpointSettings) async throws {
        switch settings.provider {
        case .openAICompatible:
            try await endpoint.validateConfiguration(settings)
        case .appleIntelligence:
            try await onDevice.validateConfiguration(settings)
        case .privateCloudCompute:
            try await privateCloudCompute.validateConfiguration(settings)
        }
    }

    public func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings
    ) async throws -> AIProcessResult {
        try await process(request, settings: settings, credentials: nil)
    }

    public func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws -> AIProcessResult {
        switch settings.provider {
        case .openAICompatible:
            return try await endpoint.process(request, settings: settings, credentials: credentials)
        case .appleIntelligence:
            return try await onDevice.process(request, settings: settings)
        case .privateCloudCompute:
            defer { privateCloudComputeObserver?() }
            return try await privateCloudCompute.process(request, settings: settings)
        }
    }

    public func testConfiguration(_ settings: AIEndpointSettings) async throws {
        try await testConfiguration(settings, credentials: nil)
    }

    /// The configuration test, with the key for the endpoint transport only.
    public func testConfiguration(
        _ settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws {
        switch settings.provider {
        case .openAICompatible:
            try await endpoint.testConfiguration(settings, credentials: credentials)
        case .appleIntelligence:
            try await onDevice.testConfiguration(settings)
        case .privateCloudCompute:
            defer { privateCloudComputeObserver?() }
            try await privateCloudCompute.testConfiguration(settings)
        }
    }

    /// Every client is told: a job id is unique, so the ones that never saw
    /// it ignore the call.
    public func cancel(jobID: JobID) async {
        await endpoint.cancel(jobID: jobID)
        await onDevice.cancel(jobID: jobID)
        await privateCloudCompute.cancel(jobID: jobID)
    }
}
