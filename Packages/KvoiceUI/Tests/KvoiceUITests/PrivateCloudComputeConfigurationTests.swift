import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-027 at the settings-page seams: the sheet's third type, the view
/// model's transport bookkeeping, the failure copy that never talks about
/// an endpoint, the quota line the row and the sheet show, the diagnostics
/// report line, and a render smoke test.
@MainActor
final class PrivateCloudComputeConfigurationTests: XCTestCase {
    // MARK: Draft and view model

    func testTheThirdTypeNeedsOnlyANameAndCarriesItsTransport() {
        var draft = AISettingsViewModel.Draft(kind: .openAI)
        draft.transport = .privateCloudCompute
        XCTAssertEqual(draft.kind, .privateCloudCompute)
        XCTAssertEqual(draft.name, "Apple Intelligence (Private Cloud Compute)")
        XCTAssertTrue(draft.isComplete)
        XCTAssertEqual(draft.endpointSettings.provider, .privateCloudCompute)
        XCTAssertNil(draft.endpointSettings.baseURL)

        draft.transport = .appleIntelligence
        XCTAssertEqual(draft.kind, .appleIntelligence, "switching between the two Apple types re-seeds the kind")
        draft.transport = .openAICompatible
        XCTAssertEqual(draft.kind, .ollama)
    }

    func testAddingSelectingAndDeletingKeepTheTransportHonest() {
        let model = AISettingsViewModel()
        var onDevice = AISettingsViewModel.Draft(kind: .appleIntelligence)
        onDevice.name = "On this Mac"
        let device = model.addConfiguration(onDevice)!
        var pccDraft = AISettingsViewModel.Draft(kind: .privateCloudCompute)
        pccDraft.name = "Apple servers"
        let pcc = model.addConfiguration(pccDraft)!
        XCTAssertEqual(model.provider, .privateCloudCompute, "the user just added and chose it")
        XCTAssertTrue(model.canTestConfiguration)
        XCTAssertNil(model.secretSettings.configurationAPIKeys[pcc.id.uuidString], "no key exists for it")

        model.selectConfiguration(id: device.id)
        XCTAssertEqual(model.provider, .appleIntelligence)
        model.selectConfiguration(id: pcc.id)
        XCTAssertEqual(model.provider, .privateCloudCompute)

        model.deleteConfiguration(id: pcc.id)
        XCTAssertEqual(model.provider, .openAICompatible,
                       "deleting the active Private Cloud Compute configuration never falls to another Apple transport")
        XCTAssertFalse(model.host.settings.ai.canEnableProcessing)
    }

    func testTheConfigurationTestReachesTheTesterWithThisTransportAndNoKey() async {
        var tested: [(AIEndpointSettings, AICredentialSnapshot?)] = []
        let model = AISettingsViewModel(configurationTester: { settings, credentials in
            tested.append((settings, credentials))
        })
        var draft = AISettingsViewModel.Draft(kind: .privateCloudCompute)
        draft.name = "Apple servers"
        model.addConfiguration(draft)
        await model.testConfiguration()
        XCTAssertEqual(tested.first?.0.provider, .privateCloudCompute)
        XCTAssertNil(tested.first?.1)
    }

    func testTheFailureCopyNeverTalksAboutAnEndpoint() {
        func pccError(_ code: KVoiceErrorCode) -> KVoiceError {
            var attributes = DiagnosticAttributes()
            attributes.endpointClass = .privateCloudCompute
            return KVoiceError(code: code, retryable: false, metadata: attributes)
        }
        let codes: [KVoiceErrorCode] = [
            .aiProviderUnavailable, .aiUnreachable, .aiTimeout, .aiQuotaExhausted,
            .aiRateLimited, .aiMalformedResponse, .aiEmptyResponse, .aiOversizedResponse,
        ]
        for code in codes {
            let text = AISettingsViewModel.failureDescription(for: pccError(code))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("endpoint"), "\(code): \(text)")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("URL"), "\(code): \(text)")
        }
        XCTAssertEqual(
            AISettingsViewModel.failureDescription(for: pccError(.aiQuotaExhausted)),
            "Today's Private Cloud Compute limit is reached."
        )
        // The on-device copy is unchanged.
        XCTAssertEqual(
            AISettingsViewModel.failureDescription(for: KVoiceError(code: .aiProviderUnavailable)),
            "Apple Intelligence isn't available on this Mac right now."
        )
    }

    // MARK: Availability model and quota line

    func testTheQuotaLineSpeaksNearOrAtTheLimitOnly() {
        let model = SettingsAvailabilityModel()
        XCTAssertNil(model.privateCloudComputeQuotaLine)
        model.update(privateCloudComputeQuota: AIProviderQuota(status: .belowLimit))
        XCTAssertNil(model.privateCloudComputeQuotaLine)
        model.update(privateCloudComputeQuota: AIProviderQuota(status: .approachingLimit))
        XCTAssertEqual(model.privateCloudComputeQuotaLine, DomainCopy.localized(AIProviderQuota.approachingLimitMessage))
        model.update(privateCloudComputeQuota: AIProviderQuota(status: .limitReached))
        XCTAssertEqual(model.privateCloudComputeQuotaLine, DomainCopy.localized(AIProviderQuota.limitReachedMessage))
        model.update(privateCloudComputeQuota: AIProviderQuota(status: .limitReached, resetDate: Date(timeIntervalSince1970: 86_400)))
        let withReset = try? XCTUnwrap(model.privateCloudComputeQuotaLine)
        XCTAssertTrue(withReset?.hasPrefix(DomainCopy.localized(AIProviderQuota.limitReachedMessage)) == true)
        XCTAssertNotEqual(withReset, DomainCopy.localized(AIProviderQuota.limitReachedMessage), "the reset time is appended")
    }

    func testTheSheetRefusesToSaveOnlyUnderAStaticRefusal() {
        let model = SettingsAvailabilityModel()
        XCTAssertNil(model.savingRefusal(for: .privateCloudCompute), "unknown refusal: saving allowed")
        for refusal in [AIProviderUnavailableReason.notInThisEdition, .buildNotEntitled] {
            model.update(privateCloudComputeStaticRefusal: refusal)
            XCTAssertEqual(model.savingRefusal(for: .privateCloudCompute), DomainCopy.localized(refusal.message))
            XCTAssertNil(model.savingRefusal(for: .appleIntelligence), "other types are never blocked by it")
            XCTAssertNil(model.savingRefusal(for: .openAICompatible))
        }
        model.update(privateCloudComputeStaticRefusal: nil)
        XCTAssertNil(model.savingRefusal(for: .privateCloudCompute), "a passing state does not block saving")
    }

    func testTheRowReadsItsOwnKey() {
        let model = SettingsAvailabilityModel(table: [
            .aiPrivateCloudComputeConfiguration: .disabled(reason: AIProviderUnavailableReason.notInThisEdition.message)
        ])
        XCTAssertFalse(model.isEnabled(.aiPrivateCloudComputeConfiguration))
        XCTAssertTrue(model.isEnabled(.aiAppleIntelligenceConfiguration))
        XCTAssertEqual(
            model.disabledReason(.aiPrivateCloudComputeConfiguration),
            DomainCopy.localized(AIProviderUnavailableReason.notInThisEdition.message)
        )
    }

    // MARK: Diagnostics report

    func testTheReportNamesTheTransportAndTheAvailabilityCaseOnly() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "1.2.3",
            buildNumber: "456",
            macOSVersion: "27.0",
            activationPolicy: "accessory",
            modelState: .absent,
            shortcut: nil,
            shortcutRegistration: .unregistered,
            recordingInteraction: .pushToTalk,
            aiMode: .polish,
            aiEndpoint: nil,
            aiProvider: .privateCloudCompute,
            privateCloudComputeAvailability: .unavailable(.buildNotEntitled),
            historyEnabled: true,
            escapeMonitorStatus: "active",
            typedInsertionEnabled: true
        )
        let report = DiagnosticsReport.render(snapshot, generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("AI provider: privateCloudCompute"), report)
        XCTAssertTrue(report.contains("AI endpoint: private-cloud-compute"), report)
        XCTAssertTrue(report.contains("Private Cloud Compute: unavailable (buildNotEntitled)"), report)
    }

    // MARK: Render smoke

    func testTheFormAndTheSheetRenderWithAPrivateCloudComputeConfiguration() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .privateCloudCompute)
        draft.name = "Apple servers"
        model.addConfiguration(draft)
        let availability = SettingsAvailabilityModel(edition: .appStore)
        availability.update(privateCloudComputeQuota: AIProviderQuota(status: .approachingLimit, canRequestIncrease: true))
        _ = AIActionsForm(configurations: model, actions: PromptModeSettingsViewModel(), availability: availability).body
        _ = AIConfigurationSheet(
            viewModel: model,
            draft: .constant(draft),
            editingID: nil,
            availability: availability,
            onDismiss: {}
        ).body
    }
}
