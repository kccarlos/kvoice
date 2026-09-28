import Foundation
import XCTest
@testable import KvoiceAI
import KvoiceDomain

/// Runs the real client against the endpoints available on the developer's
/// machine (product decision #12): local Ollama and the Gemini key stored in
/// the app's secrets file. Skipped unless `KVOICE_LIVE_AI_TESTS=1` is set
/// *and* the resource is present, so the ordinary suite stays hermetic.
///
/// The Gemini key is read at run time from the secrets file and never
/// printed, asserted on, or written anywhere.
///
///     KVOICE_LIVE_AI_TESTS=1 ./Scripts/test.sh --filter LiveEndpointVerificationTests
final class LiveEndpointVerificationTests: XCTestCase {
    private static let ollamaURL = URL(string: "http://localhost:11434/v1")!
    private static let ollamaModel = "qwen3:0.6b"
    private static let geminiURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
    private static let geminiModel = "models/gemini-3.5-flash-lite"

    private var client: OpenAICompatibleAIProcessingClient!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_AI_TESTS"] == "1",
            "live endpoint tests are opt-in (KVOICE_LIVE_AI_TESTS=1)"
        )
        client = OpenAICompatibleAIProcessingClient()
    }

    // MARK: Ollama

    func testOllamaConnectionTestPassesRepeatedly() async throws {
        try await skipUnlessOllamaIsUp()
        let settings = AIEndpointSettings(baseURL: Self.ollamaURL, modelID: Self.ollamaModel)
        // The old test failed nondeterministically; run it several times.
        for attempt in 1...4 {
            do {
                try await client.testConfiguration(settings, credentials: nil)
            } catch {
                // The reply to the fixed prompt is model output, not user
                // data; showing it is what makes a flake diagnosable.
                let reply = await rawConnectionTestReply(settings)
                XCTFail("attempt \(attempt): \((error as? KVoiceError)?.code.rawValue ?? "\(error)") reply=\(reply)")
            }
        }
    }

    func testOllamaPolishRequestReturnsText() async throws {
        try await skipUnlessOllamaIsUp()
        var settings = AIEndpointSettings(baseURL: Self.ollamaURL, modelID: Self.ollamaModel, isEnabled: true)
        settings.seedBuiltInPromptModesIfNeeded()
        settings.apply(promptMode: settings.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.clean }!)
        let result = try await client.process(
            AIProcessRequest(
                jobID: UUID(),
                mode: .polish,
                rawTranscript: "um so like, please move the, uh, review to friday",
                modelID: settings.modelID,
                targetLanguage: nil,
                polishPrompt: settings.promptConfiguration.polishPrompt,
                context: AIRequestContext(userProfile: "Role: engineer")
            ),
            settings: settings,
            credentials: nil
        )
        XCTAssertFalse(result.text.isEmpty)
    }

    func testOllamaUnknownModelReportsAnHTTPClass() async throws {
        try await skipUnlessOllamaIsUp()
        let settings = AIEndpointSettings(baseURL: Self.ollamaURL, modelID: "no-such-model:0b")
        do {
            try await client.testConfiguration(settings, credentials: nil)
            XCTFail("expected a failure")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiHTTPError)
            XCTAssertNotNil(error.metadata.httpStatus)
        }
    }

    func testUnreachablePortIsClassifiedAsUnreachable() async throws {
        let settings = AIEndpointSettings(baseURL: URL(string: "http://127.0.0.1:1")!, modelID: "x")
        do {
            try await client.testConfiguration(settings, credentials: nil)
            XCTFail("expected a failure")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiUnreachable)
        }
    }

    // MARK: Gemini

    func testGeminiConnectionTestPassesWithTheStoredKey() async throws {
        let credentials = try skipUnlessGeminiKeyIsStored()
        let settings = AIEndpointSettings(baseURL: Self.geminiURL, modelID: Self.geminiModel)
        try await client.testConfiguration(settings, credentials: credentials)
    }

    func testGeminiRejectsABadKeyAsAuthentication() async throws {
        _ = try skipUnlessGeminiKeyIsStored()
        let settings = AIEndpointSettings(baseURL: Self.geminiURL, modelID: Self.geminiModel)
        do {
            try await client.testConfiguration(settings, credentials: AICredentialSnapshot(apiKey: "invalid"))
            XCTFail("expected a failure")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiAuthentication)
            XCTAssertEqual(error.metadata.httpStatus, 400, "Gemini answers a bad key with 400")
        }
    }

    func testGeminiUnknownModelReportsHTTP404() async throws {
        let credentials = try skipUnlessGeminiKeyIsStored()
        let settings = AIEndpointSettings(baseURL: Self.geminiURL, modelID: "models/no-such-model")
        do {
            try await client.testConfiguration(settings, credentials: credentials)
            XCTFail("expected a failure")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiHTTPError)
            XCTAssertEqual(error.metadata.httpStatus, 404)
        }
    }

    // MARK: Resources

    private func rawConnectionTestReply(_ settings: AIEndpointSettings) async -> String {
        var polish = settings
        polish.mode = .polish
        let request = AIProcessRequest(
            jobID: UUID(),
            mode: .polish,
            rawTranscript: ConnectionTest.marker,
            modelID: settings.modelID,
            targetLanguage: nil,
            polishPrompt: ConnectionTest.systemPrompt
        )
        do {
            return try await client.process(request, settings: polish, credentials: nil).text.debugDescription
        } catch {
            return "<\((error as? KVoiceError)?.code.rawValue ?? "\(error)")>"
        }
    }

    private func skipUnlessOllamaIsUp() async throws {
        var request = URLRequest(url: Self.ollamaURL.appendingPathComponent("models"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200, "Ollama is not serving")
        } catch is XCTSkip {
            throw XCTSkip("Ollama is not serving")
        } catch {
            throw XCTSkip("Ollama is not running on localhost:11434")
        }
    }

    /// Reads the key from the app's secrets file through the same decoder the
    /// app uses. The value goes straight into a credential snapshot.
    private func skipUnlessGeminiKeyIsStored() throws -> AICredentialSnapshot {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kvoice/secrets.json")
        guard let data = try? Data(contentsOf: url),
              let secrets = try? JSONDecoder().decode(SecretSettings.self, from: data),
              let key = secrets.apiKey, !key.isEmpty
        else {
            throw XCTSkip("no stored key in the app's secrets file")
        }
        return AICredentialSnapshot(apiKey: key)
    }
}
