import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleIntelligence

/// The on-device client against a scripted runtime (ADR-024): routing
/// refusals, availability mapping, the shared prompt, the context-window
/// budget, error mapping onto the existing fallback codes, cancellation,
/// the timeout, and the connection test.
final class AppleIntelligenceClientTests: XCTestCase {
    private func settings(provider: AIProviderTransport = .appleIntelligence, mode: DictationMode = .polish) -> AIEndpointSettings {
        var settings = AIEndpointSettings(isEnabled: true, provider: provider)
        if provider == .openAICompatible {
            settings.baseURL = URL(string: "http://localhost:11434/v1")
            settings.modelID = "qwen3:0.6b"
        }
        settings.seedBuiltInPromptModesIfNeeded()
        settings.mode = mode
        return settings
    }

    private func request(
        _ transcript: String = "um so like, move the review to friday",
        mode: DictationMode = .polish,
        jobID: JobID = UUID(),
        context: AIRequestContext = .init()
    ) -> AIProcessRequest {
        AIProcessRequest(
            jobID: jobID,
            mode: mode,
            rawTranscript: transcript,
            modelID: "",
            targetLanguage: mode == .translate ? TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese") : nil,
            polishPrompt: "Clean up the transcript.",
            context: context
        )
    }

    private func code(_ body: () async throws -> some Any) async -> KVoiceErrorCode? {
        do {
            _ = try await body()
            return nil
        } catch let error as KVoiceError {
            return error.code
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    // MARK: Availability and routing

    func testAvailabilityIsTheRuntimesWordAndSupportedLanguagesPassThrough() async {
        let runtime = FakeAppleIntelligenceRuntime(availability: .unavailable(.modelNotReady))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let observed = await client.availability()
        XCTAssertEqual(observed, .unavailable(.modelNotReady))
        runtime.set(availability: .available)
        let later = await client.availability()
        XCTAssertEqual(later, .available)
        let languages = await client.supportedLanguageIdentifiers()
        XCTAssertEqual(languages, ["en", "zh-Hans"])
    }

    func testAnEndpointTransportIsRefusedBeforeAnythingRuns() async {
        let runtime = FakeAppleIntelligenceRuntime()
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let refused = await code { try await client.process(request(), settings: settings(provider: .openAICompatible)) }
        XCTAssertEqual(refused, .aiConfigurationMissing)
        XCTAssertTrue(runtime.calls.isEmpty)
        // Off is valid for validation and a request in Off is refused.
        let offIsValid = await code { try await client.validateConfiguration(settings(provider: .openAICompatible, mode: .off)) }
        XCTAssertNil(offIsValid)
        let off = await code { try await client.process(request(), settings: settings(mode: .off)) }
        XCTAssertEqual(off, .aiConfigurationMissing)
    }

    func testAnUnavailableModelFailsAsProviderUnavailableWithoutARequest() async {
        for reason in AIProviderUnavailableReason.allCases {
            let runtime = FakeAppleIntelligenceRuntime(availability: .unavailable(reason))
            let client = AppleIntelligenceProcessingClient(runtime: runtime)
            do {
                _ = try await client.process(request(), settings: settings())
                XCTFail("expected a failure for \(reason)")
            } catch let error as KVoiceError {
                XCTAssertEqual(error.code, .aiProviderUnavailable)
                XCTAssertEqual(error.metadata.endpointClass, .onDevice)
                XCTAssertFalse(error.retryable)
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(runtime.calls.isEmpty, "\(reason)")
        }
    }

    // MARK: The prompt

    func testTheSessionGetsTheComposerMessagesAndTheReplyComesBackNormalized() async throws {
        let runtime = FakeAppleIntelligenceRuntime(reply: .success("  Move the review to Friday.\n"))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let settings = settings()
        let request = request(context: AIRequestContext(userProfile: "Role: engineer"))
        let result = try await client.process(request, settings: settings)
        XCTAssertEqual(result.text, "Move the review to Friday.")
        XCTAssertNil(result.responseID)
        XCTAssertGreaterThanOrEqual(result.requestDuration, .zero)

        let expected = try AIPromptComposer.compose(request: request, settings: settings)
        XCTAssertEqual(runtime.calls.count, 1)
        XCTAssertEqual(runtime.calls.first?.instructions, expected.systemPrompt)
        XCTAssertEqual(runtime.calls.first?.prompt, expected.userMessage)
        XCTAssertEqual(runtime.calls.first?.prompt, "<TRANSCRIPT>\num so like, move the review to friday\n</TRANSCRIPT>\n<USER_PROFILE>\nRole: engineer\n</USER_PROFILE>")
        let maximum = try XCTUnwrap(runtime.calls.first?.maximumResponseTokens)
        XCTAssertGreaterThan(maximum, AppleIntelligenceContextBudget.minimumResponseTokens)
        XCTAssertLessThan(maximum, AppleIntelligenceContextBudget.defaultContextSize)
    }

    func testATranslateRequestUsesTheTranslatePromptWithTheLanguage() async throws {
        let runtime = FakeAppleIntelligenceRuntime(reply: .success("把评审移到周五。"))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let settings = settings(mode: .translate)
        _ = try await client.process(request(mode: .translate), settings: settings)
        let instructions = try XCTUnwrap(runtime.calls.first?.instructions)
        XCTAssertTrue(instructions.contains("Chinese"))
        XCTAssertEqual(
            instructions,
            settings.promptConfiguration.systemPrompt(for: .translate, targetLanguage: TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese"))
        )
    }

    // MARK: Context window

    func testAnOversizedPromptFailsAsInputTooLongBeforeTheModelSeesIt() async {
        let runtime = FakeAppleIntelligenceRuntime(contextSize: 4096)
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        // ~10,000 estimated tokens of Latin text: far past 4,096.
        let long = String(repeating: "word ", count: 8000)
        do {
            _ = try await client.process(request(long), settings: settings())
            XCTFail("expected a failure")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiInputTooLong)
            XCTAssertEqual(error.metadata.endpointClass, .onDevice)
            XCTAssertNotNil(error.metadata.tokenCount, "the estimate is the one scalar that travels")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runtime.calls.isEmpty)
    }

    func testTheExactCountWinsOverTheEstimateWhenTheSystemCanCount() async {
        // The estimate says the short transcript fits; the framework's exact
        // count says the window is already full.
        let runtime = FakeAppleIntelligenceRuntime(contextSize: 4096, tokenCount: 4000)
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let refused = await code { try await client.process(request(), settings: settings()) }
        XCTAssertEqual(refused, .aiInputTooLong)
        XCTAssertTrue(runtime.calls.isEmpty)

        // And a small exact count admits a transcript the estimate would refuse.
        let generous = FakeAppleIntelligenceRuntime(contextSize: 4096, tokenCount: 100)
        let admitting = AppleIntelligenceProcessingClient(runtime: generous)
        let long = String(repeating: "word ", count: 3000)
        let admitted = await code { try await admitting.process(request(long), settings: settings()) }
        // 3000 words estimate to 3,750 transcript tokens; the reply budget
        // (1.5x) does not fit even with a 100-token input, so this is refused
        // on the reply side — the rule, not the estimate, decides.
        XCTAssertEqual(admitted, .aiInputTooLong)

        let short = await code { try await admitting.process(request(String(repeating: "word ", count: 1000)), settings: settings()) }
        XCTAssertNil(short)
        XCTAssertEqual(generous.calls.count, 1)
    }

    func testACountTheFrameworkRefusesToGiveFallsBackToTheEstimate() async {
        struct Boom: Error {}
        let runtime = FakeAppleIntelligenceRuntime(contextSize: 4096)
        runtime.set(tokenCountError: Boom())
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let ok = await code { try await client.process(request(), settings: settings()) }
        XCTAssertNil(ok)
        XCTAssertEqual(runtime.calls.count, 1)
    }

    func testTheFrameworksOwnContextRefusalMapsToInputTooLong() async {
        let runtime = FakeAppleIntelligenceRuntime(reply: .failure(.exceededContextWindow))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let refused = await code { try await client.process(request(), settings: settings()) }
        XCTAssertEqual(refused, .aiInputTooLong)
    }

    func testTheBudgetRuleIsPure() {
        XCTAssertEqual(AppleIntelligenceContextBudget.estimateTokens(in: ""), 0)
        XCTAssertEqual(AppleIntelligenceContextBudget.estimateTokens(in: "abcd"), 1)
        XCTAssertEqual(AppleIntelligenceContextBudget.estimateTokens(in: "abcde"), 2)
        XCTAssertEqual(AppleIntelligenceContextBudget.estimateTokens(in: "把评审移到周五"), 7, "one token per CJK character")
        XCTAssertEqual(AppleIntelligenceContextBudget.expectedResponseTokens(forTranscriptTokens: 10), 64, "the floor")
        XCTAssertEqual(AppleIntelligenceContextBudget.expectedResponseTokens(forTranscriptTokens: 1000), 1500)

        let plan = AppleIntelligenceContextBudget.plan(inputTokens: 1000, transcriptTokens: 800, contextSize: nil)
        XCTAssertEqual(plan, .init(maximumResponseTokens: 4096 - 256 - 1000, inputTokens: 1000))
        XCTAssertNil(AppleIntelligenceContextBudget.plan(inputTokens: 2000, transcriptTokens: 1500, contextSize: 4096))
        XCTAssertNotNil(AppleIntelligenceContextBudget.plan(inputTokens: 2000, transcriptTokens: 1500, contextSize: 8192),
                        "a larger window (macOS 27's contextSize) admits more")
    }

    // MARK: Error mapping

    func testRuntimeErrorsMapOntoTheExistingFallbackCodes() async {
        let expectations: [(AppleIntelligenceRuntimeError, KVoiceErrorCode)] = [
            (.unavailable(.appleIntelligenceNotEnabled), .aiProviderUnavailable),
            (.exceededContextWindow, .aiInputTooLong),
            (.refused, .aiMalformedResponse),
            (.unsupportedLanguage, .aiMalformedResponse),
            (.generationFailed, .aiMalformedResponse),
            (.busy, .aiRateLimited)
        ]
        for (runtimeError, expected) in expectations {
            let runtime = FakeAppleIntelligenceRuntime(reply: .failure(runtimeError))
            let client = AppleIntelligenceProcessingClient(runtime: runtime)
            do {
                _ = try await client.process(request(), settings: settings())
                XCTFail("expected \(expected)")
            } catch let error as KVoiceError {
                XCTAssertEqual(error.code, expected, "\(runtimeError)")
                XCTAssertEqual(error.metadata.endpointClass, .onDevice)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testAnEmptyOrControlCharacterReplyIsRefused() async {
        let empty = await code {
            try await AppleIntelligenceProcessingClient(runtime: FakeAppleIntelligenceRuntime(reply: .success("  \n ")))
                .process(request(), settings: settings())
        }
        XCTAssertEqual(empty, .aiEmptyResponse)
        let control = await code {
            try await AppleIntelligenceProcessingClient(runtime: FakeAppleIntelligenceRuntime(reply: .success("ok\u{07}")))
                .process(request(), settings: settings())
        }
        XCTAssertEqual(control, .aiMalformedResponse)
    }

    func testAnOversizedTranscriptOrEmptyPromptIsRefusedLikeTheEndpointClient() async {
        let client = AppleIntelligenceProcessingClient(runtime: FakeAppleIntelligenceRuntime())
        let huge = String(repeating: "x", count: AppleIntelligenceProcessingClient.maximumUTF8Bytes + 1)
        let oversized = await code { try await client.process(request(huge), settings: settings()) }
        XCTAssertEqual(oversized, .aiOversizedResponse)
        let blank = await code { try await client.process(request("   "), settings: settings()) }
        XCTAssertEqual(blank, .aiEmptyResponse)
        let noPrompt = AIProcessRequest(jobID: UUID(), mode: .polish, rawTranscript: "hi", modelID: "", targetLanguage: nil, polishPrompt: " ")
        let missing = await code { try await client.process(noPrompt, settings: settings()) }
        XCTAssertEqual(missing, .aiConfigurationMissing)
    }

    // MARK: Cancellation and timeout

    func testCancelByJobIDEndsTheRequestAsCancelled() async {
        let runtime = FakeAppleIntelligenceRuntime()
        // Long enough that the cancel is the only way out; the pre-commit
        // gate must never depend on a scheduler race.
        runtime.set(delay: .seconds(3600))
        let client = AppleIntelligenceProcessingClient(runtime: runtime)
        let jobID = UUID()
        let settings = settings()
        let request = request(jobID: jobID)
        let running = Task<KVoiceErrorCode?, Never> {
            do {
                _ = try await client.process(request, settings: settings)
                return nil
            } catch let error as KVoiceError {
                return error.code
            } catch {
                return nil
            }
        }
        // Let the request register before cancelling it.
        while runtime.calls.isEmpty { await Task.yield() }
        await client.cancel(jobID: jobID)
        let outcome = await running.value
        XCTAssertEqual(outcome, .aiCancelled)
    }

    func testAStalledGenerationTimesOut() async {
        let runtime = FakeAppleIntelligenceRuntime()
        // An hour: the injected timeout is the only possible exit.
        runtime.set(delay: .seconds(3600))
        let client = AppleIntelligenceProcessingClient(runtime: runtime, requestTimeout: .milliseconds(20))
        let outcome = await code { try await client.process(request(), settings: settings()) }
        XCTAssertEqual(outcome, .aiTimeout)
    }

    // MARK: Connection test

    func testTheConnectionTestNeedsAvailabilityAndTheMarkerBack() async {
        let unavailable = AppleIntelligenceProcessingClient(
            runtime: FakeAppleIntelligenceRuntime(availability: .unavailable(.deviceNotEligible))
        )
        let refused = await code { try await unavailable.testConfiguration(settings(mode: .off)) }
        XCTAssertEqual(refused, .aiProviderUnavailable)

        let echoing = FakeAppleIntelligenceRuntime(reply: .success("<kvoice connection OK>"))
        let passing = await code { try await AppleIntelligenceProcessingClient(runtime: echoing).testConfiguration(settings(mode: .off)) }
        XCTAssertNil(passing, "the master switch and the default action are irrelevant to the test")
        XCTAssertEqual(echoing.calls.first?.instructions, ConnectionTest.systemPrompt)
        XCTAssertEqual(echoing.calls.first?.prompt, "<TRANSCRIPT>\n\(ConnectionTest.marker)\n</TRANSCRIPT>")

        let chatty = FakeAppleIntelligenceRuntime(reply: .success("Hello! How can I help you today?"))
        let failing = await code { try await AppleIntelligenceProcessingClient(runtime: chatty).testConfiguration(settings()) }
        XCTAssertEqual(failing, .aiMalformedResponse)

        let wrongTransport = await code { try await AppleIntelligenceProcessingClient(runtime: echoing).testConfiguration(settings(provider: .openAICompatible)) }
        XCTAssertEqual(wrongTransport, .aiConfigurationMissing)
    }
}
