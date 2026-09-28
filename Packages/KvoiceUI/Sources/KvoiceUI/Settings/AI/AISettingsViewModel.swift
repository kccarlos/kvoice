import Foundation
import KvoiceAI
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Main-actor state for the optional, transcript-only AI settings surface.
///
/// `apiKey` is intentionally kept outside `AppSettings`. The view model holds
/// it only while the settings view is alive and passes it to an explicit save
/// or configuration-test callback; callers decide how to persist it through
/// `SecretsFileStore`.
///
/// ADR-022 slice 7 part B: a projection over `SettingsProjectionHost` for the
/// nonsecret half. `isEnabled`, `configurations`, and `activeConfigurationID`
/// read `host.settings.ai` live and commit through one `.setAI` intent per
/// edit; `baseURLText`, `modelID`, `polishPrompt`, `translationBCP47`, and
/// `translationLanguageName` are drafts committed by `flushPendingChanges()`
/// (the view's `.onSubmit` / focus-change / `.onDisappear` /
/// resign-active hooks, unchanged) rather than the debounce `Task` this used
/// to schedule per keystroke. `apiKey` and `configurationAPIKeys` stay
/// exactly what they were before slice 7: observed state the shell feeds
/// through `applySecrets(_:)` after its `.saveSecrets` effect runs (never
/// read from `AppSettings` — rule 2), written back through one `.setSecrets`
/// intent per commit instead of the `onSecretChange` callback.
///
/// **Staleness.** The drafts above are seeded once (`init`) and then only
/// ever *committed*, never re-read — so they go stale the moment the stored
/// block moves without this model's help: `AppDelegate.init` builds this
/// model before the coordinator's real load runs
/// (`AppDelegate+Settings.loadSettingsAndRegisterShortcut`), so the drafts
/// seed as empty defaults for the whole gap; the same gap opens after an
/// Import, Restore Previous Settings, or a status-menu Configuration pick.
/// `discardStaleDrafts()` re-seeds them from `host.settings.ai` whenever it
/// has moved since the drafts were last seeded or committed (`draftBase`),
/// and is called before every read or write that uses a draft — so a stale
/// draft is never blended into a commit, and an untouched draft mid-edit is
/// never discarded just because it differs from the stored value.
@Observable
@MainActor
public final class AISettingsViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    /// The request shape the live settings would run, or `.off`. Read-only in
    /// spirit: the AI Actions section owns the master switch and the default
    /// action through `PromptModeSettingsViewModel`. The setter survives for
    /// callers written against the older mode picker and maps onto the switch.
    public var mode: DictationMode {
        get { aiSettings.mode }
        set {
            var next = aiSettings
            next.mode = newValue
            commit(next)
        }
    }

    /// The "Enable AI Actions" master switch (product decision #6). Mirrors
    /// `PromptModeSettingsViewModel.isEnabled`; both read the same stored
    /// block, so they are always in step — no re-apply needed.
    public var isEnabled: Bool {
        get { host.settings.ai.isEnabled }
        set {
            guard newValue != isEnabled else { return }
            var next = aiSettings
            next.isEnabled = newValue
            commit(next)
        }
    }
    // The text-backed fields below are typed into. They are drafts: no
    // per-keystroke commit, just the clamp / edited-timestamp bookkeeping a
    // few of them need; `flushPendingChanges()` is what commits them.
    public var baseURLText: String
    public var modelID: String
    public var polishPrompt: String {
        didSet {
            if polishPrompt != host.settings.ai.promptConfiguration.polishPrompt {
                promptLastEditedAt = Date()
            }
        }
    }
    public var translationBCP47: String
    public var translationLanguageName: String
    /// The live key. Never read from `AppSettings`; fed by `applySecrets(_:)`
    /// and committed by `flushPendingChanges()` / the immediate-commit
    /// configuration operations below, exactly like the pre-slice-7
    /// `apiKey`/`onSecretChange` pair.
    public var apiKey: String

    /// The last refusal's sentence, for the page footer; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    public private(set) var testState: TestState = .idle

    /// Saved endpoints. Editing these does not change the live endpoint until
    /// one is selected, so a half-edited configuration cannot break dictation.
    public var configurations: [AIConfiguration] {
        get { host.settings.ai.configurations }
        set {
            guard newValue != configurations else { return }
            var next = aiSettings
            next.configurations = newValue
            commit(next)
        }
    }

    public var activeConfigurationID: UUID? { host.settings.ai.activeConfigurationID }

    /// Model identifiers reported by the endpoint, so the user can pick instead
    /// of typing one exactly.
    public private(set) var discoveredModels: [String] = []
    public private(set) var discoveryState: DiscoveryState = .idle

    /// Keys held per configuration so switching providers does not require retyping a
    /// credential. Never included in `AppSettings`.
    private var configurationAPIKeys: [String: String] = [:]
    /// The secrets last fed by the shell or committed by this model, so
    /// `hasPendingChanges` / `flushPendingChanges()` know whether `apiKey` /
    /// `configurationAPIKeys` still match what is on disk.
    private var lastKnownSecrets: SecretSettings

    public enum TestState: Equatable, Sendable {
        case idle
        case testing
        case succeeded
        /// The failure class in plain words ("HTTP 404", "Timed out", …),
        /// never the endpoint, key, or response body.
        case failed(String)
    }

    /// "Verify & Save" in the configuration sheet: the same connection test,
    /// run against the draft before it is stored.
    public private(set) var verificationState: TestState = .idle

    public enum DiscoveryState: Equatable, Sendable {
        case idle
        case loading
        case loaded(count: Int)
        case failed
    }

    private let configurationTester: @MainActor (
        AIEndpointSettings,
        AICredentialSnapshot?
    ) async throws -> Void
    private let modelLister: @MainActor (
        AIEndpointSettings,
        AICredentialSnapshot?
    ) async throws -> [String]
    private var promptLastEditedAt: Date?
    /// The stored block as of the last time the drafts above were seeded or
    /// committed. `discardStaleDrafts()` compares this to the live
    /// `host.settings.ai`: equal means nothing else has touched the block,
    /// so an in-progress draft is left alone; different means the drafts
    /// are stale and are re-seeded.
    private var draftBase: AIEndpointSettings

    public init(
        host: SettingsProjectionHost = .detached(),
        secrets: SecretSettings = .init(),
        configurationTester: @escaping @MainActor (
            AIEndpointSettings,
            AICredentialSnapshot?
        ) async throws -> Void = { _, _ in },
        modelLister: @escaping @MainActor (
            AIEndpointSettings,
            AICredentialSnapshot?
        ) async throws -> [String] = { _, _ in [] }
    ) {
        self.host = host
        let settings = host.settings.ai
        draftBase = settings
        baseURLText = settings.baseURL?.absoluteString ?? ""
        modelID = settings.modelID
        polishPrompt = settings.promptConfiguration.polishPrompt
        translationBCP47 = settings.translationLanguage.bcp47
        translationLanguageName = settings.translationLanguage.displayName
        apiKey = secrets.apiKey ?? ""
        promptLastEditedAt = settings.promptConfiguration.lastEditedAt
        configurationAPIKeys = secrets.configurationAPIKeys
        lastKnownSecrets = secrets
        self.configurationTester = configurationTester
        self.modelLister = modelLister
    }

    /// Re-seeds `baseURLText`, `modelID`, `polishPrompt`, and
    /// `translationBCP47`/`translationLanguageName` from `host.settings.ai`
    /// when it has moved since they were last seeded or committed. Called
    /// before every read or write that blends a draft into a commit
    /// (`aiSettings`, `flushPendingChanges()`, `hasPendingChanges`); the
    /// shell also calls it once, explicitly, right after the coordinator's
    /// real settings load (`AppDelegate+Settings.swift`), so a page opened
    /// in the gap between `init` and that load never shows the empty
    /// defaults this model necessarily starts with.
    public func discardStaleDrafts() {
        let stored = host.settings.ai
        guard stored.baseURL != draftBase.baseURL
            || stored.modelID != draftBase.modelID
            || stored.promptConfiguration.polishPrompt != draftBase.promptConfiguration.polishPrompt
            || stored.translationLanguage != draftBase.translationLanguage
        else { return }
        draftBase = stored
        baseURLText = stored.baseURL?.absoluteString ?? ""
        modelID = stored.modelID
        polishPrompt = stored.promptConfiguration.polishPrompt
        translationBCP47 = stored.translationLanguage.bcp47
        translationLanguageName = stored.translationLanguage.displayName
        promptLastEditedAt = stored.promptConfiguration.lastEditedAt
    }

    /// App-composition initializer without actor-isolated default arguments.
    /// Keeping every dependency explicit avoids Swift's lazy-property default
    /// argument ambiguity in an `@MainActor` application delegate.
    public convenience init(
        host: SettingsProjectionHost,
        loadedSecrets secrets: SecretSettings,
        configurationTester: @escaping @MainActor (
            AIEndpointSettings,
            AICredentialSnapshot?
        ) async throws -> Void,
        modelLister: @escaping @MainActor (
            AIEndpointSettings,
            AICredentialSnapshot?
        ) async throws -> [String]
    ) {
        self.init(
            host: host,
            secrets: secrets,
            configurationTester: configurationTester,
            modelLister: modelLister
        )
    }

    /// The endpoint that reaches the nonsecret settings snapshot.
    ///
    /// A URL the client would refuse — one carrying userinfo or a query, or
    /// plain HTTP to a non-loopback host — is `nil` here, so it is never
    /// committed and never used for discovery or a test. `baseURLValidationError`
    /// explains the refusal inline. The rule itself lives in the client; this
    /// only asks it.
    public var baseURL: URL? {
        BaseURLCheck.acceptedURL(from: baseURLText)
    }

    /// Why the typed base URL is rejected, or `nil` when it is empty or usable.
    public var baseURLValidationError: String? {
        BaseURLCheck.validationError(for: baseURLText)
    }

    public var translationLanguage: TranslationLanguage {
        TranslationLanguage(
            bcp47: translationBCP47,
            displayName: translationLanguageName
        )
    }

    /// The stored block with this tab's drafts written over it.
    ///
    /// Built from `host.settings.ai` rather than from scratch on purpose.
    /// Starting from a fresh `AIEndpointSettings` would default to an empty
    /// `promptModes`, no `activePromptModeID`, and the shipped translate
    /// prompt — so every keystroke in the AI tab would commit settings with
    /// the user's prompt modes wiped, and the Modes tab and menu emptied
    /// until the next launch re-seeded the built-ins. Only the fields this
    /// view model actually edits are assigned here; `configurations` and
    /// `activeConfigurationID` need no overlay — they commit immediately, so
    /// the stored value already reads live.
    public var aiSettings: AIEndpointSettings {
        discardStaleDrafts()
        var settings = host.settings.ai
        settings.baseURL = baseURL
        settings.modelID = modelID
        settings.promptConfiguration.polishPrompt = polishPrompt
        settings.promptConfiguration.polishPromptOrigin = polishPrompt == DefaultPrompts.polish
            ? .shippedDefault
            : .userEdited
        settings.promptConfiguration.shippedDefaultVersion = DefaultPrompts.polishVersion
        settings.promptConfiguration.lastEditedAt = promptLastEditedAt
        settings.translationLanguage = translationLanguage
        return settings
    }

    // MARK: AI configurations

    /// Everything the add sheet collects before a configuration exists.
    ///
    /// The provider is chosen first because it decides what else needs asking:
    /// a preset already knows its endpoint, while `custom` must be given one.
    public struct Draft: Equatable, Sendable {
        public var kind: AIProviderKind
        public var name: String
        public var baseURLText: String
        public var modelID: String
        public var apiKey: String
        // MARK: AI actions
        /// Azure OpenAI addresses a resource and a deployment rather than a
        /// URL and a model; the endpoint is derived from these two.
        public var azureResource: String
        public var azureDeployment: String
        public var apiVersion: String
        /// Custom endpoints may need Azure-style auth; presets fix it.
        public var authStyle: AIProviderAuthStyle

        public init(kind: AIProviderKind = .ollama) {
            self.kind = kind
            name = kind.displayName
            baseURLText = kind.defaultBaseURL?.absoluteString ?? ""
            modelID = kind.suggestedModelID
            apiKey = ""
            azureResource = ""
            azureDeployment = ""
            apiVersion = kind.requestProfile.apiVersion ?? ""
            authStyle = kind.requestProfile.authStyle
        }

        /// An existing configuration opened for editing.
        public init(configuration: AIConfiguration, apiKey: String) {
            kind = configuration.kind
            name = configuration.name
            baseURLText = configuration.baseURL?.absoluteString ?? ""
            modelID = configuration.modelID
            self.apiKey = apiKey
            let azure = Self.azureParts(of: configuration.baseURL)
            azureResource = azure?.resource ?? ""
            azureDeployment = azure?.deployment ?? ""
            apiVersion = configuration.requestProfile.apiVersion ?? ""
            authStyle = configuration.requestProfile.authStyle
        }

        /// Re-seeds the provider-derived fields when the provider changes,
        /// leaving a name the user has already typed alone.
        public mutating func changeKind(
            to newKind: AIProviderKind,
            nameWasEdited: Bool
        ) {
            kind = newKind
            baseURLText = newKind.defaultBaseURL?.absoluteString ?? ""
            modelID = newKind.suggestedModelID
            apiVersion = newKind.requestProfile.apiVersion ?? ""
            authStyle = newKind.requestProfile.authStyle
            if !nameWasEdited {
                name = newKind.displayName
            }
        }

        /// The drafted endpoint, or `nil` when it is empty or the client would
        /// refuse it — see `AISettingsViewModel.baseURL`.
        public var resolvedBaseURL: URL? {
            if kind.usesAzureAddressing {
                return AIProviderKind.azureBaseURL(resource: azureResource, deployment: azureDeployment)
            }
            return BaseURLCheck.acceptedURL(from: baseURLText)
        }

        public var baseURLValidationError: String? {
            if kind.usesAzureAddressing {
                let resource = azureResource.trimmingCharacters(in: .whitespacesAndNewlines)
                let deployment = azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resource.isEmpty || !deployment.isEmpty else { return nil }
                return resolvedBaseURL == nil
                    ? String(localized: "Enter the resource name (letters, digits, hyphens) and the deployment name.", bundle: .module)
                    : nil
            }
            return BaseURLCheck.validationError(for: baseURLText)
        }

        /// The model identifier the request carries. Azure ignores it in the
        /// body but the client requires one, so the deployment name is used.
        public var resolvedModelID: String {
            let typed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind.usesAzureAddressing, typed.isEmpty {
                return azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return typed
        }

        public var requestProfile: AIRequestProfile {
            let version = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIRequestProfile(authStyle: authStyle, apiVersion: version.isEmpty ? nil : version)
        }

        /// A configuration is only worth saving if it could service a
        /// request: an endpoint needs a URL and a model, the on-device kind
        /// (ADR-024) only a name.
        public var isComplete: Bool {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if !kind.transport.needsEndpointFields { return true }
            return resolvedBaseURL != nil && !resolvedModelID.isEmpty
        }

        /// The sheet's first choice (ADR-024, ADR-027): an OpenAI-compatible
        /// endpoint, the on-device model, or Private Cloud Compute. Setting
        /// it re-seeds the kind — the first endpoint preset, or the Apple
        /// kind of that transport. A name the
        /// user typed (anything but the current kind's display name) is kept,
        /// exactly as `changeKind` keeps it for a provider change.
        public var transport: AIProviderTransport {
            get { kind.transport }
            set {
                guard newValue != kind.transport else { return }
                let seed: AIProviderKind
                switch newValue {
                case .openAICompatible: seed = .ollama
                case .appleIntelligence: seed = .appleIntelligence
                case .privateCloudCompute: seed = .privateCloudCompute
                }
                changeKind(to: seed, nameWasEdited: name != kind.displayName)
            }
        }

        /// The endpoint settings a connection test of this draft would use.
        public var endpointSettings: AIEndpointSettings {
            var settings = AIEndpointSettings(baseURL: resolvedBaseURL, modelID: resolvedModelID)
            settings.requestProfile = requestProfile
            settings.provider = kind.transport
            return settings
        }

        static func azureParts(of url: URL?) -> (resource: String, deployment: String)? {
            guard let url, let host = url.host?.lowercased(), host.hasSuffix(".openai.azure.com") else {
                return nil
            }
            let resource = String(host.dropLast(".openai.azure.com".count))
            let components = url.pathComponents.filter { $0 != "/" }
            guard let index = components.firstIndex(of: "deployments"), components.indices.contains(index + 1) else {
                return nil
            }
            return (resource, components[index + 1])
        }
    }

    // MARK: Base URL validation

    /// Runs the typed endpoint through the client's own URL rules before it
    /// can be persisted, so Settings and the request path cannot disagree.
    enum BaseURLCheck {
        static func parsed(_ text: String) -> URL? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return URL(string: value)
        }

        /// The typed URL when the client accepts it; `nil` when empty or refused.
        static func acceptedURL(from text: String) -> URL? {
            guard let url = parsed(text),
                  (try? OpenAICompatibleAIProcessingClient.normalizedCompletionURL(from: url)) != nil
            else {
                return nil
            }
            return url
        }

        /// A user-facing reason the URL is refused; `nil` when empty or accepted.
        /// The wording never echoes the URL, which may contain a credential.
        static func validationError(for text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let url = parsed(trimmed) else {
                return malformedMessage
            }
            do {
                _ = try OpenAICompatibleAIProcessingClient.normalizedCompletionURL(from: url)
                return nil
            } catch let error as KVoiceError where error.code == .aiInsecureRemoteURL {
                return String(localized: "Remote hosts need HTTPS. Plain HTTP is allowed only for localhost, 127.0.0.1, or ::1.", bundle: .module)
            } catch {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if components?.user != nil || components?.password != nil
                    || components?.query != nil || components?.fragment != nil {
                    return String(localized: "Remove the credentials or query from the URL. Put the API key in the API key field instead.", bundle: .module)
                }
                return malformedMessage
            }
        }

        private static let malformedMessage = String(localized: "Enter a full URL, such as https://api.openai.com/v1.", bundle: .module)
    }

    /// Saves a drafted configuration and makes it the live endpoint. One
    /// `.setAI` (the new configuration plus the selection together, not two
    /// separate commits with a moment in between where the array holds the
    /// configuration but it is not yet active); the key is written to
    /// `configurationAPIKeys` only once that commit is accepted, so a
    /// refused add never orphans a key into the secrets file for a
    /// configuration that was never actually saved.
    @discardableResult
    public func addConfiguration(_ draft: Draft) -> AIConfiguration? {
        guard draft.isComplete else { return nil }

        let configuration = AIConfiguration(
            name: uniqueName(from: draft.name),
            kind: draft.kind,
            baseURL: draft.resolvedBaseURL,
            modelID: draft.resolvedModelID,
            requestProfile: draft.requestProfile
        )
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        baseURLText = configuration.baseURL?.absoluteString ?? ""
        modelID = configuration.modelID
        discoveredModels = []
        discoveryState = .idle
        testState = .idle
        var next = aiSettings
        next.configurations.append(configuration)
        next.requestProfile = configuration.requestProfile
        next.provider = configuration.kind.transport
        next.activeConfigurationID = configuration.id
        guard commit(next) else { return nil }

        if !key.isEmpty {
            configurationAPIKeys[configuration.id.uuidString] = key
        }
        apiKey = key
        commitSecretsIfNeeded()
        return configuration
    }

    /// Saves an edit made in the configuration sheet. If the edited
    /// configuration is the live one, the endpoint fields follow it — one
    /// `.setAI` either way (was two when the edited configuration was
    /// active: the array update, then `selectConfiguration`'s own commit,
    /// with an intermediate persisted state in between); the key is written
    /// only once the commit is accepted, same reasoning as `addConfiguration`.
    public func updateConfiguration(id: UUID, from draft: Draft) {
        guard draft.isComplete,
              let index = configurations.firstIndex(where: { $0.id == id })
        else {
            return
        }
        // One local array, one commit: four separate `configurations[index].x
        // = y` writes through the computed property would each round-trip
        // the reducer on their own.
        var updated = configurations
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].name = trimmedName != updated[index].name
            ? uniqueName(from: trimmedName, excluding: id)
            : updated[index].name
        updated[index].kind = draft.kind
        updated[index].baseURL = draft.resolvedBaseURL
        updated[index].modelID = draft.resolvedModelID
        updated[index].requestProfile = draft.requestProfile

        let isActive = activeConfigurationID == id
        if isActive {
            baseURLText = updated[index].baseURL?.absoluteString ?? ""
            modelID = updated[index].modelID
            discoveredModels = []
            discoveryState = .idle
            testState = .idle
        }
        var next = aiSettings
        next.configurations = updated
        if isActive {
            next.requestProfile = updated[index].requestProfile
            next.provider = updated[index].kind.transport
        }
        guard commit(next) else { return }

        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            configurationAPIKeys.removeValue(forKey: id.uuidString)
        } else {
            configurationAPIKeys[id.uuidString] = key
        }
        if isActive {
            apiKey = key
        }
        commitSecretsIfNeeded()
    }

    /// "Verify & Save": runs the connection test against the draft, and only
    /// on success stores it (adding, or updating `existingID`). Returns the
    /// saved configuration, or `nil` when the test failed or the draft is
    /// incomplete; `verificationState` carries the failure class.
    @discardableResult
    public func verifyAndSave(_ draft: Draft, replacing existingID: UUID? = nil) async -> AIConfiguration? {
        guard draft.isComplete else {
            verificationState = .failed(String(localized: "Fill in a name, endpoint, and model.", bundle: .module))
            return nil
        }
        verificationState = .testing
        do {
            let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await configurationTester(
                draft.endpointSettings,
                key.isEmpty ? nil : AICredentialSnapshot(apiKey: key)
            )
        } catch {
            verificationState = .failed(Self.failureDescription(for: error))
            return nil
        }
        verificationState = .succeeded
        if let existingID {
            updateConfiguration(id: existingID, from: draft)
            return configurations.first { $0.id == existingID }
        }
        return addConfiguration(draft)
    }

    public func clearVerification() {
        verificationState = .idle
    }

    /// Plain words for a failed test, from the error class only. The
    /// endpoint, key, and response body are never part of it.
    static func failureDescription(for error: any Error) -> String {
        guard let failure = error as? KVoiceError else {
            return String(localized: "The request failed.", bundle: .module)
        }
        let status = failure.metadata.httpStatus.map { String(localized: " (HTTP \($0))", bundle: .module) } ?? ""
        // ADR-027: Private Cloud Compute has no endpoint, URL or model name
        // of ours to point at; its failures get their own words.
        if failure.metadata.endpointClass == .privateCloudCompute {
            switch failure.code {
            case .aiProviderUnavailable:
                return String(localized: "Private Cloud Compute isn't available right now.", bundle: .module)
            case .aiUnreachable, .aiTimeout:
                return String(localized: "Private Cloud Compute could not be reached. Check your internet connection.", bundle: .module)
            case .aiQuotaExhausted:
                return String(localized: "Today's Private Cloud Compute limit is reached.", bundle: .module)
            case .aiRateLimited:
                return String(localized: "Private Cloud Compute is busy. Try again shortly.", bundle: .module)
            case .aiMalformedResponse, .aiEmptyResponse, .aiOversizedResponse:
                return String(localized: "Private Cloud Compute answered, but not with the expected reply.", bundle: .module)
            default:
                break
            }
        }
        switch failure.code {
        case .aiAuthentication:
            return String(localized: "Authentication failed\(status). Check the API key.", bundle: .module)
        case .aiTimeout:
            return String(localized: "Timed out waiting for the endpoint.", bundle: .module)
        case .aiUnreachable:
            return String(localized: "The endpoint could not be reached. Check the URL and your connection.", bundle: .module)
        case .aiRateLimited:
            return String(localized: "The endpoint is rate-limited\(status). Try again shortly.", bundle: .module)
        case .aiHTTPError:
            return String(localized: "The endpoint returned an error\(status). Check the model name and URL path.", bundle: .module)
        case .aiMalformedResponse, .aiEmptyResponse, .aiOversizedResponse:
            return String(localized: "The endpoint answered, but not with the expected reply. Check the model name.", bundle: .module)
        case .aiURLInvalid, .aiInsecureRemoteURL:
            return String(localized: "The endpoint URL is not usable.", bundle: .module)
        case .aiConfigurationMissing:
            return String(localized: "Fill in the endpoint and model first.", bundle: .module)
        case .aiCancelled:
            return String(localized: "The test was cancelled.", bundle: .module)
        case .aiProviderUnavailable:
            return String(localized: "Apple Intelligence isn't available on this Mac right now.", bundle: .module)
        case .aiInputTooLong:
            return String(localized: "The request did not fit the on-device model's context window.", bundle: .module)
        case .aiQuotaExhausted:
            return String(localized: "Today's Private Cloud Compute limit is reached.", bundle: .module)
        default:
            return String(localized: "The request failed.", bundle: .module)
        }
    }

    /// Names are how a configuration is identified in the menu bar, so they are
    /// kept distinct rather than silently duplicated.
    private func uniqueName(from requested: String, excluding id: UUID? = nil) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(localized: "AI Configuration", bundle: .module) : trimmed
        let existing = Set(configurations.filter { $0.id != id }.map(\.name))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    public func renameConfiguration(id: UUID, to name: String) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != configurations[index].name else { return }
        configurations[index].name = uniqueName(from: trimmed)
    }

    /// One `.setAI` (the removal and, if it was active, clearing
    /// `activeConfigurationID` together — was two, with an intermediate
    /// persisted state where `activeConfigurationID` pointed at a
    /// configuration no longer in the array).
    public func deleteConfiguration(id: UUID) {
        guard configurations.contains(where: { $0.id == id }) else { return }
        var next = aiSettings
        next.configurations.removeAll { $0.id == id }
        if next.activeConfigurationID == id {
            next.activeConfigurationID = nil
            // ADR-024: the on-device transport needs no fields, so it would
            // keep AI "configured" with no configuration left; back to the
            // endpoint rule, where the (empty) fields read as not configured.
            next.provider = .openAICompatible
        }
        guard commit(next) else { return }
        configurationAPIKeys.removeValue(forKey: id.uuidString)
        commitSecretsIfNeeded()
    }

    /// Makes a configuration the live endpoint: copies its URL, model, and key into
    /// the fields the client actually reads.
    public func selectConfiguration(id: UUID) {
        guard let configuration = configurations.first(where: { $0.id == id }) else { return }
        baseURLText = configuration.baseURL?.absoluteString ?? ""
        modelID = configuration.modelID
        discoveredModels = []
        discoveryState = .idle
        testState = .idle
        var next = aiSettings
        next.requestProfile = configuration.requestProfile
        next.provider = configuration.kind.transport
        next.activeConfigurationID = id
        guard commit(next) else { return }
        apiKey = configurationAPIKeys[id.uuidString] ?? ""
        commitSecretsIfNeeded()
    }

    /// Writes the currently edited endpoint fields back into the active configuration,
    /// so edits made in the form are remembered.
    public func updateActiveConfigurationFromFields() {
        guard let activeConfigurationID,
              let index = configurations.firstIndex(where: { $0.id == activeConfigurationID }),
              // A refused URL must not replace the configuration's good one.
              baseURLValidationError == nil
        else {
            return
        }
        var updatedConfigurations = configurations
        updatedConfigurations[index].baseURL = baseURL
        updatedConfigurations[index].modelID = modelID
        var next = aiSettings
        next.configurations = updatedConfigurations
        guard commit(next) else { return }
        if apiKey.isEmpty {
            configurationAPIKeys.removeValue(forKey: activeConfigurationID.uuidString)
        } else {
            configurationAPIKeys[activeConfigurationID.uuidString] = apiKey
        }
        commitSecretsIfNeeded()
    }

    /// True when the endpoint fields differ from what the selected
    /// configuration stores — the only time "Save Edits to Selected
    /// Configuration" has anything to do.
    public var activeConfigurationHasUnsavedEdits: Bool {
        guard let activeConfigurationID,
              let configuration = configurations.first(where: { $0.id == activeConfigurationID })
        else {
            return false
        }
        let storedKey = configurationAPIKeys[activeConfigurationID.uuidString] ?? ""
        let storedURL = configuration.baseURL?.absoluteString ?? ""
        return storedURL != baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            || configuration.modelID != modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            || storedKey != apiKey
    }

    /// The stored key for a configuration, so the edit sheet can show it
    /// masked. Never persisted outside `SecretSettings`.
    public func apiKey(for configurationID: UUID) -> String {
        configurationAPIKeys[configurationID.uuidString] ?? ""
    }

    public func renameActiveConfiguration(_ name: String) {
        guard let activeConfigurationID,
              let index = configurations.firstIndex(where: { $0.id == activeConfigurationID })
        else {
            return
        }
        configurations[index].name = name
    }

    public var canDiscoverModels: Bool {
        baseURL != nil
    }

    /// Asks the endpoint which models it serves. User-triggered only.
    public func discoverModels() async {
        guard canDiscoverModels else {
            discoveryState = .failed
            return
        }
        discoveryState = .loading
        do {
            let models = try await modelLister(
                aiSettings,
                apiKey.isEmpty ? nil : AICredentialSnapshot(apiKey: apiKey)
            )
            discoveredModels = models
            discoveryState = .loaded(count: models.count)
            // Selecting the only sensible option saves a click.
            if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = models.first {
                modelID = first
            }
        } catch {
            // As with testing, never surface a raw transport error.
            discoveredModels = []
            discoveryState = .failed
        }
    }

    /// The API key is deliberately absent from this snapshot and from all
    /// `AppSettings` serialization.
    public var appSettings: AppSettings {
        var settings = host.settings
        settings.ai = aiSettings
        return settings
    }

    public var secretSettings: SecretSettings {
        SecretSettings(
            apiKey: apiKey.isEmpty ? nil : apiKey,
            configurationAPIKeys: configurationAPIKeys
        )
    }

    /// The test needs an endpoint and a model, nothing else: it runs its own
    /// fixed request regardless of the master switch or the default action.
    /// The on-device transport (ADR-024) needs nothing filled in; whether
    /// the model is available is what the test then reports.
    public var canTestConfiguration: Bool {
        if !host.settings.ai.provider.needsEndpointFields { return true }
        return baseURL != nil
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ADR-024: the live transport, for the pages that show or hide the
    /// endpoint fields.
    public var provider: AIProviderTransport { host.settings.ai.provider }

    /// Commits every draft now: the endpoint fields (if they differ from the
    /// stored block) and the key (if it differs from what was last fed or
    /// committed). Safe to call when nothing is pending — the view's
    /// `.onSubmit`, focus-change, `.onDisappear`, and resign-active hooks all
    /// call this unconditionally, as they did before slice 7.
    public func flushPendingChanges() {
        discardStaleDrafts()
        let nextAI = aiSettings
        if nextAI != host.settings.ai {
            commit(nextAI)
        }
        commitSecretsIfNeeded()
    }

    /// Alias kept for callers written against the pre-slice-7 API: every
    /// draft here already commits through the coordinator, so there is
    /// nothing left for a caller-owned closure to persist.
    public func save() {
        flushPendingChanges()
    }

    /// True while a draft (the endpoint fields or the key) has not yet been
    /// committed.
    public var hasPendingChanges: Bool {
        discardStaleDrafts()
        return aiSettings != host.settings.ai || secretSettings != lastKnownSecrets
    }

    /// Feeds the live key after the shell's `.saveSecrets` effect runs (on
    /// load, and after any door writes `SecretSettings` — including this
    /// model's own commits, so the shell's re-apply is idempotent). The
    /// nonsecret half needs no such call any more: it is a projection and
    /// already reads the committed value.
    public func applySecrets(_ secrets: SecretSettings) {
        apiKey = secrets.apiKey ?? ""
        configurationAPIKeys = secrets.configurationAPIKeys
        lastKnownSecrets = secrets
    }

    public func testConfiguration() async {
        guard canTestConfiguration else {
            testState = .failed(String(localized: "Fill in the endpoint and model first.", bundle: .module))
            return
        }
        testState = .testing
        do {
            try await configurationTester(
                aiSettings,
                apiKey.isEmpty ? nil : AICredentialSnapshot(apiKey: apiKey)
            )
            testState = .succeeded
        } catch {
            // Never surface a raw URLSession error: it could contain the
            // endpoint, proxy details, or an Authorization value. Only the
            // error class and HTTP status are shown.
            testState = .failed(Self.failureDescription(for: error))
        }
    }

    public func resetPolishPrompt() {
        polishPrompt = DefaultPrompts.polish
        // A button press, not typing: commit at once.
        flushPendingChanges()
    }

    /// Sends the block as one `.setAI` intent and keeps `draftBase` in step
    /// with what was actually committed, so `discardStaleDrafts()` does not
    /// mistake this model's own accepted commit for a foreign write. A
    /// refusal leaves the stored block (and `draftBase`) untouched, so every
    /// read above already shows the truth and the draft stays exactly as
    /// typed for a retry; the host records the note in `refusalNote`.
    /// Returns whether the send was accepted, so a caller that also touches
    /// `configurationAPIKeys` can gate that on the same outcome — a refused
    /// write must never orphan a key into the secrets file for a
    /// configuration that was never actually saved.
    @discardableResult
    private func commit(_ next: AIEndpointSettings) -> Bool {
        guard host.send(.setAI(next, origin: .page(.aiActions))) == nil else { return false }
        draftBase = next
        return true
    }

    /// Sends the key and per-configuration keys as one `.setSecrets` intent,
    /// only when they differ from what was last fed or committed. Rule 2:
    /// this is the only door `apiKey` / `configurationAPIKeys` ever reach —
    /// they never touch `AppSettings`.
    private func commitSecretsIfNeeded() {
        let next = secretSettings
        guard next != lastKnownSecrets else { return }
        guard host.send(.setSecrets(next, origin: .page(.aiActions))) == nil else { return }
        lastKnownSecrets = next
    }
}

public typealias AISettingsModel = AISettingsViewModel
