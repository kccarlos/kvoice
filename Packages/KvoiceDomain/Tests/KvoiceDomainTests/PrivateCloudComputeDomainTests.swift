import Foundation
import XCTest
@testable import KvoiceDomain

/// ADR-027: Private Cloud Compute at the domain seams — the third transport
/// and its kind, the coding rule that keeps it from being selected by
/// anything but the user's own active configuration, the edition and
/// signature refusal, the availability rows and the quota value.
final class PrivateCloudComputeDomainTests: XCTestCase {
    // MARK: Kind and transport

    func testTheKindIsItsOwnTransportWithNoEndpointFields() {
        let kind = AIProviderKind.privateCloudCompute
        XCTAssertEqual(kind.transport, .privateCloudCompute)
        XCTAssertNil(kind.defaultBaseURL)
        XCTAssertFalse(kind.expectsAPIKey, "no credential exists for it, so SecretSettings never gets an entry")
        XCTAssertNil(kind.apiKeyURL)
        XCTAssertNil(kind.credentialHint)
        XCTAssertTrue(kind.recommendedModels.isEmpty)
        XCTAssertEqual(kind.requestProfile, AIRequestProfile())
        XCTAssertEqual(kind.displayName, "Apple Intelligence (Private Cloud Compute)")
        XCTAssertTrue(AIConfiguration.preset(.privateCloudCompute).isUsable)
        XCTAssertFalse(AIProviderKind.endpointKinds.contains(.privateCloudCompute))
        XCTAssertTrue(DomainUserFacingCopy.displayNames.contains(kind.displayName))
    }

    func testTheTransportSaysWhatLeavesTheMac() {
        XCTAssertTrue(AIProviderTransport.openAICompatible.needsEndpointFields)
        XCTAssertFalse(AIProviderTransport.appleIntelligence.needsEndpointFields)
        XCTAssertFalse(AIProviderTransport.privateCloudCompute.needsEndpointFields)

        XCTAssertFalse(AIProviderTransport.appleIntelligence.leavesThisMac, "the one transport that never leaves")
        XCTAssertTrue(AIProviderTransport.privateCloudCompute.leavesThisMac)
        XCTAssertTrue(AIProviderTransport.openAICompatible.leavesThisMac)

        XCTAssertEqual(AIProviderTransport.appleIntelligence.fixedEndpointClass, .onDevice)
        XCTAssertEqual(AIProviderTransport.privateCloudCompute.fixedEndpointClass, .privateCloudCompute)
        XCTAssertNil(AIProviderTransport.openAICompatible.fixedEndpointClass)
    }

    // MARK: Coding

    func testAConfigurationEncodesOnlyIdentityAndDecodesBack() throws {
        let configuration = AIConfiguration(name: "Apple servers", kind: .privateCloudCompute)
        let data = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "name", "kind"])
        XCTAssertEqual(object["kind"] as? String, "privateCloudCompute")
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: data), configuration)
    }

    func testTheTransportRoundTripsWhileItsConfigurationIsActive() throws {
        let configuration = AIConfiguration(name: "Apple servers", kind: .privateCloudCompute)
        var settings = AIEndpointSettings(isEnabled: true)
        settings.configurations = [configuration]
        settings.apply(configuration: configuration)
        XCTAssertEqual(settings.provider, .privateCloudCompute)
        XCTAssertTrue(settings.canEnableProcessing)
        XCTAssertEqual(settings.mode, .polish)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AIEndpointSettings.self, from: data).provider, .privateCloudCompute)

        // AI Off is still Off: the transport never turns the switch on.
        settings.isEnabled = false
        XCTAssertEqual(settings.mode, .off)
    }

    /// The invariant that keeps Private Cloud Compute from being chosen by
    /// a file: the stored transport is honoured only while the active
    /// configuration is a Private Cloud Compute one.
    func testTheTransportIsNeverTakenFromAFileWithoutItsActiveConfiguration() throws {
        let orphan = """
        {"mode":"polish","modelID":"","promptConfiguration":{},"translationLanguage":{"bcp47":"en","displayName":"English"},
         "isEnabled":true,"provider":"privateCloudCompute"}
        """
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: Data(orphan.utf8))
        XCTAssertEqual(decoded.provider, .openAICompatible)
        XCTAssertEqual(decoded.mode, .off)

        // Private Cloud Compute stored while the on-device configuration is
        // the active one: never an upgrade to the network path.
        let onDevice = AIConfiguration(name: "On this Mac", kind: .appleIntelligence)
        let pcc = AIConfiguration(name: "Apple servers", kind: .privateCloudCompute)
        var crossed = AIEndpointSettings(isEnabled: true, provider: .privateCloudCompute)
        crossed.configurations = [onDevice, pcc]
        crossed.activeConfigurationID = onDevice.id
        XCTAssertEqual(
            try JSONDecoder().decode(AIEndpointSettings.self, from: JSONEncoder().encode(crossed)).provider,
            .openAICompatible
        )

        // And the reverse: the on-device transport under a Private Cloud
        // Compute configuration is not "on-device".
        var reverse = AIEndpointSettings(isEnabled: true, provider: .appleIntelligence)
        reverse.configurations = [onDevice, pcc]
        reverse.activeConfigurationID = pcc.id
        XCTAssertEqual(
            try JSONDecoder().decode(AIEndpointSettings.self, from: JSONEncoder().encode(reverse)).provider,
            .openAICompatible
        )
    }

    // MARK: Edition and signature

    func testOnlyTheAppStoreEditionOffersItAndOnlyWhenEntitled() {
        XCTAssertFalse(DistributionEdition.developerID.offersPrivateCloudCompute)
        XCTAssertTrue(DistributionEdition.appStore.offersPrivateCloudCompute)

        XCTAssertEqual(DistributionEdition.developerID.privateCloudComputeRefusal(isEntitled: true), .notInThisEdition,
                       "the edition decides first, whatever the signature says")
        XCTAssertEqual(DistributionEdition.developerID.privateCloudComputeRefusal(isEntitled: false), .notInThisEdition)
        XCTAssertEqual(DistributionEdition.appStore.privateCloudComputeRefusal(isEntitled: false), .buildNotEntitled)
        XCTAssertNil(DistributionEdition.appStore.privateCloudComputeRefusal(isEntitled: true))
    }

    // MARK: Availability rows

    private func pccSettings(enabled: Bool = true) -> AppSettings {
        var settings = AppSettings()
        let configuration = AIConfiguration(name: "Apple servers", kind: .privateCloudCompute)
        settings.ai.configurations = [configuration]
        settings.ai.apply(configuration: configuration)
        settings.ai.isEnabled = enabled
        return settings
    }

    private func row(_ key: SettingKey, settings: AppSettings, environment: EnvironmentProfile) -> SettingAvailability {
        SettingsAvailability.availability(key: key, settings: settings, environment: environment, gate: SettingsGate())
    }

    func testTheConfigurationRowFollowsTheObservedAvailability() {
        let settings = pccSettings()
        XCTAssertEqual(row(.aiPrivateCloudComputeConfiguration, settings: settings, environment: .unknown), .enabled)
        for reason in AIProviderUnavailableReason.allCases {
            XCTAssertEqual(
                row(.aiPrivateCloudComputeConfiguration, settings: settings,
                    environment: EnvironmentProfile(privateCloudComputeAvailability: .unavailable(reason))),
                .disabled(reason: reason.message)
            )
        }
        // The two Apple rows read their own facts only.
        let onDeviceDown = EnvironmentProfile(appleIntelligenceAvailability: .unavailable(.modelNotReady))
        XCTAssertEqual(row(.aiPrivateCloudComputeConfiguration, settings: settings, environment: onDeviceDown), .enabled)
        let pccDown = EnvironmentProfile(privateCloudComputeAvailability: .unavailable(.notInThisEdition))
        XCTAssertEqual(row(.aiAppleIntelligenceConfiguration, settings: settings, environment: pccDown), .enabled)
    }

    func testTheActionSettingsRowRefusesWhenTheActiveProviderIsPrivateCloudComputeAndUnavailable() {
        let refused = EnvironmentProfile(privateCloudComputeAvailability: .unavailable(.buildNotEntitled))
        XCTAssertEqual(
            row(.aiActionSettings, settings: pccSettings(), environment: refused),
            .disabled(reason: AIProviderUnavailableReason.buildNotEntitled.message)
        )
        XCTAssertEqual(
            row(.aiActionSettings, settings: pccSettings(enabled: false), environment: refused),
            .disabled(reason: SettingAvailabilityReason.aiActionsOff.message),
            "the master switch comes first"
        )
        // A reached quota is not a refusal: the model stays available.
        let limited = EnvironmentProfile(
            privateCloudComputeAvailability: .available,
            privateCloudComputeQuota: AIProviderQuota(status: .limitReached)
        )
        XCTAssertEqual(row(.aiActionSettings, settings: pccSettings(), environment: limited), .enabled)
    }

    // MARK: Quota and copy

    func testTheQuotaSpeaksOnlyNearOrAtTheLimit() {
        XCTAssertNil(AIProviderQuota(status: .belowLimit).message)
        XCTAssertEqual(AIProviderQuota(status: .approachingLimit).message, AIProviderQuota.approachingLimitMessage)
        XCTAssertEqual(AIProviderQuota(status: .limitReached).message, AIProviderQuota.limitReachedMessage)
        XCTAssertTrue(DomainUserFacingCopy.messages.contains(AIProviderQuota.approachingLimitMessage))
        XCTAssertTrue(DomainUserFacingCopy.messages.contains(AIProviderQuota.limitReachedMessage))
        XCTAssertTrue(DomainUserFacingCopy.messages.contains(KVoiceErrorCode.aiQuotaExhausted.userFacingMessage))
        XCTAssertEqual(KVoiceErrorCode.aiQuotaExhausted.rawValue, "AI-QUOTA-EXHAUSTED")
    }

    func testTheEnvironmentProfileCarriesBothFacts() {
        XCTAssertNil(EnvironmentProfile.unknown.privateCloudComputeAvailability)
        XCTAssertNil(EnvironmentProfile.unknown.privateCloudComputeQuota)
        let quota = AIProviderQuota(status: .approachingLimit, resetDate: Date(timeIntervalSince1970: 0), canRequestIncrease: true)
        let profile = EnvironmentProfile(
            privateCloudComputeAvailability: .unavailable(.systemNotReady),
            privateCloudComputeQuota: quota
        )
        XCTAssertEqual(profile.privateCloudComputeAvailability, .unavailable(.systemNotReady))
        XCTAssertEqual(profile.privateCloudComputeQuota, quota)
    }
}
