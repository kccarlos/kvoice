import Foundation
import KvoiceDomain

/// Maximum number of UTF-8 bytes accepted for one transcript or returned by a
/// provider. The limit is deliberately applied before a request is sent and
/// after a response has been decoded.
public enum AIProcessingLimits {
    public static let maximumUTF8Bytes = 64 * 1024
    public static let requestTimeout: TimeInterval = 15
}

/// A response returned by an injected HTTP transport. Keeping this seam small
/// makes fixture-backed tests deterministic without allowing production code
/// to substitute a persistent or cookie-bearing session.
public struct AITransportResponse: Sendable {
    public let data: Data
    public let response: URLResponse

    public init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }
}

public protocol AIRequestTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AITransportResponse
}

/// The only production transport. It owns an ephemeral URLSession and rejects
/// redirects that would cross scheme, host, or port boundaries.
public final class URLSessionAIRequestTransport: NSObject, AIRequestTransport, @unchecked Sendable {
    private let session: URLSession

    public override convenience init() {
        self.init(configuration: Self.defaultConfiguration())
    }

    public init(configuration: URLSessionConfiguration) {
        let redirectDelegate = SameOriginRedirectDelegate()
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> AITransportResponse {
        let (data, response) = try await session.data(for: request)
        return AITransportResponse(data: data, response: response)
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AIProcessingLimits.requestTimeout
        configuration.timeoutIntervalForResource = AIProcessingLimits.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = task.currentRequest?.url ?? task.originalRequest?.url,
              let destinationURL = request.url,
              Self.sameOrigin(sourceURL, destinationURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Actor-backed OpenAI-compatible Chat Completions client.
///
/// The actor keeps request cancellation serialized and never stores an API
/// key. Credentials are accepted only for the duration of one call through
/// `AICredentialSnapshot`.
public actor OpenAICompatibleAIProcessingClient: CredentialInjectingAIProcessingClient {
    private let transport: any AIRequestTransport
    private var activeRequests: [JobID: Task<AITransportResponse, Error>] = [:]

    public init(transport: any AIRequestTransport = URLSessionAIRequestTransport()) {
        self.transport = transport
    }

    public func validateConfiguration(_ settings: AIEndpointSettings) throws {
        // Off is a valid, deliberately network-free configuration. Callers
        // that actually process text still fail closed below when the request
        // mode is Off.
        guard settings.mode != .off else { return }
        // ADR-024: the on-device transport is another client's; reaching
        // this one with it is a routing error, never a network request.
        guard settings.provider == .openAICompatible else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        guard let baseURL = settings.baseURL else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        _ = try Self.normalizedCompletionURL(from: baseURL)
        guard !settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
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
        try Task.checkCancellation()
        try validateConfiguration(settings)
        guard request.mode != .off, request.mode == settings.mode else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        guard !request.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false)
        }
        try validateInput(request: request, settings: settings)

        let url = try Self.requestURL(
            Self.normalizedCompletionURL(from: settings.baseURL!),
            profile: settings.requestProfile
        )
        let body = try Self.makeRequestBody(request: request, settings: settings)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = AIProcessingLimits.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyCredentials(credentials, style: settings.requestProfile.authStyle, to: &urlRequest)

        let startedAt = ContinuousClock().now
        let requestTask = Task { [transport] in
            try await transport.send(urlRequest)
        }
        activeRequests[request.jobID] = requestTask
        defer { activeRequests.removeValue(forKey: request.jobID) }

        do {
            let transportResponse: AITransportResponse
            do {
                transportResponse = try await withThrowingTaskGroup(of: AITransportResponse.self) {
                    group -> AITransportResponse in
                    group.addTask {
                        try await requestTask.value
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(AIProcessingLimits.requestTimeout))
                        throw KVoiceError(code: .aiTimeout, retryable: false)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch {
                requestTask.cancel()
                throw error
            }
            try Task.checkCancellation()
            let text = try Self.parseResponse(transportResponse)
            let endedAt = ContinuousClock().now
            return AIProcessResult(
                text: text.text,
                requestDuration: startedAt.duration(to: endedAt),
                responseID: text.responseID
            )
        } catch is CancellationError {
            throw KVoiceError(code: .aiCancelled, retryable: false)
        } catch let error as KVoiceError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw KVoiceError(code: .aiCancelled, retryable: false)
        } catch let error as URLError where error.code == .timedOut {
            throw KVoiceError(code: .aiTimeout, retryable: false)
        } catch {
            // Do not expose the underlying URLSession error. It may include
            // a URL, proxy detail, or a credential-bearing request description.
            throw KVoiceError(code: .aiUnreachable)
        }
    }

    /// Derives the OpenAI-compatible `/models` URL from the configured endpoint.
    ///
    /// Accepts an API root (`http://host:11434`, `.../v1`) or a complete
    /// completion endpoint (`.../v1/chat/completions`) and resolves all three to
    /// the same `/models` path, so discovery works from whatever the user typed.
    public static func normalizedModelsURL(from baseURL: URL) throws -> URL {
        // Reuse the completion normalizer so scheme, loopback, and credential
        // rules are enforced in exactly one place.
        let completionURL = try normalizedCompletionURL(from: baseURL)
        guard var components = URLComponents(
            url: completionURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }

        var path = components.path
        let suffix = "/chat/completions"
        if path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.isEmpty ? "/models" : path + "/models"
        guard let url = components.url else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }
        return url
    }

    /// Lists the model identifiers the endpoint advertises.
    ///
    /// Discovery is user-triggered from Settings and is never called by
    /// `process`, so ordinary dictation issues no extra request.
    public func availableModels(
        _ settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws -> [String] {
        guard let baseURL = settings.baseURL else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }
        let url = try Self.requestURL(
            Self.normalizedModelsURL(from: baseURL),
            profile: settings.requestProfile
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyCredentials(credentials, style: settings.requestProfile.authStyle, to: &urlRequest)

        // Built outside the group for the same reason as `process`: the request
        // must not be captured by a concurrently-executing sending closure.
        let requestTask = Task { [transport] in
            try await transport.send(urlRequest)
        }

        do {
            let transportResponse = try await withThrowingTaskGroup(
                of: AITransportResponse.self
            ) { group -> AITransportResponse in
                group.addTask {
                    try await requestTask.value
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(AIProcessingLimits.requestTimeout))
                    throw KVoiceError(code: .aiTimeout, retryable: false)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            return try Self.parseModelList(transportResponse)
        } catch let error as KVoiceError {
            throw error
        } catch is CancellationError {
            throw KVoiceError(code: .aiCancelled, retryable: false)
        } catch let error as URLError where error.code == .timedOut {
            throw KVoiceError(code: .aiTimeout, retryable: false)
        } catch {
            // As elsewhere, the underlying error may carry the URL or proxy
            // detail, so it is not surfaced.
            throw KVoiceError(code: .aiUnreachable)
        }
    }

    static func parseModelList(_ response: AITransportResponse) throws -> [String] {
        if let http = response.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw Self.httpFailure(status: http.statusCode, body: response.data)
        }

        struct ModelList: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }

        guard let list = try? JSONDecoder().decode(ModelList.self, from: response.data) else {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false)
        }
        // Stable order, no blanks, no duplicates.
        var seen = Set<String>()
        return list.data
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    public func testConfiguration(_ settings: AIEndpointSettings) async throws {
        try await testConfiguration(settings, credentials: nil)
    }

    /// Manual, user-triggered configuration test (spec K.9: one fixed,
    /// harmless request). It is deliberately not called by `process` or by
    /// validation, so normal dictation has no health check request before
    /// the actual transcript request.
    ///
    /// The test carries its own minimal system prompt rather than the active
    /// action's: a polish prompt tells the model to treat the transcript as
    /// spoken words and never follow it, so "Return exactly: …" was edited
    /// back as dictation on some runs and obeyed on others. The reply is
    /// accepted when it contains the marker, case-insensitively — small
    /// local models wrap it in tags or brackets while still proving the
    /// endpoint, model, and key all work.
    public func testConfiguration(
        _ settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws {
        var testSettings = settings
        // The test is an ordinary polish-shaped request against the endpoint
        // fields as they are; the user's master switch and default action
        // are irrelevant to it.
        testSettings.activePromptModeID = nil
        testSettings.mode = .polish
        try validateConfiguration(testSettings)
        guard testSettings.mode == .polish else {
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        }
        let request = AIProcessRequest(
            jobID: UUID(),
            mode: .polish,
            rawTranscript: ConnectionTest.marker,
            modelID: testSettings.modelID,
            targetLanguage: nil,
            polishPrompt: ConnectionTest.systemPrompt
        )
        let result = try await process(request, settings: testSettings, credentials: credentials)
        guard ConnectionTest.accepts(result.text) else {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false)
        }
    }

    public func cancel(jobID: JobID) async {
        activeRequests[jobID]?.cancel()
    }

    /// Normalizes either an API root (`/v1`) or an already-complete endpoint
    /// (`/v1/chat/completions`) without appending the suffix twice.
    public static func normalizedCompletionURL(from baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }

        switch scheme {
        case "https":
            break
        case "http" where Self.isLoopback(host):
            break
        case "http":
            throw KVoiceError(code: .aiInsecureRemoteURL, retryable: false)
        default:
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }

        // A host with no path means the API root, and every OpenAI-compatible
        // server serves it under `/v1` — OpenAI itself, Ollama, LM Studio,
        // vLLM, llama.cpp. Defaulting to a bare `/chat/completions` produced a
        // 404 for `http://localhost:11434`, which reads as "the endpoint is
        // wrong" rather than "add /v1".
        if path.isEmpty {
            path = "/v1"
        }

        if !path.lowercased().hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    // MARK: Provider request profile

    /// Appends the provider's API version, if it has one, to a normalized
    /// URL. A user-typed query is still refused by the normalizer; this is the
    /// one query the client writes itself (Azure OpenAI's `api-version`).
    static func requestURL(_ url: URL, profile: AIRequestProfile) throws -> URL {
        guard let apiVersion = profile.apiVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiVersion.isEmpty
        else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        guard let versioned = components.url else {
            throw KVoiceError(code: .aiURLInvalid, retryable: false)
        }
        return versioned
    }

    /// Exactly one credential header, named by the provider's auth style.
    static func applyCredentials(
        _ credentials: AICredentialSnapshot?,
        style: AIProviderAuthStyle,
        to request: inout URLRequest
    ) {
        guard let apiKey = credentials?.apiKey, !apiKey.isEmpty else { return }
        switch style {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKeyHeader:
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
    }

    /// Maps a non-2xx status to a stable code, carrying the status as scalar
    /// metadata so Settings can say "HTTP 404" without seeing the body.
    /// Some providers answer a bad key with 400 rather than 401 (Gemini says
    /// "Please pass a valid API key"); the body is inspected for that one
    /// classification and never surfaced.
    static func httpFailure(status: Int, body: Data) -> KVoiceError {
        let metadata = DiagnosticAttributes(httpStatus: status)
        switch status {
        case 401, 403:
            return KVoiceError(code: .aiAuthentication, retryable: false, metadata: metadata)
        case 400 where Self.bodyMentionsAPIKey(body):
            return KVoiceError(code: .aiAuthentication, retryable: false, metadata: metadata)
        case 408, 504:
            return KVoiceError(code: .aiTimeout, retryable: false, metadata: metadata)
        case 429:
            return KVoiceError(code: .aiRateLimited, metadata: metadata)
        default:
            return KVoiceError(code: .aiHTTPError, retryable: status >= 500, metadata: metadata)
        }
    }

    private static func bodyMentionsAPIKey(_ body: Data) -> Bool {
        guard body.count <= 16 * 1024, let text = String(data: body, encoding: .utf8) else { return false }
        let folded = text.lowercased()
        return folded.contains("api key") || folded.contains("api_key") || folded.contains("apikey")
    }

    private func validateInput(request: AIProcessRequest, settings: AIEndpointSettings) throws {
        let model = request.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = request.polishPrompt
        guard request.rawTranscript.utf8.count <= AIProcessingLimits.maximumUTF8Bytes else {
            throw KVoiceError(code: .aiOversizedResponse, retryable: false)
        }
        // Context blocks share the transcript's ceiling so a huge clipboard
        // cannot turn one request into a megabyte upload.
        for block in [request.context.userProfile, request.context.clipboardText, request.context.selectedText] {
            guard (block?.utf8.count ?? 0) <= AIProcessingLimits.maximumUTF8Bytes else {
                throw KVoiceError(code: .aiOversizedResponse, retryable: false)
            }
        }
        guard !model.isEmpty,
              model.unicodeScalars.count <= 256,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 32 * 1024,
              settings.modelID.utf8.count <= AIProcessingLimits.maximumUTF8Bytes else {
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

    private static func makeRequestBody(
        request: AIProcessRequest,
        settings: AIEndpointSettings
    ) throws -> Data {
        // ADR-024: one composer for every provider, so the on-device client
        // sends exactly these two messages too.
        let messages = try AIPromptComposer.compose(request: request, settings: settings)
        let body = ChatCompletionsRequest(
            model: request.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: messages.systemPrompt),
                .init(role: "user", content: messages.userMessage)
            ],
            stream: false
        )
        let data = try JSONEncoder().encode(body)
        return data
    }

    // MARK: Transcript envelope (K.3, Appendix A1.2)

    // The envelope lives in `AIPromptComposer` (KvoiceDomain) since ADR-024;
    // these names stay so earlier callers and tests read unchanged.
    static let transcriptOpeningTag = AIPromptComposer.transcriptOpeningTag
    static let transcriptClosingTag = AIPromptComposer.transcriptClosingTag
    static let userProfileTag = AIPromptComposer.userProfileTag
    static let clipboardTag = AIPromptComposer.clipboardTag
    static let selectedTextTag = AIPromptComposer.selectedTextTag

    static func userMessage(for rawTranscript: String) -> String {
        AIPromptComposer.userMessage(for: rawTranscript)
    }

    static func userMessage(for rawTranscript: String, context: AIRequestContext) -> String {
        AIPromptComposer.userMessage(for: rawTranscript, context: context)
    }

    static func neutralizingTranscriptDelimiters(in transcript: String) -> String {
        AIPromptComposer.neutralizingTranscriptDelimiters(in: transcript)
    }

    private static func parseResponse(_ transportResponse: AITransportResponse) throws -> ParsedCompletion {
        guard let httpResponse = transportResponse.response as? HTTPURLResponse else {
            throw KVoiceError(code: .aiUnreachable)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.httpFailure(status: httpResponse.statusCode, body: transportResponse.data)
        }

        guard transportResponse.data.count <= AIProcessingLimits.maximumUTF8Bytes else {
            throw KVoiceError(code: .aiOversizedResponse, retryable: false)
        }
        if let mimeType = httpResponse.mimeType,
           !mimeType.lowercased().contains("json") {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false)
        }

        let decoded: ChatCompletionsResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: transportResponse.data)
        } catch {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false)
        }
        guard let choice = decoded.choices.first else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false)
        }
        guard let content = choice.message.content else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false)
        }
        let normalized = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else {
            throw KVoiceError(code: .aiEmptyResponse, retryable: false)
        }
        guard normalized.utf8.count <= AIProcessingLimits.maximumUTF8Bytes else {
            throw KVoiceError(code: .aiOversizedResponse, retryable: false)
        }
        guard !normalized.contains("<channel|>"),
              !normalized.contains("<|channel|>"),
              !Self.containsForbiddenControlCharacter(normalized)
        else {
            throw KVoiceError(code: .aiMalformedResponse, retryable: false)
        }
        return ParsedCompletion(text: normalized, responseID: decoded.id)
    }

    private static func containsForbiddenControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if value == 9 || value == 10 || value == 13 { return false }
            return (value <= 31) || (value >= 127 && value <= 159)
        }
    }
}

// `ConnectionTest` moved to KvoiceDomain with ADR-024 so the on-device client
// runs the same fixed request; `import KvoiceAI` still resolves the name.
public typealias ConnectionTest = KvoiceDomain.ConnectionTest

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionsResponse: Decodable {
    let id: String?
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessageResponse
}

private struct ChatMessageResponse: Decodable {
    let content: String?
}

private struct ParsedCompletion {
    let text: String
    let responseID: String?
}

// Names used by early callers and by the product language. They remain
// aliases so there is one implementation and one privacy boundary.
public typealias GenericAIProcessingClient = OpenAICompatibleAIProcessingClient
public typealias OpenAICompatibleAIClient = OpenAICompatibleAIProcessingClient
public typealias ChatCompletionsClient = OpenAICompatibleAIProcessingClient
