import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleIntelligence

/// ADR-027: the Apple client over a scripted Private Cloud Compute runtime —
/// the privacy invariants (Off never reaches the runtime, a static refusal
/// never asks it anything, no transport crossing), the availability and
/// quota facts, the error mapping onto the ordinary fallback codes, the
/// larger context window, the scalar-only diagnostics, and the signing
/// heuristic.
final class PrivateCloudComputeClientTests: XCTestCase {
    private func settings(provider: AIProviderTransport = .privateCloudCompute, mode: DictationMode = .polish) -> AIEndpointSettings {
        var settings = AIEndpointSettings(isEnabled: true, provider: provider)
        settings.seedBuiltInPromptModesIfNeeded()
        settings.mode = mode
        return settings
    }

    private func request(_ transcript: String = "move the review to friday", mode: DictationMode = .polish) -> AIProcessRequest {
        AIProcessRequest(jobID: UUID(), mode: mode, rawTranscript: transcript, modelID: "", targetLanguage: nil, polishPrompt: "Clean up the transcript.")
    }

    private func pcc(
        availability: AIProviderAvailability = .available,
        contextSize: Int? = nil,
        reply: Result<String, AppleIntelligenceRuntimeError> = .success("ok")
    ) -> FakeAppleIntelligenceRuntime {
        FakeAppleIntelligenceRuntime(transport: .privateCloudCompute, availability: availability, contextSize: contextSize, reply: reply)
    }

    private func failure(_ body: () async throws -> some Any) async -> KVoiceError? {
        do {
            _ = try await body()
            return nil
        } catch let error as KVoiceError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    private func scalars(tokenCount: Int? = nil) -> DiagnosticAttributes {
        var attributes = DiagnosticAttributes()
        attributes.endpointClass = .privateCloudCompute
        attributes.tokenCount = tokenCount
        return attributes
    }

    // MARK: Privacy invariants

    func testAnOffRequestNeverReachesTheRuntime() async {
        let runtime = pcc()
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let off = await failure { try await client.process(self.request(mode: .off), settings: self.settings(mode: .off)) }
        XCTAssertEqual(off?.code, .aiConfigurationMissing)
        XCTAssertEqual(runtime.frameworkReads, 0, "AI Off asks Private Cloud Compute nothing")
    }

    func testTheClientServesItsOwnTransportOnly() async {
        let runtime = pcc()
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        XCTAssertEqual(client.transport, .privateCloudCompute)
        XCTAssertNil(client.staticRefusal, "an entitled App Store build has no static refusal")
        XCTAssertEqual(runtime.frameworkReads, 0, "reading the refusal asks the runtime nothing")
        for other in [AIProviderTransport.appleIntelligence, .openAICompatible] {
            let refused = await failure { try await client.process(self.request(), settings: self.settings(provider: other)) }
            XCTAssertEqual(refused?.code, .aiConfigurationMissing, "\(other)")
        }
        XCTAssertTrue(runtime.calls.isEmpty)

        // And the on-device client refuses the Private Cloud Compute transport.
        let onDeviceRuntime = FakeAppleIntelligenceRuntime()
        let onDevice = AppleIntelligenceProcessingClient(runtime: onDeviceRuntime)
        let crossed = await failure { try await onDevice.process(self.request(), settings: self.settings()) }
        XCTAssertEqual(crossed?.code, .aiConfigurationMissing)
        XCTAssertTrue(onDeviceRuntime.calls.isEmpty)
    }

    func testAStaticRefusalNeverAsksTheRuntimeAnything() async {
        for reason in [AIProviderUnavailableReason.notInThisEdition, .buildNotEntitled] {
            let runtime = pcc()
            runtime.set(quota: AIProviderQuota(status: .approachingLimit, canRequestIncrease: true))
            let client = AppleIntelligenceProcessingClient(runtime: runtime, staticRefusal: reason)
            XCTAssertEqual(client.staticRefusal, reason, "readable by the shell without asking the runtime")

            let availability = await client.availability()
            XCTAssertEqual(availability, .unavailable(reason))
            let quota = await client.quota()
            XCTAssertNil(quota)
            let languages = await client.supportedLanguageIdentifiers()
            XCTAssertEqual(languages, [])
            await client.showQuotaIncreaseOptions()

            let processed = await failure { try await client.process(self.request(), settings: self.settings()) }
            XCTAssertEqual(processed?.code, .aiProviderUnavailable)
            XCTAssertEqual(processed?.metadata, scalars())
            let tested = await failure { try await client.testConfiguration(self.settings()) }
            XCTAssertEqual(tested?.code, .aiProviderUnavailable)

            XCTAssertEqual(runtime.frameworkReads, 0, "\(reason): the framework was asked something")
            XCTAssertEqual(runtime.quotaOptionsShown, 0)
        }
    }

    // MARK: Availability and quota

    func testEveryUnavailableReasonFailsWithoutARequest() async {
        for reason in AIProviderUnavailableReason.allCases {
            let runtime = pcc(availability: .unavailable(reason))
            let client = AppleIntelligenceProcessingClient(runtime: runtime)
            let refused = await failure { try await client.process(self.request(), settings: self.settings()) }
            XCTAssertEqual(refused?.code, .aiProviderUnavailable, "\(reason)")
            XCTAssertEqual(refused?.metadata.endpointClass, .privateCloudCompute)
            XCTAssertTrue(runtime.calls.isEmpty, "\(reason)")
        }
    }

    func testTheQuotaAndTheLimitOptionsPassThrough() async {
        let runtime = pcc()
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let none = await client.quota()
        XCTAssertNil(none)
        let limited = AIProviderQuota(status: .limitReached, resetDate: Date(timeIntervalSince1970: 86_400), canRequestIncrease: true)
        runtime.set(quota: limited)
        let observed = await client.quota()
        XCTAssertEqual(observed, limited)
        await client.showQuotaIncreaseOptions()
        XCTAssertEqual(runtime.quotaOptionsShown, 1)
    }

    func testTheOnDeviceRuntimeHasNoQuota() async {
        // The protocol default, which `FoundationModelsRuntime` relies on.
        struct Minimal: AppleIntelligenceRuntime {
            var transport: AIProviderTransport { .appleIntelligence }
            func availability() -> AIProviderAvailability { .available }
            func contextSize() async -> Int? { nil }
            func tokenCount(instructions _: String, prompt _: String) async throws -> Int? { nil }
            func supportedLanguageIdentifiers() async -> [String] { [] }
            func respond(instructions _: String, prompt _: String, maximumResponseTokens _: Int?) async throws -> String { "" }
        }
        XCTAssertNil(Minimal().quota())
        let quota = await AppleIntelligenceProcessingClient(runtime: Minimal()).quota()
        XCTAssertNil(quota)
    }

    // MARK: Requests

    func testASuccessfulRequestReturnsTheReplyWithTheSharedPrompt() async throws {
        let runtime = pcc(reply: .success("  Move the review to Friday.  "))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let result = try await client.process(request(), settings: settings())
        XCTAssertEqual(result.text, "Move the review to Friday.")
        let call = try XCTUnwrap(runtime.calls.first)
        let composed = try AIPromptComposer.compose(request: request(), settings: settings())
        XCTAssertEqual(call.instructions, composed.systemPrompt)
        XCTAssertEqual(call.prompt, composed.userMessage)
    }

    /// The window Apple documents (32K) is assumed when the asynchronous
    /// `contextSize` cannot be read: a transcript that would overflow the
    /// on-device default still fits.
    func testTheLargerWindowIsAssumedWhenTheFrameworkCannotSay() async throws {
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 300)
        let runtime = pcc(contextSize: nil)
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        _ = try await client.process(request(long), settings: settings())
        let budget = try XCTUnwrap(runtime.calls.first?.maximumResponseTokens)
        XCTAssertGreaterThan(budget, AppleIntelligenceContextBudget.defaultContextSize)

        let onDevice = AppleIntelligenceProcessingClient(runtime: FakeAppleIntelligenceRuntime(contextSize: nil))
        let refused = await failure { try await onDevice.process(self.request(long), settings: self.settings(provider: .appleIntelligence)) }
        XCTAssertEqual(refused?.code, .aiInputTooLong)

        XCTAssertEqual(AppleIntelligenceContextBudget.defaultContextSize(for: .privateCloudCompute), 32_768)
        XCTAssertEqual(AppleIntelligenceContextBudget.defaultContextSize(for: .appleIntelligence), 4096)
    }

    func testRuntimeErrorsMapOntoTheOrdinaryFallbackCodesWithScalarsOnly() async {
        let cases: [(AppleIntelligenceRuntimeError, KVoiceErrorCode, Bool)] = [
            (.networkFailure, .aiUnreachable, false),
            (.quotaExhausted, .aiQuotaExhausted, false),
            (.unavailable(.unknown), .aiProviderUnavailable, false),
            (.busy, .aiRateLimited, true),
            (.refused, .aiMalformedResponse, false),
            (.generationFailed, .aiMalformedResponse, false),
        ]
        for (runtimeError, expected, retryable) in cases {
            let runtime = pcc(reply: .failure(runtimeError))
            let client = AppleIntelligenceProcessingClient(runtime: runtime)
            let error = await failure { try await client.process(self.request(), settings: self.settings()) }
            XCTAssertEqual(error?.code, expected, "\(runtimeError)")
            XCTAssertEqual(error?.retryable, retryable, "\(runtimeError)")
            XCTAssertEqual(error?.metadata, scalars(), "\(runtimeError): only the endpoint class travels")
        }
        let overflow = await failure {
            try await AppleIntelligenceProcessingClient(runtime: self.pcc(reply: .failure(.exceededContextWindow)))
                .process(self.request(), settings: self.settings())
        }
        XCTAssertEqual(overflow?.code, .aiInputTooLong)
        XCTAssertEqual(overflow?.metadata.endpointClass, .privateCloudCompute)
        XCTAssertNotNil(overflow?.metadata.tokenCount)
    }

    func testTheConnectionTestRunsOneRequestOnThisTransport() async throws {
        let runtime = pcc(reply: .success(ConnectionTest.marker))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        try await client.testConfiguration(settings())
        XCTAssertEqual(runtime.calls.count, 1)
    }

    // MARK: Signing heuristic

    func testTheSigningHeuristicNeedsTheKeyAndAProfile() {
        XCTAssertEqual(PrivateCloudComputeSigning.entitlementKey, "com.apple.developer.private-cloud-compute")
        XCTAssertTrue(PrivateCloudComputeSigning.isEntitled(entitlementValue: true, hasProvisioningProfile: true))
        XCTAssertTrue(PrivateCloudComputeSigning.isEntitled(entitlementValue: NSNumber(value: true), hasProvisioningProfile: true))
        XCTAssertFalse(PrivateCloudComputeSigning.isEntitled(entitlementValue: true, hasProvisioningProfile: false),
                       "a locally signed bundle may carry the key with nothing granting it")
        XCTAssertFalse(PrivateCloudComputeSigning.isEntitled(entitlementValue: false, hasProvisioningProfile: true))
        XCTAssertFalse(PrivateCloudComputeSigning.isEntitled(entitlementValue: "true", hasProvisioningProfile: true))
        XCTAssertFalse(PrivateCloudComputeSigning.isEntitled(entitlementValue: nil, hasProvisioningProfile: true))
        XCTAssertFalse(PrivateCloudComputeSigning.currentProcessIsEntitled(bundle: Bundle(for: Self.self)),
                       "the test runner is not entitled")
    }
}
