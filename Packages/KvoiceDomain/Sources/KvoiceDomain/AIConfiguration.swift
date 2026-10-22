import Foundation

/// A built-in provider preset, `custom` for a hand-entered endpoint,
/// `appleIntelligence` for the on-device model (ADR-024), or
/// `privateCloudCompute` for Apple's server model (ADR-027).
///
/// Presets supply a default base URL, whether a key is expected, a few
/// recommended models, and the two request scalars that differ between
/// providers (`AIRequestProfile`). Every endpoint provider is reached over the
/// same OpenAI-compatible path, so no provider-specific request code exists.
/// `appleIntelligence` is the one kind with a different `transport`: no
/// endpoint, no model id, no key — Apple's Foundation Models framework runs
/// the same prompts on this Mac, and the `KvoiceAppleIntelligence` adapter
/// is what serves it. `privateCloudCompute` is the third transport: the same
/// framework and adapter, but the request goes to Apple's Private Cloud
/// Compute over the network (ADR-027).
public enum AIProviderKind: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case ollama
    case openAI
    case gemini
    case openRouter
    // MARK: AI actions
    case anthropic
    case groq
    case cerebras
    case azureOpenAI
    case custom
    /// ADR-024: Apple's on-device language model through the Foundation
    /// Models framework (macOS 26+). Never a network request.
    case appleIntelligence
    /// ADR-027: Apple's server model on Private Cloud Compute, through the
    /// same framework (macOS 27+, App Store edition, entitled builds only).
    /// A network request to Apple, opt-in like every other configuration.
    case privateCloudCompute

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .groq: return "Groq"
        case .cerebras: return "Cerebras"
        case .azureOpenAI: return "Azure OpenAI"
        case .custom: return "Custom"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .privateCloudCompute: return "Apple Intelligence (Private Cloud Compute)"
        }
    }

    /// How a request for this kind leaves the app: over HTTP to an
    /// OpenAI-compatible endpoint, not at all (on-device), or through the
    /// framework to Apple's Private Cloud Compute (ADR-027).
    public var transport: AIProviderTransport {
        switch self {
        case .appleIntelligence: return .appleIntelligence
        case .privateCloudCompute: return .privateCloudCompute
        case .ollama, .openAI, .gemini, .openRouter, .anthropic, .groq, .cerebras, .azureOpenAI, .custom:
            return .openAICompatible
        }
    }

    /// The kinds the endpoint editor offers as a "Provider": every kind that
    /// needs a base URL and a model. `appleIntelligence` and
    /// `privateCloudCompute` are chosen as a configuration *type* instead,
    /// and have neither.
    public static var endpointKinds: [AIProviderKind] {
        allCases.filter { $0.transport == .openAICompatible }
    }

    /// The endpoint a preset starts from. `custom` and Azure have none by
    /// design: Azure's is built from the resource and deployment names.
    public var defaultBaseURL: URL? {
        switch self {
        case .ollama:
            return URL(string: "http://localhost:11434/v1")
        case .openAI:
            return URL(string: "https://api.openai.com/v1")
        case .gemini:
            // Gemini's OpenAI-compatible surface is not under /v1.
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1")
        case .anthropic:
            // Anthropic's OpenAI SDK compatibility layer. It takes the key as
            // a bearer token, like the OpenAI SDK sends it.
            return URL(string: "https://api.anthropic.com/v1")
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1")
        case .cerebras:
            return URL(string: "https://api.cerebras.ai/v1")
        case .azureOpenAI, .custom, .appleIntelligence, .privateCloudCompute:
            return nil
        }
    }

    /// Local servers accept requests without a key; hosted ones do not. Used
    /// only to warn, never to block — a self-hosted gateway may differ. The
    /// on-device model has no credential at all, so `SecretSettings` never
    /// gets an entry for it (rule 2 has nothing to protect here).
    public var expectsAPIKey: Bool {
        switch self {
        case .ollama, .appleIntelligence, .privateCloudCompute: return false
        case .openAI, .gemini, .openRouter, .anthropic, .groq, .cerebras, .azureOpenAI, .custom:
            return true
        }
    }

    /// Whether the user must supply the endpoint themselves.
    public var requiresManualBaseURL: Bool {
        self == .custom
    }

    /// Whether the endpoint is derived from a resource name and a deployment
    /// name rather than typed as a URL.
    public var usesAzureAddressing: Bool {
        self == .azureOpenAI
    }

    /// Whether the configuration sheet offers Fetch Models: the endpoint
    /// answers the OpenAI-compatible `GET /models` with the credential the
    /// client sends. Not Azure (a deployment is named in the portal, not
    /// listed), not Anthropic (its model list is the native API, which takes
    /// an `x-api-key` header this client never sends; the compatibility
    /// layer it does use documents no `/models`), and not the two Apple
    /// kinds (no endpoint, no model id).
    public var supportsModelListing: Bool {
        switch self {
        case .ollama, .openAI, .gemini, .openRouter, .groq, .cerebras, .custom:
            return true
        case .anthropic, .azureOpenAI, .appleIntelligence, .privateCloudCompute:
            return false
        }
    }

    /// A model to prefill so a new configuration is not empty.
    public var suggestedModelID: String {
        recommendedModels.first ?? ""
    }

    /// Models worth suggesting for the preset, cheapest and fastest first —
    /// the job is short-text cleanup and translation, and the first entry is
    /// the prefill. Fetch Models in the configuration sheet lists what the
    /// endpoint actually serves; these exist so a new configuration is usable
    /// without looking up a model name.
    ///
    /// Generally available IDs as of October 2026, from each provider's own
    /// list (no preview models):
    /// - OpenAI: https://developers.openai.com/api/docs/models
    /// - Gemini: https://ai.google.dev/gemini-api/docs/models (stable only)
    /// - Anthropic: https://platform.claude.com/docs/en/about-claude/models/overview
    /// - Groq: https://console.groq.com/docs/models (production only)
    /// - Cerebras: https://inference-docs.cerebras.ai/models/overview
    /// - OpenRouter: https://openrouter.ai/api/v1/models (its IDs use dots,
    ///   `anthropic/claude-haiku-5.5`, where Anthropic's own use hyphens)
    public var recommendedModels: [String] {
        switch self {
        case .ollama:
            return []
        case .openAI:
            return ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"]
        case .gemini:
            return ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.6-flash"]
        case .openRouter:
            // OpenRouter namespaces models by vendor; Fetch Models returns
            // hundreds, so a concrete default is more useful than an empty field.
            return ["openai/gpt-6-luna", "google/gemini-3.5-flash-lite", "anthropic/claude-haiku-5.5"]
        case .anthropic:
            return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .groq:
            return ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "llama-3.3-70b-versatile"]
        case .cerebras:
            return ["gpt-oss-120b", "qwen-3.8-27b"]
        case .azureOpenAI:
            // Azure addresses a deployment, not a model; the deployment name
            // is whatever the user chose in the portal.
            return []
        case .custom, .appleIntelligence, .privateCloudCompute:
            return []
        }
    }

    /// Where to obtain a key, shown next to the key field.
    public var credentialHint: String? {
        switch self {
        case .ollama: return "Ollama runs locally and normally needs no key."
        case .openAI: return "Create a key at platform.openai.com."
        case .gemini: return "Create a key at aistudio.google.com."
        case .openRouter: return "Create a key at openrouter.ai/keys."
        case .anthropic: return "Create a key at platform.claude.com."
        case .groq: return "Create a key at console.groq.com/keys."
        case .cerebras: return "Create a key at cloud.cerebras.ai."
        case .azureOpenAI: return "Use a key from your Azure OpenAI resource (Keys and Endpoint)."
        case .custom, .appleIntelligence, .privateCloudCompute: return nil
        }
    }

    /// The "Get API Key" link.
    public var apiKeyURL: URL? {
        switch self {
        case .ollama, .custom, .appleIntelligence, .privateCloudCompute: return nil
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai/")
        case .azureOpenAI: return URL(string: "https://portal.azure.com/")
        }
    }

    /// How the client authenticates this provider.
    public var requestProfile: AIRequestProfile {
        switch self {
        case .azureOpenAI:
            return AIRequestProfile(authStyle: .apiKeyHeader, apiVersion: Self.azureDefaultAPIVersion)
        default:
            return AIRequestProfile()
        }
    }

    public static let azureDefaultAPIVersion = "2024-10-21"

    /// Builds the Azure OpenAI chat endpoint for a resource and deployment:
    /// `https://<resource>.openai.azure.com/openai/deployments/<deployment>`.
    /// The client appends `/chat/completions` and `?api-version=`.
    public static func azureBaseURL(resource: String, deployment: String) -> URL? {
        let resourceName = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        let deploymentName = deployment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resourceName.isEmpty, !deploymentName.isEmpty,
              resourceName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let encodedDeployment = deploymentName.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
              )
        else {
            return nil
        }
        return URL(string: "https://\(resourceName).openai.azure.com/openai/deployments/\(encodedDeployment)")
    }
}

/// A saved endpoint the user can switch to from the menu bar.
///
/// The API key is not stored here: keys live in `SecretSettings`, keyed by this
/// configuration's `id`, so ordinary settings can be written to disk without ever
/// carrying a credential.
public struct AIConfiguration: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: URL?
    public var modelID: String
    // MARK: AI actions
    /// Copied into `AIEndpointSettings.requestProfile` when the configuration
    /// is applied. Defaults to the preset's profile; `custom` may pick either
    /// auth style.
    public var requestProfile: AIRequestProfile

    public init(
        id: UUID = UUID(),
        name: String,
        kind: AIProviderKind,
        baseURL: URL? = nil,
        modelID: String = "",
        requestProfile: AIRequestProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = modelID
        self.requestProfile = requestProfile ?? kind.requestProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelID
        case requestProfile
    }

    /// Explicit so configurations saved before `requestProfile` existed load
    /// with their preset's profile.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        // A provider this build does not know (written by a newer build)
        // loads as Custom with its URL intact rather than failing the file.
        let kindName = try values.decode(String.self, forKey: .kind)
        kind = AIProviderKind(rawValue: kindName) ?? .custom
        baseURL = try values.decodeIfPresent(URL.self, forKey: .baseURL)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        requestProfile = try values.decodeIfPresent(AIRequestProfile.self, forKey: .requestProfile)
            ?? kind.requestProfile
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        // ADR-024/027: an Apple configuration carries no endpoint fields at
        // all; the decoder's `decodeIfPresent ?? ""` reads it back.
        if kind.transport.needsEndpointFields || !modelID.isEmpty {
            try container.encode(modelID, forKey: .modelID)
        }
        if requestProfile != kind.requestProfile {
            try container.encode(requestProfile, forKey: .requestProfile)
        }
    }

    /// A new configuration seeded from its preset.
    public static func preset(_ kind: AIProviderKind, id: UUID = UUID()) -> Self {
        Self(
            id: id,
            name: kind.displayName,
            kind: kind,
            baseURL: kind.defaultBaseURL,
            modelID: kind.suggestedModelID
        )
    }

    /// Whether this configuration can actually be used for a request. The
    /// Apple kinds need no fields; whether a model is *available* right now
    /// is an environment fact (`EnvironmentProfile.appleIntelligenceAvailability`,
    /// `.privateCloudComputeAvailability`), not a property of the stored
    /// value.
    public var isUsable: Bool {
        if !kind.transport.needsEndpointFields { return true }
        guard let baseURL,
              !baseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Label for the menu bar; falls back to the model when unnamed.
    public var menuTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? kind.displayName : model
    }
}

extension AIConfiguration {
    /// UI v2 (Window.dc "Where AI runs": the This Mac / Cloud chip): whether
    /// a request stays on this Mac — the on-device model (ADR-024), or an
    /// endpoint whose host is loopback (`localhost`, `127.0.0.1`, `::1`),
    /// whatever its preset. Decided by the host, never by the kind: an
    /// Ollama preset pointed at another machine leaves this Mac, a Custom
    /// one on localhost does not. Private Cloud Compute (ADR-027) and an
    /// endpoint not filled in yet count as leaving it.
    public var runsOnThisMac: Bool {
        switch kind.transport {
        case .appleIntelligence:
            return true
        case .privateCloudCompute:
            return false
        case .openAICompatible:
            guard let host = baseURL?.host(percentEncoded: false) else { return false }
            let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
        }
    }
}
