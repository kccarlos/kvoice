import Foundation

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Identifiers and settings

public typealias JobID = UUID
public typealias HistoryEntryID = UUID
public typealias ModelID = String

public enum DictationMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case polish
    case translate

    public var aiMode: AIMode? {
        switch self {
        case .off: return nil
        case .polish: return .polish
        case .translate: return .translate
        }
    }
}

/// The subset of `DictationMode` that performs an AI request. Keeping this as a
/// distinct type makes `.processingAI` unable to represent the `.off` mode.
public enum AIMode: String, Codable, Sendable, Equatable, CaseIterable {
    case polish
    case translate

    public init?(dictationMode: DictationMode) {
        switch dictationMode {
        case .off: return nil
        case .polish: self = .polish
        case .translate: self = .translate
        }
    }

    public var dictationMode: DictationMode {
        switch self {
        case .polish: return .polish
        case .translate: return .translate
        }
    }
}

public enum RecordingInteraction: String, Codable, Sendable, Equatable, CaseIterable {
    case pushToTalk
    case toggle
    /// One key, two gestures: a quick tap (key-up within
    /// `TriggerSettings.hybridTapWindow`) starts a hands-free recording that
    /// the next tap stops; a press-and-hold is push-to-talk and the release
    /// stops. Product decision #5.
    case hybrid

    public var displayName: String {
        switch self {
        case .pushToTalk: return "Push-to-Talk"
        case .toggle: return "Toggle"
        case .hybrid: return "Hybrid"
        }
    }
}

public struct TargetApplicationSnapshot: Codable, Sendable, Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let capturedAt: Date

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?,
        capturedAt: Date
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.capturedAt = capturedAt
    }
}

public struct AudioRecording: Sendable, Equatable {
    public let id: UUID
    public let samples: ContiguousArray<Float>
    public let sampleRate: Double
    public let channelCount: Int
    public let duration: Duration
    public let peakLevelDBFS: Float
    public let clippedFrameCount: Int

    /// Audio at the transcription boundary is expected to be mono 16 kHz Float32.
    /// The immutable value keeps the boundary explicit; capture adapters validate this
    /// invariant before constructing a recording.
    public init(
        id: UUID = UUID(),
        samples: ContiguousArray<Float>,
        sampleRate: Double = 16_000,
        channelCount: Int = 1,
        duration: Duration,
        peakLevelDBFS: Float,
        clippedFrameCount: Int
    ) {
        self.id = id
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.peakLevelDBFS = peakLevelDBFS
        self.clippedFrameCount = clippedFrameCount
    }

    public var isEngineCompatible: Bool {
        sampleRate == 16_000 && channelCount == 1
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let start: Duration
    public let end: Duration
    public let text: String

    public init(start: Duration, end: Duration, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptionTimings: Sendable, Equatable {
    public let requestStart: ContinuousClock.Instant
    public let inferenceStart: ContinuousClock.Instant
    public let inferenceEnd: ContinuousClock.Instant
    public let runtimeReportedRealTimeFactor: Double?

    public init(
        requestStart: ContinuousClock.Instant,
        inferenceStart: ContinuousClock.Instant,
        inferenceEnd: ContinuousClock.Instant,
        runtimeReportedRealTimeFactor: Double?
    ) {
        self.requestStart = requestStart
        self.inferenceStart = inferenceStart
        self.inferenceEnd = inferenceEnd
        self.runtimeReportedRealTimeFactor = runtimeReportedRealTimeFactor
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let segments: [TranscriptSegment]
    public let timings: TranscriptionTimings
    public let modelID: ModelID

    public init(
        text: String,
        detectedLanguage: String?,
        segments: [TranscriptSegment],
        timings: TranscriptionTimings,
        modelID: ModelID
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
        self.timings = timings
        self.modelID = modelID
    }
}

public struct TranslationLanguage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let bcp47: String
    public let displayName: String

    public var id: String { bcp47 }

    public init(bcp47: String, displayName: String) {
        self.bcp47 = bcp47
        self.displayName = displayName
    }
}

public struct AIEndpointSettings: Codable, Sendable, Equatable {
    /// The request shape the AI stage runs, or `.off` for no request.
    ///
    /// Derived, not stored: `isEnabled` is the master switch and
    /// `defaultActionBehavior` is the shape of the default action. Reading
    /// `.off` here is the one condition the controller and client check, so it
    /// also folds in `canEnableProcessing` — an enabled switch with no endpoint
    /// never produces a request. The setter is kept for callers written
    /// against the older stored field: `.off` turns the switch off, anything
    /// else turns it on. The behavior follows the default action when one is
    /// set — a caller asking for `.polish` while the default action
    /// translates must not leave a translate prompt behind a polish request —
    /// and is recorded from the value only when no action is chosen.
    public var mode: DictationMode {
        get {
            guard isEnabled, canEnableProcessing else { return .off }
            return defaultActionBehavior.dictationMode
        }
        set {
            if let behavior = newValue.aiMode {
                isEnabled = true
                defaultActionBehavior = activePromptMode?.behavior ?? behavior
            } else {
                isEnabled = false
            }
        }
    }

    public var baseURL: URL?
    public var modelID: String
    public var promptConfiguration: PromptConfiguration
    public var translationLanguage: TranslationLanguage

    /// Saved endpoints the user can switch between from the menu bar.
    ///
    /// `baseURL`/`modelID` above remain the single source of truth for a
    /// request; selecting a configuration copies its values into them. Keeping the
    /// request path unaware of configurations means the client, validation, and the
    /// active-job snapshot are all unchanged.
    public var configurations: [AIConfiguration]

    /// The configuration whose values were last applied, for UI selection state.
    public var activeConfigurationID: UUID?

    /// Named prompts the user can switch between from the menu bar.
    ///
    /// Like configurations, a mode is applied by copying its values into the
    /// fields above, so the request path never needs to know modes exist.
    public var promptModes: [PromptMode]

    /// The default action: the prompt mode applied after every transcription
    /// while `isEnabled` is on.
    public var activePromptModeID: UUID?

    // MARK: AI actions

    /// Master switch for AI post-processing, independent of which action is
    /// chosen (product decision #6). Off means no request is ever made; the
    /// chosen default action is remembered for when it is turned back on.
    public var isEnabled: Bool

    /// Request shape of the default action. Recorded by `apply(promptMode:)`
    /// and by the legacy `mode` setter; only meaningful while `isEnabled`.
    public private(set) var defaultActionBehavior: AIMode

    /// How the client authenticates the live endpoint and whether it must
    /// append an API version. Copied from the active configuration, so the
    /// client reads a scalar rather than learning about providers.
    public var requestProfile: AIRequestProfile

    /// ADR-024: where the live request goes — the OpenAI-compatible endpoint
    /// in `baseURL`/`modelID`, or Apple's on-device model, which needs
    /// neither. Copied from the active configuration's kind like
    /// `requestProfile`; the routing client reads this one scalar. Absent in
    /// settings written before the on-device kind existed, which decode as
    /// `.openAICompatible`.
    public var provider: AIProviderTransport

    /// When on, a transcript that begins with one of an action's trigger
    /// words runs that action instead of the default (`ActionTriggerResolver`).
    public var actionTriggersEnabled: Bool

    /// Optional free-text context about the user (name, role, tech stack…)
    /// included in every request when non-empty. Never a secret.
    public var userProfile: String

    /// Prompt-mode ids bound to the three Selection Action shortcut slots.
    /// Always `selectionActionSlotCount` entries; `nil` means the slot is unbound.
    public var selectionActionSlots: [UUID?]

    public static let selectionActionSlotCount = 3

    /// Upper bound on the user profile, so a pasted document cannot become
    /// part of every request.
    public static let userProfileMaximumCharacters = 500

    public init(
        mode: DictationMode = .off,
        baseURL: URL? = nil,
        modelID: String = "",
        promptConfiguration: PromptConfiguration = .init(),
        translationLanguage: TranslationLanguage = .init(bcp47: "en", displayName: "English"),
        configurations: [AIConfiguration] = [],
        activeConfigurationID: UUID? = nil,
        promptModes: [PromptMode] = [],
        activePromptModeID: UUID? = nil,
        // MARK: AI actions
        isEnabled: Bool? = nil,
        requestProfile: AIRequestProfile = .init(),
        provider: AIProviderTransport = .openAICompatible,
        actionTriggersEnabled: Bool = false,
        userProfile: String = "",
        selectionActionSlots: [UUID?] = []
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.promptConfiguration = promptConfiguration
        self.translationLanguage = translationLanguage
        self.configurations = configurations
        self.activeConfigurationID = activeConfigurationID
        self.promptModes = promptModes
        self.activePromptModeID = activePromptModeID
        // `mode` remains the older spelling of the same intent; an explicit
        // `isEnabled` wins over it.
        self.isEnabled = isEnabled ?? (mode != .off)
        defaultActionBehavior = mode.aiMode ?? .polish
        self.requestProfile = requestProfile
        self.provider = provider
        self.actionTriggersEnabled = actionTriggersEnabled
        self.userProfile = userProfile
        self.selectionActionSlots = Self.normalizedSlots(selectionActionSlots)
    }

    /// Copies a mode's prompt and semantics into the live request fields.
    ///
    /// The prompt copied is the mode's *effective* prompt: the house template
    /// around the user's instructions when the mode asks for it, plus any
    /// mode-settings addenda (formal writing, second translation, …). The
    /// request path keeps reading one system prompt.
    public mutating func apply(promptMode: PromptMode) {
        defaultActionBehavior = promptMode.behavior
        switch promptMode.behavior {
        case .polish:
            promptConfiguration.polishPrompt = promptMode.effectiveSystemPrompt
        case .translate:
            promptConfiguration.translatePrompt = promptMode.effectiveSystemPrompt
            if let language = promptMode.translationLanguage {
                translationLanguage = language
            }
        }
        activePromptModeID = promptMode.id
    }

    public var activePromptMode: PromptMode? {
        guard let activePromptModeID else { return nil }
        return promptModes.first { $0.id == activePromptModeID }
    }

    /// Seeds the shipped modes the first time, leaving any the user already has.
    public mutating func seedBuiltInPromptModesIfNeeded() {
        guard promptModes.isEmpty else { return }
        promptModes = BuiltInPromptModes.all
    }

    /// Copies a saved configuration into the active endpoint fields.
    public mutating func apply(configuration: AIConfiguration) {
        baseURL = configuration.baseURL
        modelID = configuration.modelID
        requestProfile = configuration.requestProfile
        provider = configuration.kind.transport
        activeConfigurationID = configuration.id
    }

    public var activeConfiguration: AIConfiguration? {
        guard let activeConfigurationID else { return nil }
        return configurations.first { $0.id == activeConfigurationID }
    }

    /// The prompt mode bound to a Selection Action slot (0-based), if any.
    public func selectionAction(slot: Int) -> PromptMode? {
        guard selectionActionSlots.indices.contains(slot),
              let id = selectionActionSlots[slot]
        else {
            return nil
        }
        return promptModes.first { $0.id == id }
    }

    public mutating func bindSelectionAction(_ modeID: UUID?, slot: Int) {
        guard selectionActionSlots.indices.contains(slot) else { return }
        selectionActionSlots[slot] = modeID
    }

    private static func normalizedSlots(_ slots: [UUID?]) -> [UUID?] {
        var normalized = Array(slots.prefix(selectionActionSlotCount))
        while normalized.count < selectionActionSlotCount { normalized.append(nil) }
        return normalized
    }

    /// Written explicitly because `CodingKeys` carries read-only legacy names,
    /// which blocks synthesis. Only current keys are emitted, and empty
    /// collections are omitted so settings.json stays minimal.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(promptConfiguration, forKey: .promptConfiguration)
        try container.encode(translationLanguage, forKey: .translationLanguage)
        if !configurations.isEmpty {
            try container.encode(configurations, forKey: .configurations)
        }
        try container.encodeIfPresent(activeConfigurationID, forKey: .activeConfigurationID)
        if !promptModes.isEmpty {
            try container.encode(promptModes, forKey: .promptModes)
        }
        try container.encodeIfPresent(activePromptModeID, forKey: .activePromptModeID)
        // MARK: AI actions
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(defaultActionBehavior, forKey: .defaultActionBehavior)
        if requestProfile != AIRequestProfile() {
            try container.encode(requestProfile, forKey: .requestProfile)
        }
        if provider != .openAICompatible {
            try container.encode(provider, forKey: .provider)
        }
        if actionTriggersEnabled {
            try container.encode(actionTriggersEnabled, forKey: .actionTriggersEnabled)
        }
        if !userProfile.isEmpty {
            try container.encode(userProfile, forKey: .userProfile)
        }
        if selectionActionSlots.contains(where: { $0 != nil }) {
            try container.encode(selectionActionSlots, forKey: .selectionActionSlots)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case baseURL
        case modelID
        case promptConfiguration
        case translationLanguage
        case configurations
        case activeConfigurationID
        // Accepted on read only. These were the key names before the feature
        // was renamed from "provider profiles" to "AI configurations"; the
        // strict decoder rejects unknown keys, so settings written under the
        // old names must still load. Never written.
        case legacyConfigurations = "profiles"
        case legacyActiveConfigurationID = "activeProfileID"
        case promptModes
        case activePromptModeID
        // MARK: AI actions
        case isEnabled
        case defaultActionBehavior
        case requestProfile
        case provider
        case actionTriggersEnabled
        case userProfile
        case selectionActionSlots
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let allValues = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknownKeys = allValues.allKeys.filter { key in
            !CodingKeys.allCases.contains { $0.stringValue == key.stringValue }
        }
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: values,
                debugDescription: "AI settings contain unsupported keys"
            )
        }
        // FR-AI-002: a persisted mode this build does not know (a value written
        // by a newer or older build, or hand-edited) maps to Off rather than
        // failing the whole settings file, which would silently discard every
        // other setting the user has.
        let modeName = try values.decodeIfPresent(String.self, forKey: .mode)
        let decodedMode = modeName.flatMap(DictationMode.init(rawValue:)) ?? .off
        baseURL = try values.decodeIfPresent(URL.self, forKey: .baseURL)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        promptConfiguration = try values.decodeIfPresent(PromptConfiguration.self, forKey: .promptConfiguration) ?? .init()
        translationLanguage = try values.decodeIfPresent(TranslationLanguage.self, forKey: .translationLanguage)
            ?? .init(bcp47: "en", displayName: "English")
        // Absent in settings written before AI configurations existed; the
        // legacy keys cover settings written under the earlier name.
        configurations = try values.decodeIfPresent(
            [AIConfiguration].self,
            forKey: .configurations
        ) ?? values.decodeIfPresent(
            [AIConfiguration].self,
            forKey: .legacyConfigurations
        ) ?? []
        activeConfigurationID = try values.decodeIfPresent(
            UUID.self,
            forKey: .activeConfigurationID
        ) ?? values.decodeIfPresent(UUID.self, forKey: .legacyActiveConfigurationID)
        // Absent before prompt modes existed; seeded on first load by the caller.
        promptModes = try values.decodeIfPresent([PromptMode].self, forKey: .promptModes) ?? []
        activePromptModeID = try values.decodeIfPresent(UUID.self, forKey: .activePromptModeID)

        // MARK: AI actions
        // Settings written before the master switch existed carry only
        // `mode`: anything but Off meant enabled. A file that has the switch
        // keeps it even when the endpoint is incomplete — `mode` reads Off
        // until a configuration is added, which is the FR-SET-002 sanitizing
        // this decoder used to do by hand (see "Two traps" in Architecture.md).
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? (decodedMode != .off)
        defaultActionBehavior = try values.decodeIfPresent(AIMode.self, forKey: .defaultActionBehavior)
            ?? decodedMode.aiMode
            ?? .polish
        requestProfile = try values.decodeIfPresent(AIRequestProfile.self, forKey: .requestProfile) ?? .init()
        // ADR-024: absent before the on-device kind existed; a transport this
        // build does not know reads as the endpoint one so the file loads.
        let providerName = try values.decodeIfPresent(String.self, forKey: .provider)
        let decodedProvider = providerName.flatMap(AIProviderTransport.init(rawValue:)) ?? .openAICompatible
        // An Apple transport needs no endpoint fields, so it must not
        // outlive its configuration: a file (imported, hand-edited, or
        // written by a build that let it slip) whose active configuration is
        // not of that transport reads as the endpoint transport, where the
        // empty fields mean "not configured". ADR-027: this is also what
        // keeps Private Cloud Compute from ever being selected by a file —
        // it is live only while a Private Cloud Compute configuration the
        // user created is the active one. The view model keeps the same
        // invariant when the active Apple configuration is deleted.
        let decodedConfigurations = configurations
        let decodedActiveID = activeConfigurationID
        let activeKind = decodedConfigurations.first { $0.id == decodedActiveID }?.kind
        provider = !decodedProvider.needsEndpointFields && activeKind?.transport != decodedProvider
            ? .openAICompatible
            : decodedProvider
        actionTriggersEnabled = try values.decodeIfPresent(Bool.self, forKey: .actionTriggersEnabled) ?? false
        userProfile = try values.decodeIfPresent(String.self, forKey: .userProfile) ?? ""
        selectionActionSlots = Self.normalizedSlots(
            try values.decodeIfPresent([UUID?].self, forKey: .selectionActionSlots) ?? []
        )
    }

    /// True when the endpoint fields are complete enough for a request. The
    /// `mode` getter folds this in, so an enabled switch with no endpoint
    /// reads Off; the UI uses it to show the "add a configuration" call-out.
    /// The Apple providers (ADR-024, ADR-027) have no endpoint fields, so
    /// they are always complete here; whether it is *available* is an environment
    /// fact the availability projection reads, and a request while it is not
    /// fails into the ordinary raw-transcript fallback.
    public static func canEnableProcessing(
        baseURL: URL?,
        modelID: String,
        provider: AIProviderTransport = .openAICompatible
    ) -> Bool {
        if !provider.needsEndpointFields { return true }
        guard let baseURL,
              !baseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canEnableProcessing: Bool {
        Self.canEnableProcessing(baseURL: baseURL, modelID: modelID, provider: provider)
    }
}

/// How the client must authenticate and address the live endpoint. Every
/// provider still speaks OpenAI-compatible Chat Completions; these are the two
/// scalars that differ (Azure OpenAI wants an `api-key` header and an
/// `api-version` query, everything else a bearer token).
public struct AIRequestProfile: Codable, Sendable, Equatable, Hashable {
    public var authStyle: AIProviderAuthStyle
    /// Appended as `?api-version=` to every request when set. Only Azure uses it.
    public var apiVersion: String?

    public init(authStyle: AIProviderAuthStyle = .bearer, apiVersion: String? = nil) {
        self.authStyle = authStyle
        self.apiVersion = apiVersion
    }

    private enum CodingKeys: String, CodingKey {
        case authStyle
        case apiVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        authStyle = try values.decodeIfPresent(AIProviderAuthStyle.self, forKey: .authStyle) ?? .bearer
        apiVersion = try values.decodeIfPresent(String.self, forKey: .apiVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authStyle, forKey: .authStyle)
        try container.encodeIfPresent(apiVersion, forKey: .apiVersion)
    }
}

public enum AIProviderAuthStyle: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// `Authorization: Bearer <key>` — OpenAI, Ollama, Gemini, OpenRouter,
    /// Groq, Cerebras, and Anthropic's OpenAI-compatible surface.
    case bearer
    /// `api-key: <key>` — Azure OpenAI.
    case apiKeyHeader
}

public struct SecretSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int

    /// The key for the currently applied endpoint. Kept as the value the client
    /// actually sends, so the request path is unaware of configurations.
    public var apiKey: String?

    /// Per-configuration keys, so switching providers in the menu bar does not
    /// require retyping a credential. Keyed by `AIConfiguration.id`.
    public var configurationAPIKeys: [String: String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case apiKey = "openAICompatibleAPIKey"
        // Deliberately keeps the original on-disk name: renaming the Swift
        // property should not invalidate a secrets file that already holds keys.
        case configurationAPIKeys = "profileAPIKeys"
    }

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = 1,
        apiKey: String? = nil,
        configurationAPIKeys: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.apiKey = apiKey
        self.configurationAPIKeys = configurationAPIKeys
    }

    public func apiKey(for configurationID: UUID) -> String? {
        let value = configurationAPIKeys[configurationID.uuidString]
        return value?.isEmpty == true ? nil : value
    }

    public mutating func setAPIKey(_ key: String?, for configurationID: UUID) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            configurationAPIKeys[configurationID.uuidString] = trimmed
        } else {
            configurationAPIKeys.removeValue(forKey: configurationID.uuidString)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let allValues = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknownKeys = allValues.allKeys.filter { key in
            !CodingKeys.allCases.contains { $0.stringValue == key.stringValue }
        }
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Secrets contain unsupported keys"
            )
        }

        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Secrets schema is unsupported"
            )
        }

        schemaVersion = version
        let decodedKey = try values.decodeIfPresent(String.self, forKey: .apiKey)
        apiKey = decodedKey?.isEmpty == true ? nil : decodedKey
        // Absent in secrets written before per-configuration keys existed.
        configurationAPIKeys = try values.decodeIfPresent(
            [String: String].self,
            forKey: .configurationAPIKeys
        ) ?? [:]
    }

    /// Written explicitly so an empty configuration-key map is omitted rather than
    /// serialized as `{}`. The on-disk shape is a tested contract, and a user
    /// with no per-configuration keys should get byte-identical output to before.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(apiKey, forKey: .apiKey)
        if !configurationAPIKeys.isEmpty {
            try container.encode(configurationAPIKeys, forKey: .configurationAPIKeys)
        }
    }
}

public enum ModelReference: Codable, Sendable, Equatable {
    case managed(modelID: ModelID, revision: String)
    case external(path: String, expectedModelID: ModelID, expectedRevision: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case modelID
        case revision
        case path
        case expectedModelID
        case expectedRevision
    }

    private enum Kind: String, Codable {
        case managed
        case external
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        switch kind {
        case .managed:
            self = .managed(
                modelID: try values.decode(String.self, forKey: .modelID),
                revision: try values.decode(String.self, forKey: .revision)
            )
        case .external:
            self = .external(
                path: try values.decode(String.self, forKey: .path),
                expectedModelID: try values.decode(String.self, forKey: .expectedModelID),
                expectedRevision: try values.decode(String.self, forKey: .expectedRevision)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .managed(let modelID, let revision):
            try values.encode(Kind.managed, forKey: .kind)
            try values.encode(modelID, forKey: .modelID)
            try values.encode(revision, forKey: .revision)
        case .external(let path, let expectedModelID, let expectedRevision):
            try values.encode(Kind.external, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(expectedModelID, forKey: .expectedModelID)
            try values.encode(expectedRevision, forKey: .expectedRevision)
        }
    }
}

/// Settings › General › Interface language (product decision #9). The value is
/// persisted here; the app shell mirrors it into the process's
/// `AppleLanguages` default and relaunches, because AppKit menus and hosted
/// SwiftUI do not re-localize in place (Docs/Architecture.md, "Localization").
public enum InterfaceLanguage: String, Codable, Sendable, Equatable, CaseIterable {
    /// Follow the macOS language list (the `AppleLanguages` override is
    /// removed).
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// The identifier written to `AppleLanguages`; nil for `.system`, which
    /// removes the override. The raw values double as the identifiers so a
    /// new language is one case plus its `<code>.lproj`.
    public var languageIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

/// The user's preferences (ADR-022 item 1: the second of the four
/// configuration sources). Everything here is exportable by construction —
/// `SettingsBackupEnvelope` wraps the whole value — so a field that describes
/// *this Mac's past* rather than a choice (onboarding completion, the tutorial
/// flag, the main window's section, the export-folder grant) does not belong
/// here: it is `LocalState`, a separate blob. A settings file written before
/// the 2026-09-16 split still carries those keys; the decoder ignores them
/// and `LocalStateStore` migrated them once.
public struct AppSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var showDockIcon: Bool
    public var launchAtLogin: Bool
    public var recordingInteraction: RecordingInteraction
    public var shortcut: ShortcutDefinition?
    public var selectedModel: ModelReference?
    public var ai: AIEndpointSettings
    public var historyEnabled: Bool
    public var maxRecordingSeconds: Int
    /// Third insertion tier for targets whose focused text element is not
    /// writable through Accessibility (terminals): Unicode keyboard events
    /// posted to the target process. Never touches the pasteboard.
    public var typedInsertionEnabled: Bool
    // MARK: Recorder
    /// Settings › Recording › Recorder style (ADR-021): the floating pill or
    /// the shape under the camera housing. Captured per job like the other
    /// recording settings.
    public var recorderStyle: HUDStyle
    // MARK: Speech models (ADR-017)
    /// Catalog ID of the model dictation uses. `nil` means the catalog's
    /// recommended entry.
    public var defaultSpeechModelID: ModelID?
    /// Whisper language code passed to the runtime as a hint; `nil` means
    /// auto-detect (FR-STT-003 as amended by ADR-017).
    public var transcriptionLanguage: String?
    /// Streaming or batch, per catalog ID. A missing entry is batch.
    public var speechModelModes: [ModelID: SpeechTranscriptionMode]
    /// Manage Models gear: append one space after an inserted transcript.
    public var addSpaceAfterInsertion: Bool
    /// Manage Models gear: reserved hook for automatic text formatting.
    public var automaticTextFormatting: Bool
    /// Manage Models gear: let the streaming session cut its window at
    /// silences. Segmentation only; it never ends a recording (FR-AUD-007).
    public var voiceActivityDetectionEnabled: Bool

    // MARK: Runtime
    /// Compute devices the resident speech model may use (Speech Models ›
    /// Runtime). Changing it reloads the model; the default is WhisperKit's.
    public var speechComputeUnits: SpeechComputeUnits

    // MARK: Memory
    /// Later waves: memory-pressure warnings. Off by default — unloading the
    /// resident model is always offered under critical pressure ("Unload
    /// model now"), but doing it automatically, without being asked, is
    /// opt-in only. Lives in General (not Recording): it is a background
    /// resource-management behavior like Launch at Login, not something that
    /// changes what a recording does.
    public var freeModelMemoryUnderCriticalPressure: Bool

    // MARK: App shell

    /// Interface language override (product decision #9). `.system` unless the
    /// user picked one in General.
    public var interfaceLanguage: InterfaceLanguage

    // MARK: Triggers and audio
    /// Cancel/append shortcuts, auto-send, and the middle mouse trigger.
    public var triggers: TriggerSettings
    /// Sound cues, output muting, and clipboard preservation.
    public var recordingFeedback: RecordingFeedbackSettings
    /// Which microphone to record from.
    public var audioInput: AudioInputSettings
    // MARK: History and data
    /// Age-based deletion of transcript rows (Data & Privacy).
    public var historyRetention: HistoryRetentionSettings
    /// Opt-in stored audio for playback and Retranscribe (decision #1).
    public var audioStorage: AudioStorageSettings
    /// Auto Daily Export folder and toggle.
    public var export: ExportSettings
    // MARK: Dictionary
    /// Terms fed to the speech model as its initial prompt (ADR-018).
    public var dictionary: DictionarySettings

    public init(
        schemaVersion: Int = 1,
        showDockIcon: Bool = false,
        launchAtLogin: Bool = false,
        recordingInteraction: RecordingInteraction = .pushToTalk,
        shortcut: ShortcutDefinition? = nil,
        selectedModel: ModelReference? = nil,
        ai: AIEndpointSettings = .init(),
        historyEnabled: Bool = true,
        maxRecordingSeconds: Int = 600,
        typedInsertionEnabled: Bool = true,
        // MARK: Recorder
        recorderStyle: HUDStyle = .mini,
        // MARK: Speech models (ADR-017)
        defaultSpeechModelID: ModelID? = nil,
        transcriptionLanguage: String? = nil,
        speechModelModes: [ModelID: SpeechTranscriptionMode] = [:],
        addSpaceAfterInsertion: Bool = false,
        automaticTextFormatting: Bool = false,
        voiceActivityDetectionEnabled: Bool = true,
        // MARK: Runtime
        speechComputeUnits: SpeechComputeUnits = .default,
        // MARK: Memory
        freeModelMemoryUnderCriticalPressure: Bool = false,
        // MARK: App shell
        interfaceLanguage: InterfaceLanguage = .system,
        // MARK: Triggers and audio
        triggers: TriggerSettings = .init(),
        recordingFeedback: RecordingFeedbackSettings = .init(),
        audioInput: AudioInputSettings = .init(),
        // MARK: History and data
        historyRetention: HistoryRetentionSettings = .init(),
        audioStorage: AudioStorageSettings = .init(),
        export: ExportSettings = .init(),
        // MARK: Dictionary
        dictionary: DictionarySettings = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.recordingInteraction = recordingInteraction
        self.shortcut = shortcut
        self.selectedModel = selectedModel
        self.ai = ai
        self.historyEnabled = historyEnabled
        self.maxRecordingSeconds = maxRecordingSeconds
        self.typedInsertionEnabled = typedInsertionEnabled
        // MARK: Recorder
        self.recorderStyle = recorderStyle
        // MARK: Speech models (ADR-017)
        self.defaultSpeechModelID = defaultSpeechModelID
        self.transcriptionLanguage = transcriptionLanguage
        self.speechModelModes = speechModelModes
        self.addSpaceAfterInsertion = addSpaceAfterInsertion
        self.automaticTextFormatting = automaticTextFormatting
        self.voiceActivityDetectionEnabled = voiceActivityDetectionEnabled
        // MARK: Runtime
        self.speechComputeUnits = speechComputeUnits
        // MARK: Memory
        self.freeModelMemoryUnderCriticalPressure = freeModelMemoryUnderCriticalPressure
        // MARK: App shell
        self.interfaceLanguage = interfaceLanguage
        // MARK: Triggers and audio
        self.triggers = triggers
        self.recordingFeedback = recordingFeedback
        self.audioInput = audioInput
        // MARK: History and data
        self.historyRetention = historyRetention
        self.audioStorage = audioStorage
        self.export = export
        // MARK: Dictionary
        self.dictionary = dictionary
    }

    /// The picker's view of `maxRecordingSeconds` (product decision #10).
    public var recordingDurationLimit: RecordingDurationLimit {
        get { RecordingDurationLimit(seconds: maxRecordingSeconds) }
        set { maxRecordingSeconds = newValue.seconds }
    }

    public static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case showDockIcon
        case launchAtLogin
        case recordingInteraction
        case shortcut
        case selectedModel
        case ai
        case historyEnabled
        case maxRecordingSeconds
        case typedInsertionEnabled
        // MARK: Recorder
        case recorderStyle
        // MARK: Speech models (ADR-017)
        case defaultSpeechModelID
        case transcriptionLanguage
        case speechModelModes
        case addSpaceAfterInsertion
        case automaticTextFormatting
        case voiceActivityDetectionEnabled
        // MARK: Runtime
        case speechComputeUnits
        // MARK: Memory
        case freeModelMemoryUnderCriticalPressure
        // MARK: App shell
        case interfaceLanguage
        // MARK: Triggers and audio
        case triggers
        case recordingFeedback
        case audioInput
        // MARK: History and data
        case historyRetention
        case audioStorage
        case export
        // MARK: Dictionary
        case dictionary
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Settings schema is newer than this app"
            )
        }

        schemaVersion = version
        showDockIcon = try values.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        recordingInteraction = try values.decodeIfPresent(RecordingInteraction.self, forKey: .recordingInteraction) ?? .pushToTalk
        shortcut = try values.decodeIfPresent(ShortcutDefinition.self, forKey: .shortcut)
        selectedModel = try values.decodeIfPresent(ModelReference.self, forKey: .selectedModel)
        ai = try values.decodeIfPresent(AIEndpointSettings.self, forKey: .ai) ?? .init()
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        maxRecordingSeconds = try values.decodeIfPresent(Int.self, forKey: .maxRecordingSeconds) ?? 600
        typedInsertionEnabled = try values.decodeIfPresent(Bool.self, forKey: .typedInsertionEnabled) ?? true
        // MARK: Recorder
        recorderStyle = try values.decodeIfPresent(HUDStyle.self, forKey: .recorderStyle) ?? .mini
        // MARK: Speech models (ADR-017)
        defaultSpeechModelID = try values.decodeIfPresent(ModelID.self, forKey: .defaultSpeechModelID)
        transcriptionLanguage = try values.decodeIfPresent(String.self, forKey: .transcriptionLanguage)
        speechModelModes = try values.decodeIfPresent(
            [ModelID: SpeechTranscriptionMode].self,
            forKey: .speechModelModes
        ) ?? [:]
        addSpaceAfterInsertion = try values.decodeIfPresent(Bool.self, forKey: .addSpaceAfterInsertion) ?? false
        automaticTextFormatting = try values.decodeIfPresent(Bool.self, forKey: .automaticTextFormatting) ?? false
        voiceActivityDetectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceActivityDetectionEnabled) ?? true
        // MARK: Runtime
        speechComputeUnits = try values.decodeIfPresent(SpeechComputeUnits.self, forKey: .speechComputeUnits) ?? .default
        // MARK: Memory
        freeModelMemoryUnderCriticalPressure = try values.decodeIfPresent(Bool.self, forKey: .freeModelMemoryUnderCriticalPressure) ?? false
        // MARK: App shell
        interfaceLanguage = try values.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? .system
        // MARK: History and data
        historyRetention = try values.decodeIfPresent(HistoryRetentionSettings.self, forKey: .historyRetention) ?? .init()
        audioStorage = try values.decodeIfPresent(AudioStorageSettings.self, forKey: .audioStorage) ?? .init()
        export = try values.decodeIfPresent(ExportSettings.self, forKey: .export) ?? .init()
        // The ceiling is the "No limit" technical bound (product decision #10),
        // not the old fixed 600 s.
        guard (1...RecordingDurationLimit.technicalCeilingSeconds).contains(maxRecordingSeconds) else {
            throw DecodingError.dataCorruptedError(
                forKey: .maxRecordingSeconds,
                in: values,
                debugDescription: "Recording duration is outside the supported range"
            )
        }
        // MARK: Triggers and audio
        triggers = try values.decodeIfPresent(TriggerSettings.self, forKey: .triggers) ?? .init()
        recordingFeedback = try values.decodeIfPresent(RecordingFeedbackSettings.self, forKey: .recordingFeedback) ?? .init()
        audioInput = try values.decodeIfPresent(AudioInputSettings.self, forKey: .audioInput) ?? .init()
        // MARK: Dictionary
        dictionary = try values.decodeIfPresent(DictionarySettings.self, forKey: .dictionary) ?? .init()
    }
}

/// The outcome of the optional AI stage for one history row (J.5 `ai_status`).
///
/// `.cancelledFallback` is the user pressing Escape while the provider request
/// was in flight; the raw transcript was inserted instead.  In every case other
/// than `.succeeded`, `rawText == finalText`.
public enum HistoryAIStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case succeeded
    case failed
    case cancelledFallback
}

/// One completed dictation, written after the insertion outcome is known
/// (FR-HIST-002, FR-HIST-006).  It deliberately has no credential,
/// bundle-identifier, or field-content property: `targetClass` is a role
/// class such as `"textArea"` (or `"file"` for a transcribed media file),
/// never a bundle ID or the target's text.  Audio is never embedded; with
/// stored audio opted in (decision #1) a row carries only the relative path
/// of its WAV file.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: HistoryEntryID
    public let createdAt: Date
    public private(set) var rawText: String
    public private(set) var finalText: String
    public let mode: DictationMode
    public let insertionOutcome: InsertionOutcome
    public let errorCode: KVoiceErrorCode?
    /// The speech-to-text model that produced `rawText`.
    public let modelID: ModelID
    /// BCP-47 target language when `mode == .translate`.
    public let translationTarget: String?
    public let sttDurationMilliseconds: Int?
    public let aiStatus: HistoryAIStatus
    /// Role class of the insertion target (for example `"textArea"`).
    public let targetClass: String?
    public let appVersion: String
    // MARK: History and data
    /// Length of the recording that produced `rawText`.  Drives the duration
    /// filter, the words-per-minute tile, and the detail badge.
    public let recordingDurationMilliseconds: Int?
    /// Wall time of the AI request when `aiStatus == .succeeded`.
    public let aiDurationMilliseconds: Int?
    /// Relative path of the stored recording (`Audio/<id>.wav`) under the
    /// History folder when the user opted in; `nil` otherwise.
    public private(set) var audioPath: String?

    public init(
        id: HistoryEntryID = UUID(),
        createdAt: Date,
        rawText: String,
        finalText: String,
        mode: DictationMode,
        insertionOutcome: InsertionOutcome,
        errorCode: KVoiceErrorCode? = nil,
        modelID: ModelID = "",
        translationTarget: String? = nil,
        sttDurationMilliseconds: Int? = nil,
        aiStatus: HistoryAIStatus = .off,
        targetClass: String? = nil,
        appVersion: String = "",
        // MARK: History and data
        recordingDurationMilliseconds: Int? = nil,
        aiDurationMilliseconds: Int? = nil,
        audioPath: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.mode = mode
        self.insertionOutcome = insertionOutcome
        self.errorCode = errorCode
        self.modelID = modelID
        self.translationTarget = translationTarget
        self.sttDurationMilliseconds = sttDurationMilliseconds
        self.aiStatus = aiStatus
        self.targetClass = targetClass
        self.appVersion = appVersion
        // MARK: History and data
        self.recordingDurationMilliseconds = recordingDurationMilliseconds
        self.aiDurationMilliseconds = aiDurationMilliseconds
        self.audioPath = audioPath
    }

    // MARK: History and data

    /// `targetClass` of a row produced by "Transcribe File…" rather than a
    /// dictation.  Such rows insert nothing (`insertionOutcome` is
    /// `.deliveredInApp`).
    public static let fileTargetClass = "file"

    /// Words in `finalText`, segmented by the text system.
    public var wordCount: Int {
        TranscriptMetrics.wordCount(of: finalText)
    }

    /// Whether the Enhanced tab has anything to show: AI ran, succeeded, and
    /// changed the text.
    public var hasDistinctEnhancedText: Bool {
        aiStatus == .succeeded && finalText != rawText
    }

    public var isFileTranscription: Bool {
        targetClass == Self.fileTargetClass
    }

    /// The same row with the transcript replaced (Retranscribe).  Audio,
    /// timing, and provenance are kept; `finalText` follows `rawText` when AI
    /// had not changed it.
    public func replacingRawText(_ newRawText: String) -> HistoryEntry {
        var copy = self
        copy.rawText = newRawText
        if !hasDistinctEnhancedText {
            copy.finalText = newRawText
        }
        return copy
    }

    /// The same row without its audio reference (audio retention expired or
    /// the file was removed).
    public func removingAudio() -> HistoryEntry {
        var copy = self
        copy.audioPath = nil
        return copy
    }

    /// True when the row did not take the happy path: the AI stage failed or
    /// was cancelled, or insertion fell back to the clipboard.  The History
    /// UI shows this as a fallback badge.
    public var isFallback: Bool {
        if case .copiedToClipboard = insertionOutcome { return true }
        switch aiStatus {
        case .failed, .cancelledFallback: return true
        case .off, .succeeded: return errorCode != nil
        }
    }
}

// MARK: - Transcription

public struct TranscriptionCapabilities: Sendable, Equatable {
    public let supportsBatch: Bool
    public let supportsStreaming: Bool
    public let supportsCancellation: Bool
    public let supportedSampleRate: Double
    public let supportedChannelCount: Int

    public init(
        supportsBatch: Bool,
        supportsStreaming: Bool,
        supportsCancellation: Bool,
        supportedSampleRate: Double,
        supportedChannelCount: Int
    ) {
        self.supportsBatch = supportsBatch
        self.supportsStreaming = supportsStreaming
        self.supportsCancellation = supportsCancellation
        self.supportedSampleRate = supportedSampleRate
        self.supportedChannelCount = supportedChannelCount
    }
}

public enum TranscriptionPhase: Sendable, Equatable {
    case loadingModel
    case preparingAudio
    case encoding
    case decoding
    case finalizing
}

public enum TranscriptionEvent: Sendable, Equatable {
    case phase(TranscriptionPhase)
    case progress(Double?)
    /// Reserved for a future streaming engine. Whisper v1 does not emit partial text.
    case partialText(String)
    /// A streaming model's end-of-utterance signal changed (Parakeet
    /// Realtime EOU's `<EOU>` token, 2026-09-16): `true` when the model has
    /// decided the utterance ended, published once per change. **Display
    /// and future-use only — nothing acts on it.** FR-AUD-007 forbids
    /// ending a recording on silence; the opt-in that would let this stop
    /// a recording is the planned ADR-023 (spec section H), and until it
    /// lands the job runner ignores this event as it ignores `.phase`.
    /// Scalar, so it may be logged; it never carries text.
    case endOfUtteranceDetected(Bool)
}

public enum TranscriptionTask: Sendable, Equatable {
    case transcribe
    case translate
}

public struct TranscriptionRequest: Sendable, Equatable {
    public let jobID: JobID
    public let audio: AudioRecording
    public let languageHint: String?
    public let task: TranscriptionTask
    /// Conditioning text the decoder sees before the audio (ADR-018): the
    /// rendered user dictionary (`DictionaryPrompt.render`). The engine
    /// encodes it with the resident tokenizer and enforces the runtime's
    /// limit; `nil` sends no prompt.
    public let initialPrompt: String?

    public init(
        jobID: JobID,
        audio: AudioRecording,
        languageHint: String? = nil,
        task: TranscriptionTask = .transcribe,
        initialPrompt: String? = nil
    ) {
        self.jobID = jobID
        self.audio = audio
        self.languageHint = languageHint
        self.task = task
        self.initialPrompt = initialPrompt
    }
}

// MARK: - Model lifecycle

public enum ModelArtifactRole: String, Codable, Sendable, Equatable {
    case audioEncoder
    case melSpectrogram
    case textDecoder
    case decoderPrefill
    case tokenizer
    case configuration
    case otherRequired
}

public struct ModelFileDescriptor: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let role: ModelArtifactRole

    public init(path: String, bytes: Int64, sha256: String, role: ModelArtifactRole) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.role = role
    }
}

public struct ModelManifestSource: Codable, Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let subdirectory: String

    public init(repository: String, revision: String, subdirectory: String) {
        self.repository = repository
        self.revision = revision
        self.subdirectory = subdirectory
    }
}

public struct ModelRuntimeCompatibility: Codable, Sendable, Equatable {
    public let swiftPackage: String
    public let exactVersion: String

    public init(swiftPackage: String, exactVersion: String) {
        self.swiftPackage = swiftPackage
        self.exactVersion = exactVersion
    }
}

public struct ModelTokenizer: Codable, Sendable, Equatable {
    public let relativeRoot: String
    public let offlineRequired: Bool

    public init(relativeRoot: String, offlineRequired: Bool = true) {
        self.relativeRoot = relativeRoot
        self.offlineRequired = offlineRequired
    }
}

public struct ModelManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let modelID: ModelID
    public let family: String
    public let format: String
    public let workingSpaceBytes: Int64
    public let source: ModelManifestSource
    public let runtimeCompatibility: ModelRuntimeCompatibility
    public let tokenizer: ModelTokenizer
    public let files: [ModelFileDescriptor]

    public init(
        schemaVersion: Int,
        modelID: ModelID,
        family: String,
        format: String,
        workingSpaceBytes: Int64,
        source: ModelManifestSource,
        runtimeCompatibility: ModelRuntimeCompatibility,
        tokenizer: ModelTokenizer,
        files: [ModelFileDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.family = family
        self.format = format
        self.workingSpaceBytes = workingSpaceBytes
        self.source = source
        self.runtimeCompatibility = runtimeCompatibility
        self.tokenizer = tokenizer
        self.files = files
    }
}

public enum ModelOwnership: String, Codable, Sendable, Equatable {
    case managedByKvoice
    case externalReadOnly
    /// ADR-025: the OS owns the assets (Apple Speech through
    /// `AssetInventory`). Nothing is on kvoice's disk, so there is no
    /// sentinel, no staging and no delete of files — "Delete" releases the
    /// app's locale reservation and the system removes the assets later.
    case systemManaged

    /// The `.installed.json` spelling (`InstalledModelSentinel`). A
    /// system-managed package never writes a sentinel; the spelling exists
    /// so the sentinel's coder stays total over the enum.
    var sentinelSpelling: String {
        switch self {
        case .managedByKvoice: return "managed"
        case .externalReadOnly: return "external"
        case .systemManaged: return "system"
        }
    }
}

public struct InstalledModelPackage: Sendable, Equatable {
    public let manifest: ModelManifest
    public let packageURL: URL
    public let modelFolderURL: URL
    public let tokenizerFolderURL: URL
    public let ownership: ModelOwnership

    public init(
        manifest: ModelManifest,
        packageURL: URL,
        modelFolderURL: URL,
        tokenizerFolderURL: URL,
        ownership: ModelOwnership
    ) {
        self.manifest = manifest
        self.packageURL = packageURL
        self.modelFolderURL = modelFolderURL
        self.tokenizerFolderURL = tokenizerFolderURL
        self.ownership = ownership
    }
}

/// The `.installed.json` sentinel written next to an installed package.
///
/// Records the canonical fields from spec C.3 step 12 / A5.5. Schema version 2
/// is a clean break from the unreleased version 1 shape (`installerBuild`);
/// older sentinels fail to decode and the package is treated as unverified.
public struct InstalledModelSentinel: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let modelID: ModelID
    public let repository: String
    public let revision: String
    public let manifestVersion: Int
    public let manifestSHA256: String
    public let installedBytes: Int64
    public let installedAt: Date
    public let appVersion: String
    public let ownership: ModelOwnership

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case modelID
        case repository
        case revision
        case manifestVersion
        case manifestSHA256
        case installedBytes
        case installedAt
        case appVersion
        case ownership
    }

    public init(
        schemaVersion: Int = InstalledModelSentinel.currentSchemaVersion,
        modelID: ModelID,
        repository: String,
        revision: String,
        manifestVersion: Int,
        manifestSHA256: String,
        installedBytes: Int64,
        installedAt: Date,
        appVersion: String,
        ownership: ModelOwnership
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.repository = repository
        self.revision = revision
        self.manifestVersion = manifestVersion
        self.manifestSHA256 = manifestSHA256
        self.installedBytes = installedBytes
        self.installedAt = installedAt
        self.appVersion = appVersion
        self.ownership = ownership
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        modelID = try values.decode(String.self, forKey: .modelID)
        repository = try values.decode(String.self, forKey: .repository)
        revision = try values.decode(String.self, forKey: .revision)
        manifestVersion = try values.decode(Int.self, forKey: .manifestVersion)
        manifestSHA256 = try values.decode(String.self, forKey: .manifestSHA256)
        installedBytes = try values.decode(Int64.self, forKey: .installedBytes)
        installedAt = try values.decode(Date.self, forKey: .installedAt)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        let ownership = try values.decode(String.self, forKey: .ownership)
        switch ownership {
        case "managed": self.ownership = .managedByKvoice
        case "external": self.ownership = .externalReadOnly
        case "system": self.ownership = .systemManaged
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .ownership,
                in: values,
                debugDescription: "Unknown installed model ownership"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(modelID, forKey: .modelID)
        try values.encode(repository, forKey: .repository)
        try values.encode(revision, forKey: .revision)
        try values.encode(manifestVersion, forKey: .manifestVersion)
        try values.encode(manifestSHA256, forKey: .manifestSHA256)
        try values.encode(installedBytes, forKey: .installedBytes)
        try values.encode(installedAt, forKey: .installedAt)
        try values.encode(appVersion, forKey: .appVersion)
        try values.encode(ownership.sentinelSpelling, forKey: .ownership)
    }
}

public struct InstalledModelSummary: Sendable, Equatable {
    public let modelID: ModelID
    public let revision: String
    public let ownership: ModelOwnership

    public init(modelID: ModelID, revision: String, ownership: ModelOwnership) {
        self.modelID = modelID
        self.revision = revision
        self.ownership = ownership
    }
}

public struct ModelFailure: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ModelLifecycleState: Sendable, Equatable {
    case absent
    case validatingExternal
    case downloading(completed: Int64, total: Int64)
    case downloadPaused(resumableBytes: Int64?)
    case verifying(completedFiles: Int, totalFiles: Int)
    case installing
    case loading
    /// 2026-09-29: a `.loading` that is this Mac's first build of the model
    /// under the current compute units (`ModelCompileRecording` has no
    /// record of it), so Core ML is compiling it for the Neural Engine —
    /// minutes rather than seconds, once. Every surface says "Optimizing
    /// for your Mac — first time only" instead of "Loading…"; everything
    /// else (the start gate, the busy checks) treats it exactly as
    /// `.loading`.
    case optimizing
    case ready(InstalledModelSummary)
    case inference(InstalledModelSummary, jobID: JobID)
    case corrupt(ModelFailure)
    case incompatible(ModelFailure)
    case deleting(InstalledModelSummary)
    case error(ModelFailure)
    /// ADR-025: the model cannot be installed on *this Mac* — a
    /// system-managed entry on an OS without its framework ("Requires
    /// macOS 26 or later."), a locale the platform does not support, or a
    /// framework that reports itself unavailable on this hardware. Unlike
    /// `.error`, nothing can be retried or deleted: the card is shown
    /// (one settings file works everywhere) with the reason and no action.
    case unavailable(ModelFailure)
}

// MARK: - Audio, AI, insertion, and shortcut values

public enum AudioCaptureWarning: Sendable, Equatable {
    case durationCap
    case inputChanged
    case interruption
    case clipping(frameCount: Int)
}

public enum AudioCaptureEvent: Sendable, Equatable {
    case level(rmsDBFS: Float, peakDBFS: Float)
    case elapsed(Duration)
    case deviceChanged(name: String?)
    case warning(AudioCaptureWarning)
}

public struct MicrophoneTestResult: Sendable, Equatable {
    public let duration: Duration
    public let peakLevelDBFS: Float
    public let capturedSamples: Int

    public init(duration: Duration, peakLevelDBFS: Float, capturedSamples: Int) {
        self.duration = duration
        self.peakLevelDBFS = peakLevelDBFS
        self.capturedSamples = capturedSamples
    }
}

public struct AIProcessRequest: Sendable, Equatable {
    public let jobID: JobID
    public let mode: DictationMode
    public let rawTranscript: String
    public let modelID: String
    public let targetLanguage: TranslationLanguage?
    public let polishPrompt: String

    // MARK: AI actions

    /// Optional context the user opted into, each sent as its own delimited
    /// block after the transcript (product decision #2: clipboard and selected
    /// text only, never a screen capture). Empty sends nothing, so a request
    /// built without it is byte-identical to one from before it existed.
    public let context: AIRequestContext

    public init(
        jobID: JobID,
        mode: DictationMode,
        rawTranscript: String,
        modelID: String,
        targetLanguage: TranslationLanguage?,
        polishPrompt: String,
        context: AIRequestContext = .init()
    ) {
        self.jobID = jobID
        self.mode = mode
        self.rawTranscript = rawTranscript
        self.modelID = modelID
        self.targetLanguage = targetLanguage
        self.polishPrompt = polishPrompt
        self.context = context
    }
}

/// Context blocks that accompany a transcript. Assembled by the caller from
/// the action's opt-ins and the settings; the client only frames them.
public struct AIRequestContext: Sendable, Equatable {
    /// Free-text personal context from settings (`AIEndpointSettings.userProfile`).
    /// Blank values normalize to `nil` so an empty block is never sent.
    public var userProfile: String? {
        didSet { userProfile = Self.nonEmpty(userProfile) }
    }
    /// The pasteboard's plain-text content at request time.
    public var clipboardText: String? {
        didSet { clipboardText = Self.nonEmpty(clipboardText) }
    }
    /// The focused element's selected text at request time.
    public var selectedText: String? {
        didSet { selectedText = Self.nonEmpty(selectedText) }
    }

    public init(userProfile: String? = nil, clipboardText: String? = nil, selectedText: String? = nil) {
        self.userProfile = Self.nonEmpty(userProfile)
        self.clipboardText = Self.nonEmpty(clipboardText)
        self.selectedText = Self.nonEmpty(selectedText)
    }

    public var isEmpty: Bool {
        userProfile == nil && clipboardText == nil && selectedText == nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

public struct AIProcessResult: Sendable, Equatable {
    public let text: String
    public let requestDuration: Duration
    public let responseID: String?

    public init(text: String, requestDuration: Duration, responseID: String?) {
        self.text = text
        self.requestDuration = requestDuration
        self.responseID = responseID
    }
}

public enum InsertionMethod: String, Codable, Sendable, Equatable {
    case selectedTextAttribute
    case textEditValueSplice
    /// ADR-016 third tier: Unicode keyboard events posted to the target
    /// process when neither AX text attribute is writable (terminals).
    case typedKeyboardEvents
}

public enum ClipboardFallbackReason: String, Codable, Sendable, Equatable {
    case noFrontmostApplication
    case targetApplicationChanged
    case noFocusedElement
    case notEditable
    case secureTarget
    case unsupportedValueType
    case setFailed
    case verifyFailed
    case timeout
    /// ADR-026: the App Store edition's insertion permission (PostEvent,
    /// listed under Accessibility) is not granted.
    case permissionNotGranted
    /// ADR-026: the text is over `AXInsertionLimits` for typing (the App
    /// Store edition; the Accessibility path keeps `unsupportedValueType`).
    case textTooLarge
}

public enum InsertionOutcome: Codable, Sendable, Equatable {
    case inserted(method: InsertionMethod)
    case copiedToClipboard(reason: ClipboardFallbackReason)
    /// The onboarding dictation test: text was shown in-app, not inserted.
    case deliveredInApp
    /// The app terminated after the raw transcript existed but before an
    /// insertion outcome (FR-LIFE-009). Written to history only.
    case abortedAtTermination
}

public enum ShortcutEvent: Sendable, Equatable {
    case keyDown
    case keyUp
}

public struct ShortcutDefinition: Codable, Sendable, Equatable {
    public let key: String
    public let modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A lone modifier key used as the whole shortcut (`key: "rightOption"`,
    /// `modifiers: []`). Carbon cannot register these; the hotkeys package
    /// watches `flagsChanged` for them instead. Right-hand keys are offered
    /// because the left ones are the everyday modifiers.
    public enum ModifierOnlyKey: String, Codable, Sendable, Equatable, CaseIterable {
        case rightOption
        case rightCommand
        case rightControl
        case rightShift
        case fn

        public var displayName: String {
            switch self {
            case .rightOption: return "Right Option"
            case .rightCommand: return "Right Command"
            case .rightControl: return "Right Control"
            case .rightShift: return "Right Shift"
            case .fn: return "Fn"
            }
        }

        /// Case-insensitive parse of the persisted `key` spelling.
        public init?(key: String) {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized }) else {
                return nil
            }
            self = match
        }
    }

    public init(modifierOnly key: ModifierOnlyKey) {
        self.init(key: key.rawValue, modifiers: [])
    }

    /// The recommended default: Right Option on its own.
    public static let rightOption = ShortcutDefinition(modifierOnly: .rightOption)

    public var modifierOnlyKey: ModifierOnlyKey? {
        guard modifiers.isEmpty else { return nil }
        return ModifierOnlyKey(key: key)
    }

    public var isModifierOnly: Bool {
        modifierOnlyKey != nil
    }

    /// Spellings accepted for a modifier in a key + modifier shortcut.
    public static let supportedModifierSpellings: Set<String> = [
        "command", "cmd", "⌘",
        "option", "alt", "⌥",
        "control", "ctrl", "^",
        "shift", "⇧",
        "function", "fn",
        "capslock", "caps-lock", "caps_lock"
    ]

    /// Structural validity shared by settings validation and the recorder:
    /// either a known modifier-only key with no modifiers, or a non-empty key
    /// with at least one distinct, supported modifier.
    public var isStructurallyValid: Bool {
        if modifiers.isEmpty {
            return isModifierOnly
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey.utf8.count <= 32 else { return false }
        let normalized = modifiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized.count == Set(normalized).count
            && normalized.allSatisfy(Self.supportedModifierSpellings.contains)
    }
}

public enum ShortcutRegistrationState: Sendable, Equatable {
    case unregistered
    case registered(ShortcutDefinition)
    case failed(KVoiceErrorCode)
}

public enum TargetResolution: Sendable, Equatable {
    case target(TargetApplicationSnapshot)
    case unavailable
}
