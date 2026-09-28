import XCTest
@testable import KvoiceAI
@testable import KvoiceDomain

/// `http://localhost:11434` normalized to `/chat/completions`, which Ollama
/// answers with 404 — the manual test then reported a generic failure that read
/// as "wrong endpoint" rather than "add /v1". Every OpenAI-compatible server
/// serves the API under `/v1`, so a bare host means the `/v1` root.
final class AIEndpointNormalizationTests: XCTestCase {
    private func completion(_ string: String) throws -> String {
        try OpenAICompatibleAIProcessingClient
            .normalizedCompletionURL(from: URL(string: string)!)
            .absoluteString
    }

    private func models(_ string: String) throws -> String {
        try OpenAICompatibleAIProcessingClient
            .normalizedModelsURL(from: URL(string: string)!)
            .absoluteString
    }

    // MARK: Completion URL

    func testBareHostGetsTheV1Root() throws {
        XCTAssertEqual(
            try completion("http://localhost:11434"),
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            try completion("http://localhost:11434/"),
            "http://localhost:11434/v1/chat/completions"
        )
    }

    func testExplicitRootIsRespected() throws {
        XCTAssertEqual(
            try completion("http://localhost:11434/v1"),
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            try completion("https://api.openai.com/v1"),
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testCompleteEndpointIsNotDoubled() throws {
        XCTAssertEqual(
            try completion("http://localhost:11434/v1/chat/completions"),
            "http://localhost:11434/v1/chat/completions"
        )
    }

    func testNonV1PathIsPreserved() throws {
        // Gemini's OpenAI-compatible surface is not under /v1.
        XCTAssertEqual(
            try completion("https://generativelanguage.googleapis.com/v1beta/openai"),
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
    }

    // MARK: Models URL

    func testModelsURLIsDerivedFromAnyAcceptedForm() throws {
        for input in [
            "http://localhost:11434",
            "http://localhost:11434/",
            "http://localhost:11434/v1",
            "http://localhost:11434/v1/chat/completions"
        ] {
            XCTAssertEqual(
                try models(input),
                "http://localhost:11434/v1/models",
                "unexpected models URL for \(input)"
            )
        }
    }

    func testModelsURLForNonV1Path() throws {
        XCTAssertEqual(
            try models("https://generativelanguage.googleapis.com/v1beta/openai"),
            "https://generativelanguage.googleapis.com/v1beta/openai/models"
        )
    }

    // MARK: Security rules still apply

    func testRemoteHTTPIsStillRejected() {
        XCTAssertThrowsError(try completion("http://example.com/v1")) { error in
            XCTAssertEqual((error as? KVoiceError)?.code, .aiInsecureRemoteURL)
        }
        XCTAssertThrowsError(try models("http://example.com/v1"))
    }

    func testCredentialBearingURLIsRejected() {
        XCTAssertThrowsError(try completion("https://user:pass@example.com/v1"))
        XCTAssertThrowsError(try completion("https://example.com/v1?key=secret"))
    }

    // MARK: Model list parsing

    private func response(_ json: String, status: Int = 200) -> AITransportResponse {
        AITransportResponse(
            data: Data(json.utf8),
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:11434/v1/models")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func testParsesSortedUniqueModelIdentifiers() throws {
        let parsed = try OpenAICompatibleAIProcessingClient.parseModelList(
            response("""
            {"object":"list","data":[
              {"id":"gemma4:latest"},{"id":"llama3:8b"},{"id":"gemma4:latest"},{"id":"  "}
            ]}
            """)
        )
        XCTAssertEqual(parsed, ["gemma4:latest", "llama3:8b"])
    }

    func testEmptyListIsValid() throws {
        XCTAssertEqual(
            try OpenAICompatibleAIProcessingClient.parseModelList(
                response(#"{"object":"list","data":[]}"#)
            ),
            []
        )
    }

    func testMalformedBodyIsRejected() {
        XCTAssertThrowsError(
            try OpenAICompatibleAIProcessingClient.parseModelList(response(#"{"nope":true}"#))
        ) { error in
            XCTAssertEqual((error as? KVoiceError)?.code, .aiMalformedResponse)
        }
    }

    func testUnauthorizedStatusMapsToAuthentication() {
        XCTAssertThrowsError(
            try OpenAICompatibleAIProcessingClient.parseModelList(response("{}", status: 401))
        ) { error in
            XCTAssertEqual((error as? KVoiceError)?.code, .aiAuthentication)
        }
    }
}
