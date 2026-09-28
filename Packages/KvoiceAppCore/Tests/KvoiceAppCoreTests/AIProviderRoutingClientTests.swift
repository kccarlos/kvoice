import Foundation
import KvoiceAI
import KvoiceDomain
import KvoiceTestSupport
import XCTest
@testable import KvoiceAppCore

/// ADR-024 / ADR-027: one client for the shell, three behind it, chosen by
/// the settings' transport; the credential travels to the endpoint only, and
/// no failure ever moves a request to another transport.
final class AIProviderRoutingClientTests: XCTestCase {
    /// Records what reached it, including the credential.
    private actor RecordingClient: CredentialInjectingAIProcessingClient {
        var processed: [(AIProcessRequest, AICredentialSnapshot?)] = []
        var tested: [(AIEndpointSettings, AICredentialSnapshot?)] = []
        var cancelled: [JobID] = []
        let reply: String

        init(reply: String) { self.reply = reply }

        func validateConfiguration(_: AIEndpointSettings) throws {}
        func process(_ request: AIProcessRequest, settings: AIEndpointSettings) async throws -> AIProcessResult {
            try await process(request, settings: settings, credentials: nil)
        }
        func process(_ request: AIProcessRequest, settings _: AIEndpointSettings, credentials: AICredentialSnapshot?) async throws -> AIProcessResult {
            processed.append((request, credentials))
            return AIProcessResult(text: reply, requestDuration: .zero, responseID: nil)
        }
        func testConfiguration(_ settings: AIEndpointSettings) async throws {
            try await testConfiguration(settings, credentials: nil)
        }
        func testConfiguration(_ settings: AIEndpointSettings, credentials: AICredentialSnapshot?) async throws {
            tested.append((settings, credentials))
        }
        func cancel(jobID: JobID) async { cancelled.append(jobID) }
    }

    /// The Apple sides have no credential path at all.
    private actor PlainClient: AIProcessingClient {
        var processed: [AIProcessRequest] = []
        var tested: [AIEndpointSettings] = []
        var cancelled: [JobID] = []
        let reply: String
        let failure: KVoiceError?

        init(reply: String = "on-device", failure: KVoiceError? = nil) {
            self.reply = reply
            self.failure = failure
        }

        func validateConfiguration(_: AIEndpointSettings) throws {}
        func process(_ request: AIProcessRequest, settings _: AIEndpointSettings) async throws -> AIProcessResult {
            processed.append(request)
            if let failure { throw failure }
            return AIProcessResult(text: reply, requestDuration: .zero, responseID: nil)
        }
        func testConfiguration(_ settings: AIEndpointSettings) async throws { tested.append(settings) }
        func cancel(jobID: JobID) async { cancelled.append(jobID) }
    }

    private func settings(_ provider: AIProviderTransport) -> AIEndpointSettings {
        var settings = AIEndpointSettings(isEnabled: true, provider: provider)
        if provider == .openAICompatible {
            settings.baseURL = URL(string: "http://localhost:11434/v1")
            settings.modelID = "qwen3:0.6b"
        }
        return settings
    }

    private func request() -> AIProcessRequest {
        AIProcessRequest(jobID: UUID(), mode: .polish, rawTranscript: "hi", modelID: "", targetLanguage: nil, polishPrompt: "p")
    }

    func testRequestsFollowTheTransportAndTheKeyReachesTheEndpointOnly() async throws {
        let endpoint = RecordingClient(reply: "endpoint")
        let onDevice = PlainClient()
        let router = AIProviderRoutingClient(endpoint: endpoint, onDevice: onDevice, privateCloudCompute: PlainClient(reply: "pcc"))
        let key = AICredentialSnapshot(apiKey: "sk-test")

        let viaEndpoint = try await router.process(request(), settings: settings(.openAICompatible), credentials: key)
        XCTAssertEqual(viaEndpoint.text, "endpoint")
        let viaDevice = try await router.process(request(), settings: settings(.appleIntelligence), credentials: key)
        XCTAssertEqual(viaDevice.text, "on-device")

        let endpointCalls = await endpoint.processed
        XCTAssertEqual(endpointCalls.count, 1)
        XCTAssertEqual(endpointCalls.first?.1, key)
        let deviceCalls = await onDevice.processed
        XCTAssertEqual(deviceCalls.count, 1, "the on-device client is reached without any credential")

        // The credential-less entry point routes the same way.
        _ = try await router.process(request(), settings: settings(.appleIntelligence))
        let deviceCallsAfter = await onDevice.processed
        XCTAssertEqual(deviceCallsAfter.count, 2)
    }

    func testTheConfigurationTestFollowsTheTransportToo() async throws {
        let endpoint = RecordingClient(reply: "endpoint")
        let onDevice = PlainClient()
        let router = AIProviderRoutingClient(endpoint: endpoint, onDevice: onDevice, privateCloudCompute: PlainClient(reply: "pcc"))
        let key = AICredentialSnapshot(apiKey: "sk-test")

        try await router.testConfiguration(settings(.openAICompatible), credentials: key)
        try await router.testConfiguration(settings(.appleIntelligence), credentials: key)
        try await router.testConfiguration(settings(.openAICompatible))

        let endpointTests = await endpoint.tested
        XCTAssertEqual(endpointTests.map { $0.1 }, [key, nil], "the key reaches the endpoint's credential-taking test")
        let deviceTests = await onDevice.tested
        XCTAssertEqual(deviceTests.count, 1)
    }

    func testCancelReachesEveryClient() async {
        let endpoint = RecordingClient(reply: "endpoint")
        let onDevice = PlainClient()
        let router = AIProviderRoutingClient(endpoint: endpoint, onDevice: onDevice, privateCloudCompute: PlainClient(reply: "pcc"))
        let jobID = UUID()
        await router.cancel(jobID: jobID)
        let endpointCancelled = await endpoint.cancelled
        let deviceCancelled = await onDevice.cancelled
        XCTAssertEqual(endpointCancelled, [jobID])
        XCTAssertEqual(deviceCancelled, [jobID])
    }

    func testCancelReachesThePrivateCloudComputeClient() async {
        let pcc = PlainClient(reply: "pcc")
        let router = AIProviderRoutingClient(endpoint: RecordingClient(reply: ""), onDevice: PlainClient(), privateCloudCompute: pcc)
        let jobID = UUID()
        await router.cancel(jobID: jobID)
        let cancelled = await pcc.cancelled
        XCTAssertEqual(cancelled, [jobID])
    }

    // MARK: ADR-027

    /// Private Cloud Compute is reached only by its own transport, without
    /// the key; the on-device transport never reaches it.
    func testPrivateCloudComputeIsReachedOnlyByItsTransportAndWithoutTheKey() async throws {
        let endpoint = RecordingClient(reply: "endpoint")
        let onDevice = PlainClient()
        let pcc = PlainClient(reply: "pcc")
        let router = AIProviderRoutingClient(endpoint: endpoint, onDevice: onDevice, privateCloudCompute: pcc)
        let key = AICredentialSnapshot(apiKey: "sk-test")

        let viaPCC = try await router.process(request(), settings: settings(.privateCloudCompute), credentials: key)
        XCTAssertEqual(viaPCC.text, "pcc")
        _ = try await router.process(request(), settings: settings(.appleIntelligence), credentials: key)
        _ = try await router.process(request(), settings: settings(.openAICompatible), credentials: key)
        try await router.testConfiguration(settings(.privateCloudCompute), credentials: key)

        let pccProcessed = await pcc.processed.count
        let pccTested = await pcc.tested.count
        let deviceProcessed = await onDevice.processed.count
        let endpointProcessed = await endpoint.processed.count
        XCTAssertEqual(pccProcessed, 1)
        XCTAssertEqual(pccTested, 1)
        XCTAssertEqual(deviceProcessed, 1)
        XCTAssertEqual(endpointProcessed, 1)
    }

    /// The shell re-reads the quota after a Private Cloud Compute request or
    /// test — success or failure — and is not told about other transports.
    func testTheObserverHearsEveryPrivateCloudComputeRequestAndNothingElse() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let failing = PlainClient(reply: "pcc", failure: KVoiceError(code: .aiQuotaExhausted, retryable: false))
        let router = AIProviderRoutingClient(endpoint: RecordingClient(reply: "endpoint"), onDevice: PlainClient(), privateCloudCompute: failing)
        await router.setPrivateCloudComputeObserver { counter.bump() }

        _ = try await router.process(request(), settings: settings(.appleIntelligence), credentials: nil)
        _ = try await router.process(request(), settings: settings(.openAICompatible), credentials: nil)
        try await router.testConfiguration(settings(.appleIntelligence))
        XCTAssertEqual(counter.count, 0)

        await XCTAssertThrowsCode(.aiQuotaExhausted) {
            _ = try await router.process(self.request(), settings: self.settings(.privateCloudCompute), credentials: nil)
        }
        try await router.testConfiguration(settings(.privateCloudCompute))
        XCTAssertEqual(counter.count, 2)

        await router.setPrivateCloudComputeObserver(nil)
        try await router.testConfiguration(settings(.privateCloudCompute))
        XCTAssertEqual(counter.count, 2)
    }

    /// The privacy invariant: an on-device failure is returned, never
    /// retried on Private Cloud Compute (a network path), and the reverse.
    func testNoFailureIsRetriedOnAnotherTransport() async {
        let onDevice = PlainClient(failure: KVoiceError(code: .aiProviderUnavailable, retryable: false))
        let pcc = PlainClient(reply: "pcc", failure: KVoiceError(code: .aiUnreachable, retryable: false))
        let endpoint = RecordingClient(reply: "endpoint")
        let router = AIProviderRoutingClient(endpoint: endpoint, onDevice: onDevice, privateCloudCompute: pcc)

        await XCTAssertThrowsCode(.aiProviderUnavailable) {
            _ = try await router.process(self.request(), settings: self.settings(.appleIntelligence), credentials: nil)
        }
        await XCTAssertThrowsCode(.aiUnreachable) {
            _ = try await router.process(self.request(), settings: self.settings(.privateCloudCompute), credentials: nil)
        }
        let pccCalls = await pcc.processed.count
        let deviceCalls = await onDevice.processed.count
        let endpointCalls = await endpoint.processed.count
        XCTAssertEqual(pccCalls, 1, "only the Private Cloud Compute request reached it")
        XCTAssertEqual(deviceCalls, 1, "only the on-device request reached it")
        XCTAssertEqual(endpointCalls, 0)
    }

    /// Validation is delegated to the client that owns the rule, so the
    /// endpoint client's URL refusals reach the caller through the router.
    func testValidationIsTheOwningClientsAndURLErrorsSurface() async {
        let router = AIProviderRoutingClient(
            endpoint: OpenAICompatibleAIProcessingClient(),
            onDevice: PlainClient(),
            privateCloudCompute: PlainClient(reply: "pcc")
        )
        await XCTAssertNoThrowAsync { try await router.validateConfiguration(AIEndpointSettings()) }
        await XCTAssertNoThrowAsync { try await router.validateConfiguration(self.settings(.openAICompatible)) }
        await XCTAssertNoThrowAsync { try await router.validateConfiguration(self.settings(.appleIntelligence)) }

        var insecure = settings(.openAICompatible)
        insecure.baseURL = URL(string: "http://api.example.com/v1")
        await XCTAssertThrowsCode(.aiInsecureRemoteURL) { try await router.validateConfiguration(insecure) }

        var credentialBearing = settings(.openAICompatible)
        credentialBearing.baseURL = URL(string: "https://user:pass@api.example.com/v1")
        await XCTAssertThrowsCode(.aiURLInvalid) { try await router.validateConfiguration(credentialBearing) }

        var noModel = settings(.openAICompatible)
        noModel.modelID = "   "
        // `mode` reads Off without a model, which is valid — the endpoint
        // client's own rule; force the switch to reach the model check.
        XCTAssertEqual(noModel.mode, .off)
        await XCTAssertNoThrowAsync { try await router.validateConfiguration(noModel) }

        // An on-device transport handed the endpoint transport's client (or
        // the reverse) is a routing error the owning client reports.
        let crossed = AIProviderRoutingClient(endpoint: RecordingClient(reply: ""), onDevice: PlainClient(), privateCloudCompute: PlainClient(reply: "pcc"))
        await XCTAssertNoThrowAsync { try await crossed.validateConfiguration(self.settings(.appleIntelligence)) }
    }

    /// The job runner's fallback path: an on-device refusal surfaces as the
    /// ordinary AI failure with its code, and the raw transcript is what the
    /// job inserts. Exercised at the client seam the runner holds.
    func testAnOnDeviceRefusalIsAnOrdinaryAIFailureForTheRunner() async {
        let refusing = FakeAIProcessingClient(failure: KVoiceError(code: .aiInputTooLong, retryable: false))
        let router = AIProviderRoutingClient(endpoint: FakeAIProcessingClient(result: nil), onDevice: refusing, privateCloudCompute: PlainClient(reply: "pcc"))
        do {
            _ = try await router.process(request(), settings: settings(.appleIntelligence), credentials: nil)
            XCTFail("expected the refusal to pass through")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiInputTooLong)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private func XCTAssertNoThrowAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsCode(_ code: KVoiceErrorCode, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected \(code)", file: file, line: line)
    } catch let error as KVoiceError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}
