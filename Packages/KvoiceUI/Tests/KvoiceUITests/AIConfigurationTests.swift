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
        XCTAssertEqual(draft.modelID, "openai/gpt-4o-mini")
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

    // MARK: Discovery

    func testDiscoveryPopulatesTheListAndPrefillsWhenEmpty() async {
        let model = AISettingsViewModel(modelLister: { _, _ in ["b-model", "a-model"] })
        model.baseURLText = "http://localhost:11434"
        model.modelID = ""

        await model.discoverModels()

        XCTAssertEqual(model.discoveredModels, ["b-model", "a-model"])
        XCTAssertEqual(model.discoveryState, .loaded(count: 2))
        XCTAssertEqual(model.modelID, "b-model")
    }

    func testDiscoveryDoesNotOverwriteAChosenModel() async {
        let model = AISettingsViewModel(modelLister: { _, _ in ["other"] })
        model.baseURLText = "http://localhost:11434"
        model.modelID = "gemma4:latest"

        await model.discoverModels()

        XCTAssertEqual(model.modelID, "gemma4:latest")
    }

    func testDiscoveryFailureIsReportedWithoutDetail() async {
        let model = AISettingsViewModel(
            modelLister: { _, _ in throw KVoiceError(code: .aiUnreachable) }
        )
        model.baseURLText = "http://localhost:11434"

        await model.discoverModels()

        XCTAssertEqual(model.discoveryState, .failed)
        XCTAssertTrue(model.discoveredModels.isEmpty)
    }

    func testDiscoveryRequiresABaseURL() async {
        let model = AISettingsViewModel(modelLister: { _, _ in ["x"] })
        model.baseURLText = ""

        XCTAssertFalse(model.canDiscoverModels)
        await model.discoverModels()
        XCTAssertEqual(model.discoveryState, .failed)
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
