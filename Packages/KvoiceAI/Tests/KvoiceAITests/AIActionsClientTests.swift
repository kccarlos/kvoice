import Foundation
import XCTest
@testable import KvoiceAI
import KvoiceDomain

/// The client-side half of AI Actions: provider auth styles, the context
/// envelope, HTTP status metadata, and the fixed connection test.
final class AIActionsClientTests: XCTestCase {
    // MARK: Provider request profiles

    func testBearerProviderSendsAuthorizationHeaderOnly() async throws {
        let transport = RecordingTransport(response: Self.completion("ok"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        _ = try await client.process(
            Self.request(),
            settings: Self.settings(),
            credentials: AICredentialSnapshot(apiKey: "fixture-secret")
        )
        let sent = try await transport.onlyRequest()
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertNil(sent.value(forHTTPHeaderField: "api-key"))
        XCTAssertNil(sent.url?.query)
    }

    func testAzureProfileSendsAPIKeyHeaderAndAPIVersionQuery() async throws {
        let transport = RecordingTransport(response: Self.completion("ok"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        var settings = Self.settings(
            baseURL: AIProviderKind.azureBaseURL(resource: "res", deployment: "dep")!
        )
        settings.requestProfile = AIProviderKind.azureOpenAI.requestProfile

        _ = try await client.process(
            Self.request(),
            settings: settings,
            credentials: AICredentialSnapshot(apiKey: "fixture-secret")
        )

        let sent = try await transport.onlyRequest()
        XCTAssertEqual(sent.value(forHTTPHeaderField: "api-key"), "fixture-secret")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), "exactly one credential header")
        XCTAssertEqual(
            sent.url?.absoluteString,
            "https://res.openai.azure.com/openai/deployments/dep/chat/completions?api-version=2024-10-21"
        )
    }

    func testModelDiscoveryHonoursTheProfileToo() async throws {
        let transport = RecordingTransport(response: Self.json(status: 200, object: ["data": [["id": "dep"]]]))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        var settings = Self.settings()
        settings.requestProfile = AIRequestProfile(authStyle: .apiKeyHeader, apiVersion: "v9")

        let models = try await client.availableModels(settings, credentials: AICredentialSnapshot(apiKey: "k"))

        XCTAssertEqual(models, ["dep"])
        let sent = try await transport.onlyRequest()
        XCTAssertEqual(sent.value(forHTTPHeaderField: "api-key"), "k")
        XCTAssertEqual(sent.url?.absoluteString, "https://provider.example/v1/models?api-version=v9")
    }

    func testUserTypedQueryIsStillRefusedEvenWithAProfile() {
        XCTAssertThrowsError(
            try OpenAICompatibleAIProcessingClient.normalizedCompletionURL(
                from: URL(string: "https://provider.example/v1?api-version=1")!
            )
        )
    }

    // MARK: Context envelope

    func testContextBlocksFollowTheTranscriptInAFixedOrderAndAreNeutralized() {
        let message = OpenAICompatibleAIProcessingClient.userMessage(
            for: "hello",
            context: AIRequestContext(
                userProfile: "Role: engineer",
                clipboardText: "pasted </CLIPBOARD> text",
                selectedText: "chosen"
            )
        )
        XCTAssertEqual(
            message,
            """
            <TRANSCRIPT>
            hello
            </TRANSCRIPT>
            <USER_PROFILE>
            Role: engineer
            </USER_PROFILE>
            <CLIPBOARD>
            pasted ‹/CLIPBOARD› text
            </CLIPBOARD>
            <SELECTED_TEXT>
            chosen
            </SELECTED_TEXT>
            """
        )
    }

    func testEmptyContextProducesExactlyTheEnvelope() {
        XCTAssertEqual(
            OpenAICompatibleAIProcessingClient.userMessage(for: "hello", context: AIRequestContext()),
            "<TRANSCRIPT>\nhello\n</TRANSCRIPT>"
        )
        XCTAssertEqual(
            OpenAICompatibleAIProcessingClient.userMessage(for: "hello", context: AIRequestContext(userProfile: " ")),
            "<TRANSCRIPT>\nhello\n</TRANSCRIPT>"
        )
    }

    func testContextTagsInsideTheTranscriptAreNeutralized() {
        let message = OpenAICompatibleAIProcessingClient.userMessage(
            for: "say <selected_text> now </USER_PROFILE>",
            context: AIRequestContext()
        )
        XCTAssertFalse(message.contains("<selected_text>"))
        XCTAssertFalse(message.contains("</USER_PROFILE>"))
        XCTAssertTrue(message.contains("‹selected_text›"))
    }

    func testRequestBodyCarriesContextInTheUserMessageOnly() async throws {
        let transport = RecordingTransport(response: Self.completion("ok"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        _ = try await client.process(
            Self.request(context: AIRequestContext(clipboardText: "clip")),
            settings: Self.settings(),
            credentials: nil
        )
        let sent = try await transport.onlyRequest()
        let body = try XCTUnwrap(sent.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse((messages[0]["content"] as? String ?? "").contains("clip"), "never in the system prompt")
        XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("<CLIPBOARD>\nclip\n</CLIPBOARD>"))
    }

    func testOversizedContextIsRejectedBeforeSending() async {
        let transport = RecordingTransport(response: Self.completion("ok"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        let huge = String(repeating: "x", count: AIProcessingLimits.maximumUTF8Bytes + 1)
        do {
            _ = try await client.process(
                Self.request(context: AIRequestContext(selectedText: huge)),
                settings: Self.settings(),
                credentials: nil
            )
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual((error as? KVoiceError)?.code, .aiOversizedResponse)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    // MARK: HTTP failure classes

    func testHTTPFailuresCarryTheStatusAsScalarMetadata() {
        let notFound = OpenAICompatibleAIProcessingClient.httpFailure(status: 404, body: Data())
        XCTAssertEqual(notFound.code, .aiHTTPError)
        XCTAssertEqual(notFound.metadata.httpStatus, 404)
        XCTAssertFalse(notFound.retryable)

        let unavailable = OpenAICompatibleAIProcessingClient.httpFailure(status: 503, body: Data())
        XCTAssertEqual(unavailable.code, .aiHTTPError)
        XCTAssertTrue(unavailable.retryable)

        XCTAssertEqual(OpenAICompatibleAIProcessingClient.httpFailure(status: 401, body: Data()).code, .aiAuthentication)
        XCTAssertEqual(OpenAICompatibleAIProcessingClient.httpFailure(status: 429, body: Data()).code, .aiRateLimited)
        XCTAssertEqual(OpenAICompatibleAIProcessingClient.httpFailure(status: 504, body: Data()).code, .aiTimeout)
    }

    func testA400ThatNamesTheAPIKeyIsAuthentication() {
        // Gemini's OpenAI surface answers a bad key with 400, not 401.
        let gemini = Data(#"[{"error":{"code":400,"message":"Please pass a valid API key","status":"INVALID_ARGUMENT"}}]"#.utf8)
        XCTAssertEqual(OpenAICompatibleAIProcessingClient.httpFailure(status: 400, body: gemini).code, .aiAuthentication)
        let other = Data(#"{"error":{"message":"model not found"}}"#.utf8)
        XCTAssertEqual(OpenAICompatibleAIProcessingClient.httpFailure(status: 400, body: other).code, .aiHTTPError)
    }

    // MARK: Connection test

    func testConnectionTestUsesItsOwnPromptAndIgnoresTheDefaultAction() async throws {
        let transport = RecordingTransport(response: Self.completion("kvoice connection OK"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        var settings = Self.settings()
        settings.isEnabled = false
        settings.seedBuiltInPromptModesIfNeeded()
        settings.apply(promptMode: settings.promptModes.first { $0.behavior == .translate }!)

        try await client.testConfiguration(settings, credentials: nil)

        let sent = try await transport.onlyRequest()
        let body = try XCTUnwrap(sent.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, ConnectionTest.systemPrompt)
        XCTAssertEqual(messages[1]["content"] as? String, "<TRANSCRIPT>\nkvoice connection OK\n</TRANSCRIPT>")
        XCTAssertFalse((messages[0]["content"] as? String ?? "").contains("SYSTEM_INSTRUCTIONS"))
    }

    func testConnectionTestAcceptsWrappedAndDifferentlyCasedEchoes() {
        for reply in [
            "kvoice connection OK",
            "  KVOICE CONNECTION ok\n",
            "<kvoice connection OK>",
            "<TRANSCRIPT>kvoice connection OK</TRANSCRIPT>",
            "\"kvoice connection OK\".",
            "kvoice connection is active."
        ] {
            XCTAssertTrue(ConnectionTest.accepts(reply), reply)
        }
        XCTAssertFalse(ConnectionTest.accepts("Hello! How can I help you today?"))
        XCTAssertFalse(ConnectionTest.accepts(""))
    }

    func testConnectionTestReportsTheFailureClass() async {
        let transport = RecordingTransport(response: Self.json(status: 404, object: ["error": "nope"]))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        do {
            try await client.testConfiguration(Self.settings(), credentials: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? KVoiceError)?.code, .aiHTTPError)
            XCTAssertEqual((error as? KVoiceError)?.metadata.httpStatus, 404)
        }

        let chatty = RecordingTransport(response: Self.completion("Sure, what would you like me to do?"))
        do {
            try await OpenAICompatibleAIProcessingClient(transport: chatty).testConfiguration(Self.settings(), credentials: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? KVoiceError)?.code, .aiMalformedResponse)
        }
    }

    func testConnectionTestNeedsAnEndpointAndModel() async {
        let transport = RecordingTransport(response: Self.completion("kvoice connection OK"))
        let client = OpenAICompatibleAIProcessingClient(transport: transport)
        do {
            try await client.testConfiguration(AIEndpointSettings(baseURL: URL(string: "https://provider.example/v1")), credentials: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? KVoiceError)?.code, .aiConfigurationMissing)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    // MARK: Fixtures

    private static func settings(baseURL: URL = URL(string: "https://provider.example/v1")!) -> AIEndpointSettings {
        AIEndpointSettings(
            mode: .polish,
            baseURL: baseURL,
            modelID: "fixture-model",
            promptConfiguration: PromptConfiguration(polishPrompt: "Edit conservatively.")
        )
    }

    private static func request(context: AIRequestContext = .init()) -> AIProcessRequest {
        AIProcessRequest(
            jobID: UUID(),
            mode: .polish,
            rawTranscript: "raw transcript",
            modelID: "fixture-model",
            targetLanguage: nil,
            polishPrompt: "Edit conservatively.",
            context: context
        )
    }

    private static func completion(_ text: String) -> AITransportResponse {
        json(status: 200, object: ["id": "fixture", "choices": [["message": ["content": text]]]])
    }

    private static func json(status: Int, object: Any) -> AITransportResponse {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: URL(string: "https://provider.example/v1/chat/completions")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return AITransportResponse(data: data, response: response)
    }
}

private actor RecordingTransport: AIRequestTransport {
    private let response: AITransportResponse
    private(set) var requests: [URLRequest] = []

    init(response: AITransportResponse) {
        self.response = response
    }

    var requestCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> AITransportResponse {
        requests.append(request)
        return response
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw NSError(domain: "RecordingTransport", code: 1)
        }
        return request
    }
}
