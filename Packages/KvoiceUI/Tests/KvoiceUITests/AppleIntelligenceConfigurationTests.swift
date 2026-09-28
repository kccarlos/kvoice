import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-024 at the settings-page seams: the sheet's type choice (a draft
/// whose kind is `appleIntelligence` needs only a name), the view model's
/// transport bookkeeping through add / select / update / delete, the
/// configuration test gate, the failure copy, and the availability row the
/// list and the sheet read.
@MainActor
final class AppleIntelligenceConfigurationTests: XCTestCase {
    // MARK: Draft

    func testAnOnDeviceDraftNeedsOnlyANameAndCarriesTheTransport() {
        var draft = AISettingsViewModel.Draft(kind: .appleIntelligence)
        XCTAssertEqual(draft.transport, .appleIntelligence)
        XCTAssertEqual(draft.name, "Apple Intelligence (on-device)")
        XCTAssertEqual(draft.baseURLText, "")
        XCTAssertEqual(draft.modelID, "")
        XCTAssertTrue(draft.isComplete, "no endpoint or model to fill in")
        XCTAssertEqual(draft.endpointSettings.provider, .appleIntelligence)
        XCTAssertNil(draft.endpointSettings.baseURL)

        draft.name = "  "
        XCTAssertFalse(draft.isComplete, "a name is still required")
    }

    func testTheTypeChoiceReseedsTheKindBothWays() {
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        draft.transport = .appleIntelligence
        XCTAssertEqual(draft.kind, .appleIntelligence)
        XCTAssertEqual(draft.name, "Apple Intelligence (on-device)")
        XCTAssertTrue(draft.isComplete)

        draft.transport = .openAICompatible
        XCTAssertEqual(draft.kind, .ollama, "back to the first endpoint preset")
        XCTAssertEqual(draft.transport, .openAICompatible)
        XCTAssertEqual(draft.baseURLText, "http://localhost:11434/v1")
        XCTAssertFalse(draft.isComplete, "Ollama still needs a model")

        // Setting the transport it already has changes nothing.
        draft.kind = .gemini
        draft.transport = .openAICompatible
        XCTAssertEqual(draft.kind, .gemini)

        // A name the user typed survives the switch in both directions —
        // including on Edit, where the draft opens with the saved name.
        draft.name = "Mine"
        draft.transport = .appleIntelligence
        XCTAssertEqual(draft.kind, .appleIntelligence)
        XCTAssertEqual(draft.name, "Mine")
        draft.transport = .openAICompatible
        XCTAssertEqual(draft.name, "Mine")
        let saved = AIConfiguration(name: "Work Mac", kind: .appleIntelligence)
        var editing = AISettingsViewModel.Draft(configuration: saved, apiKey: "")
        editing.transport = .openAICompatible
        XCTAssertEqual(editing.name, "Work Mac", "editing must not rename the configuration")
    }

    func testAnExistingOnDeviceConfigurationOpensAsAnOnDeviceDraft() {
        let configuration = AIConfiguration(name: "On this Mac", kind: .appleIntelligence)
        let draft = AISettingsViewModel.Draft(configuration: configuration, apiKey: "")
        XCTAssertEqual(draft.transport, .appleIntelligence)
        XCTAssertEqual(draft.name, "On this Mac")
        XCTAssertTrue(draft.isComplete)
    }

    // MARK: View model

    func testAddingAnOnDeviceConfigurationSetsTheTransportAndNoKey() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .appleIntelligence)
        draft.name = "On this Mac"

        let added = model.addConfiguration(draft)
        XCTAssertEqual(added?.kind, .appleIntelligence)
        XCTAssertEqual(model.activeConfigurationID, added?.id)
        XCTAssertEqual(model.provider, .appleIntelligence)
        XCTAssertEqual(model.host.settings.ai.provider, .appleIntelligence)
        XCTAssertNil(model.host.settings.ai.baseURL)
        XCTAssertEqual(model.host.settings.ai.modelID, "")
        XCTAssertTrue(model.host.settings.ai.canEnableProcessing)
        XCTAssertTrue(model.canTestConfiguration, "the test needs nothing filled in")
        XCTAssertNil(model.secretSettings.configurationAPIKeys[added!.id.uuidString], "nothing to store")
        XCTAssertEqual(model.apiKey, "")
    }

    func testSelectingSwitchesTheTransportBothWays() {
        let model = AISettingsViewModel()
        var ollama = AISettingsViewModel.Draft(kind: .ollama)
        ollama.modelID = "gemma4:latest"
        let endpoint = model.addConfiguration(ollama)!
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "On this Mac"
        let device = model.addConfiguration(onDevice)!
        XCTAssertEqual(model.provider, .appleIntelligence)

        model.selectConfiguration(id: endpoint.id)
        XCTAssertEqual(model.provider, .openAICompatible)
        XCTAssertEqual(model.modelID, "gemma4:latest")
        XCTAssertTrue(model.canTestConfiguration)

        model.selectConfiguration(id: device.id)
        XCTAssertEqual(model.provider, .appleIntelligence)
        XCTAssertEqual(model.modelID, "")
        XCTAssertNil(model.baseURL)
        XCTAssertTrue(model.canTestConfiguration)
    }

    func testEditingTheActiveConfigurationIntoTheOtherTypeFollowsIt() {
        let model = AISettingsViewModel()
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "Mine"
        let saved = model.addConfiguration(onDevice)!

        var edited = AISettingsViewModel.Draft(configuration: saved, apiKey: "")
        edited.transport = .openAICompatible
        edited.modelID = "gemma4:latest"
        model.updateConfiguration(id: saved.id, from: edited)
        XCTAssertEqual(model.configurations.first?.kind, .ollama)
        XCTAssertEqual(model.provider, .openAICompatible)
        XCTAssertEqual(model.host.settings.ai.baseURL?.absoluteString, "http://localhost:11434/v1")
    }

    func testDeletingTheActiveOnDeviceConfigurationLeavesAIUnconfigured() {
        let model = AISettingsViewModel()
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "Mine"
        let saved = model.addConfiguration(onDevice)!
        model.isEnabled = true
        XCTAssertEqual(model.mode, .polish)

        model.deleteConfiguration(id: saved.id)
        XCTAssertTrue(model.configurations.isEmpty)
        XCTAssertEqual(model.provider, .openAICompatible, "the on-device transport does not outlive its configuration")
        XCTAssertFalse(model.host.settings.ai.canEnableProcessing)
        XCTAssertEqual(model.mode, .off)
        XCTAssertFalse(model.canTestConfiguration)
    }

    func testTheConfigurationTestReachesTheTesterWithTheOnDeviceTransportAndNoKey() async {
        var tested: [(AIEndpointSettings, AICredentialSnapshot?)] = []
        let model = AISettingsViewModel(configurationTester: { settings, credentials in
            tested.append((settings, credentials))
        })
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "Mine"
        model.addConfiguration(onDevice)
        await model.testConfiguration()
        XCTAssertEqual(model.testState, .succeeded)
        XCTAssertEqual(tested.count, 1)
        XCTAssertEqual(tested.first?.0.provider, .appleIntelligence)
        XCTAssertNil(tested.first?.1)

        // Verify & Save on a draft carries the transport the same way.
        var another = AISettingsViewModel.Draft(kind: .appleIntelligence)
        another.name = "Second"
        let saved = await model.verifyAndSave(another)
        XCTAssertEqual(saved?.kind, .appleIntelligence)
        XCTAssertEqual(tested.last?.0.provider, .appleIntelligence)
    }

    func testTheFailureCopyNamesTheOnDeviceCodes() {
        XCTAssertEqual(
            AISettingsViewModel.failureDescription(for: KVoiceError(code: .aiProviderUnavailable)),
            "Apple Intelligence isn't available on this Mac right now."
        )
        XCTAssertEqual(
            AISettingsViewModel.failureDescription(for: KVoiceError(code: .aiInputTooLong)),
            "The request did not fit the on-device model's context window."
        )
    }

    // MARK: Availability row

    func testTheAvailabilityModelCarriesTheOnDeviceRow() {
        let model = SettingsAvailabilityModel()
        XCTAssertTrue(model.isEnabled(.aiAppleIntelligenceConfiguration), "a preview or a shell-less build sees enabled")
        model.update([.aiAppleIntelligenceConfiguration: .disabled(reason: AIProviderUnavailableReason.appleIntelligenceNotEnabled.message)])
        XCTAssertFalse(model.isEnabled(.aiAppleIntelligenceConfiguration))
        XCTAssertEqual(
            model.disabledReason(.aiAppleIntelligenceConfiguration),
            DomainCopy.localized(AIProviderUnavailableReason.appleIntelligenceNotEnabled.message)
        )
    }

    func testTheStatusPanelChooserAndSheetRenderWithAnOnDeviceConfiguration() {
        // Smoke: the views build with an on-device configuration present.
        let model = AISettingsViewModel()
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "Mine"
        model.addConfiguration(onDevice)
        let availability = SettingsAvailabilityModel(table: [
            .aiAppleIntelligenceConfiguration: .disabled(reason: AIProviderUnavailableReason.modelNotReady.message)
        ])
        _ = AIActionsForm(configurations: model, actions: PromptModeSettingsViewModel(), availability: availability).body
        var draft = AISettingsViewModel.Draft(kind: .appleIntelligence)
        _ = AIConfigurationSheet(
            viewModel: model,
            draft: .init(get: { draft }, set: { draft = $0 }),
            editingID: nil,
            availability: availability,
            onDismiss: {}
        ).body
    }
}
