import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// AI configurations let the user save several endpoints and switch between them
/// by name from the menu bar. The provider is chosen when a configuration is
/// created, because it determines what else must be asked for.
@MainActor
final class AIConfigurationTests: XCTestCase {
    // MARK: Providers

    func testPresetsCarryTheirEndpoint() {
        XCTAssertEqual(
            AIProviderKind.ollama.defaultBaseURL?.absoluteString,
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            AIProviderKind.openAI.defaultBaseURL?.absoluteString,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            AIProviderKind.gemini.defaultBaseURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai"
        )
        XCTAssertEqual(
            AIProviderKind.openRouter.defaultBaseURL?.absoluteString,
            "https://openrouter.ai/api/v1"
        )
        XCTAssertNil(
            AIProviderKind.custom.defaultBaseURL,
            "custom must not presume an endpoint"
        )
    }

    func testOnlyCustomRequiresAManualEndpoint() {
        XCTAssertTrue(AIProviderKind.custom.requiresManualBaseURL)
        for kind in [AIProviderKind.ollama, .openAI, .gemini, .openRouter] {
            XCTAssertFalse(kind.requiresManualBaseURL, "\(kind) ships an endpoint")
        }
    }

    func testOnlyHostedProvidersExpectAKey() {
        XCTAssertFalse(AIProviderKind.ollama.expectsAPIKey)
        for kind in [AIProviderKind.openAI, .gemini, .openRouter] {
            XCTAssertTrue(kind.expectsAPIKey, "\(kind) needs a key")
        }
    }

    func testUsabilityRequiresBothURLAndModel() {
        XCTAssertFalse(AIConfiguration.preset(.custom).isUsable)
        XCTAssertFalse(AIConfiguration.preset(.ollama).isUsable, "no model yet")

        var configuration = AIConfiguration.preset(.ollama)
        configuration.modelID = "gemma4:latest"
        XCTAssertTrue(configuration.isUsable)
    }

    // MARK: Draft

    func testDraftSeedsFromTheChosenProvider() {
        let draft = AISettingsViewModel.Draft(kind: .openRouter)

        XCTAssertEqual(draft.name, "OpenRouter")
        XCTAssertEqual(draft.baseURLText, "https://openrouter.ai/api/v1")
        XCTAssertEqual(draft.modelID, AIProviderKind.openRouter.suggestedModelID)
        XCTAssertEqual(draft.modelID, "openai/gpt-6-luna")
        XCTAssertTrue(draft.isComplete)
    }

    func testCustomDraftIsIncompleteUntilGivenAnEndpointAndModel() {
        var draft = AISettingsViewModel.Draft(kind: .custom)
        XCTAssertFalse(draft.isComplete)

        draft.baseURLText = "http://localhost:8080/v1"
        XCTAssertFalse(draft.isComplete, "still needs a model")

        draft.modelID = "local-model"
        XCTAssertTrue(draft.isComplete)
    }

    func testChangingProviderReseedsFieldsButKeepsAnEditedName() {
        var draft = AISettingsViewModel.Draft(kind: .ollama)

        draft.changeKind(to: .openAI, nameWasEdited: false)
        XCTAssertEqual(draft.name, "OpenAI", "an untouched name follows the provider")
        XCTAssertEqual(draft.baseURLText, "https://api.openai.com/v1")

        draft.name = "Work account"
        draft.changeKind(to: .gemini, nameWasEdited: true)
        XCTAssertEqual(draft.name, "Work account", "a chosen name must survive")
        XCTAssertEqual(
            draft.baseURLText,
            "https://generativelanguage.googleapis.com/v1beta/openai"
        )
    }

    // MARK: Adding and switching

    func testAddingUsesTheChosenNameAndSelectsIt() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .ollama)
        draft.name = "Local gemma"
        draft.modelID = "gemma4:latest"

        let added = model.addConfiguration(draft)

        XCTAssertEqual(added?.name, "Local gemma")
        XCTAssertEqual(model.activeConfigurationID, added?.id)
        XCTAssertEqual(model.baseURLText, "http://localhost:11434/v1")
        XCTAssertEqual(model.modelID, "gemma4:latest")
    }

    func testIncompleteDraftIsRefused() {
        let model = AISettingsViewModel()
        let draft = AISettingsViewModel.Draft(kind: .custom)

        XCTAssertNil(model.addConfiguration(draft))
        XCTAssertTrue(model.configurations.isEmpty)
    }

    func testDuplicateNamesAreDisambiguated() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .ollama)
        draft.name = "Local"
        draft.modelID = "gemma4:latest"

        let first = model.addConfiguration(draft)
        let second = model.addConfiguration(draft)

        XCTAssertEqual(first?.name, "Local")
        XCTAssertEqual(second?.name, "Local 2", "menu names must be tellable apart")
    }

    func testRenamingKeepsNamesDistinct() {
        let model = AISettingsViewModel()
        var a = AISettingsViewModel.Draft(kind: .ollama)
        a.name = "Local"
        a.modelID = "m1"
        let first = model.addConfiguration(a)!

        var b = AISettingsViewModel.Draft(kind: .openAI)
        b.name = "Hosted"
        b.apiKey = "sk-test"
        let second = model.addConfiguration(b)!

        model.renameConfiguration(id: second.id, to: "Local")
        XCTAssertEqual(model.configurations.last?.name, "Local 2")
        XCTAssertEqual(model.configurations.first?.name, "Local")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testSwitchingCarriesEachConfigurationsOwnKey() {
        let model = AISettingsViewModel()

        var local = AISettingsViewModel.Draft(kind: .ollama)
        local.name = "Local"
        local.modelID = "gemma4:latest"
        let localConfiguration = model.addConfiguration(local)!

        var hosted = AISettingsViewModel.Draft(kind: .openAI)
        hosted.name = "Hosted"
        hosted.apiKey = "sk-test"
        let hostedConfiguration = model.addConfiguration(hosted)!

        model.selectConfiguration(id: localConfiguration.id)
        XCTAssertEqual(model.baseURLText, "http://localhost:11434/v1")
        XCTAssertEqual(model.apiKey, "", "the local provider has no key")

        model.selectConfiguration(id: hostedConfiguration.id)
        XCTAssertEqual(model.baseURLText, "https://api.openai.com/v1")
        XCTAssertEqual(model.apiKey, "sk-test")
    }

    func testDeletingClearsSelectionAndKey() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        draft.name = "Hosted"
        draft.apiKey = "sk-test"
        let added = model.addConfiguration(draft)!

        model.deleteConfiguration(id: added.id)

        XCTAssertTrue(model.configurations.isEmpty)
        XCTAssertNil(model.activeConfigurationID)
        XCTAssertNil(model.secretSettings.apiKey(for: added.id))
    }

    // MARK: Persistence

    func testConfigurationsSurviveARoundTrip() throws {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .openRouter)
        draft.name = "Router"
        let added = model.addConfiguration(draft)!

        let encoded = try JSONEncoder().encode(model.aiSettings)
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: encoded)

        XCTAssertEqual(decoded.configurations.count, 1)
        XCTAssertEqual(decoded.activeConfigurationID, added.id)
        XCTAssertEqual(decoded.activeConfiguration?.name, "Router")
        XCTAssertEqual(decoded.activeConfiguration?.kind, .openRouter)
    }

    /// The feature was first shipped as "provider profiles"; settings written
    /// then must still load, since the decoder rejects unknown keys.
    func testLegacyProfileKeysStillDecode() throws {
        let id = UUID()
        let json = """
        {
          "mode": "off",
          "modelID": "gemma4:latest",
          "baseURL": "http://localhost:11434/v1",
          "profiles": [
            {"id":"\(id.uuidString)","name":"Local","kind":"ollama",
             "baseURL":"http://localhost:11434/v1","modelID":"gemma4:latest"}
          ],
          "activeProfileID": "\(id.uuidString)"
        }
        """

        let decoded = try JSONDecoder().decode(
            AIEndpointSettings.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.configurations.count, 1)
        XCTAssertEqual(decoded.activeConfigurationID, id)
        XCTAssertEqual(decoded.activeConfiguration?.name, "Local")
    }

    func testKeysAreNeverPartOfNonsecretSettings() throws {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        // Prefixed "test" so `Scripts/validate_phase0.py` recognizes the literal
        // as a fixture rather than a committed credential.
        let sentinel = "test-sk-must-not-persist"
        draft.apiKey = sentinel
        model.addConfiguration(draft)

        let json = String(
            decoding: try JSONEncoder().encode(model.appSettings),
            as: UTF8.self
        )
        XCTAssertFalse(
            json.contains(sentinel),
            "a credential must never reach AppSettings"
        )
    }

    // MARK: Fetch Models (from the sheet's draft)

    func testFetchModelsAsksTheDraftedEndpointWithTheTypedKey() async throws {
        let harness = SettingsProjectionTestHarness()
        var calls: [(AIEndpointSettings, AICredentialSnapshot?)] = []
        let model = AISettingsViewModel(host: harness.host, modelLister: { settings, credentials in
            calls.append((settings, credentials))
            return ["b-model", "a-model"]
        })
        var draft = AISettingsViewModel.Draft(kind: .openRouter)
        draft.apiKey = "  fixture-secret  "

        XCTAssertTrue(model.canDiscoverModels(for: draft))
        await model.discoverModels(for: draft)

        let (settings, credentials) = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(settings.baseURL?.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(settings.requestProfile, draft.requestProfile)
        XCTAssertEqual(settings.provider, .openAICompatible)
        XCTAssertEqual(credentials?.apiKey, "fixture-secret", "trimmed, as Verify & Save sends it")
        XCTAssertEqual(model.discoveredModels(for: draft), ["b-model", "a-model"])
        XCTAssertEqual(model.discoveryState(for: draft), .loaded(count: 2))
        XCTAssertEqual(draft.modelID, AIProviderKind.openRouter.suggestedModelID, "fetching never overwrites the model")
        // Fetching saves nothing, and rule 2: the key reaches no settings.
        XCTAssertTrue(harness.sent.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(model.appSettings), as: UTF8.self)
        XCTAssertFalse(json.contains("fixture-secret"))
    }

    func testAnEmptyKeyIsSentAsNoCredential() async {
        var received: AICredentialSnapshot? = AICredentialSnapshot(apiKey: "sentinel")
        let model = AISettingsViewModel(modelLister: { _, credentials in
            received = credentials
            return []
        })
        let draft = AISettingsViewModel.Draft(kind: .ollama)

        await model.discoverModels(for: draft)

        XCTAssertNil(received)
        XCTAssertEqual(model.discoveryState(for: draft), .loaded(count: 0))
    }

    func testEditingAConfigurationFetchesWithItsStoredKey() async throws {
        var received: AICredentialSnapshot?
        let model = AISettingsViewModel(modelLister: { _, credentials in
            received = credentials
            return ["x"]
        })
        var draft = AISettingsViewModel.Draft(kind: .groq)
        draft.apiKey = "fixture-stored"
        let saved = try XCTUnwrap(model.addConfiguration(draft))

        // As AIActionsForm opens the edit sheet: the key field is seeded
        // with the stored key and left untouched.
        let edit = AISettingsViewModel.Draft(configuration: saved, apiKey: model.apiKey(for: saved.id))
        await model.discoverModels(for: edit)

        XCTAssertEqual(received?.apiKey, "fixture-stored")
    }

    func testAFetchedListBelongsToTheEndpointItCameFrom() async {
        let model = AISettingsViewModel(modelLister: { _, _ in ["m"] })
        var draft = AISettingsViewModel.Draft(kind: .custom)
        draft.baseURLText = "http://localhost:8080/v1"
        await model.discoverModels(for: draft)
        XCTAssertEqual(model.discoveredModels(for: draft), ["m"])

        var moved = draft
        moved.baseURLText = "http://localhost:9090/v1"
        XCTAssertTrue(model.discoveredModels(for: moved).isEmpty, "another URL")
        XCTAssertEqual(model.discoveryState(for: moved), .idle)

        var reauthed = draft
        reauthed.authStyle = .apiKeyHeader
        XCTAssertTrue(model.discoveredModels(for: reauthed).isEmpty, "another auth style")

        var other = draft
        other.changeKind(to: .groq, nameWasEdited: false)
        XCTAssertTrue(model.discoveredModels(for: other).isEmpty, "another provider")

        var retyped = draft
        retyped.modelID = "something-else"
        XCTAssertEqual(model.discoveredModels(for: retyped), ["m"], "typing a model keeps the list")
    }

    func testResetForgetsTheListAndDropsAReplyInFlight() async {
        var model: AISettingsViewModel!
        model = AISettingsViewModel(modelLister: { _, _ in
            // The user changes the key while the request is out.
            model.resetModelDiscovery()
            return ["late"]
        })
        let draft = AISettingsViewModel.Draft(kind: .openAI)

        await model.discoverModels(for: draft)

        XCTAssertTrue(model.discoveredModels(for: draft).isEmpty)
        XCTAssertEqual(model.discoveryState(for: draft), .idle)
    }

    func testAnOlderFetchDoesNotOverwriteANewerOne() async {
        var model: AISettingsViewModel!
        var calls = 0
        let draft = AISettingsViewModel.Draft(kind: .openAI)
        model = AISettingsViewModel(modelLister: { _, _ in
            calls += 1
            if calls == 1 {
                // A second click lands before the first reply.
                await model.discoverModels(for: draft)
                return ["stale"]
            }
            return ["fresh"]
        })

        await model.discoverModels(for: draft)

        XCTAssertEqual(model.discoveredModels(for: draft), ["fresh"])
        XCTAssertEqual(model.discoveryState(for: draft), .loaded(count: 1))
    }

    func testFetchFailuresAreReportedAsScalarReasons() async throws {
        // One scripted failure per fetch, in order.
        var errors: [any Error] = [
            KVoiceError(code: .aiAuthentication, retryable: false, metadata: DiagnosticAttributes(httpStatus: 401)),
            KVoiceError(code: .aiHTTPError, retryable: false, metadata: DiagnosticAttributes(httpStatus: 404)),
            URLError(.notConnectedToInternet),
        ]
        let model = AISettingsViewModel(modelLister: { _, _ in throw errors.removeFirst() })
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        draft.apiKey = "fixture-secret"

        await model.discoverModels(for: draft)
        guard case .failed(let auth) = model.discoveryState(for: draft) else { return XCTFail("expected a failure") }
        XCTAssertTrue(auth.contains("401") && auth.contains("API key"), auth)
        XCTAssertTrue(model.discoveredModels(for: draft).isEmpty)

        await model.discoverModels(for: draft)
        guard case .failed(let notListed) = model.discoveryState(for: draft) else { return XCTFail("expected a failure") }
        XCTAssertTrue(notListed.contains("404") && notListed.contains("model ID"), notListed)

        await model.discoverModels(for: draft)
        guard case .failed(let raw) = model.discoveryState(for: draft) else { return XCTFail("expected a failure") }
        for message in [auth, notListed, raw] {
            XCTAssertFalse(message.contains("fixture-secret"))
            XCTAssertFalse(message.contains("api.openai.com"))
        }
    }

    func testFetchModelsIsNotOfferedWhereThereIsNoList() async {
        var calls = 0
        let model = AISettingsViewModel(modelLister: { _, _ in calls += 1; return ["x"] })
        var noURL = AISettingsViewModel.Draft(kind: .custom)
        noURL.baseURLText = ""
        var azure = AISettingsViewModel.Draft(kind: .azureOpenAI)
        azure.azureResource = "res"
        azure.azureDeployment = "dep"
        let drafts = [
            noURL,
            azure,
            AISettingsViewModel.Draft(kind: .anthropic),
            AISettingsViewModel.Draft(kind: .appleIntelligence),
            AISettingsViewModel.Draft(kind: .privateCloudCompute),
        ]
        for draft in drafts {
            XCTAssertFalse(model.canDiscoverModels(for: draft), "\(draft.kind)")
            await model.discoverModels(for: draft)
            guard case .failed = model.discoveryState(for: draft) else { return XCTFail("\(draft.kind)") }
        }
        XCTAssertEqual(calls, 0, "nothing is sent")
    }

    func testFilteringTheFetchedList() {
        let models = ["anthropic/claude-haiku-5.5", "google/gemini-3.5-flash-lite", "openai/gpt-6-luna"]
        XCTAssertEqual(AISettingsViewModel.filterModels(models, matching: ""), models)
        XCTAssertEqual(AISettingsViewModel.filterModels(models, matching: "  "), models)
        XCTAssertEqual(AISettingsViewModel.filterModels(models, matching: "GEMINI"), ["google/gemini-3.5-flash-lite"])
        XCTAssertEqual(AISettingsViewModel.filterModels(models, matching: "openai luna"), ["openai/gpt-6-luna"])
        XCTAssertEqual(AISettingsViewModel.filterModels(models, matching: "luna haiku"), [])
    }

    func testChoosingAFetchedModelFillsTheModelID() {
        var draft = AISettingsViewModel.Draft(kind: .openRouter)
        draft.chooseModel("google/gemini-3.5-flash-lite")
        XCTAssertEqual(draft.modelID, "google/gemini-3.5-flash-lite")
        XCTAssertEqual(draft.resolvedModelID, "google/gemini-3.5-flash-lite")
        XCTAssertEqual(draft.endpointSettings.modelID, "google/gemini-3.5-flash-lite", "what Verify & Save then tests")
    }

    // MARK: One commit per operation (review, 2026-09-16)

    private func setAICount(_ harness: SettingsProjectionTestHarness) -> Int {
        harness.sent.filter { if case .setAI = $0 { return true }; return false }.count
    }

    func testAddingAConfigurationSendsExactlyOneSetAI() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)
        var draft = AISettingsViewModel.Draft(kind: .ollama)
        draft.name = "Local"
        draft.modelID = "gemma4:latest"

        let added = model.addConfiguration(draft)

        XCTAssertNotNil(added)
        XCTAssertEqual(setAICount(harness), 1, "the new configuration and its selection commit together")
        XCTAssertEqual(harness.settings.ai.activeConfigurationID, added?.id)
        XCTAssertEqual(harness.settings.ai.configurations.map(\.id), [added?.id])
    }

    func testUpdatingTheActiveConfigurationSendsExactlyOneSetAI() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)
        var draft = AISettingsViewModel.Draft(kind: .ollama)
        draft.name = "Local"
        draft.modelID = "gemma4:latest"
        let added = model.addConfiguration(draft)!
        harness.clearRecords()

        var edit = AISettingsViewModel.Draft(configuration: added, apiKey: "")
        edit.modelID = "gemma5:latest"
        model.updateConfiguration(id: added.id, from: edit)

        XCTAssertEqual(setAICount(harness), 1, "the array update and the active endpoint following it commit together")
        XCTAssertEqual(model.modelID, "gemma5:latest")
        XCTAssertEqual(harness.settings.ai.configurations.first?.modelID, "gemma5:latest")
    }

    func testDeletingTheActiveConfigurationSendsExactlyOneSetAI() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)
        var draft = AISettingsViewModel.Draft(kind: .ollama)
        draft.name = "Local"
        draft.modelID = "gemma4:latest"
        let added = model.addConfiguration(draft)!
        harness.clearRecords()

        model.deleteConfiguration(id: added.id)

        XCTAssertEqual(setAICount(harness), 1, "removing it from the array and clearing activeConfigurationID commit together")
        XCTAssertTrue(harness.settings.ai.configurations.isEmpty)
        XCTAssertNil(harness.settings.ai.activeConfigurationID, "never left pointing at a configuration that no longer exists")
        XCTAssertNil(model.secretSettings.apiKey(for: added.id))
    }

    /// A refused add must not orphan a key into the secrets file for a
    /// configuration that was never actually saved (review, 2026-09-16).
    func testARefusedAddNeverWritesTheKeyIntoTheSecretsFile() {
        let harness = SettingsProjectionTestHarness()
        harness.gate = SettingsGate(settingsLoaded: false)
        let model = AISettingsViewModel(host: harness.host)
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        draft.name = "Hosted"
        draft.apiKey = "sk-test"

        let added = model.addConfiguration(draft)

        XCTAssertNil(added, "the .setAI was refused, so nothing was saved")
        XCTAssertTrue(model.configurations.isEmpty)
        XCTAssertTrue(model.secretSettings.configurationAPIKeys.isEmpty, "the refused add's key never reached configurationAPIKeys")
    }
}
